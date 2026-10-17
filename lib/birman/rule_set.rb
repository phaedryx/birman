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
  # any other Ruby method.
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
      check_rule_name!(name)
      define_method(:"__rule_#{name}", &)
      private :"__rule_#{name}"
      define_method(name) { Ref.new(name) }
      @instance = nil # a grammar class's cached instance (see Grammar::ClassMethods)
    end

    # A rule for a token (a number, a string, an identifier): it skips
    # trailing spacing when the grammar declares `ignore`.
    # [method.lexeme]
    # params = ["name: Symbol", "body: block returning the token's matcher"]
    # returns = "nil"
    # side_effects = ["Defines a rule that skips trailing spacing via the grammar's ignore rule"]
    def lexeme(name, &body)
      rule(name) { Lexeme.new(Birman.coerce(instance_exec(&body)), ignore_rule) }
    end

    private

    # A rule named after a method the grammar relies on (send, class,
    # match, token...) would silently replace it. Redefining a rule is
    # fine, and so are private Kernel names like print or select.
    def check_rule_name!(name)
      return if private_method_defined?(:"__rule_#{name}")

      owner = [Object, Combinators, Grammar].find { _1.public_method_defined?(name) } ||
              [Combinators, Grammar].find { _1.private_method_defined?(name) } ||
              (instance_method(name).owner if method_defined?(name))
      raise ArgumentError, "rule :#{name} would replace #{owner}##{name}; give the rule another name" if owner
    end
  end
end
