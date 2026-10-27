# frozen_string_literal: true

# [file]
# purpose = "The rule and lexeme macros"
# responsibility = "Turning rule blocks into methods, and guarding rule names"
# pattern = "Class-level DSL (extend)"
module Birman
  # The `rule` and `lexeme` macros. Extend any module or class with it.
  #
  # Each rule becomes two ordinary methods: `name` returns a Ref, and a
  # private `__rule_name` builds the matcher. Because rules are just
  # methods, they travel through `include` and can be overridden like
  # any other Ruby method; an overriding rule reaches the one it
  # replaces with `super()` (parenthesised: define_method can't pass
  # arguments on implicitly, and Grammar#matcher_for says so).
  # [module.RuleSet]
  # purpose = "Defines rules; extend a module with it to write a reusable rule module"
  # collaborators = ["Grammar (extends its classes with this)", "Ref"]
  module RuleSet
    # [method.rule]
    # params = ["name: Symbol", "block: returns the rule's matcher (String, Regexp or Matcher)"]
    # returns = "nil"
    # side_effects = [
    #   "Defines name (returns a Ref) and a private __rule_name",
    #   "Resets a grammar class's cached instance"
    # ]
    # raises = ["ArgumentError if name would replace a method the grammar relies on (send, match, token...)"]
    def rule(name, &)
      raise ArgumentError, "no block given for rule :#{name}" unless block_given?

      check_rule_name!(name)
      define_method(:"__rule_#{name}", &)
      private :"__rule_#{name}"
      define_method(name) { Ref.new(name) }
      (@__rules ||= []) << name unless @__rules&.include?(name)
      @instance = nil # a grammar class's cached instance (see Grammar::ClassMethods)
    end

    # [method.rules]
    # returns = "Array of Symbol: every rule's name, in declaration order (included modules' first)"
    def rules
      ancestors.reverse.flat_map { _1.instance_variable_get(:@__rules) || [] }.uniq
    end

    # [method."rule?"]
    # params = ["name: Symbol"]
    # returns = "true if the grammar has a rule of that name (a method of that name isn't one)"
    def rule?(name) = name.is_a?(Symbol) && private_method_defined?(:"__rule_#{name}")

    # A rule for a token (a number, a string, an identifier): it skips
    # trailing spacing when the grammar declares `ignore`.
    # [method.lexeme]
    # params = ["name: Symbol", "body: block returning the token's matcher"]
    # returns = "nil"
    # side_effects = ["Defines a rule that skips trailing spacing via the grammar's ignore rule"]
    def lexeme(name, &body)
      rule(name) { Lexeme.new(Birman.coerce(instance_exec(&body))) }
    end

    private

    # A rule named after a method the grammar relies on (send, class,
    # match, token, or a private helper in any of Birman's modules) would
    # silently replace it. Redefining a rule is fine, and so are private
    # Kernel names like print or select, and the grammar's own private
    # helpers: those are the grammar's to replace.
    def check_rule_name!(name)
      return if private_method_defined?(:"__rule_#{name}")

      birman = [Object, Combinators, Grammar] | ancestors.select { _1.name&.start_with?("Birman::") }
      owner = birman.find { _1.public_method_defined?(name) } ||
              (birman - [Object]).find { _1.private_method_defined?(name, false) } ||
              (instance_method(name).owner if method_defined?(name))
      return unless owner

      raise ArgumentError, "rule :#{name} would replace #{owner}##{name}, #{why_taken(owner, birman)}, " \
                           "since rules are methods too; give the rule another name"
    end

    def why_taken(owner, birman)
      if owner == Object then "a method every Ruby object has"
      elsif birman.include?(owner) then "which Birman relies on"
      else "a method of this grammar"
      end
    end
  end
end
