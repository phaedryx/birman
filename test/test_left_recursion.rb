# frozen_string_literal: true

require "test_helper"

# Left recursion is found from the grammar itself, on the first parse,
# not only when some input happens to reach it.
class TestLeftRecursion < Minitest::Test
  def analysis(rules) = Birman::LeftRecursion.new(rules)

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
