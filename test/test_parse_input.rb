# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"
require "pathname"
require_relative "support/differential"

# What parse takes as input besides a String: anything with read (an IO,
# a StringIO, a File) or to_path (a Pathname), read once to a String.
class TestParseInput < Minitest::Test
  Pair = Birman.node(:name, :value)

  def pairs
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace
      include Birman::Rules::Numbers
      include Birman::Rules::Identifiers

      root :pair
      ignore :spacing
      rule(:pair) { seq(identifier.as(:name), "=", integer.as(:value)).to(Pair) }
    end
  end

  # pairs, but the value is a non-ASCII word, so a file read as
  # US-ASCII is invalid where one read as UTF-8 parses.
  def tilde_pairs
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace
      include Birman::Rules::Identifiers

      root :pair
      ignore :spacing
      rule(:pair) { seq(identifier.as(:name), "=", lit("ma\u00f1ana").as(:value)).to(Pair) }
    end
  end

  def with_file(text)
    Tempfile.create(["input", ".txt"], binmode: true) do |file|
      file.write(text)
      file.flush
      yield file
    end
  end

  # --- read ---

  def test_parses_a_stringio_as_its_contents
    assert_equal Pair.new(name: "a", value: 1), pairs.parse(StringIO.new("a = 1")).value
  end

  def test_reads_from_the_current_position_without_rewinding_or_closing
    io = StringIO.new("x = 0\na = 1")
    io.gets
    assert_equal Pair.new(name: "a", value: 1), pairs.parse(io).value
    assert io.eof?
    refute io.closed?
  end

  def test_a_failure_and_a_success_are_in_terms_of_the_string_read
    failure = pairs.parse(StringIO.new("a = b"))
    assert_equal "a = b", failure.input
    assert_equal 4, failure.pos
    assert_equal 5, pairs.parse(StringIO.new("a = 1 "), consume: false).pos
  end

  def test_parses_an_open_file_by_reading_it
    with_file("a = 1") do |file|
      file.rewind
      assert_equal Pair.new(name: "a", value: 1), pairs.parse(file).value
      refute file.closed?
    end
  end

  def test_parse_bang_birman_parse_and_birman_parse_bang_read_too
    assert_equal Pair.new(name: "a", value: 1), pairs.parse!(StringIO.new("a = 1"))
    pair = Birman.seq("a", "=", "1")
    assert_equal Birman::Success.new(["a", "=", "1"]), Birman.parse(pair, StringIO.new("a = 1"), ignore: /\s*/)
    assert_equal ["a", "=", "1"], Birman.parse!(pair, StringIO.new("a = 1"), ignore: /\s*/)
  end

  def test_offset_counts_characters_of_the_string_read
    assert_equal Pair.new(name: "b", value: 2), pairs.parse(StringIO.new("ñ = 1 b = 2"), offset: 6).value
  end

  # --- to_path ---

  def test_parses_the_file_a_pathname_names
    with_file("a = 1") do |file|
      assert_equal Pair.new(name: "a", value: 1), pairs.parse(Pathname.new(file.path)).value
    end
  end

  def test_a_pathname_to_invalid_utf8_is_a_failure
    with_file("a = \xFF") do |file|
      failure = pairs.parse(Pathname.new(file.path))
      assert_equal "invalid UTF-8", failure.reason
      assert_equal 4, failure.pos
      assert_equal Encoding::UTF_8, failure.input.encoding
    end
  end

  def test_a_pathname_to_a_missing_file_raises_as_file_read_does
    assert_raises(Errno::ENOENT) { pairs.parse(Pathname.new("/nonexistent/birman-input")) }
  end

  # Pathname has read too (Pathname#read is File.read, in the default
  # external encoding), so a Pathname must take the to_path branch,
  # whatever the locale: under LANG=C the default is US-ASCII.
  def with_default_external(encoding)
    was = Encoding.default_external
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = was
  end

  def test_a_pathname_to_a_non_ascii_file_is_utf8_whatever_the_default_external_encoding
    with_default_external(Encoding::US_ASCII) do
      with_file("a = ma\u00f1ana") do |file|
        assert_equal Encoding::UTF_8, Birman.read_input(Pathname.new(file.path)).encoding
        assert_equal Pair.new(name: "a", value: "ma\u00f1ana"), tilde_pairs.parse(Pathname.new(file.path)).value
      end
    end
  end

  def test_a_pathname_to_invalid_utf8_is_a_failure_whatever_the_default_external_encoding
    with_default_external(Encoding::US_ASCII) do
      with_file("a = \xFF") do |file|
        failure = pairs.parse(Pathname.new(file.path))
        assert_equal "invalid UTF-8", failure.reason
        assert_equal 4, failure.pos
        assert_equal Encoding::UTF_8, failure.input.encoding
      end
    end
  end

  def test_an_open_file_is_still_read_from_its_current_position
    with_file("x = 0\na = 1") do |file|
      file.rewind
      file.gets
      assert_equal Pair.new(name: "a", value: 1), pairs.parse(file).value
      assert file.eof?
      refute file.closed?
    end
  end

  # --- anything else ---

  def test_anything_else_raises_argument_error_naming_it
    [42, nil, :sym, ["a = 1"]].each do |bad|
      error = assert_raises(ArgumentError) { pairs.parse(bad) }
      assert_includes error.message, bad.inspect
      assert_raises(ArgumentError) { pairs.parse!(bad) }
      assert_raises(ArgumentError) { Birman.parse("a", bad) }
    end
  end

  # --- the generated parser ---

  def generated = Differential.load(pairs, "ParseInputParser")

  def test_the_generated_parser_reads_too
    parser = generated
    assert_equal Differential.interpreted(pairs, "a = 1"), Differential.generated(parser, StringIO.new("a = 1"))
    io = StringIO.new("x = 0\na = b")
    io.gets
    assert_equal Differential.interpreted(pairs, "a = b"), Differential.generated(parser, io)
    assert io.eof?
    refute io.closed?
    assert_equal "a = b", parser.new(StringIO.new("a = b")).input
  end

  def test_the_generated_parser_reads_a_pathname_too
    parser = generated
    with_file("a = \xFF") do |file|
      assert_equal Differential.interpreted(pairs, "a = \xFF".b.force_encoding(Encoding::UTF_8)),
                   Differential.generated(parser, Pathname.new(file.path))
    end
  end

  def test_the_generated_parser_reads_a_pathname_as_utf8_whatever_the_default_external_encoding
    with_default_external(Encoding::US_ASCII) do
      parser = Differential.load(tilde_pairs, "TildeParseInputParser")
      with_file("a = ma\u00f1ana") do |file|
        assert_equal Differential.interpreted(tilde_pairs, "a = ma\u00f1ana"),
                     Differential.generated(parser, Pathname.new(file.path))
        assert parser.new(Pathname.new(file.path)).parse.success?
      end
      parser = generated
      with_file("a = \xFF") do |file|
        assert_equal Differential.interpreted(pairs, "a = \xFF".b.force_encoding(Encoding::UTF_8)),
                     Differential.generated(parser, Pathname.new(file.path))
      end
    end
  end

  def test_the_generated_parser_reads_an_open_file_from_its_current_position_too
    parser = generated
    with_file("x = 0\na = 1") do |file|
      file.rewind
      file.gets
      assert_equal Differential.interpreted(pairs, "a = 1"), Differential.generated(parser, file)
      assert file.eof?
      refute file.closed?
    end
  end

  def test_the_generated_parser_refuses_anything_else_too
    parser = generated
    [42, nil, :sym].each do |bad|
      assert_includes assert_raises(ArgumentError) { parser.new(bad) }.message, bad.inspect
    end
  end

  def test_a_string_is_parsed_as_before
    assert_equal Pair.new(name: "a", value: 1), pairs.parse("a = 1").value
    assert_equal "invalid UTF-8", pairs.parse("a = \xFF".b.force_encoding(Encoding::UTF_8)).reason
  end
end
