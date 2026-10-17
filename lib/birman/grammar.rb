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

    # Settings are inherited by subclasses. Passing nil clears an
    # inherited one: `ignore nil`, `keywords nil`.
    module ClassMethods
      UNSET = Object.new.freeze

      # The rule a parse starts from.
      def root(name = UNSET) = setting(:root, name)

      # A rule the parser matches and discards after every literal and
      # lexeme, and at the start of input. Usually :spacing (from
      # Birman::Rules::Whitespace or Comments).
      def ignore(name = UNSET) = setting(:ignore, name)

      # Reserved words, which Birman::Rules::Identifiers won't accept.
      def keywords(*words)
        return setting(:keywords) || [] if words.empty?

        setting(:keywords, words == [nil] ? [] : words.map(&:to_s))
      end

      # These share one instance, so each rule's matcher is built once
      # rather than on every parse. Defining a rule or changing a
      # setting starts a fresh one.
      def parse(input)  = instance.parse(input)
      def parse!(input, **) = instance.parse!(input, **)
      def to_ast        = instance.to_ast
      def to_ebnf       = EBNF.call(to_ast)

      private

      def instance = @instance ||= new

      def setting(key, value = UNSET)
        ivar = :"@#{key}"
        unless value.equal?(UNSET)
          @instance = nil
          return instance_variable_set(ivar, value)
        end
        return instance_variable_get(ivar) if instance_variable_defined?(ivar)

        superclass.public_send(key) if superclass.respond_to?(key)
      end
    end

    def keywords = self.class.keywords

    # Returns Success(value) or Failure(...). Never raises on bad input.
    def parse(input)
      ctx = Context.new(input, self)
      start = (ignore_rule && Ref.new(ignore_rule).match(ctx, 0)&.pos) || 0
      result = Ref.new(root_rule).match(ctx, start)
      return Success.new(result.value) if result && result.pos == input.bytesize

      ctx.fail_at(result.pos, "end of input") if result
      build_failure(input, ctx.furthest, ctx.expected)
    rescue Committed => e
      build_failure(input, e.pos, e.expected, committed: true)
    rescue SystemStackError
      build_failure(input, ctx.position, [], reason: "input is nested too deeply")
    end

    # Returns the value or raises ParseError, worded by formatter.
    def parse!(input, formatter: ErrorFormatter.new) = parse(input).value!(formatter)

    def matcher_for(name)
      (@matchers ||= {})[name] ||= begin
        body = :"__rule_#{name}"
        raise ArgumentError, "undefined rule :#{name}" unless respond_to?(body, true)

        Birman.coerce(send(body))
      end
    end

    # { rule_name => ast } for every rule reachable from the root (and
    # the ignore rule), in first-use order.
    def to_ast
      rules = {}
      queue = [root_rule, ignore_rule].compact
      while (name = queue.shift)
        next if rules.key?(name)

        rules[name] = matcher_for(name).to_ast
        queue.concat(AST.refs(rules[name]))
      end
      rules
    end

    private

    def build_failure(input, byte_pos, expected, committed: false, reason: nil)
      Failure.new(input:, pos: Birman.char_offset(input, byte_pos), expected: expected.uniq, committed:, reason:)
    end

    def root_rule = self.class.root || raise(ArgumentError, "#{self.class} has no root rule")
  end
end
