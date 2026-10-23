# frozen_string_literal: true

require "test_helper"

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
end
