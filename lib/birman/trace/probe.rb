# frozen_string_literal: true

module Birman
  class Trace
    # Wraps a matcher of a traced parse so the TracingContext records a
    # frame for it. Only TracingContext runs these: Grammar#__traced_matcher_for
    # builds them, apart from the matchers an untraced parse runs.
    # description is worked out once, when the tree is instrumented.
    Probe = Data.define(:inner, :kind, :description) do
      include Matcher

      def match(ctx, pos) = ctx.probe(self, pos) { inner.match(ctx, pos) }
      def to_ast = inner.to_ast
      def capture_key = inner.capture_key
    end

    # Rebuilds a rule's matcher tree with a Probe around every node a
    # trace shows.
    module Instrument
      module_function

      # Wrappers that only change the value: their inner matcher takes
      # their place in the trace.
      TRANSPARENT = [Named, Const, Map, Send, Action, To, Text, SpannedMatcher, Lexeme].freeze

      # Matchers with parts, and the kind of node each is. Anything not
      # here or in TRANSPARENT is a leaf, its insides not instrumented:
      # Captures reads its Pat when built, Upto finds a bare Str or Pat
      # its own faster way, and a custom matcher's insides are its own.
      KINDS = { Choice => :choice, Seq => :seq, Pick => :seq, Rep => :rep, SepBy => :sep_by,
                Operators => :operators, Maybe => :maybe, Label => :label, Check => :check,
                Quiet => :quiet, Not => :not, And => :and, Both => :both }.freeze

      # With fold, a rule's body that is a seq or a choice (seen through
      # transparent wrappers) gets no node: its parts or alternatives are
      # the rule's own children.
      def call(matcher, fold: false)
        return matcher if matcher.is_a?(Ref) # recorded by TracingContext#memoize
        return rebuild(matcher, fold) if TRANSPARENT.include?(matcher.class)

        kind = KINDS[matcher.class]
        return Probe.new(matcher, :leaf, describe(matcher)) unless kind

        inner = rebuild(matcher, false)
        return inner if fold && %i[choice seq].include?(kind)

        Probe.new(inner, kind, describe(matcher))
      end

      # matcher with every matcher among its members instrumented.
      def rebuild(matcher, fold)
        changes = matcher.to_h.filter_map do |key, value|
          case value
          when Matcher then [key, call(value, fold:)]
          when Array then [key, value.map { member(_1) }]
          end
        end
        matcher.with(**changes.to_h)
      end

      def member(value)
        case value
        when Matcher then call(value)
        when Operators::Entry then value.with(matcher: call(value.matcher))
        else value
        end
      end

      # The text a node is shown as: its EBNF, but sep_by and operators
      # as written, since their EBNF is long, and label, check and quiet
      # as themselves. A matcher with no to_ast is
      # shown by its class.
      def describe(matcher) # rubocop:disable Metrics
        case matcher
        when SepBy
          args = [matcher.item, matcher.sep].map { EBNF.expr(_1.to_ast, EBNF::CHOICE) }
          args << "trailing: true" if matcher.trailing
          "#{matcher.min.zero? ? "sep_by" : "sep_by1"}(#{args.join(", ")})"
        when Operators then "operators(#{EBNF.expr(matcher.operand.to_ast, EBNF::CHOICE)})"
        # These three get a node of their own over their inner matcher's,
        # so they're shown as what they add to it.
        when Label then "label #{matcher.name.inspect}"
        when Check then "check :#{matcher.method_name}"
        when Quiet then "quiet"
        else EBNF.expr(matcher.to_ast, EBNF::CHOICE)
        end
      rescue NoMethodError => e
        raise unless e.name == :to_ast

        matcher.class.name || matcher.class.inspect
      end
    end
  end
end
