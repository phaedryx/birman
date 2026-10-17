# frozen_string_literal: true

module Birman
  # The `rule` and `lexeme` macros. Extend any module or class with it.
  #
  # Each rule becomes two ordinary methods: `name` returns a Ref, and a
  # private `__rule_name` builds the matcher. Because rules are just
  # methods, they travel through `include` and can be overridden like
  # any other Ruby method.
  module RuleSet
    def rule(name, &body)
      define_method(:"__rule_#{name}", &body)
      private :"__rule_#{name}"
      define_method(name) { Ref.new(name) }
    end

    # A rule for a token (a number, a string, an identifier): it skips
    # trailing whitespace when the grammar declares `skip`.
    def lexeme(name, &body)
      rule(name) { Lexeme.new(Birman.coerce(instance_exec(&body)), skip_rule) }
    end
  end
end
