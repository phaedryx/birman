# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "support/compiler_helpers"

# operators(operand, *levels): a precedence table, interpreter side.
class OperatorsTest < Minitest::Test
  include CompilerTestHelpers

  Bin = Birman.node(:op, :left, :right)
  Un = Birman.node(:op, :operand)
  Leaf = Birman.node(:value)

  def bin(sym, lhs, rhs) = Bin.new(op: sym, left: lhs, right: rhs)

  def num_grammar(*levels)
    grammar do
      ignore :spacing
      rule(:top) { operators(num, *levels) }
      lexeme(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
  end

  def test_left_levels_bind_by_rank
    g = num_grammar({ left: ["*", "/"], node: Bin }, { left: ["+", "-"], node: Bin })
    tree = g.parse!("1 + 2 * 3 - 4")
    want = bin("-", bin("+", Leaf.new(1), bin("*", Leaf.new(2), Leaf.new(3))), Leaf.new(4))
    assert_equal want, tree
    assert_equal "1 + 2 * 3 - 4", tree.span.text
    assert_equal "2 * 3", tree.left.right.span.text
  end

  def test_right_level_groups_right
    tree = num_grammar({ right: "^", node: Bin }).parse!("2 ^ 3 ^ 4")
    assert_equal bin("^", Leaf.new(2), bin("^", Leaf.new(3), Leaf.new(4))), tree
    assert_equal "3 ^ 4", tree.right.span.text
  end

  def test_mixed_right_and_left
    g = grammar do
      ignore :spacing
      rule(:top) do
        operators(either(num, var),
                  { right: "^", node: Bin }, { left: "*", node: Bin }, { right: "=", node: Bin })
      end
      lexeme(:num) { match(/\d+/).map(:to_i).to(Leaf) }
      lexeme(:var) { match(/[a-z]/).to(Leaf) }
    end
    want = bin("=", Leaf.new("a"),
               bin("=", Leaf.new("b"),
                   bin("*", bin("*", Leaf.new(2), bin("^", Leaf.new(3), Leaf.new(2))), Leaf.new(4))))
    assert_equal want, g.parse!("a = b = 2 * 3 ^ 2 * 4")
  end

  def test_trailing_operator_stops_before_it
    g = num_grammar({ left: "+", node: Bin })
    assert_equal Leaf.new(1), g.parse("1 +", consume: false).value
    old = grammar do
      ignore :spacing
      rule(:top) { infix(num, "+", node: Bin) }
      lexeme(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
    got = g.parse("1 +")
    want = old.parse("1 +")
    assert got.failure?
    assert_equal want.pos, got.pos
    assert_equal want.expected, got.expected
  end

  def test_table_errors
    bad = [
      [],
      [{ node: Bin }],
      [{ left: "+", right: "-", node: Bin }],
      [{ middle: "+", node: Bin }],
      [{ left: "+" }],
      [{ left: [], node: Bin }],
      ["+"]
    ]
    bad.each do |levels|
      g = Class.new { include Birman::Combinators }.new
      assert_raises(ArgumentError, levels.inspect) { g.operators(Birman.coerce("x"), *levels) }
    end
  end

  def test_wrong_node_fields
    g = grammar { rule(:top) { operators(match(/\d/), { left: "+", node: Un }) } }
    error = assert_raises(ArgumentError) { g.parse("1+2") }
    assert_match(/op, left and right/, error.message)
    g = grammar { rule(:top) { operators(match(/\d/), { prefix: "-", node: Bin }) } }
    error = assert_raises(ArgumentError) { g.parse("1+2") }
    assert_match(/op and operand/, error.message)
  end

  def test_prefix_looser_than_power
    g = num_grammar({ right: "**", node: Bin }, { prefix: "-", node: Un }, { left: "*", node: Bin })
    assert_equal Un.new(op: "-", operand: bin("**", Leaf.new(2), Leaf.new(2))), g.parse!("-2 ** 2")
    assert_equal bin("**", Leaf.new(2), Un.new(op: "-", operand: Leaf.new(3))), g.parse!("2 ** -3")
    assert_equal bin("*", Un.new(op: "-", operand: Leaf.new(2)), Leaf.new(3)), g.parse!("-2 * 3")
  end

  def test_prefix_chains_with_spans
    tree = num_grammar({ prefix: "-", node: Un }).parse!("- - 1")
    assert_equal Un.new(op: "-", operand: Un.new(op: "-", operand: Leaf.new(1))), tree
    assert_equal "- - 1", tree.span.text
    assert_equal "- 1", tree.operand.span.text
  end

  def test_postfix
    g = num_grammar({ postfix: "!", node: Un }, { left: "+", node: Bin })
    tree = g.parse!("1 + 2 !")
    assert_equal bin("+", Leaf.new(1), Un.new(op: "!", operand: Leaf.new(2))), tree
    assert_equal "2 !", tree.right.span.text
    assert_equal Un.new(op: "!", operand: Un.new(op: "!", operand: Leaf.new(3))), g.parse!("3!!")
  end

  def test_prefix_and_postfix_ranks
    tighter_prefix = num_grammar({ prefix: "-", node: Un }, { postfix: "!", node: Un })
    tree = tighter_prefix.parse!("-3!")
    assert_equal Un.new(op: "!", operand: Un.new(op: "-", operand: Leaf.new(3))), tree
    assert_equal "-3!", tree.span.text
    tighter_postfix = num_grammar({ postfix: "!", node: Un }, { prefix: "-", node: Un })
    assert_equal Un.new(op: "-", operand: Un.new(op: "!", operand: Leaf.new(3))), tighter_postfix.parse!("-3!")
  end

  def test_postfix_matcher_operator
    g = grammar do
      rule(:top) { operators(match(/[a-z]/), { postfix: seq("(", only(sep_by(num, ",")), ")"), node: Un }) }
      rule(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
    want = Un.new(op: [Leaf.new(1), Leaf.new(2)], operand: "f")
    assert_equal want, g.parse!("f(1,2)")
  end

  def test_prefix_without_operand_falls_back
    g = grammar do
      rule(:top) { operators(either(num, str("-").means(:dash).to(Leaf)), { prefix: "-", node: Un }) }
      rule(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
    assert_equal Leaf.new(:dash), g.parse!("-")
  end

  def test_empty_prefix_is_no_match
    g = grammar do
      ignore :spacing
      rule(:top) { operators(num, { prefix: match(/~*/), node: Un }) }
      lexeme(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
    assert_equal Leaf.new(1), g.parse!("1")
    assert_equal Un.new(op: "~~", operand: Leaf.new(1)), g.parse!("~~1")
  end

  def test_nullable_operand_and_postfix_terminate
    g = grammar { rule(:top) { operators(match(/a*/), { postfix: match(/!*/), node: Un }) } }
    Timeout.timeout(2) do
      assert_equal "", g.parse!("")
      assert_equal Un.new(op: "!!", operand: "a"), g.parse!("a!!")
      assert_equal Un.new(op: "!", operand: ""), g.parse!("!")
    end
  end

  def test_nullable_binary_operator_terminates
    g = grammar { rule(:top) { operators(match(/a*/), { left: match(/\+*/), node: Bin }) } }
    Timeout.timeout(2) do
      assert_equal "a", g.parse!("a")
      assert_equal bin("+", "a", "a"), g.parse!("a+a")
    end
  end

  def test_prefix_only_table_records_no_operator_expectation
    g = num_grammar({ prefix: "-", node: Un })
    plain = grammar do
      ignore :spacing
      rule(:top) { num }
      lexeme(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
    got = g.parse("1 x")
    want = plain.parse("1 x")
    assert got.failure?
    assert_equal want.pos, got.pos
    assert_equal want.expected, got.expected
  end

  def test_longer_operator_wins_across_levels
    g = grammar do
      ignore :spacing
      rule(:top) { operators(id, { left: "|", node: Bin }, { left: "||", node: Bin }) }
      lexeme(:id) { match(/[a-z]/) }
    end
    assert_equal bin("||", "a", bin("|", "b", "c")), g.parse!("a || b | c")
    g = grammar do
      ignore :spacing
      rule(:top) { operators(id, { left: "&", node: Bin }, { left: "&&", node: Bin }) }
      lexeme(:id) { match(/[a-z]/) }
    end
    assert_equal bin("&&", "a", bin("&", "b", "c")), g.parse!("a && b & c")
  end

  def test_munch_order_is_stable_and_leaves_matchers
    g = Class.new { include Birman::Combinators }.new
    op = g.operators(g.match(/\d/), { left: ["*", "**"], node: Bin }, { left: [g.match(/<>/), "<", "<="], node: Bin })
    assert_equal ["**", "*", g.match(/<>/), "<=", "<"], op.suffixes.map(&:source)
  end

  def test_errors_say_operator_and_hide_prefix
    g = grammar do
      ignore :spacing
      rule(:top) { operators(num.label("number"), { prefix: "-", node: Un }, { left: "+", node: Bin }) }
      lexeme(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
    old = grammar do
      ignore :spacing
      rule(:top) { infix(num.label("number"), "+", node: Bin) }
      lexeme(:num) { match(/\d+/).map(:to_i).to(Leaf) }
    end
    assert_equal old.parse("1 2").expected, g.parse("1 2").expected
    assert_equal ["number"], g.parse("1 +").expected
  end

  # --- to_ast, to_ebnf, left recursion ---

  def test_ast_of_one_left_level_equals_infix
    g = Class.new { include Birman::Combinators }.new
    num = g.match(/\d/)
    assert_equal g.infix(num, "+", "-", node: Bin).to_ast, g.operators(num, { left: ["+", "-"], node: Bin }).to_ast
  end

  def test_ast_is_flat
    g = Class.new { include Birman::Combinators }.new
    g.singleton_class.send(:define_method, :num) { Birman::Ref.new(:num) }
    op = g.operators(g.num, { postfix: "!", node: Un }, { prefix: "-", node: Un }, { left: "+", node: Bin })
    pre = [:quiet, g.lit("-").to_ast]
    bang = g.lit("!").to_ast
    plus = g.lit("+").to_ast
    want = [:seq, nil, [[:rep, 0, nil, pre], %i[ref num],
                        [:rep, 0, nil, [:label, "operator",
                                        [:choice, [bang, [:seq, nil, [plus, [:rep, 0, nil, pre], %i[ref num]]]]]]]]]
    assert_equal want, op.to_ast
  end

  def test_ast_of_a_prefix_only_table_has_no_operator_loop
    g = Class.new { include Birman::Combinators }.new
    op = g.operators(g.match(/\d/), { prefix: ["-", "+"], node: Un })
    pre = [:quiet, [:choice, [g.lit("-").to_ast, g.lit("+").to_ast]]]
    assert_equal [:seq, nil, [[:rep, 0, nil, pre], g.match(/\d/).to_ast]], op.to_ast
  end

  def test_ast_of_a_postfix_only_table_has_no_prefix_rep
    g = Class.new { include Birman::Combinators }.new
    op = g.operators(g.match(/\d/), { postfix: "!", node: Un })
    want = [:seq, nil, [g.match(/\d/).to_ast, [:rep, 0, nil, [:label, "operator", g.lit("!").to_ast]]]]
    assert_equal want, op.to_ast
  end

  def test_ebnf
    g = grammar do
      rule(:top) do
        operators(num, { prefix: "-", node: Un }, { left: ["*", "/"], node: Bin }, { left: ["+", "-"], node: Bin })
      end
      rule(:num) { match(/\d+/) }
    end
    assert_includes g.new.to_ebnf, %(top = "-"* num (("*" / "/" / "+" / "-") "-"* num)* ;)
  end

  def test_nullability_and_left_calls
    build = lambda do |operand|
      grammar do
        rule(:top) { operators(send(operand), { prefix: sign, node: Un }, { left: "+", node: Bin }) }
        rule(:sign) { "-" }
        rule(:num) { match(/\d+/) }
        rule(:opt) { match(/a?/) }
      end.new.left_recursion
    end
    with_num = build.call(:num)
    assert_includes with_num.left_calls(:top), :sign
    assert_includes with_num.left_calls(:top), :num
    refute with_num.nullable?(:top)
    assert build.call(:opt).nullable?(:top)
  end

  def test_operand_left_recursion_is_reported
    message = "left-recursive rule :top has no alternative that doesn't start with :top, so it can never " \
              "match; add one that doesn't, as a base case"
    klass = grammar { rule(:top) { operators(top, { left: "+", node: Bin }) } }
    ["x", "1", ""].each do |input|
      error = assert_raises(ArgumentError, input.inspect) { klass.parse(input) }
      assert_equal message, error.message
    end
  end

  # A right operator that can match nothing, on an operand that can too,
  # used to recurse at its own start until "nested too deeply".
  def test_nullable_right_operator_with_nullable_operand
    g = grammar { rule(:top) { operators(match(/a*/), { right: match(/=*/), node: Bin }) } }
    assert_equal "", g.parse("").value
    assert_equal "a", g.parse("a").value
    assert_equal bin("=", "a", "a"), g.parse("a=a").value
    assert g.parse("a==a=a").success?
  end

  def test_nullable_right_operator_juxtaposes
    g = grammar { rule(:top) { operators(match(/a/), { right: match(/=*/), node: Bin }) } }
    assert_equal bin("", "a", bin("", "a", "a")), g.parse("aaa").value
  end
end
