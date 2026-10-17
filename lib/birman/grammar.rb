# frozen_string_literal: true

module Birman
  # Include this to make a class a grammar. The class body also gets
  # `node` (see Nodes), so AST nodes can live beside their rules.
  #
  # Including it in a module makes a module of shared rules: whatever
  # includes that module (a class, or another such module) becomes a
  # grammar too.
  module Grammar
    include Combinators

    def self.included(base)
      base.extend(RuleSet)
      base.extend(Nodes)
      base.extend(base.is_a?(Class) ? ClassMethods : Shared)
    end

    # Extended onto a module that includes Grammar.
    module Shared
      def included(base)
        super
        base.include(Grammar)
      end
    end

    module ClassMethods
      # The rule a parse starts from.
      def root(name = nil) = name ? @root = name : inherited_setting(:root, @root)

      # A rule to skip after every literal and lexeme, and at the start
      # of input. Usually :sp (from Birman::Rules::Whitespace or Comments).
      def skip(name = nil) = name ? @skip = name : inherited_setting(:skip, @skip)

      # Reserved words, which Birman::Rules::Identifiers won't accept.
      def keywords(*words)
        return @keywords = words.map(&:to_s) if words.any?

        inherited_setting(:keywords, @keywords) || []
      end

      def parse(input)  = new.parse(input)
      def parse!(input) = new.parse!(input)
      def to_ast        = new.to_ast
      def to_ebnf       = EBNF.call(to_ast)

      private

      def inherited_setting(setting, own)
        own || (superclass.public_send(setting) if superclass.respond_to?(setting))
      end
    end

    def keywords = self.class.keywords

    # Returns Success(value) or Failure(...). Never raises on bad input.
    def parse(input)
      ctx = Context.new(input, self)
      start = (skip_rule && Ref.new(skip_rule).match(ctx, 0)&.pos) || 0
      result = Ref.new(root_rule).match(ctx, start)
      return Success.new(result.value) if result && result.pos == input.size

      ctx.fail_at(result.pos, "end of input") if result
      Failure.new(input:, pos: ctx.furthest, expected: ctx.expected.uniq, committed: false)
    rescue Committed => e
      Failure.new(input:, pos: e.pos, expected: e.expected.uniq, committed: true)
    end

    # Returns the value or raises ParseError.
    def parse!(input) = parse(input).value!

    def matcher_for(name)
      (@matchers ||= {})[name] ||= begin
        body = :"__rule_#{name}"
        raise ArgumentError, "undefined rule :#{name}" unless respond_to?(body, true)

        Birman.coerce(send(body))
      end
    end

    # { rule_name => ast } for every rule reachable from the root (and
    # the skip rule), in first-use order.
    def to_ast
      rules = {}
      queue = [root_rule, skip_rule].compact
      while (name = queue.shift)
        next if rules.key?(name)

        rules[name] = matcher_for(name).to_ast
        queue.concat(AST.refs(rules[name]))
      end
      rules
    end

    private

    def root_rule = self.class.root || raise(ArgumentError, "#{self.class} has no root rule")
  end
end
