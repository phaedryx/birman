# frozen_string_literal: true

require "test_helper"
require_relative "support/differential"

# Grammar#parse's offset: option: the character offset the parse starts
# at. Positions stay relative to the whole input.
class TestParseOffset < Minitest::Test
  Pair = Birman.node(:name, :value)

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

  # --- Where the parse starts ---

  def test_offset_starts_the_parse_partway_into_the_input
    result = pairs.parse("x = 1 b = 2", offset: 6)
    assert_equal ["b", "=", 2], result.value
    assert_equal 11, result.pos
  end

  def test_offset_zero_is_the_default
    assert_equal pairs.parse("a = 1"), pairs.parse("a = 1", offset: 0)
    assert_equal 5, pairs.parse("a = 1", offset: 0).pos
  end

  def test_offset_counts_characters
    result = pairs.parse("ñ = 1 b = 2", offset: 6)
    assert_equal ["b", "=", 2], result.value
  end

  def test_offset_may_be_the_end_of_the_input
    g = grammar { rule(:pair) { match(/\d*/) } }
    result = g.parse("abc", offset: 3)
    assert_equal "", result.value
    assert_equal 3, result.pos
  end

  def test_an_offset_outside_the_input_raises
    error = assert_raises(ArgumentError) { pairs.parse("a = 1", offset: 6) }
    assert_equal "offset 6 is outside the input (0..5)", error.message
    error = assert_raises(ArgumentError) { pairs.parse("ñ = 1", offset: 6) }
    assert_equal "offset 6 is outside the input (0..5)", error.message
    assert_raises(ArgumentError) { pairs.parse("a = 1", offset: -1) }
    assert_raises(ArgumentError) { pairs.parse!("a = 1", offset: 6) }
  end

  def test_an_offset_that_isnt_an_integer_raises
    error = assert_raises(ArgumentError) { pairs.parse("a = 1", offset: 1.0) }
    assert_equal "offset must be an Integer, not 1.0", error.message
    assert_raises(ArgumentError) { pairs.parse("a = 1", offset: 0.0) }
  end

  def test_offset_counts_bytes_as_characters_in_single_byte_encodings
    assert_equal ["b", "=", 2], pairs.parse("\xFF = 1 b = 2".b, offset: 6).value
    assert_equal ["b", "=", 2], pairs.parse("x = 1 b = 2".encode("US-ASCII"), offset: 6).value
  end

  # --- Positions are relative to the whole input ---

  def test_success_pos_counts_from_the_start_of_the_input
    input = "ñ = 1 b = 2 c = 3"
    result = pairs.parse(input, offset: 6, consume: false)
    assert_equal 11, result.pos
    assert_equal " c = 3", input[result.pos..]
  end

  def test_failure_positions_count_from_the_start_of_the_input
    input = "ñ = 1\nb = x"
    failure = pairs.parse(input, offset: 6)
    assert_equal 10, failure.pos
    assert_equal 2, failure.line
    assert_equal 5, failure.column
    assert_equal '"x"', failure.found
    assert_includes failure.expected, "integer"
  end

  def test_node_spans_count_from_the_start_of_the_input
    g = grammar { rule(:pair) { seq(identifier.as(:name), "=", integer.as(:value)).to(Pair) } }
    node = g.parse!("ñ = 1 b = 2", offset: 6)
    assert_equal 6, node.span.from
    assert_equal 11, node.span.to
    assert_equal "b = 2", node.span.text
  end

  # --- Leading ignore ---

  def test_ignored_spacing_at_the_offset_is_skipped
    result = pairs.parse("x = 1   \n b = 2", offset: 5)
    assert_equal ["b", "=", 2], result.value
    assert_equal 15, result.pos
  end

  # --- Anchors see the whole input ---

  def test_a_start_anchor_doesnt_match_at_an_offset
    g = grammar { rule(:pair) { match(/\Ab/) } }
    assert_equal "b", g.parse!("b")
    failure = g.parse("ab", offset: 1)
    assert_kind_of Birman::Failure, failure
    assert_equal 1, failure.pos
  end

  def test_a_lookbehind_sees_the_input_before_the_offset
    g = grammar { rule(:pair) { match(/(?<=a)b/) } }
    assert_equal "b", g.parse!("ab", offset: 1)
    assert_kind_of Birman::Failure, g.parse("b")
  end

  # --- Invalid input ---

  # Regexps refuse a string with invalid bytes wherever they are, so
  # the whole input is checked, not just the part from the offset.
  def test_invalid_utf8_before_the_offset_is_a_failure_there
    failure = pairs.parse("\xFF = 1 b = 2", offset: 6)
    assert_equal "invalid UTF-8", failure.reason
    assert_equal 0, failure.pos
  end

  def test_invalid_utf8_after_the_offset_is_a_failure_there
    failure = pairs.parse("a = 1 b = \xFF", offset: 6)
    assert_equal "invalid UTF-8", failure.reason
    assert_equal 10, failure.pos
  end

  # --- With root:, consume: and left recursion ---

  def expressions
    grammar do
      rule(:pair) { seq(identifier, "=", expr) }
      rule(:expr) { either(seq(expr, "-", integer).action(:minus), integer) }

      def minus(parts) = parts[0] - parts[2] # rubocop:disable Lint/NestedMethodDefinition
    end
  end

  def test_a_left_recursive_root_grows_from_the_offset
    assert_equal(-4, expressions.parse!("x = 1 - 2 - 3", root: :expr, offset: 4))
    result = expressions.parse("x = 1 - 2 - 3 !", root: :expr, offset: 4, consume: false)
    assert_equal(-4, result.value)
    assert_equal 13, result.pos
  end

  def test_end_of_input_means_the_real_end
    failure = pairs.parse("x = 1 b = 2 c", offset: 6)
    assert_equal 12, failure.pos
    assert_includes failure.expected, "end of input"
    assert_kind_of Birman::Success, pairs.parse("x = 1 b = 2 c", root: :pairs, offset: 6, consume: false)
  end

  # --- Every entry point ---

  def test_parse_bang_and_the_instance_methods_take_offset
    assert_equal ["b", "=", 2], pairs.parse!("x = 1 b = 2", offset: 6)
    assert_equal ["b", "=", 2], pairs.new.parse!("x = 1 b = 2", offset: 6)
    assert_equal 11, pairs.new.parse("x = 1 b = 2", offset: 6).pos
  end

  def test_birman_parse_takes_offset
    m = Birman.seq("b", "c")
    result = Birman.parse(m, "a b c", ignore: /\s*/, offset: 1)
    assert_equal %w[b c], result.value
    assert_equal 5, result.pos
    assert_equal %w[b c], Birman.parse!(m, "ñ b c d", ignore: /\s*/, offset: 1, consume: false)
    assert_raises(ArgumentError) { Birman.parse(m, "a b c", offset: 9) }
  end

  # --- to_ruby ---

  def generated(grammar, **)
    Differential.load(grammar, "ParseOffsetParser", **)
  end

  def test_a_generated_parser_takes_offset
    parser = generated(pairs)
    result = parser.new("ñ = 1 b = 2").parse(offset: 6)
    assert_equal ["b", "=", 2], result.value
    assert_equal 11, result.pos
    assert_equal 11, parser.new("ñ = 1 b = 2 c").parse(offset: 6, consume: false).pos
  end

  def test_a_generated_parser_refuses_an_offset_outside_the_input
    parser = generated(pairs)
    error = assert_raises(ArgumentError) { parser.new("a = 1").parse(offset: 6) }
    assert_equal "offset 6 is outside the input (0..5)", error.message
    error = assert_raises(ArgumentError) { parser.new("ñ = 1").parse(offset: 6) }
    assert_equal "offset 6 is outside the input (0..5)", error.message
    assert_raises(ArgumentError) { parser.new("a = 1").parse(offset: -1) }
    assert_equal "", generated(grammar { rule(:pair) { match(/\d*/) } }).new("abc").parse(offset: 3).value
  end

  def test_a_generated_parser_parses_from_an_offset_as_the_interpreter_does
    g = grammar do
      rule(:pair) { seq(identifier.as(:name), "=", expr.as(:value)).to(Pair) }
      rule(:expr) { either(seq(expr, "-", integer).action(:minus), integer) }

      def minus(parts) = parts[0] - parts[2] # rubocop:disable Lint/NestedMethodDefinition
    end
    parser = generated(g, roots: [:expr])
    inputs = ["ñ = 1 b = 2", "ñ = 1 b = 2 - 3", "ñ = 1 b = 2 - x", "ñ = 1 b = 2 c", "ñ = 1   \n b = 2", "ñ = 1 ",
              "é\nb = \xFF", "\xFF = 1 b = 2", "ñ = 1 b = 1 - 2 - 3 !", "\xFF = 1 b = 2".b, "\xFF = 1 b = x".b,
              "x = 1 b = 2".encode("US-ASCII")]
    options = [{ offset: 6 }, { offset: 6, consume: false }, { offset: 9, root: :expr }, { offset: 1, consume: false },
               { offset: 10, root: :expr, consume: false }]
    options.product(inputs).each do |opts, input|
      next if opts[:offset] > input.length

      assert_equal Differential.interpreted(g, input, **opts), Differential.generated(parser, input, **opts),
                   "#{input.inspect} #{opts}"
    end
  end
end
