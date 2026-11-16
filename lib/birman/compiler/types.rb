# frozen_string_literal: true

module Birman
  class Compiler
    # A coarse static type for each matcher's value, so every value
    # instance variable starts as a literal of the type it will hold
    # (Spinel boxes a variable whose writes disagree). :poly means it
    # varies, or isn't known; nil, nodes and :poly all start as nil. A
    # recover's value may be an ErrorNode, and over one that recovered,
    # .map and .means keep their inner value: both are :poly.
    # [class.Compiler.Types]
    # purpose = "Infers the type a matcher's value has, for initializers"
    class Types
      INITIAL = { str: '""', int: "0", float: "0.0", sym: ':""', array: "[]", hash: "{}" }.freeze

      SENDS = { to_i: :int, to_f: :float, to_sym: :sym, to_s: :str, join: :str, to_h: :hash,
                upcase: :str, downcase: :str, strip: :str, to_a: :array }.freeze

      # entries: rules the parser may start at besides the root.
      def initialize(grammar, entries = [])
        @grammar = grammar
        @entries = entries
      end

      # The initializer literal for a value of matcher's type.
      def initial(matcher) = INITIAL.fetch(of(matcher), "nil")

      def of(matcher) # rubocop:disable Metrics
        case matcher
        when Str, Pat, Text, Upto then :str
        when Lit then of(@grammar.literal_matcher(matcher.str))
        when Nocase then of(@grammar.nocase_matcher(matcher.str))
        when Seq then seq(matcher)
        when Pick then of(matcher.parts[matcher.index])
        when SepBy, Rep then :array
        when Captures then :hash
        when Choice then matcher.alts.map { of(_1) }.reduce { |a, b| join(a, b) }
        when Not, And then :nil
        when Both then of(matcher.right)
        when Recover then :poly
        when Const then recovers?(matcher.inner) ? :poly : constant(matcher.constant)
        when Send then recovers?(matcher.inner) ? :poly : SENDS.fetch(matcher.method_name, :poly)
        when To then recovers?(matcher.inner) ? :poly : :node # see To: maybe the value passed on
        when SpannedMatcher then :spanned
        when Operators then infix(of(matcher.operand))
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

      # Can matcher's match record errors, by recovering (see
      # Matcher#recover) or calling a rule that does? Only then can it
      # change the error log. If the ignore rule can, any lexeme can, so
      # anything is taken to.
      def recovers?(matcher)
        ignore = @grammar.class.ignore
        recovering_rules.key?(ignore) || recover_in?(matcher) || refs(matcher).any? { recovering_rules.key?(_1) }
      end

      # Does any rule the parser reaches recover?
      def any_recovers? = !recovering_rules.empty?

      private

      def rules = @rules ||= solve

      # The rules that can record errors: those with a recover of their
      # own, and those calling one, found by widening until nothing
      # changes (rules call each other in cycles).
      def recovering_rules
        return @recovering_rules if @recovering_rules

        found = rule_names.select { recover_in?(@grammar.matcher_for(_1)) }.to_h { [_1, true] }
        loop do
          callers = (rule_names - found.keys).select { |name| refs(@grammar.matcher_for(name)).any? { found.key?(_1) } }
          break if callers.empty?

          callers.each { found[_1] = true }
        end
        @recovering_rules = found
      end

      # A Recover anywhere in value, without following Refs.
      def recover_in?(value)
        case value
        when Recover then true
        when Lit then recover_in?(@grammar.literal_matcher(value.str))
        when Nocase then recover_in?(@grammar.nocase_matcher(value.str))
        when Data then value.to_h.values.any? { recover_in?(_1) }
        when Array then value.any? { recover_in?(_1) }
        else false
        end
      end

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

      # The rules reachable from the root, the ignore rule and the entries.
      def rule_names
        names = []
        queue = [@grammar.class.root, @grammar.class.ignore, *@entries].compact
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
        when Lit then refs(@grammar.literal_matcher(value.str))
        when Nocase then refs(@grammar.nocase_matcher(value.str))
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
