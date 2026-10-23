# frozen_string_literal: true

require "test_helper"
require_relative "support/differential"

# Grammar#parse's options: consume: false, which succeeds when a prefix
# of the input matches, and root:, which starts at any rule.
class TestParseOptions < Minitest::Test
  def grammar(&rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace
      include Birman::Rules::Numbers
      include Birman::Rules::Identifiers

      root :pair
      ignore :spacing
      class_eval(&rules)
    end
  end

  def pairs
    grammar do
      rule(:pair) { seq(identifier, "=", integer) }
      rule(:pairs) { pair.rep(1) }
    end
  end

  # --- consume: false ---

  def test_consume_false_matches_a_prefix
    result = pairs.parse("a = 1 b = 2", consume: false)
    assert_equal Birman::Success.new(["a", "=", 1]), result
    assert_equal 5, result.pos
  end

  def test_consume_false_matches_all_of_the_input
    result = pairs.parse("a = 1", consume: false)
    assert_equal ["a", "=", 1], result.value
    assert_equal 5, result.pos
  end

  def test_consume_false_with_an_empty_match
    g = grammar { rule(:pair) { match(/\d*/) } }
    result = g.parse("abc", consume: false)
    assert_equal "", result.value
    assert_equal 0, result.pos
  end

  # The position is where the last token ended, before the spacing
  # ignored after it, as a node's span ends.
  def test_the_end_position_is_before_trailing_ignored_spacing
    assert_equal 5, pairs.parse("a = 1   \n b = 2", consume: false).pos
    assert_equal 5, pairs.parse("a = 1   \n ").pos
  end

  def test_the_end_position_counts_characters
    g = grammar { rule(:pair) { seq(match(/[^=\s]+/), "=", integer) } }
    assert_equal 7, g.parse("ñandú=1 ñ=2", consume: false).pos
    assert_equal 7, g.parse("ñandú=1  ").pos
  end

  def test_consume_false_fails_only_when_the_root_fails
    failure = pairs.parse("a = x", consume: false)
    assert_kind_of Birman::Failure, failure
    assert_equal 4, failure.pos
    refute_includes failure.expected, "end of input"

    failure = pairs.parse("= 1", consume: false)
    assert_equal 0, failure.pos
    refute_includes failure.expected, "end of input"
  end

  def test_by_default_the_whole_input_must_parse
    failure = pairs.parse("a = 1 b = 2")
    assert_includes failure.expected, "end of input"
  end

  def test_committed_failures_are_unchanged_by_consume_false
    g = grammar { rule(:pair) { seq(identifier, "=", commit, integer) } }
    failure = g.parse("a = x", consume: false)
    assert failure.committed
    assert_equal 4, failure.pos
  end

  def test_success_still_matches_one_positional_field
    [pairs.parse("a = 1"), pairs.parse("a = 1 b", consume: false)].each do |result|
      matched = case result
                in Birman::Success(value) then value
                end
      assert_equal ["a", "=", 1], matched
    end
  end

  def test_the_end_position_is_left_out_of_equality_and_inspect
    a = pairs.parse("a = 1 b", consume: false)
    b = pairs.parse("a = 1")
    assert_equal a, b
    assert_equal({ value: ["a", "=", 1] }, a.to_h)
    refute_includes a.inspect, "pos"
  end

  def test_a_success_built_by_hand_has_no_end_position
    assert_nil Birman::Success.new(1).pos
  end

  def test_parse_bang_takes_consume
    assert_equal ["a", "=", 1], pairs.parse!("a = 1 b", consume: false)
    assert_raises(Birman::ParseError) { pairs.parse!("a = 1 b") }
  end

  def test_the_instance_methods_take_consume
    assert_equal 5, pairs.new.parse("a = 1 b", consume: false).pos
    assert_equal ["a", "=", 1], pairs.new.parse!("a = 1 b", consume: false)
  end

  def test_birman_parse_takes_consume
    m = Birman.seq("a", "b")
    result = Birman.parse(m, "a b c", ignore: /\s*/, consume: false)
    assert_equal %w[a b], result.value
    assert_equal 3, result.pos
    assert_equal %w[a -], Birman.parse!(Birman.seq("a", "-"), "a-b", consume: false)
  end

  # The matcher is the only rule, so there's nothing for root: to name.
  def test_birman_parse_takes_no_root
    assert_raises(ArgumentError) { Birman.parse("a", "a", root: :a) }
    assert_raises(ArgumentError) { Birman.parse!("a", "a", root: :a) }
  end
  # --- root: ---

  def expressions
    grammar do
      rule(:pair) { seq(identifier, "=", expr) }
      rule(:expr) { either(seq(expr, "-", integer).action(:minus), integer) }
      lexeme(:word) { match(/[a-z]+/) }
      # Not reachable from :pair.
      rule(:product) { either(seq(product, "*", integer).action(:times), integer) }
      rule(:no_base) { seq(no_base, "!") }

      # rubocop:disable Lint/NestedMethodDefinition
      def minus(parts) = parts[0] - parts[2]
      def times(parts) = parts[0] * parts[2]
      # rubocop:enable Lint/NestedMethodDefinition
    end
  end

  def test_root_starts_at_a_plain_rule
    assert_equal [["a", "=", 1], ["b", "=", 2]], pairs.parse!("a = 1 b = 2", root: :pairs)
  end

  def test_root_starts_at_a_lexeme_rule
    result = expressions.parse(" abc  ", root: :word)
    assert_equal "abc", result.value
    assert_equal 4, result.pos
  end

  def test_root_starts_at_a_left_recursive_rule
    assert_equal(-4, expressions.parse!("1 - 2 - 3", root: :expr))
  end

  def test_root_grows_a_left_recursive_rule_the_default_root_never_reaches
    assert_equal 24, expressions.parse!("2 * 3 * 4", root: :product)
  end

  def test_root_checks_the_left_recursion_it_reaches
    g = expressions
    assert_equal ["a", "=", 1], g.parse!("a = 1")
    error = assert_raises(ArgumentError) { g.parse("x!", root: :no_base) }
    assert_match(/left-recursive rule :no_base has no alternative/, error.message)
    assert_raises(ArgumentError) { g.parse("x!", root: :no_base) }
  end

  # Starting elsewhere doesn't change which rule leads a cycle the
  # default root reaches, so a generated parser's one set of leaders is
  # the interpreter's for every root.
  def test_root_keeps_the_default_roots_leaders
    g = Class.new do
      include Birman::Grammar

      root :top
      rule(:top) { a }
      rule(:a) { either(seq(b, "a"), "x") }
      rule(:b) { either(seq(a, "b"), seq(b, "c"), "y") }
    end.new
    assert_equal({ a: :b, b: :b }, g.left_recursion.leaders)
    assert_equal g.left_recursion.leaders, g.left_recursion(:b).leaders
    assert_equal g.left_recursion.leaders, g.left_recursion(:a).leaders
  end

  def test_an_unknown_root_raises_naming_it
    error = assert_raises(ArgumentError) { pairs.parse("a = 1", root: :nope) }
    assert_equal "undefined rule :nope", error.message
    error = assert_raises(ArgumentError) { pairs.parse("a = 1", root: :send) }
    assert_equal "undefined rule :send", error.message
    assert_raises(ArgumentError) { pairs.parse!("a = 1", root: :nope) }
  end

  def test_root_works_without_a_default_root
    g = Class.new do
      include Birman::Grammar

      rule(:digits) { match(/\d+/) }
    end
    assert_equal "12", g.parse!("12", root: :digits)
  end

  def test_root_and_consume_together
    result = pairs.parse("a = 1 b = 2 !", root: :pairs, consume: false)
    assert_equal [["a", "=", 1], ["b", "=", 2]], result.value
    assert_equal 11, result.pos

    failure = expressions.parse("1 - x", root: :expr, consume: false)
    assert_equal Birman::Success.new(1), failure
    assert_equal 1, failure.pos
  end

  def test_parse_bang_takes_root
    assert_equal 3, expressions.parse!("5 - 2", root: :expr)
    error = assert_raises(Birman::ParseError) { expressions.parse!("5 -", root: :expr) }
    assert_includes error.failure.expected, "integer"
  end

  def test_the_instance_methods_take_root
    assert_equal 3, expressions.new.parse!("5 - 2", root: :expr)
    assert_equal 3, expressions.new.parse("5 - 2", root: :expr).value
  end

  # --- to_ruby ---

  def generated(grammar, **)
    Differential.load(grammar, "ParseOptionsParser", **)
  end

  def test_a_generated_parser_takes_consume_and_reports_where_it_stopped
    g = grammar { rule(:pair) { seq(match(/[^=\s]+/), "=", integer) } }
    result = generated(g).new("ñandú= 1   b = 2").parse(consume: false)
    assert_equal ["ñandú", "=", 1], result.value
    assert_equal 8, result.pos
    assert_equal 8, generated(g).new("ñandú= 1   ").parse.pos
  end

  def test_a_generated_parser_starts_at_its_roots
    parser = generated(expressions, roots: %i[expr product])
    assert_equal(-4, parser.new("1 - 2 - 3").parse(root: :expr).value)
    assert_equal 24, parser.new("2 * 3 * 4").parse(root: :product).value
    assert_equal ["a", "=", 1], parser.new("a = 1").parse.value
    assert_equal ["a", "=", 1], parser.new("a = 1").parse(root: :pair).value
  end

  def test_a_generated_parser_refuses_a_root_it_wasnt_generated_with
    parser = generated(expressions, roots: [:expr])
    error = assert_raises(ArgumentError) { parser.new("2").parse(root: :product) }
    assert_equal ":product isn't a root of this parser (:pair, :expr); Grammar.to_ruby's roots: adds others",
                 error.message
  end

  def test_to_ruby_refuses_roots_that_arent_rules
    error = assert_raises(ArgumentError) { expressions.to_ruby(namespace: "Nope", roots: [:nope]) }
    assert_equal "undefined rule :nope", error.message
  end

  def test_to_ruby_checks_the_left_recursion_its_roots_reach
    error = assert_raises(ArgumentError) { expressions.to_ruby(namespace: "Nope", roots: [:no_base]) }
    assert_match(/left-recursive rule :no_base has no alternative/, error.message)
  end

  # --- Leaders don't depend on where a parse starts ---

  # A cycle (aa, bb) either rule could lead, below the root, and entries
  # reaching it at each rule.
  def shifting
    Class.new do
      include Birman::Grammar

      root :top
      rule(:top) { ma }
      rule(:ma) { aa }
      rule(:aa) { either(seq(bb, "+"), "1") }
      rule(:bb) { either(seq(aa, "-"), aa) }
      rule(:xx) { bb }
      rule(:yy) { aa }
    end
  end

  def test_an_entry_doesnt_change_the_leaders_of_cycles_the_root_reaches
    g = shifting.new
    assert_equal({ aa: :aa, bb: :aa }, g.left_recursion.leaders)
    assert_equal g.left_recursion.leaders, g.left_recursion(:xx).leaders
    assert_equal g.left_recursion.leaders, g.left_recursion(%i[xx yy]).leaders
  end

  def test_leaders_of_cycles_only_entries_reach_dont_depend_on_the_entries
    g = Class.new(shifting) { root :zz }.tap { _1.rule(:zz) { "z" } }.new
    leaders = g.left_recursion(:yy).leaders
    assert_equal leaders, g.left_recursion(:xx).leaders
    assert_equal leaders, g.left_recursion(%i[xx yy]).leaders
    assert_equal leaders, g.left_recursion(%i[yy xx]).leaders
  end

  def test_a_parser_generated_with_roots_parses_as_the_interpreter_does
    g = shifting
    inputs = ["1+", "1-+", "1+-", "1", "1-", "1+-+"]
    parser = generated(g, roots: %i[xx yy])
    [{}, { root: :xx }, { root: :yy }, { root: :xx, consume: false }].each do |options|
      inputs.each do |input|
        assert_equal Differential.interpreted(g, input, **options), Differential.generated(parser, input, **options),
                     "#{input.inspect} #{options}"
      end
    end
    other = Class.new(g) { root :zz }.tap { _1.rule(:zz) { "z" } }
    parser = generated(other, roots: %i[xx yy])
    inputs.each do |input|
      assert_equal Differential.interpreted(other, input, root: :yy), Differential.generated(parser, input, root: :yy)
    end
  end

  def test_a_success_from_a_parse_survives_marshal
    result = pairs.parse("a = 1 b", consume: false)
    copy = Marshal.load(Marshal.dump(result))
    assert_equal result, copy
    assert_equal 5, copy.pos
  end
end
