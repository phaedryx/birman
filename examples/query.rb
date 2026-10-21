# frozen_string_literal: true

# A GitHub/Gmail-style search query, parsed into nodes and turned into a
# Ruby predicate over Hash records:
#
#   status:open author:tad -label:wontfix "parse error" (bug OR crash)
#   created:>2026-01-01 comments:3..10
#
# Words side by side must all match (AND), OR between them means either,
# a leading - negates, and parentheses group. name:value is a filter on
# a field; any other word, or a "quoted phrase", is free text. Its
# actions make Dates, so unlike calc and json it can't go through to_ruby.
#
#   ruby examples/query.rb

require "date"
require_relative "../lib/birman"

module QueryExample
  # Queries into Field, Text, Not, And and Or nodes. Nothing here knows
  # how a query is run: see Evaluator.
  class Grammar
    include Birman::Grammar
    include Birman::Rules::Whitespace
    include Birman::Rules::Strings

    Field = node(:name, :op, :value) # op: :eq, :gt, :gte, :lt or :lte; a range is :eq with a Range value
    Text  = node(:value)
    Not   = node(:expr)
    And   = node(:terms)
    Or    = node(:left, :right)

    # What a field's name or value can hold: not spacing, parentheses,
    # quotes or colons, and not "..", which separates a range's ends.
    WORD_CHAR = /[^\s()":.]|\.(?!\.)/

    root :query
    ignore :spacing

    # OR binds looser than juxtaposition: a b OR c is (a AND b) OR c.
    rule(:query) { either(seq(conjunction.as(:left), "OR", query.as(:right)).to(Or), conjunction) }

    # Two or more terms side by side are an And; one is left as it is.
    rule(:conjunction) { either(term.rep(2).to(And), term) }

    rule(:term) { either(seq(str("-"), atom.as(:expr)).to(Not), atom).label("search term") }

    # OR is a keyword: never free text, never a field name.
    rule(:atom) { either(parens(query), seq(lit("OR").absent, only(either(text, field)))).label("search term") }

    # Free text: a quoted phrase, or a run of anything but spacing,
    # parentheses, quotes and colons that isn't followed by ":" (that
    # would be a field). The lookahead only looks, so `status:open` is
    # left whole for field. A leading - negates, and a leading .. would
    # be the rest of a bad range (label:a..b).
    lexeme(:text) do
      either(string, seq(only(match(/(?!-|\.\.)[^\s()":]+/).label("word")), str(":").absent)).to(Text)
    end

    # A field's parts are raw (no spacing skipped), so `status: open`
    # and `status :open` aren't fields.
    lexeme(:field) { either(comparison_field, equality_field) }

    # Commit right after "name:" (or "name:>"), and nowhere earlier: once
    # a word has a colon after it, it can only be a field, so a bad value
    # is reported where it is. Free text never commits, so any word that
    # isn't a field can always fall back to being text instead of
    # failing the query. comparison_field commits only past the operator,
    # so that without one equality_field still gets its turn.
    rule(:comparison_field) do
      seq(word.as(:name), str(":"), comparison.as(:op), commit, bound.as(:value)).to(Field)
    end

    rule(:equality_field) do
      seq(word.as(:name), str(":"), commit, str("").means(:eq).as(:op), equality_value.as(:value)).to(Field)
    end

    # >= before >, so ">=" isn't read as ">" then "=".
    rule(:comparison) do
      either(str(">=").means(:gte), str(">").means(:gt), str("<=").means(:lte), str("<").means(:lt))
    end

    rule(:bound) { either(date, integer).label("a date or number") }

    rule(:equality_value) { either(range, string, date, integer, word).label("value") }

    # Both ends of a range are dates, or both are numbers.
    rule(:range) do
      either(seq(date.as(:from), str(".."), date.label("a date").as(:to)),
             seq(integer.as(:from), str(".."), integer.label("a number").as(:to))).action(:to_range)
    end

    # Dates before integers, so 2026-01-01 isn't the number 2026. Each
    # must end where a word would, so 3abc is the word "3abc".
    rule(:date) do
      seq(date_text.present, commit, only(date_text.check(:real_date?, "a real date"))).action(:to_date)
    end
    rule(:integer) { seq(only(match(/\d+/)), word_end).map(:to_i) }

    # Anything shaped like a date must be a real one: looking first and
    # then committing makes 2026-02-30 an error rather than a word.
    rule(:date_text) { seq(only(match(/\d{4}-\d\d-\d\d/)), word_end) }

    # A name or value can't start with - (that negates) or with < or >
    # (those compare), so `created:>x` isn't a test for equality.
    rule(:word)     { match(/(?![-<>])(?:#{WORD_CHAR})+/).label("word") }
    rule(:word_end) { match(WORD_CHAR).absent }

    private

    def real_date?(text) = Date.valid_date?(*text.split("-").map(&:to_i))
    def to_date(text) = Date.iso8601(text)
    def to_range(ends) = ends[:from]..ends[:to]
  end

  # Turns a query's AST into a lambda that takes a record (a Hash with
  # Symbol keys) and says whether it matches. Fields are looked up by
  # name; free text searches title and body.
  module Evaluator
    COMPARISONS = { gt: :>, gte: :>=, lt: :<, lte: :<= }.freeze
    TEXT_FIELDS = %i[title body].freeze

    module_function

    def predicate(node) # rubocop:disable Metrics
      case node
      in Grammar::And(terms)
        tests = terms.map { predicate(_1) }
        ->(record) { tests.all? { _1.call(record) } }
      in Grammar::Or(left, right)
        either = predicate(left)
        other = predicate(right)
        ->(record) { either.call(record) || other.call(record) }
      in Grammar::Not(expr)
        test = predicate(expr)
        ->(record) { !test.call(record) }
      in Grammar::Text(value)
        needle = value.downcase
        ->(record) { record.values_at(*TEXT_FIELDS).compact.any? { _1.downcase.include?(needle) } }
      in Grammar::Field(name, op, value)
        key = name.to_sym
        # A field holding a list (labels) matches if any item does.
        ->(record) { Array(record[key]).any? { compare(_1, op, value) } }
      end
    end

    # Values of different types (a Date and an Integer, say) never match.
    # Strings compare ignoring case; that's this backend's choice, not
    # the grammar's.
    def compare(actual, operator, expected)
      case [operator, expected]
      in [:eq, Range] then expected.begin.instance_of?(actual.class) && expected.cover?(actual)
      in [:eq, String] then actual.is_a?(String) && actual.casecmp?(expected)
      in [:eq, _] then actual == expected
      else expected.instance_of?(actual.class) && actual.public_send(COMPARISONS.fetch(operator), expected)
      end
    end
  end

  # Error messages for a one-line query: the query, then a caret under
  # where it went wrong, with what was expected beside it.
  class ErrorFormatter
    def call(failure)
      line = failure.input.lines.fetch(failure.line - 1, "").chomp
      "#{line}\n#{" " * (failure.column - 1)}^ #{problem(failure)}"
    end

    private

    def problem(failure)
      return failure.reason if failure.reason

      expected = failure.expected.empty? ? "" : "expected #{failure.expected.join(" or ")}, "
      "#{expected}found #{found(failure)}"
    end

    # The whole word at the caret, not just its first character.
    def found(failure)
      rest = failure.input[failure.pos..]
      rest.empty? ? "end of query" : rest[/\A[^\s()]+|\A./m].inspect
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  issues = [
    { id: 1, title: "Parse error on empty input", body: "Crash in the lexer", status: "open", author: "tad",
      label: %w[bug], created: Date.new(2026, 2, 3), comments: 4 },
    { id: 2, title: "Add TOML dates", body: "Feature request", status: "open", author: "sam",
      label: %w[enhancement], created: Date.new(2026, 1, 15), comments: 12 },
    { id: 3, title: "Crash on deep nesting", body: "parse error after 750 levels", status: "closed", author: "tad",
      label: %w[bug wontfix], created: Date.new(2025, 11, 30), comments: 7 },
    { id: 4, title: "Docs typo", body: "README says parsre", status: "open", author: "tad",
      label: %w[docs], created: Date.new(2026, 3, 1), comments: 0 }
  ]

  queries = [
    %(status:open author:tad -label:wontfix "parse error" (bug OR crash) created:>2026-01-01 comments:3..10),
    "crash OR typo",
    "label:bug -status:closed",
    "created:<2026-01-01 OR comments:>=10"
  ]

  queries.each do |query|
    ast = QueryExample::Grammar.parse!(query)
    matches = issues.select(&QueryExample::Evaluator.predicate(ast)).map { _1[:id] }
    puts query, "  #{ast.inspect}", "  matches issues #{matches}", ""
  end

  puts "--- Errors ---"
  ["created:>banana", "created:2026-02-30", "comments:3..", "status: open", "(bug OR crash"].each do |bad|
    QueryExample::Grammar.parse!(bad, formatter: QueryExample::ErrorFormatter.new)
  rescue Birman::ParseError => e
    puts e.message, ""
  end
end
