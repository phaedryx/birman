# frozen_string_literal: true

require "test_helper"
require_relative "../examples/calc"
require_relative "../examples/json"
require_relative "../examples/query"
require_relative "../examples/toml"
require_relative "../examples/email"

# Left recursion is found from the grammar itself, on the first parse,
# not only when some input happens to reach it.
class TestLeftRecursion < Minitest::Test
  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace

      self.root(root)
      class_eval(&rules)
    end
  end

  def assert_left_recursion(message, klass, input = "x")
    error = assert_raises(ArgumentError) { klass.parse(input) }
    assert_equal "left recursion: #{message} (each rule can call the next without consuming input)", error.message
  end

  def refute_left_recursion(klass, input = "x")
    klass.parse(input) # raises if the grammar is left-recursive
    pass
  end

  def analysis(rules) = Birman::LeftRecursion.new(rules)

  # --- Found before any input reaches it ---

  def test_direct_left_recursion_raises_on_input_that_never_reaches_it
    g = grammar(:expr) do
      rule(:expr) { either(num, seq(expr, "+", num)) }
      rule(:num) { match(/\d+/) }
    end
    assert_left_recursion ":expr -> :expr", g, "1"
  end

  def test_indirect_left_recursion_names_the_cycle
    g = grammar(:a) do
      rule(:a) { either("x", seq(b, "!")) }
      rule(:b) { either("y", seq(a, "?")) }
    end
    assert_left_recursion ":a -> :b -> :a", g
  end

  def test_the_cycle_starts_at_the_rule_reached_first
    g = grammar do
      rule(:top) { seq("(", b) }
      rule(:b) { either("x", c) }
      rule(:c) { seq(d, "!") }
      rule(:d) { seq(b, "?") }
    end
    assert_left_recursion ":b -> :c -> :d -> :b", g
  end

  def test_every_cycle_is_named
    g = grammar do
      rule(:top) { either(seq(a, "!"), seq(b, "?")) }
      rule(:a) { either("x", seq(a, "1")) }
      rule(:b) { either("y", seq(c, "2")) }
      rule(:c) { seq(b, "3") }
    end
    assert_left_recursion ":a -> :a; :b -> :c -> :b", g
  end

  def test_left_recursion_hidden_behind_a_nullable_prefix
    g = grammar do
      rule(:top) { either("x", seq(str("-").maybe, top, "!")) }
    end
    assert_left_recursion ":top -> :top", g

    g = grammar do
      rule(:top) { either("x", seq(str("-").rep, top, "!")) }
    end
    assert_left_recursion ":top -> :top", g
  end

  def test_left_recursion_behind_nullable_rules
    g = grammar do
      rule(:top) { either("x", seq(sign, top)) }
      rule(:sign) { either(str("-"), str("+"), seq(blank, blank)) }
      rule(:blank) { str("") }
    end
    assert_left_recursion ":top -> :top", g
  end

  def test_left_recursion_behind_patterns_that_match_nothing
    g = grammar { rule(:top) { either("x", seq(match(/ */), top)) } }
    assert_left_recursion ":top -> :top", g

    g = grammar { rule(:top) { either("x", seq(match(/ +/), top)) } }
    refute_left_recursion g
  end

  def test_left_recursion_behind_lookaheads
    g = grammar { rule(:top) { either("x", seq(match(/y/).absent, top, "!")) } }
    assert_left_recursion ":top -> :top", g

    g = grammar { rule(:top) { either("x", seq(match(/y/).present, top, "!")) } }
    assert_left_recursion ":top -> :top", g

    g = grammar { rule(:top) { either("x", match(/y/) & top) } }
    assert_left_recursion ":top -> :top", g
  end

  def test_a_lookahead_that_reenters_its_rule_loops_too
    g = grammar { rule(:top) { either(top.absent >> str("x"), str("y")) } }
    assert_left_recursion ":top -> :top", g

    g = grammar { rule(:top) { top.present & str("x") } }
    assert_left_recursion ":top -> :top", g
  end

  def test_left_recursion_through_wrappers
    node = Birman.node(:value)
    wrappers = {
      label: ->(m) { m.label("thing") },
      quiet: lambda(&:quiet),
      map: ->(m) { m.map(&:to_s) },
      send: ->(m) { m.map(:to_s) },
      means: ->(m) { m.means(1) },
      action: ->(m) { m.action(:itself) },
      check: ->(m) { m.check(:itself, "thing") },
      as: ->(m) { m.as(:x) },
      to: ->(m) { m.to(node) }
    }
    wrappers.each do |name, wrap|
      g = grammar { rule(:top) { either("x", seq(wrap.call(top), "!")) } }
      error = assert_raises(ArgumentError, "through #{name}") { g.parse("x") }
      assert_match(/left recursion: :top -> :top/, error.message, "through #{name}")
    end
  end

  def test_left_recursion_through_combinators
    node = Birman.node(:op, :left, :right)
    g = grammar { rule(:top) { infix(top, "+", node:) } }
    assert_left_recursion ":top -> :top", g

    g = grammar { rule(:top) { either("x", sep_by(top, ",")) } }
    assert_left_recursion ":top -> :top", g

    g = grammar { rule(:top) { either("x", seq(top, commit, "!")) } }
    assert_left_recursion ":top -> :top", g

    g = grammar { rule(:top) { either("x", top > "!") } }
    assert_left_recursion ":top -> :top", g
  end

  def test_the_ignore_rule_is_checked
    g = grammar do
      ignore :spacing
      rule(:top) { "x" }
      rule(:spacing) { either(match(/\s+/), seq(spacing, "#")) }
    end
    assert_left_recursion ":spacing -> :spacing", g
  end

  def test_rules_nothing_reaches_are_not_checked
    g = grammar do
      rule(:top) { "x" }
      rule(:unused) { seq(unused, "x") }
    end
    refute_left_recursion g
  end

  def test_fixing_the_rule_lets_the_grammar_parse
    g = grammar { rule(:top) { either("x", seq(top, "!")) } }
    assert_raises(ArgumentError) { g.parse("x") }
    assert_raises(ArgumentError, "the check isn't skipped on a later parse") { g.parse("x") }

    g.rule(:top) { either(seq("x", "!", top), "x") }
    assert g.parse("x!x").success?
  end

  def test_a_new_instance_is_checked_too
    g = grammar { rule(:top) { either("x", seq(top, "!")) } }
    assert_raises(ArgumentError) { g.new.parse("x") }
  end

  def test_no_root_rule_is_still_reported
    g = Class.new { include Birman::Grammar }
    error = assert_raises(ArgumentError) { g.parse("x") }
    assert_match(/has no root rule/, error.message)
  end

  # --- Not left recursion ---

  def test_right_recursion_and_recursion_after_input_are_fine
    g = grammar { rule(:top) { either(seq("x", top), "x") } }
    refute_left_recursion g, "xxx"

    g = grammar(:expr) do
      rule(:expr) { either(parens(expr), match(/\d+/)) }
    end
    refute_left_recursion g, "((1))"
  end

  def test_a_literal_is_not_nullable_even_with_ignore_after_it
    g = grammar do
      ignore :spacing
      rule(:top) { either(seq("x", top), "y") }
    end
    refute_left_recursion g, "x x y"
  end

  def test_infix_on_another_rule_is_fine
    node = Birman.node(:op, :left, :right)
    g = grammar do
      rule(:top) { infix(atom, "+", node:) }
      rule(:atom) { either(match(/\d+/), parens(top)) }
    end
    refute_left_recursion g, "1+(2+3)"
  end

  def test_the_example_grammars_are_not_left_recursive
    [Calc::Grammar, JSONExample::Grammar, QueryExample::Grammar, TOMLExample::Grammar,
     EmailExample::Grammar].each do |g|
      Birman::LeftRecursion.new(g.to_ast).check!
    end
    pass
  end

  def test_matchers_without_an_ast_are_skipped
    custom = Data.define(:x) do
      include Birman::Matcher

      def match(_ctx, pos) = Birman::Match.new(pos + 1, x)
    end
    g = grammar { rule(:top) { seq(custom.new(1), "!") } }
    assert_equal [1, "!"], g.parse!("x!")
  end

  def test_an_undefined_rule_is_still_reported_only_when_reached
    g = grammar { rule(:top) { either("x", Birman::Ref.new(:missing)) } }
    assert g.parse("x").success?
    error = assert_raises(ArgumentError) { g.parse("y") }
    assert_equal "undefined rule :missing", error.message
  end

  # --- The analysis ---

  def test_nullability_of_each_node_type
    nullable = [
      [:str, ""], [:pat, "/ */"], [:pat, "/a?/i"], [:pat, "/\\A/"],
      [:seq, nil, []], [:seq, 1, [[:str, ""], [:rep, 0, nil, [:str, "a"]]]],
      [:choice, [[:str, "a"], [:str, ""]]],
      [:rep, 0, nil, [:str, "a"]], [:rep, 0, 1, [:str, "a"]], [:rep, 2, nil, [:pat, "/a*/"]],
      [:not, [:str, "a"]], [:and, [:str, "a"]], [:both, [:str, "a"], [:str, ""]],
      [:action, [:str, ""]], [:label, "x", [:str, ""]], [:check, "x", [:str, ""]], [:quiet, [:str, ""]]
    ]
    non_nullable = [
      [:str, "a"], [:pat, "/a+/"], [:pat, "/a/x"], [:pat, "/\\/+/"], [:pat, "/(?!)/"],
      [:seq, nil, [[:str, ""], [:str, "a"]]], [:choice, [[:str, "a"], [:str, "b"]]], [:choice, []],
      [:rep, 1, nil, [:str, "a"]], [:both, [:str, ""], [:str, "a"]],
      [:action, [:str, "a"]], [:label, "x", [:str, "a"]], [:check, "x", [:str, "a"]], [:quiet, [:str, "a"]]
    ]
    a = analysis({ top: [:str, "a"] })
    nullable.each { assert a.nullable_node?(_1), "#{_1.inspect} is nullable" }
    non_nullable.each { refute a.nullable_node?(_1), "#{_1.inspect} isn't nullable" }
  end

  def test_nullability_reaches_a_fixpoint_over_rules
    a = analysis({
                   top: [:seq, nil, [%i[ref b], [:str, "x"]]],
                   b: [:choice, [[:seq, nil, [%i[ref c], [:str, "y"]]], %i[ref d]]],
                   c: [:seq, nil, [%i[ref b], [:str, "z"]]],
                   d: [:rep, 0, nil, [:str, "w"]],
                   loop: [:seq, nil, [%i[ref loop]]]
                 })
    assert a.nullable?(:b)
    assert a.nullable?(:d)
    refute a.nullable?(:c)
    refute a.nullable?(:top)
    refute a.nullable?(:loop), "a rule that only calls itself never matches, so isn't nullable"
    refute a.nullable?(:undefined)
  end

  def test_left_calls_stop_after_the_first_part_that_consumes
    a = analysis({
                   top: [:seq, nil, [[:rep, 0, 1, %i[ref a]], [:not, %i[ref b]], %i[ref c], %i[ref d]]],
                   a: [:str, "a"], b: [:str, "b"], c: [:str, "c"], d: [:str, "d"]
                 })
    assert_equal %i[a b c], a.left_calls(:top)
  end

  def test_sccs_and_leaders_for_left_recursion_support
    a = analysis({
                   top: [:seq, nil, [%i[ref expr], [:str, ";"]]],
                   expr: [:choice, [[:seq, nil, [%i[ref term], [:str, "+"]]], %i[ref term]]],
                   term: [:choice, [[:seq, nil, [%i[ref expr], [:str, "-"]]], %i[ref num]]],
                   num: [:pat, "/\\d+/"],
                   self_ref: [:seq, nil, [%i[ref self_ref], [:str, "x"]]]
                 })
    assert_equal [%i[expr term], %i[self_ref]], a.cycles
    assert a.left_recursive?(:expr)
    assert a.left_recursive?(:self_ref)
    refute a.left_recursive?(:top)
    refute a.left_recursive?(:num)
    assert_equal :expr, a.leader(:term)
    assert_equal :expr, a.leader(:expr)
    assert_nil a.leader(:top)
    assert_equal %i[expr term], a.cycle(:term)
  end
end
