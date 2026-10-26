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
      # params = ["input: String", "root:, consume:, offset: as Grammar#parse"]
      # returns = "Success(value) or Failure; see Grammar#parse"
      # notes = "Uses one cached instance; defining a rule or changing a setting resets it"
      def parse(input, **) = instance.parse(input, **)

      # [method."Grammar.parse!"]
      # params = [
      #   "input: String", "root:, consume:, offset: as parse", "formatter: #call(failure) = ErrorFormatter.new"
      # ]
      # returns = "The parsed value"
      # raises = ["Birman::ParseError", "ArgumentError, as parse"]
      def parse!(input, **) = instance.parse!(input, **)

      # [method."Grammar.to_ast"]
      # returns = "Hash of rule name => AST, for every rule reachable from root and ignore"
      def to_ast = instance.to_ast

      # [method."Grammar.to_ebnf"]
      # returns = "String: the grammar in PEG-flavored EBNF"
      def to_ebnf = EBNF.call(to_ast)

      # A standalone parser for this grammar, as Ruby source: the same
      # results as parse, from code Spinel can compile to a native binary.
      # Its parse takes consume: and offset: as parse does, and root: for
      # the grammar's root or one of roots: (other rules aren't in it).
      # [method."Grammar.to_ruby"]
      # params = [
      #   "namespace: String, the module the parser is defined in (\"CalcParser\")",
      #   "roots: Array of Symbol = [], rules its parse may start at (root:) besides the grammar's root",
      #   "lookahead_depth: Integer = 56, how deeply lookaheads may nest (see Compiler)"
      # ]
      # returns = "String: Ruby source defining <namespace>::Parser (new(input).parse => Success or Failure)"
      # raises = [
      #   "ArgumentError naming a root that isn't a rule",
      #   "ArgumentError for left-recursive cycles with no rule in common, or a cycle that can't grow, as parse",
      #   "Birman::Compiler::Error for what can't be compiled (.map blocks, custom matchers...)",
      #   "Birman::Compiler::Error for actions calling Integer() or to_i: use large_integer"
      # ]
      def to_ruby(namespace:, **) = Compiler.new(self, namespace:, **).to_ruby

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
    #
    # root: starts the parse at that rule instead of the grammar's root;
    # the rule needn't be reachable from it. Its left recursion is
    # checked, and grown, as the root's is (see left_recursion).
    #
    # consume: false succeeds when a prefix of input matches, rather than
    # all of it, and fails only if the root rule does: the Failure never
    # expects "end of input". Success#pos says where the match ended.
    #
    # offset: starts the parse at that character of input instead of the
    # first, past whatever the ignore rule matches there. Positions
    # (Success#pos, a Failure's, spans) still count from the start of
    # input, and the regexps see all of it: \A matches only at 0, and a
    # lookbehind can see what's before the offset. "End of input" is the
    # real end. Invalid bytes anywhere in input, before the offset too,
    # are a Failure, since a regexp would refuse the whole string.
    # [method.parse]
    # params = [
    #   "input: String",
    #   "root: Symbol | nil = nil (the rule to start at; nil: the grammar's root)",
    #   "consume: Boolean = true (false: a prefix of input may match)",
    #   "offset: Integer = 0 (the character offset to start at; positions still count from 0)"
    # ]
    # returns = "Birman::Success(value) when all of input parses (or a prefix, with consume: false), else Birman::Failure"
    # raises = [
    #   "ArgumentError on the first parse, whatever the input, for no root rule (and no root:)",
    #   "ArgumentError for a root: that isn't a rule of the grammar, naming it",
    #   "ArgumentError for an offset: that's negative or past the end of input (checked after the input's encoding)",
    #   "ArgumentError on the first parse for left-recursive cycles with no rule in common",
    #   "ArgumentError on the first parse for a left-recursive cycle with no base case, or a base case first",
    #   "ArgumentError on the first parse for a reachable rule whose matcher can't be built (unnamed captures...)",
    #   "ArgumentError for an undefined rule, or left recursion through a custom matcher, when the parse reaches it"
    # ]
    # notes = [
    #   "Bad input never raises: invalid UTF-8 and too-deep nesting are Failures with reason set",
    #   "\"The first parse\" is per root: a root: is checked on its first parse, for what it reaches"
    # ]
    def parse(input, root: nil, consume: true, offset: 0)
      analysis = left_recursion(root)
      if (bad = Birman.invalid_byte(input))
        return build_failure(input, bad, [], reason: "invalid #{input.encoding}")
      end

      __match_all(input, root || root_rule, consume, analysis, Birman.byte_offset(input, offset))
    end

    # Returns the value or raises ParseError, worded by formatter.
    # [method."parse!"]
    # params = ["input: String", "root:, consume:, offset: as parse", "formatter: #call(failure) = ErrorFormatter.new"]
    # returns = "The parsed value"
    # raises = ["Birman::ParseError (message from formatter)", "ArgumentError, as parse"]
    def parse!(input, formatter: ErrorFormatter.new, **) = parse(input, **).value!(formatter)

    def matcher_for(name)
      (@matchers ||= {})[name] ||= begin
        body = :"__rule_#{name}"
        raise ArgumentError, "undefined rule :#{name}" unless respond_to?(body, true)

        Birman.coerce(send(body))
      end
    end

    # { rule_name => ast } for every rule reachable from the root (and
    # the ignore rule), in first-use order.
    def to_ast = __reachable_asts { matcher_for(_1).to_ast }

    # The grammar's left-call analysis (see LeftRecursion), built on the
    # first parse or to_ruby. It raises then, and every time after, if
    # the grammar has left-recursive cycles with no rule in common, or a
    # cycle that can't grow (see LeftRecursion#check!); later parses only
    # read the ivar. Context reads its leaders, to grow them.
    #
    # entry: a rule parse's root: starts at (or, for to_ruby's roots:,
    # an Array of them). Its analysis is of the rules reachable from the
    # grammar's root and ignore rule, in first-use order as without one,
    # then of the rest the entry reaches, by name: built (and checked)
    # once per entry, and read from a Hash after that. Leaders are
    # chosen in that order, which no entry changes, so every cycle has
    # the same leader whatever the entry, and a generated parser's one
    # set of leaders agrees with every parse's.
    # [method.left_recursion]
    # params = ["entry: Symbol | Array of Symbol | nil = nil (rules a parse may start at, besides the root)"]
    # returns = "LeftRecursion, checked"
    # raises = ["ArgumentError naming an entry that isn't a rule", "ArgumentError, as LeftRecursion#check!"]
    def left_recursion(entry = nil)
      return @left_recursion ||= __left_recursion(nil) unless entry

      (@left_recursions ||= {})[entry] ||= __left_recursion(Array(entry))
    end

    private

    def __left_recursion(entries)
      entries&.each do |name|
        next if name.is_a?(Symbol) && respond_to?(:"__rule_#{name}", true)

        raise ArgumentError, "undefined rule #{name.inspect}"
      end
      LeftRecursion.new(__analyzable_asts(entries), ignore: ignore_rule).check!
    end

    def __match_all(input, root, consume, analysis, from)
      ctx = Context.new(input, self, ignore_rule, analysis, from)
      result = Ref.new(root).match(ctx, ctx.start)
      if result && (!consume || result.pos == input.bytesize)
        return Success.new(value: result.value, input:, byte_pos: ctx.token_end(result.pos))
      end

      ctx.fail_at(result.pos, "end of input") if result
      build_failure(input, ctx.furthest, ctx.expected)
    rescue Committed => e
      build_failure(input, e.pos, e.expected, committed: true)
    rescue SystemStackError
      build_failure(input, ctx.position, [], reason: "input is nested too deeply")
    end

    # As to_ast, leaving out what it can't describe: undefined rules
    # (the parse reports them if it gets there) and rules using a
    # matcher with no to_ast. The analysis takes those to consume input
    # and to call nothing, so a cycle through one is left to
    # Context#memoize, and rules only it refers to aren't analyzed.
    def __analyzable_asts(entries = nil)
      __reachable_asts(entries) do |name|
        next unless respond_to?(:"__rule_#{name}", true)

        matcher_for(name).to_ast
      rescue NoMethodError => e
        raise unless e.name == :to_ast && e.receiver.is_a?(Matcher)
      end
    end

    # { rule_name => yield(rule_name) } for every rule reachable from the
    # root and the ignore rule, in first-use order, then the others
    # reachable from entries (when given, the root may be unset), by
    # name, skipping nil results. The order of a rule never depends on
    # the entries, so neither does a cycle's leader (see left_recursion).
    def __reachable_asts(entries = nil, &)
      rules = __closure([entries ? self.class.root : root_rule, ignore_rule].compact, {}, &)
      if entries
        more = __closure(entries.dup, rules.dup, &).except(*rules.keys)
        rules.merge!(more.sort_by { |name, _| name.to_s }.to_h)
      end
      rules.compact
    end

    # rules, with yield(name) for every rule reachable from queue that it
    # doesn't have yet, in first-use order.
    def __closure(queue, rules)
      while (name = queue.shift)
        next if rules.key?(name)

        rules[name] = yield(name)
        queue.concat(AST.refs(rules[name]))
      end
      rules
    end

    # Kernel#Integer(value, base), for actions: use it instead of Integer
    # or String#to_i in a grammar you'll generate a parser from (see
    # to_ruby). Past 63 bits, a Spinel binary's Integer and to_i raise or
    # give 2**63 - 1; the generated parser's large_integer gives Bignums,
    # as Ruby's does. Bases: Integers, or Floats truncated (Rational and
    # NaN bases differ from Kernel#Integer in a generated parser). A base
    # that isn't a number raises TypeError, as in Ruby 3.3+; Ruby 3.2's
    # Integer ignores it.
    # [method.large_integer]
    # params = ["value: String or Numeric", "base: Integer = 0 (from the prefix, as Integer's)"]
    # notes = "In a Spinel binary too, Floats past 63 bits convert exactly; negative bases raise there"
    # returns = "Integer(value, base)"
    # raises = ["ArgumentError or TypeError, as Kernel#Integer in Ruby 3.3+"]
    def large_integer(value, base = 0)
      raise TypeError, "no implicit conversion from nil to integer" if base.nil?
      unless base.respond_to?(:to_int)
        raise TypeError, "no implicit conversion of #{[true, false].include?(base) ? base : base.class} into Integer"
      end

      Integer(value, base)
    end

    def build_failure(input, byte_pos, expected, committed: false, reason: nil)
      Failure.new(input:, pos: Birman.char_offset(input, byte_pos), expected: expected.uniq, committed:, reason:)
    end

    def root_rule = self.class.root || raise(ArgumentError, "#{self.class} has no root rule")
  end
end
