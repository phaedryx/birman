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
        @rules = {}
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
        when Choice then matcher.alts.filter_map { of(_1) }.reduce { |a, b| a == b ? a : :poly }
        when Not, And then :nil
        when Both then of(matcher.right)
        when Const then constant(matcher.constant)
        when Send then SENDS.fetch(matcher.method_name, :poly)
        when To then :node
        when Infix then of(matcher.operand) == :node ? :node : :poly
        when Ref then rule(matcher.name)
        when Label, Quiet, Named, Lexeme then of(matcher.inner)
        else :poly
        end
      end

      private

      def seq(matcher)
        return of(matcher.parts[matcher.only_at]) if matcher.only_at

        matcher.parts.any?(&:capture_key) ? :hash : :array
      end

      def constant(value)
        { String => :str, Integer => :int, Float => :float, Symbol => :sym, NilClass => :nil }
          .fetch(value.class, :poly)
      end

      # A rule refers to itself through others (expr -> atom -> expr), so
      # a rule met again while its type is being worked out counts as
      # adding nothing: the other alternatives decide.
      def rule(name)
        return @rules[name] if @rules.key?(name)

        @rules[name] = nil
        type = of(@grammar.matcher_for(name))
        @rules[name] = type
      end
    end
  end
end
