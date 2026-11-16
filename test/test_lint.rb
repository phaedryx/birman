# frozen_string_literal: true

require "test_helper"
require_relative "../examples/calc"
require_relative "../examples/leftcalc"
require_relative "../examples/json"
require_relative "../examples/email"
require_relative "../examples/toml"
require_relative "../examples/query"

# Grammar.lint, and the error a rule naming an undefined rule raises.
class LintTest < Minitest::Test
  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar

      self.root(root) if root
      class_eval(&rules)
    end
  end

  def kinds(problems) = problems.map { [_1.kind, _1.rule] }

  # --- undefined rules ---

  def test_parsing_a_rule_that_names_an_undefined_rule_raises_argument_error_naming_both
    g = grammar { rule(:top) { seq("x", item) } }

    error = assert_raises(ArgumentError) { g.parse("x") }
    assert_equal "rule :top refers to undefined rule :item", error.message
  end

  def test_a_misspelt_call_with_arguments_is_named_too
    g = grammar { rule(:top) { seq("x", item(1)) } }

    error = assert_raises(ArgumentError) { g.parse("x") }
    assert_equal "rule :top refers to undefined rule :item", error.message
  end

  def test_an_undefined_constant_in_a_rule_is_left_as_ruby_raised_it
    g = grammar { rule(:top) { str("x").to(NoSuchNode) } }

    assert_raises(NameError) { g.parse("x") }
  end

  def test_lint_reports_an_undefined_rule_without_raising
    g = grammar { rule(:top) { seq("x", item) } }

    problems = g.lint
    assert_equal [%i[undefined_rule top]], kinds(problems)
    assert_equal "rule :top refers to undefined rule :item", problems.first.message
  end

  def test_lint_reports_an_undefined_root_and_ignore_rule
    g = grammar(:start) do
      ignore :spacing
      rule(:top) { "x" }
    end

    assert_equal [%i[undefined_rule start], %i[undefined_rule spacing]], kinds(g.lint)
    assert_equal ["root :start isn't a rule", "ignore :spacing isn't a rule"], g.lint.map(&:message)
  end

  def test_lint_reports_a_rule_that_cant_be_built
    g = grammar { rule(:top) { operators(match(/\d/)) } }

    assert_equal [%i[invalid_rule top]], kinds(g.lint)
  end

  # --- unreachable rules ---

  def test_lint_reports_a_rule_the_root_doesnt_reach
    g = grammar do
      rule(:top)    { item }
      rule(:item)   { "x" }
      rule(:orphan) { "y" }
    end

    problems = g.lint
    assert_equal [%i[unreachable_rule orphan]], kinds(problems)
    assert_equal "rule :orphan isn't reached from root :top", problems.first.message
  end

  def test_rules_the_ignore_rule_reaches_are_reachable
    g = grammar do
      ignore :spacing
      rule(:top)     { "x" }
      rule(:spacing) { either(blank, comment).rep }
      rule(:blank)   { match(/\s+/) }
      rule(:comment) { match(/#.*/) }
    end

    assert_empty g.lint
  end

  def test_unused_rules_from_an_included_module_arent_reported
    g = grammar do
      include Birman::Rules::Whitespace
      include Birman::Rules::Numbers

      rule(:top) { number }
    end

    assert_empty g.lint
  end

  def test_a_subclass_reports_its_parents_rules_it_no_longer_reaches
    parent = grammar do
      rule(:top) { a }
      rule(:a)   { "a" }
    end
    child = Class.new(parent) { rule(:top) { "b" } }

    assert_equal [%i[unreachable_rule a]], kinds(child.lint)
  end

  # top can't be built, so what else it refers to is unknown.
  def test_no_rule_is_unreachable_past_a_reached_rule_that_cant_be_built
    g = grammar do
      rule(:top)   { seq(other, missing) }
      rule(:other) { "y" }
    end

    assert_equal [%i[undefined_rule top]], kinds(g.lint)
  end

  def test_without_a_root_no_rule_is_unreachable
    g = grammar(nil) { rule(:orphan) { "y" } }

    assert_empty g.lint
  end

  # --- shadowed alternatives ---

  def test_a_shorter_literal_first_shadows_a_longer_one
    g = grammar { rule(:top) { seq(either("<", "<="), "1") } }

    problems = g.lint
    assert_equal [%i[shadowed_alternative top]], kinds(problems)
    assert_equal 'rule :top: "<=" (alternative 2) never matches, since "<" (alternative 1) matches first; ' \
                 "put the longer one first", problems.first.message
  end

  def test_one_of_with_values_is_checked_too
    g = grammar { rule(:top) { one_of("<" => :lt, "<=" => :le) } }

    assert_equal [%i[shadowed_alternative top]], kinds(g.lint)
  end

  def test_longer_literals_first_are_fine
    g = grammar { rule(:top) { one_of("<=", "<", "==", "=") } }

    assert_empty g.lint
  end

  def test_a_word_literal_doesnt_shadow_a_longer_word
    g = grammar { rule(:top) { either("in", "int") } }

    assert_empty g.lint
  end

  def test_a_word_literal_shadows_a_longer_literal_that_continues_with_punctuation
    g = grammar { rule(:top) { either("a", "a+") } }

    assert_equal [%i[shadowed_alternative top]], kinds(g.lint)
  end

  def test_a_repeated_literal_is_shadowed
    g = grammar { rule(:top) { either("x", "y", "x") } }

    assert_equal ['rule :top: "x" (alternative 3) never matches, since "x" (alternative 1) matches first'],
                 g.lint.map(&:message)
  end

  def test_a_sequence_starting_with_a_shadowed_literal_is_shadowed
    g = grammar { rule(:top) { either("<", seq("<=", "1")) } }

    assert_equal [%i[shadowed_alternative top]], kinds(g.lint)
  end

  def test_literals_behind_rule_references_are_compared
    g = grammar do
      rule(:top) { either(lt, le) }
      rule(:lt)  { "<" }
      rule(:le)  { "<=" }
    end

    assert_equal [%i[shadowed_alternative top]], kinds(g.lint)
  end

  def test_case_insensitive_literals_are_compared_without_case
    g = grammar { rule(:top) { either(nocase("go"), nocase("GO!")) } }

    assert_equal [%i[shadowed_alternative top]], kinds(g.lint)
  end

  def test_an_alternative_that_always_matches_shadows_the_rest
    g = grammar { rule(:top) { either(str("x").maybe, "y", "z") } }

    problems = g.lint
    assert_equal [%i[shadowed_alternative top]], kinds(problems)
    assert_equal "rule :top: alternatives 2-3 never match, since alternative 1 never fails",
                 problems.first.message
  end

  def test_a_lookahead_or_pattern_first_isnt_reported
    g = grammar { rule(:top) { either(match(/</), "<=", str("<").present >> "<=") } }

    assert_empty g.lint
  end

  def test_a_choice_inside_a_sequence_or_repetition_is_checked
    g = grammar { rule(:top) { seq("(", either("-", "->").rep, ")") } }

    assert_equal [%i[shadowed_alternative top]], kinds(g.lint)
  end

  # A recover fails where what it recovers from fails at its start, so
  # it shadows what follows only when that never fails.
  def test_a_recover_fails_as_what_it_recovers_from
    never_fails = grammar { rule(:top) { either(str("x").maybe.recover(to: ";"), "y") } }
    assert_equal [%i[shadowed_alternative top]], kinds(never_fails.lint)

    fails = grammar do
      rule(:top) { either(seq("x", commit, "y").recover(to: stop), "z") }
      rule(:stop) { either("-", "->") }
    end
    assert_equal [%i[shadowed_alternative stop]], kinds(fails.lint), "the sync point is linted and reached"
  end

  # --- the whole ---

  def test_problems_print_as_their_message
    g = grammar { rule(:top) { seq("x", item) } }

    assert_equal "rule :top refers to undefined rule :item", g.lint.first.to_s
  end

  def test_the_instance_lints_too
    g = grammar { rule(:top) { seq("x", item) } }

    assert_equal g.lint, g.new.lint
  end

  def test_the_example_grammars_are_clean
    [Calc::Grammar, LeftCalc::Grammar, JSONExample::Grammar, EmailExample::Grammar, TOMLExample::Grammar,
     QueryExample::Grammar].each do |g|
      assert_empty g.lint, g.name
    end
  end
end
