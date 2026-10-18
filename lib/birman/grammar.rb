# frozen_string_literal: true

# [file]
# purpose = "Makes a class (or a module of shared rules) a grammar"
# responsibility = "Settings, parse entry points, rule lookup and introspection"
# dependencies = ["Birman::Combinators", "Birman::RuleSet", "Birman::Nodes", "Birman::Context"]
# pattern = "Mixin with class-level DSL"
module Birman
  # Include this to make a class a grammar. The class body also gets
  # `node` (see Nodes), so AST nodes can live beside their rules.
  #
  # Including it in a module makes a module of shared rules: whatever
  # includes that module (a class, or another such module) becomes a
  # grammar too.
  # [module.Grammar]
  # purpose = "include this in a class to make it a grammar"
  # provides = ["rule / lexeme (RuleSet)", "node (Nodes)", "combinators", "settings and parse"]
  # collaborators = ["Context", "Success", "Failure", "ErrorFormatter"]
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
    # [module.Grammar.ClassMethods]
    # purpose = "Settings and parse entry points on a grammar class"
    # notes = "Settings are inherited by subclasses; pass nil to clear one"
    module ClassMethods
      UNSET = Object.new.freeze

      # The rule a parse starts from.
      # [method.root]
      # params = ["name: Symbol | nil (omit to read)"]
      # returns = "The start rule's name"
      def root(name = UNSET) = setting(:root, name)

      # A rule the parser matches and discards after every literal and
      # lexeme, and at the start of input. Usually :spacing (from
      # Birman::Rules::Whitespace or Comments).
      # [method.ignore]
      # params = ["name: Symbol | nil (omit to read)"]
      # returns = "The ignore rule's name (matched and discarded after literals and lexemes)"
      def ignore(name = UNSET) = setting(:ignore, name)

      # Reserved words, which Birman::Rules::Identifiers won't accept.
      # [method.keywords]
      # params = ["*words: String (none to read; nil to clear)"]
      # returns = "Array of reserved words (Rules::Identifiers rejects them as names)"
      def keywords(*words)
        return setting(:keywords) || [] if words.empty?

        setting(:keywords, words == [nil] ? [] : words.map(&:to_s))
      end

      # These share one instance, so each rule's matcher is built once
      # rather than on every parse. Defining a rule or changing a
      # setting starts a fresh one.
      # [method."Grammar.parse"]
      # params = ["input: String"]
      # returns = "Success(value) or Failure; see Grammar#parse"
      # notes = "Uses one cached instance; defining a rule or changing a setting resets it"
      def parse(input) = instance.parse(input)

      # [method."Grammar.parse!"]
      # params = ["input: String", "formatter: #call(failure) = ErrorFormatter.new"]
      # returns = "The parsed value"
      # raises = ["Birman::ParseError"]
      def parse!(input, **) = instance.parse!(input, **)

      # [method."Grammar.to_ast"]
      # returns = "Hash of rule name => AST, for every rule reachable from root and ignore"
      def to_ast = instance.to_ast

      # [method."Grammar.to_ebnf"]
      # returns = "String: the grammar in PEG-flavored EBNF"
      def to_ebnf = EBNF.call(to_ast)

      # A standalone parser for this grammar, as Ruby source: the same
      # results as parse, from code Spinel can compile to a native binary.
      # [method."Grammar.to_ruby"]
      # params = ["namespace: String, the module the parser is defined in (\"CalcParser\")"]
      # returns = "String: Ruby source defining <namespace>::Parser (new(input).parse => Success or Failure)"
      # raises = ["Birman::Compiler::Error for what can't be compiled (.map blocks, custom matchers...)"]
      def to_ruby(namespace:) = Compiler.new(self, namespace:).to_ruby

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
    # [method.parse]
    # params = ["input: String"]
    # returns = "Birman::Success(value) when all of input parses, else Birman::Failure"
    # raises = ["ArgumentError for grammar mistakes (no root, undefined rule, left recursion)"]
    # notes = "Bad input never raises: too-deep nesting is a Failure with reason set"
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
    # [method."parse!"]
    # params = ["input: String", "formatter: #call(failure) = ErrorFormatter.new"]
    # returns = "The parsed value"
    # raises = ["Birman::ParseError (message from formatter)"]
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
