# frozen_string_literal: true

require "test_helper"
require_relative "../examples/query"

# The query example parses search queries into nodes, and its evaluator
# filters records with them.
class TestQueryExample < Minitest::Test
  G = QueryExample::Grammar

  def field(name, value, operator = :eq) = G::Field.new(name:, op: operator, value:)
  def text(value) = G::Text.new(value:)
  def no(expr) = G::Not.new(expr:)
  def all(*terms) = G::And.new(terms:)
  def any(left, right) = G::Or.new(left:, right:)

  def date(text) = Date.iso8601(text)

  PARSES = {
    "bug" => -> { text("bug") },
    '"parse error"' => -> { text("parse error") },
    "status:open" => -> { field("status", "open") },
    'title:"parse error"' => -> { field("title", "parse error") },
    "comments:3" => -> { field("comments", 3) },
    "created:2026-01-01" => -> { field("created", date("2026-01-01")) },
    "created:>2026-01-01" => -> { field("created", date("2026-01-01"), :gt) },
    "comments:>=3" => -> { field("comments", 3, :gte) },
    "comments:<10" => -> { field("comments", 10, :lt) },
    "comments:<=10" => -> { field("comments", 10, :lte) },
    "comments:3..10" => -> { field("comments", 3..10) },
    "created:2026-01-01..2026-03-31" => -> { field("created", date("2026-01-01")..date("2026-03-31")) },
    "-label:wontfix" => -> { no(field("label", "wontfix")) },
    "-crash" => -> { no(text("crash")) },
    "bug crash" => -> { all(text("bug"), text("crash")) },
    "bug OR crash" => -> { any(text("bug"), text("crash")) },
    "a b OR c d" => -> { any(all(text("a"), text("b")), all(text("c"), text("d"))) },
    "a OR b OR c" => -> { any(text("a"), any(text("b"), text("c"))) },
    "a (b OR c)" => -> { all(text("a"), any(text("b"), text("c"))) },
    "-(a OR b)" => -> { no(any(text("a"), text("b"))) },
    " ( bug ) " => -> { text("bug") },
    # Free text is any word that isn't a field or OR.
    "ORANGE or" => -> { all(text("ORANGE"), text("or")) },
    "3abc" => -> { text("3abc") },
    "2026-02-30" => -> { text("2026-02-30") },
    "created:2026-01-01x" => -> { field("created", "2026-01-01x") },
    "comments:3abc" => -> { field("comments", "3abc") },
    "c++ a>b x..y <3" => -> { all(text("c++"), text("a>b"), text("x..y"), text("<3")) },
    'status:open author:tad -label:wontfix "parse error" (bug OR crash) created:>2026-01-01 comments:3..10' => lambda {
      all(field("status", "open"), field("author", "tad"), no(field("label", "wontfix")), text("parse error"),
          any(text("bug"), text("crash")), field("created", date("2026-01-01"), :gt), field("comments", 3..10))
    }
  }.freeze

  def test_queries_parse_to_nodes
    PARSES.each do |query, expected|
      assert_equal instance_exec(&expected), G.parse!(query), query
    end
  end

  def test_grammar_uses_no_blocks
    assert_empty matchers_in(G).grep(Birman::Map)
  end

  def test_spans_cover_each_term
    value = G.parse!("status:open  -label:x  (a OR b)")
    assert_equal(["status:open", "-label:x", "a OR b"], value.terms.map { _1.span.text })
    assert_equal "label:x", value.terms[1].expr.span.text
  end

  ISSUES = [
    { id: 1, title: "Parse error on empty input", body: "Crash in the lexer", status: "open", author: "tad",
      label: %w[bug], created: Date.new(2026, 2, 3), comments: 4 },
    { id: 2, title: "Add TOML dates", body: "Feature request", status: "open", author: "sam",
      label: %w[enhancement], created: Date.new(2026, 1, 15), comments: 12 },
    { id: 3, title: "Crash on deep nesting", body: "parse error after 750 levels", status: "closed", author: "tad",
      label: %w[bug wontfix], created: Date.new(2025, 11, 30), comments: 7 },
    { id: 4, title: "Docs typo", status: "open", author: "Tad", label: [], created: Date.new(2026, 3, 1),
      comments: 0 }
  ].freeze

  MATCHES = {
    "crash" => [1, 3],
    "CRASH" => [1, 3],
    '"parse error"' => [1, 3],
    "author:tad" => [1, 3, 4],
    "label:bug" => [1, 3],
    "-label:wontfix" => [1, 2, 4],
    "crash OR typo" => [1, 3, 4],
    "label:bug -status:closed" => [1],
    "created:>2026-01-15" => [1, 4],
    "created:>=2026-01-15" => [1, 2, 4],
    "created:<2026-01-01" => [3],
    "created:2026-01-15" => [2],
    "created:2026-01-01..2026-02-28" => [1, 2],
    "comments:3..10" => [1, 3],
    "comments:>4" => [2, 3],
    "comments:<=4" => [1, 4],
    "comments:0" => [4],
    # Types that don't match never match, and neither do missing fields.
    "comments:>2026-01-01" => [],
    "created:>3" => [],
    "milestone:v1" => [],
    "-milestone:v1" => [1, 2, 3, 4],
    'status:open author:tad -label:wontfix "parse error" (bug OR crash) created:>2026-01-01 comments:3..10' => [1]
  }.freeze

  def test_evaluator_filters_records
    MATCHES.each do |query, ids|
      matches = ISSUES.select(&QueryExample::Evaluator.predicate(G.parse!(query)))
      assert_equal ids, matches.map { _1[:id] }, query
    end
  end

  ERRORS = {
    "created:>banana" => [1, 10, "expected a date or number"],
    "comments:3.." => [1, 13, "expected a number"],
    "comments:4..2026-01-01" => [1, 13, "expected a number"],
    "created:2026-01-01..3" => [1, 21, "expected a date"],
    "created:>2026-02-30" => [1, 10, "expected a real date"],
    "created:2026-02-30" => [1, 9, "expected a real date"],
    "created:2026-01-01..2026-02-30" => [1, 21, "expected a real date"],
    "status: open" => [1, 8, "expected value"],
    "status:" => [1, 8, "expected value"],
    "bug OR" => [1, 7, "expected search term"],
    "OR bug" => [1, 1, "expected search term"],
    "(bug OR crash" => [1, 14, '")"'],
    "a - b" => [1, 4, "expected search term"],
    '"unclosed' => [1, 10, "closing quote"],
    "" => [1, 1, "expected search term"],
    "bug\nstatus:>x" => [2, 9, "expected a date or number"]
  }.freeze

  def test_errors_point_at_the_mistake
    ERRORS.each do |query, (line, column, text)|
      failure = G.parse(query)
      assert_equal [line, column], [failure.line, failure.column], query
      assert_includes failure.message, text, query
    end
  end

  def test_errors_after_a_field_name_are_committed
    assert G.parse("created:>banana").committed
    refute G.parse("bug OR").committed
  end

  def test_formatter_puts_a_caret_under_the_mistake
    message = G.parse("label:bug created:>banana").message(QueryExample::ErrorFormatter.new)
    assert_equal <<~MSG.chomp, message
      label:bug created:>banana
                         ^ expected a date or number, found "banana"
    MSG

    error = assert_raises(Birman::ParseError) { G.parse!("bug OR", formatter: QueryExample::ErrorFormatter.new) }
    assert_equal "bug OR\n      ^ expected search term, found end of query", error.message
  end
end
