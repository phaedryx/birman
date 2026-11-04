# frozen_string_literal: true

require "test_helper"
require_relative "support/compiler_helpers"

# operators(operand, *levels): a precedence table, interpreter side.
class OperatorsTest < Minitest::Test
  include CompilerTestHelpers

  Bin = Birman.node(:op, :left, :right)
  Un = Birman.node(:op, :operand)
  Leaf = Birman.node(:value)

  def bin(sym, lhs, rhs) = Bin.new(op: sym, left: lhs, right: rhs)

  def num_grammar(*levels, operand: nil)
    grammar do
      ignore :spacing
      rule(:top) { operators(operand ? instance_exec(&operand) : num, *levels) }
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
end
