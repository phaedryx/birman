# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../examples/json"

# The JSON example should agree with Ruby's own JSON.parse.
class TestJSONExample < Minitest::Test
  VALID = [
    "0", "-0", "42", "-17", "3.25", "1e3", "1E-2", "-2.5e+10", "12345678901234567890",
    '""', '"plain"', '"tab\\tnewline\\nquote\\"slash\\/back\\\\"', '"\\u00e9\\u4e2d"',
    '"\\ud83d\\udc08"', "\"café \u{1F408}\"",
    "true", "false", "null",
    "[]", "{}", "[1, [2, [3, []]]]", '{"a": {"b": {"c": {}}}}',
    ' { "a" : [ 1 , true , null ] , "b" : "x" } ',
    "\t\n\r [1,\n2]\n"
  ].freeze

  INVALID = [
    "", "[1, 2,]", '{"a": 1,}', '{"a" 1}', "{a: 1}", "['x']", '"unterminated',
    "[1, 2", "01", "1.", ".5", "+1", "tru", "nul", "truex", '"\\x"', "\"a\u0001b\"",
    "[1] [2]", "// comment\n1"
  ].freeze

  def test_valid_documents_match_json_parse
    VALID.each do |source|
      assert_equal JSON.parse(source), JSONExample::Grammar.parse!(source), source
    end
  end

  def test_invalid_documents_fail
    INVALID.each do |source|
      assert JSONExample::Grammar.parse(source).failure?, "#{source.inspect} should not parse"
      assert_raises(JSON::ParserError, "JSON.parse agrees #{source.inspect} is invalid") { JSON.parse(source) }
    end
  end

  def test_errors_point_at_the_mistake
    {
      '{"a": 1,}' => [1, 9, "expected string"],
      '{"a" 1}' => [1, 6, 'expected ":"'],
      "[1,\n  2,\n  x]" => [3, 3, "expected value"]
    }.each do |source, (line, column, text)|
      failure = JSONExample::Grammar.parse(source)
      assert_equal [line, column], [failure.line, failure.column], source
      assert_includes failure.message, text, source
    end
  end
end
