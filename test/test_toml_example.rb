# frozen_string_literal: true

require "test_helper"
require "json"
require "time"
require_relative "../examples/toml"

# The TOML example against a slice of the official toml-test corpus
# (test/toml-test; see its README), plus where its errors point.
class TestTOMLExample < Minitest::Test
  CORPUS = File.expand_path("toml-test", __dir__)

  FLOATS = { "inf" => Float::INFINITY, "-inf" => -Float::INFINITY, "nan" => Float::NAN }.freeze

  # toml-test's value types, and the Ruby value each should parse to.
  SCALARS = {
    "string" => ->(text) { text },
    "integer" => ->(text) { Integer(text, 10) },
    "float" => ->(text) { FLOATS.fetch(text) { Float(text) } },
    "bool" => ->(text) { text == "true" },
    "datetime" => ->(text) { Time.iso8601(text) },
    "datetime-local" => ->(text) { Time.iso8601(text) },
    "date-local" => ->(text) { Date.iso8601(text) },
    "time-local" => ->(text) { local_time(text) }
  }.freeze

  def self.local_time(text)
    hour, minute, second = text.split(":")
    TOMLExample::LocalTime.new(hour: Integer(hour, 10), minute: Integer(minute, 10),
                               second: second.include?(".") ? Rational(second) : Integer(second, 10))
  end

  def test_grammar_uses_no_blocks
    assert_empty matchers_in(TOMLExample::Grammar).grep(Birman::Map)
  end

  def test_valid_documents_match_the_corpus
    cases = Dir.glob("valid/**/*.toml", base: CORPUS).sort
    refute_empty cases
    cases.each do |name|
      want = typed(JSON.parse(File.read(File.join(CORPUS, name.sub(/\.toml\z/, ".json")))))
      got = TOMLExample.parse(read(name))
      assert got.success?, "#{name}:\n#{got.message if got.failure?}"
      assert_equal comparable(want), comparable(got.value), name
    end
  end

  def test_invalid_documents_fail
    cases = Dir.glob("invalid/**/*.toml", base: CORPUS).sort
    refute_empty cases
    cases.each do |name|
      assert TOMLExample.parse(read(name)).failure?, "#{name} should not parse"
    end
  end

  def test_values
    doc = TOMLExample.parse!(<<~TOML)
      odt = 1979-05-27T07:32:00-07:00
      ldt = 1979-05-27T07:32:00.5
      ld = 1979-05-27
      lt = 07:32:00.25
      big = 0xffff_ffff_ffff_ffff_ff
      ints = [0o17, 0b101, -1_000]
      floats = [-inf, 6.02e23]
    TOML
    assert_equal Time.new(1979, 5, 27, 7, 32, 0, "-07:00"), doc["odt"]
    assert_equal(-7 * 3600, doc["odt"].utc_offset)
    assert_equal Time.new(1979, 5, 27, 7, 32, Rational(1, 2)), doc["ldt"]
    assert_equal Time.new(1979, 5, 27, 7, 32).utc_offset, doc["ldt"].utc_offset, "a local date-time is in local time"
    assert_equal Date.new(1979, 5, 27), doc["ld"]
    assert_equal TOMLExample::LocalTime.new(hour: 7, minute: 32, second: Rational(1, 4)), doc["lt"]
    assert_equal "07:32:00.25", doc["lt"].to_s
    assert_equal "23:59:60", TOMLExample.parse!("leap = 23:59:60")["leap"].to_s
    assert_equal 0xffff_ffff_ffff_ffff_ff, doc["big"]
    assert_equal [15, 5, -1000], doc["ints"]
    assert_equal [-Float::INFINITY, 6.02e23], doc["floats"]
  end

  def test_errors_point_at_the_mistake
    {
      "a = 1\nb = " => [2, 5, "expected value"],
      "a = [1, 2\nb = 3" => [2, 1, 'expected "," or "]"'],
      "a = { b = 1,\n c = 2 }" => [1, 13, "expected key"],
      "a = 1 b = 2" => [1, 7, "expected newline or end of input"],
      # Semantic errors, found after parsing, point at the node that
      # broke the rule: here the second [fruit], and below, the date.
      "[fruit]\napple = 1\n\n[fruit]\npear = 2" => [4, 1, "fruit is already defined"],
      "a = 1\n  a = 2" => [2, 3, "a is already defined"],
      "[t]\nx.y = 1\n[t.x]" => [3, 1, "t.x is already defined"],
      "point = { x = 1 }\n[point.z]" => [2, 1, "point is an inline table"],
      "ports = [80]\n[ports.http]" => [2, 1, "ports is an array"],
      "a = 1\n[a.b]" => [2, 1, "a is already defined"],
      "d = 1979-02-30" => [1, 5, "1979-02-30 is not a real date"],
      "t = 07:32:00Z" => [1, 13, "expected newline or end of input"],
      "s = \"caf\xE9\"".dup.force_encoding(Encoding::UTF_8) => [1, 9, "invalid UTF-8"]
    }.each do |source, (line, column, text)|
      failure = TOMLExample.parse(source)
      assert failure.failure?, source
      assert_equal [line, column], [failure.line, failure.column], source
      assert_includes failure.message, text, source
    end
  end

  def test_parse_bang_raises_with_the_location
    error = assert_raises(Birman::ParseError) { TOMLExample.parse!("[a]\n[a]") }
    assert_match(/\Aline 2, column 1: a is already defined/, error.message)
  end

  private

  def read(name) = File.binread(File.join(CORPUS, name)).force_encoding(Encoding::UTF_8)

  # toml-test's expected JSON gives every value as {"type": ..., "value": "..."}.
  def typed(json)
    case json
    in Hash if json.keys.sort == %w[type value] && json["value"].is_a?(String)
      scalar(*json.values_at("type", "value"))
    in Hash then json.transform_values { typed(_1) }
    in Array then json.map { typed(_1) }
    end
  end

  def scalar(type, value) = SCALARS.fetch(type).call(value)

  # Hash#== would call 1 and 1.0 equal, and NaN unequal to itself, and
  # Time#== ignores the offset; this keeps each value's class and offset.
  def comparable(value)
    case value
    in Hash then value.transform_values { comparable(_1) }
    in Array then value.map { comparable(_1) }
    in Float if value.nan? then [Float, :nan]
    in Time then [Time, value.to_r, value.utc_offset, value.utc?]
    else [value.class, value]
    end
  end
end
