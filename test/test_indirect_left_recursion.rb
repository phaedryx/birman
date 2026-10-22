# frozen_string_literal: true

require "test_helper"
require_relative "support/compiler_helpers"
require_relative "support/examples"

# Indirect left recursion, grown from a seed at each cycle's leader (as
# pegen does): only the leader grows, and while it grows at a position
# the cycle's other rules are matched there afresh each round. Each
# grammar is also checked against its generated parser.
class TestIndirectLeftRecursion < Minitest::Test
  include CompilerTestHelpers

  Bin = Birman.node(:op, :left, :right)
  Num = Birman.node(:value)

  # Arithmetic as actions, which the generated parser copies.
  def numbers(root, ignore: :spacing, &rules)
    grammar(root, ignore:) do
      include Birman::Rules::Numbers

      def add(parts) = parts[0] + parts[2] # rubocop:disable Lint/NestedMethodDefinition
      def sub(parts) = parts[0] - parts[2] # rubocop:disable Lint/NestedMethodDefinition
      def mul(parts) = parts[0] * parts[2] # rubocop:disable Lint/NestedMethodDefinition
      def div(parts) = parts[0] / parts[2] # rubocop:disable Lint/NestedMethodDefinition
      class_eval(&rules)
    end
  end

  # Citrus PR mjackson/citrus#19's ILR: x -> expr -> x.
  def ilr
    numbers(:x) do
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", num).action(:sub), num) }
      rule(:num) { integer }
    end
  end

  # Its BigILR: t -> term -> t over f -> fa -> fact -> f, two cycles
  # nested by precedence.
  def big_ilr
    numbers(:t) do
      rule(:t) { term }
      rule(:term) do
        either(seq(t, "+", f).action(:add), seq(t, "-", f).action(:sub), f)
      end
      rule(:f) { fa }
      rule(:fa) { fact }
      rule(:fact) do
        either(seq(f, "*", num).action(:mul), seq(f, "/", num).action(:div), num)
      end
      rule(:num) { integer }
    end
  end

  # --- Values ---

  def test_ilr
    assert_equal(-6, ilr.parse!("3-4-5"))
    assert_equal 3, ilr.parse!("3")
    assert_same_results ilr, ["3-4-5", " 3 - 4 - 5 ", "3", "3-", "3-4-x", "", "-"]
  end

  def test_big_ilr
    assert_equal(-6, big_ilr.parse!("3-4-5"))
    assert_equal(-50, big_ilr.parse!("5*4*2-5*9*2"))
    assert_equal 13, big_ilr.parse!("1 + 2 * 6 / 3 * 3")
    assert_same_results big_ilr, ["3-4-5", "5*4*2-5*9*2", "1 + 2 * 6 / 3 * 3", "5*", "5*4-", "5 5", ""]
  end

  # examples/calc.rb's arithmetic through two cycles (see
  # Examples::LeftCalc::Indirect) gives the same trees as its infix.
  def test_the_same_trees_as_the_calculators_infix
    inputs = ["1 + 2 * 3", "1 - 2 - 3", "8 / 4 / 2", "(1 - 2) - (3 - 4) * 5 * 6", "2 * (3 + 4) - 5 + 6 / 7", "42"]
    inputs.each do |input|
      assert_equal Calc::Grammar.parse!(input), Examples::LeftCalc::Indirect.parse!(input), input
    end
  end

  # In BigILR, fact first matches just a number at 0, then f * num once
  # f's seed has grown: a match of fact kept from the first round would
  # stop f at "5".
  def test_the_cycles_other_rules_are_matched_again_each_round
    g = numbers(:f) do
      rule(:f) { fa }
      rule(:fa) { fact }
      rule(:fact) { either(seq(f, "*", num).action(:mul), num) }
      rule(:num) { integer }
    end
    assert_equal 40, g.parse!("5*4*2")
    assert_same_results g, ["5*4*2", "5*4*", "5"]
  end

  def test_a_cycle_through_three_rules
    g = numbers(:a) do
      rule(:a) { b }
      rule(:b) { either(c, parens(a)) }
      rule(:c) { either(seq(a, "-", integer).action(:sub), integer) }
    end
    assert_equal(-6, g.parse!("3-4-5"))
    assert_equal(-6, g.parse!("(3-4)-5"))
    assert_same_results g, ["3-4-5", "(3-4)-5", "(3-4-5", "3-", ""]
  end

  # Every way round passes through :b, which calls itself, so it leads,
  # though :a is used first.
  def test_a_cycle_led_by_a_rule_that_also_calls_itself
    g = grammar(:a) do
      rule(:a) { either(seq(b, "!"), "x") }
      rule(:b) { either(seq(b, "+"), seq(a, "-"), "y") }
    end
    assert_equal :b, g.new.left_recursion.leader(:a)
    assert_equal [[[[["y", "+"], "!"], "-"], "+"], "!"], g.parse!("y+!-+!")
    assert_equal [["x", "-"], "!"], g.parse!("x-!")
    assert_same_results g, ["y+!-+!", "x-!", "y+", "x-", "x", "y", ""]
  end

  # Medeiros et al. 2014's mutually left-recursive l-values: P grows
  # inside L. Here P leads, and grows to the whole subject.
  def test_the_papers_lvalues_from_their_leader
    g = grammar(:pp) do
      rule(:pp) { either(seq(pp, "(n)"), l) }
      rule(:l) { either(seq(pp, ".x"), "x") }
    end
    assert_equal :pp, g.new.left_recursion.leader(:l)
    assert_equal [[[[["x", "(n)"], "(n)"], ".x"], "(n)"], ".x"], g.parse!("x(n)(n).x(n).x")
    assert_same_results g, ["x(n)(n).x(n).x", "x.x", "x(n)", "x(n).", ""]
  end

  # Entered at L instead, L sees only P's final match, which already ate
  # the ".x" L needs: pegen's approach gives "x" here, where the paper's
  # semantics, growing L around P, gives the whole subject. Pinned, not
  # designed.
  def test_the_papers_lvalues_from_another_rule
    g = grammar(:l) do
      rule(:l) { either(seq(pp, ".x"), "x") }
      rule(:pp) { either(seq(pp, "(n)"), l) }
    end
    assert_pattern { g.parse("x(n)(n).x(n).x") => Birman::Failure(pos: 14, expected: ['"(n)"', '".x"']) }
    assert_equal "x", g.parse!("x")
    assert_pattern { g.parse("x.x") => Birman::Failure(pos: 3) }
    assert_same_results g, ["x(n)(n).x(n).x", "x(n).x", "x.x", "x", ""]
  end

  # --- Shapes ---

  # Tratt 2010's expr op expr, through a cycle: as with direct left
  # recursion, the right-hand call grows to the end of the input first,
  # so it groups to the right.
  def test_the_rule_on_both_sides_groups_to_the_right
    g = numbers(:x) do
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", x).action(:sub), integer) }
    end
    assert_equal 4, g.parse!("3-4-5") # 3 - (4 - 5)
    assert_same_results g, ["3-4-5", "3-4", "3-", ""]
  end

  def test_spans_cross_rule_boundaries
    g = numbers(:x) do
      rule(:x) { expr }
      rule(:expr) { either(seq(x.as(:left), either("-").as(:op), term.as(:right)).to(Bin), term) }
      rule(:term) { integer.to(Num) }
    end
    tree = g.parse!("1 - 2 - 3 ")
    assert_equal "1 - 2 - 3", tree.span.text
    assert_equal "1 - 2", tree.left.span.text
    assert_equal "1", tree.left.left.span.text
    assert_equal "3", tree.right.span.text
    assert_same_results g, ["1 - 2 - 3 ", "1", " 1 -", "1 - 2 x"]
  end

  def test_wrappers_around_the_cycling_call
    wrappers = {
      label: ->(m) { m.label("expression") },
      quiet: lambda(&:quiet),
      map: ->(m) { m.map(:itself) }
    }
    wrappers.each do |name, wrap|
      g = numbers(:x) do
        rule(:x) { wrap.call(expr) }
        rule(:expr) { either(seq(wrap.call(x), "-", integer), integer) }
      end
      assert_equal [[3, "-", 4], "-", 5], g.parse!("3-4-5"), "through #{name}"
      assert g.parse("3-4-5-").failure?, "through #{name}"
      assert_same_results g, ["3-4-5", "3-4-5-", "3 x", ""]
    end
  end

  # The ignore rule can be in a cycle too.
  def test_the_ignore_rule_in_a_cycle
    g = numbers(:expr, ignore: :blank) do
      rule(:expr) { either(seq(expr, "-", integer).action(:sub), integer) }
      rule(:blank) { either(seq(gap, str("#")), match(/ */)).quiet }
      rule(:gap) { blank }
    end
    assert_equal :blank, g.new.left_recursion.leader(:gap)
    assert_equal(-6, g.parse!(" ##3 -#4  ##- 5"))
    assert_pattern { g.parse("3 - # x") => Birman::Failure(pos: 5, expected: ["integer"]) }
    assert_same_results g, [" ##3 -#4  ##- 5", "3 - # x", "#", ""]
  end

  # --- Errors ---

  def test_a_trailing_operator_expects_what_follows_it
    assert_pattern { ilr.parse("1 - ") => Birman::Failure(pos: 4, expected: ["integer"]) }
    assert_pattern { big_ilr.parse("1 - 2 *") => Birman::Failure(pos: 7, expected: ["integer"]) }
  end

  # A commit failure reports what its own round expected, not what an
  # earlier round failed on, whether the commit is in the leader or in
  # another rule of the cycle.
  def test_a_commit_failure_mid_growth_ignores_earlier_rounds
    leader = grammar(:x) do
      rule(:x) { either(seq(x, "+", commit, "x"), expr) }
      rule(:expr) { either(seq(x, "-", "y"), seq("1", "+", match(/y/), "w"), "1") }
    end
    assert_pattern { leader.parse("1+yz") => Birman::Failure(pos: 2, expected: ['"x"'], committed: true) }
    assert_same_results leader, ["1+yz", "1+z", "1+x+yz", "1+x", "1-y+x-y+q", "1-y-"]

    other = grammar(:x) do
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "+", commit, "x"), seq("1", "+", match(/y/), "w"), "1") }
    end
    assert_pattern { other.parse("1+yz") => Birman::Failure(pos: 2, expected: ['"x"'], committed: true) }
    assert_same_results other, ["1+yz", "1+z", "1+x+yz", "1+x"]

    # The leader's round fails further along before the other rule's
    # commit: that failure is the round's, not the commit's.
    further = grammar(:x) do
      rule(:x) { either(seq(x, "+", "y", "w"), expr) }
      rule(:expr) { either(seq(x, "+", commit, "x"), "1") }
    end
    assert_pattern { further.parse("1+yz") => Birman::Failure(pos: 2, expected: ['"x"'], committed: true) }
    assert_same_results further, ["1+yz", "1+yw+x", "1+x+yz", "1+z"]

    stmt = grammar(:stmt) do
      rule(:stmt) { seq(x, ";") }
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", commit, atom), seq(atom, "-", "-"), atom) }
      rule(:atom) { match(/[a-z0-9]/) }
    end
    assert_same_results stmt, ["a-1;", "a--;", "a-b;", "a-;", "a--1;", "a-b-;"]
  end

  # A lookahead catches a commit failure from the middle of the growth;
  # the cycle is tried again there afterwards, from scratch.
  def test_a_commit_failure_caught_by_a_lookahead_leaves_the_cycle_retryable
    calls = 0
    flaky = Data.define do
      include Birman::Matcher

      define_method(:match) do |_ctx, pos|
        calls += 1
        Birman::Match.new(pos + 1, :digit) if calls > 1
      end
      def to_ast = [:str, "d"]
    end
    g = numbers(:top) do
      rule(:top) { either(seq(x.present, "?"), x) }
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", commit, flaky.new), integer) }
    end
    assert_equal [1, "-", :digit], g.new.parse!("1-2")
    assert_equal 2, calls

    g = numbers(:top) do
      rule(:top) { either(seq(x.present, "?"), x) }
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", commit, integer), integer) }
    end
    assert_same_results g, ["1 - 2 ?", "1 - 2", "1 - x", "1 - 2 - x", "1 ?", "x"]
  end

  # --- Depth ---

  def test_a_long_chain_uses_no_extra_stack
    depths = []
    g = numbers(:x) do
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", num).action(:sub), num) }
      rule(:num) { integer.map { |n| (depths << caller_locations.size) && n } }
    end
    assert_equal(-8, g.new.parse!(Array.new(10, "1").join("-")))
    short = depths.max
    depths.clear
    assert_equal(-9998, g.new.parse!(Array.new(10_000, "1").join("-")))
    assert_equal short, depths.max

    g = grammar(:x) do
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", str("1")).means(0), str("1")) }
    end
    assert_same_results g, [Array.new(10_000, "1").join("-"), "#{Array.new(10_000, "1").join("-")}-"]
  end
end
