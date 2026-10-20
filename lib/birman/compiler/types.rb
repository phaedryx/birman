# frozen_string_literal: true

module Birman
  class Compiler
    # A coarse static type for each matcher's value, so every value
    # instance variable starts as a literal of the type it will hold
    # (Spinel boxes a variable whose writes disagree). :poly means it
    # varies, or isn't known; nil, nodes and :poly all start as nil.
    # [class.Compiler.Types]
    # purpose = "Infers the type a matcher's value has, for initializers"
    class Types
      INITIAL = { str: '""', int: "0", float: "0.0", sym: ':""', array: "[]", hash: "{}" }.freeze

      SENDS = { to_i: :int, to_f: :float, to_sym: :sym, to_s: :str, join: :str, to_h: :hash,
                upcase: :str, downcase: :str, strip: :str, to_a: :array }.freeze

      def initialize(grammar)
        @grammar = grammar
      end

      # The initializer literal for a value of matcher's type.
      def initial(matcher) = INITIAL.fetch(of(matcher), "nil")

      def of(matcher) # rubocop:disable Metrics
        case matcher
        when Str, Pat then :str
        when Lit then of(@grammar.literal_matcher(matcher.text))
        when Seq then seq(matcher)
        when Pick then of(matcher.parts[matcher.index])
        when SepBy, Rep then :array
        when Choice then matcher.alts.map { of(_1) }.reduce { |a, b| join(a, b) }
        when Not, And then :nil
        when Both then of(matcher.right)
        when Const then constant(matcher.constant)
        when Send then SENDS.fetch(matcher.method_name, :poly)
        when To then :node
        when Infix then infix(of(matcher.operand))
        when Ref then rules.fetch(matcher.name, :poly)
        when Label, Check, Quiet, Named, Lexeme then of(matcher.inner)
        else :poly
        end
      end

      # A String, or nil where it's optional: str.maybe.
      def str_or_nil?(matcher, seen = {})
        case matcher
        when Maybe then of(matcher.inner) == :str
        when Label, Check, Quiet, Named, Lexeme then str_or_nil?(matcher.inner, seen)
        when Ref
          !seen.key?(matcher.name) && (seen[matcher.name] = true) &&
            str_or_nil?(@grammar.matcher_for(matcher.name), seen)
        else false
        end
      end

      private

      def rules = @rules ||= solve

      def seq(matcher)
        return of(matcher.parts[matcher.only_at]) if matcher.only_at

        matcher.parts.any?(&:capture_key) ? :hash : :array
      end

      def constant(value)
        { String => :str, Integer => :int, Float => :float, Symbol => :sym, NilClass => :nil }
          .fetch(value.class, :poly)
      end

      # Every rule's type at once, so none depends on which was asked about
      # first: starting from nothing known (nil) for each, a rule's type is
      # widened by what its body gives until nothing changes. Rules refer
      # to each other in cycles (expr -> atom -> expr); one that still
      # gives nothing (it only recurses) is :poly.
      def solve
        names = rule_names
        @rules = names.to_h { [_1, nil] }
        changed = true
        while changed
          changed = false
          names.each do |name|
            type = join(@rules[name], of(@grammar.matcher_for(name)))
            changed ||= type != @rules[name]
            @rules[name] = type
          end
        end
        @rules.transform_values { _1 || :poly }
      end

      # The rules reachable from the root and the ignore rule.
      def rule_names
        names = []
        queue = [@grammar.class.root, @grammar.class.ignore].compact
        while (name = queue.shift)
          next if names.include?(name)

          names << name
          queue.concat(refs(@grammar.matcher_for(name)))
        end
        names
      end

      # Rule names a matcher refers to (custom matchers, which the emitter
      # refuses, refer to none).
      def refs(value)
        case value
        when Ref then [value.name]
        when Lit then refs(@grammar.literal_matcher(value.text))
        when Data then value.to_h.values.flat_map { refs(_1) }
        when Array then value.flat_map { refs(_1) }
        else []
        end
      end

      # The type of a value that is either: nil is nothing known yet.
      def join(one, other)
        return other if one.nil?
        return one if other.nil? || one == other

        :poly
      end

      def infix(operand) = operand.nil? || operand == :node ? operand : :poly
    end
  end
end
