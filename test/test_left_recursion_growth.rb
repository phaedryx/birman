# frozen_string_literal: true

require "test_helper"
require_relative "../examples/calc"

# Direct left recursion, grown from a seed (Warth et al. 2008): a rule
# that calls itself first is matched once with that call failing, then
# again with it returning the last match, for as long as that gets
# further.
class TestLeftRecursionGrowth < Minitest::Test
  BinOp = Calc::Grammar::BinOp
  Num = Calc::Grammar::Num

  def grammar(root = :expr, &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace
      include Birman::Rules::Numbers

      self.root(root)
      ignore :spacing
      class_eval(&rules)
    end
  end

  def subtraction
    grammar do
      rule(:expr) { either(seq(expr, "-", integer).map { |l, _, r| l - r }, integer) }
    end
  end

  # The calculator's arithmetic, left-recursive instead of infix, giving
  # its nodes.
  def calc
    grammar do
      rule(:expr) { either(seq(expr.as(:left), either("+", "-").as(:op), term.as(:right)).to(BinOp), term) }
      rule(:term) { either(seq(term.as(:left), either("*", "/").as(:op), fact.as(:right)).to(BinOp), fact) }
      rule(:fact) { either(number.to(Num), parens(expr)).label("expression") }
    end
  end

  # --- Values ---

  def test_direct_left_recursion_is_left_associative
    assert_equal(-6, subtraction.parse!("3-4-5"))
    assert_equal(-6, subtraction.parse!(" 3 - 4 - 5 "))
    assert_equal 3, subtraction.parse!("3")
  end

  def test_two_levels_of_precedence
    g = grammar do
      rule(:expr) do
        either(seq(expr, "-", term).map { |l, _, r| l - r }, seq(expr, "+", term).map { |l, _, r| l + r }, term)
      end
      rule(:term) { either(seq(term, "*", integer).map { |l, _, r| l * r }, integer) }
    end
    assert_equal(-50, g.parse!("5*4*2-5*9*2"))
    assert_equal 40, g.parse!("1 + 2 * 3 * 4 * 2 - 10 + 0 * 7 + 1 * 1")
  end

  def test_the_same_trees_as_the_calculators_infix
    inputs = ["1 + 2 * 3", "1 - 2 - 3", "8 / 4 / 2", "(1 - 2) - (3 - 4) * 5 * 6", "2 * (3 + 4) - 5 + 6 / 7", "42"]
    inputs.each do |input|
      assert_equal Calc::Grammar.parse!(input), [calc.parse!(input)], input
    end
  end

  def test_spans_cover_each_level
    tree = calc.parse!("1 - 2 - 3 ")
    assert_equal "1 - 2 - 3", tree.span.text
    assert_equal "1 - 2", tree.left.span.text
    assert_equal "1", tree.left.left.span.text
    assert_equal "2", tree.left.right.span.text
    assert_equal "3", tree.right.span.text
  end

  def test_wrappers_around_the_recursive_call
    wrappers = {
      label: ->(m) { m.label("expression") },
      quiet: lambda(&:quiet),
      map: ->(m) { m.map(&:itself) }
    }
    wrappers.each do |name, wrap|
      g = grammar { rule(:expr) { either(seq(wrap.call(expr), "-", integer), integer) } }
      assert_equal [[3, "-", 4], "-", 5], g.parse!("3-4-5"), "through #{name}"
      assert g.parse("3-4-5-").failure?, "through #{name}"
    end
    g = grammar { rule(:expr) { either(seq(expr.label("expression"), "-", integer).map { |l, _, r| l - r }, integer) } }
    assert_equal(-6, g.parse!("3-4-5"))
  end

  # The call is still at the rule's start when what's before it can
  # match nothing.
  def test_left_recursion_behind_a_nullable_prefix
    g = grammar do
      rule(:expr) { either(seq(str("~").maybe, expr, "-", integer).map { |_, l, _, r| l - r }, integer) }
    end
    assert_equal(-6, g.parse!("3-4-5"))

    g = grammar do
      rule(:expr) { either(seq(sign, expr, "-", integer).map { |_, l, _, r| l - r }, integer) }
      rule(:sign) { either("+", "") }
    end
    assert_equal(-6, g.parse!("3 - 4 - 5"))
  end

  # The ignore rule can be left-recursive too: it's grown like any rule.
  def test_a_left_recursive_ignore_rule
    g = grammar do
      ignore :blank
      rule(:expr) { either(seq(expr, "-", integer).map { |l, _, r| l - r }, integer) }
      rule(:blank) { either(seq(blank, str("#")), match(/ */)).quiet }
    end
    assert_equal(-6, g.parse!(" ##3 -#4  ##- 5"))
    assert_pattern { g.parse("3 - # x") => Birman::Failure(pos: 5, expected: ["integer"]) }
  end

  # --- Errors ---

  # The last attempt, the one that didn't get further, says what the
  # parse needed next.
  def test_a_trailing_operator_expects_what_follows_it
    assert_pattern { subtraction.parse("1 - ") => Birman::Failure(pos: 4, expected: ["integer"]) }
    assert_pattern { subtraction.parse("1 - 2 -") => Birman::Failure(pos: 7, expected: ["integer"]) }
  end

  def test_a_bad_token_mid_chain
    assert_pattern { subtraction.parse("1 - 2 - x - 3") => Birman::Failure(pos: 8, expected: ["integer"]) }
    assert_pattern { subtraction.parse("1 - 2 3") => Birman::Failure(pos: 6, expected: ['"-"', "end of input"]) }
  end

  # infix labels its operators "operator"; the rules here don't.
  def test_errors_at_the_calculators_positions
    ["1 + ", "1 + 2 * ", "(1 - 2", "1 + 2 )", "1 + * 2"].each do |input|
      assert_equal Calc::Grammar.parse(input).pos, calc.parse(input).pos, input.inspect
    end
    assert_pattern { calc.parse("1 + 2 * ") => Birman::Failure(pos: 8, expected: ["expression"]) }
    assert_pattern { calc.parse("(1 - 2") => Birman::Failure(pos: 6, expected: ['"*"', '"/"', '"+"', '"-"', '")"']) }
  end

  def test_a_commit_after_the_operator
    g = grammar { rule(:expr) { either(seq(expr, "-", commit, integer), integer) } }
    assert_pattern { g.parse("1 - 2 - x") => Birman::Failure(pos: 8, expected: ["integer"], committed: true) }
    assert_pattern { g.parse("1 - x") => Birman::Failure(pos: 4, expected: ["integer"], committed: true) }
    assert_equal [[1, "-", 2], "-", 3], g.parse!("1 - 2 - 3")
  end

  # A lookahead catches a commit failure from the middle of the growth;
  # the rule is tried again there afterwards, from scratch.
  def test_a_commit_failure_caught_by_a_lookahead_leaves_the_rule_retryable
    calls = 0
    flaky = Data.define do
      include Birman::Matcher

      define_method(:match) do |_ctx, pos|
        calls += 1
        Birman::Match.new(pos + 1, :digit) if calls > 1
      end
      def to_ast = [:str, "d"]
    end
    g = grammar(:top) do
      rule(:top) { either(seq(expr.present, "?"), expr) }
      rule(:expr) { either(seq(expr, "-", commit, flaky.new), integer) }
    end
    assert_equal [1, "-", :digit], g.new.parse!("1-2")
    assert_equal 2, calls
  end

  # --- Shapes Warth's algorithm gives as they are ---

  # With the rule on both sides of the operator the growth makes it
  # right-associative (Tratt 2010): the right-hand call grows too, to
  # the end of the input, before the left can.
  def test_the_rule_on_both_sides_groups_to_the_right
    g = grammar do
      rule(:expr) { either(seq(expr, "-", expr).map { |l, _, r| l - r }, integer) }
    end
    assert_equal 4, g.parse!("3-4-5") # 3 - (4 - 5)
  end

  # --- Depth ---

  # The growth is a loop: each longer match reuses the last one from
  # the memo, so a longer chain uses no more stack.
  def test_a_long_chain_uses_no_extra_stack
    depths = []
    g = grammar do
      rule(:expr) { either(seq(expr, "-", num).map { |l, _, r| l - r }, num) }
      rule(:num) { integer.map { |n| (depths << caller_locations.size) && n } }
    end
    assert_equal(-8, g.new.parse!(Array.new(10, "1").join("-")))
    short = depths.max
    depths.clear
    assert_equal(-9998, g.new.parse!(Array.new(10_000, "1").join("-")))
    assert_equal short, depths.max
  end

  # Nesting still uses stack, and too much of it is a Failure, wherever
  # in the growth it runs out: starting each parse a frame deeper moves
  # where that is.
  def test_nesting_too_deeply_is_a_failure
    g = calc.new
    input = "#{"(" * 20_000}1#{")" * 20_000}"
    100.times do |frames|
      failure = deeper(frames) { g.parse(input) }
      assert_equal "input is nested too deeply", failure.reason, "#{frames} frames deeper"
    end
  end

  def deeper(frames, &) = frames.zero? ? yield : deeper(frames - 1, &)
end
