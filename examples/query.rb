# frozen_string_literal: true

# A GitHub/Gmail-style search query, parsed into nodes and turned into a
# Ruby predicate over Hash records, or into a SQL condition for
# ActiveRecord's where:
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

  # A query naming a field that Where wasn't given a column for.
  class UnknownField < StandardError
    def initialize(node, known)
      super("unknown field `#{node.name}` at #{node.span} (known: #{known.join(", ")})")
    end
  end

  # Compiles a query's AST into a SQL condition with bind parameters,
  # ready for ActiveRecord: Issue.where(*sql), or sanitize_sql(sql) for a
  # string to hand to Arel.sql.
  #
  #   ["status = ? AND NOT COALESCE(label = ?, FALSE) AND created_at > ?", "open", "wontfix", #<Date 2026-01-01>]
  #
  # Why not a hash like { and: [{ status: "open" }, { not: ... }] }? where
  # can't take one: its hashes say only "these columns equal these
  # values", so OR, NOT and > would each need code to translate them.
  # A string with binds is what where takes as is, nested any way the
  # query is. Only two kinds of thing are ever written into the string:
  # column names from the allowlist and the fixed operators below. Every
  # value from the query is a bind.
  #
  # Where agrees with Evaluator except in three places:
  # - Equality uses =, so it's as case-sensitive as the column is (citext
  #   or a case-insensitive collation make it not). LOWER(col) would
  #   match Evaluator, but keeps an index on col from being used.
  # - Columns hold one value. Evaluator's "any label matches" needs a
  #   join or an EXISTS subquery, which a column name can't express.
  # - Types aren't checked. comments:>2026-01-01 matches nothing in
  #   Evaluator; a database compares a number with a date as it sees
  #   fit, or rejects the query.
  # Free text is case-insensitive, as in Evaluator: LOWER(col) LIKE works
  # on every database, where ILIKE is PostgreSQL's alone.
  class Where
    OPERATORS = { eq: "=", gt: ">", gte: ">=", lt: "<", lte: "<=" }.freeze
    COLUMN = /\A\w+(?:\.\w+)?\z/

    # columns: the query's field names and the column each one searches,
    # { "created" => "issues.created_at" }. Any other name is rejected.
    # text_columns: the columns free text searches.
    def initialize(columns:, text_columns:)
      @columns = columns.to_h { |name, column| [name.to_s, column(column)] }.freeze
      @text_columns = text_columns.map { column(_1) }.freeze
      raise ArgumentError, "free text needs at least one text column" if @text_columns.empty?
    end

    # The condition and its binds, as one Array: [sql, *binds].
    def call(node)
      binds = []
      [condition(node, binds), *binds]
    end

    private

    def condition(node, binds) # rubocop:disable Metrics
      case node
      in Grammar::And(terms)
        terms.map { group(_1, binds) }.join(" AND ")
      in Grammar::Or
        alternatives(node).map { group(_1, binds) }.join(" OR ")
      in Grammar::Not(expr)
        # A comparison with NULL is NULL, and NOT NULL is NULL too, so
        # -label:wontfix would skip rows with no label. Evaluator keeps
        # them, and so does reading NULL as FALSE before negating.
        "NOT COALESCE(#{condition(expr, binds)}, FALSE)"
      in Grammar::Text(value)
        pattern = "%#{escape_like(value.downcase)}%"
        @text_columns.map do |column|
          binds << pattern
          "LOWER(#{column}) LIKE ? ESCAPE '!'"
        end.join(" OR ")
      in Grammar::Field(name, op, value)
        column = @columns.fetch(name) { raise UnknownField.new(node, @columns.keys) }
        comparison(column, op, value, binds)
      end
    end

    def comparison(column, operator, value, binds)
      if value.is_a?(Range)
        binds.push(value.begin, value.end)
        "#{column} BETWEEN ? AND ?"
      else
        binds << value
        "#{column} #{OPERATORS.fetch(operator)} ?"
      end
    end

    # Parentheses around a part with its own AND or OR, so its precedence
    # never depends on what it's inside.
    def group(node, binds)
      sql = condition(node, binds)
      compound?(node) ? "(#{sql})" : sql
    end

    def compound?(node)
      node.is_a?(Grammar::And) || node.is_a?(Grammar::Or) || (node.is_a?(Grammar::Text) && @text_columns.size > 1)
    end

    # a OR b OR c parses as a OR (b OR c); list it as a, b, c.
    def alternatives(node)
      node.is_a?(Grammar::Or) ? [*alternatives(node.left), *alternatives(node.right)] : [node]
    end

    # % and _ are LIKE's wildcards. They're escaped with !, not with a
    # backslash, whose meaning in a SQL string differs between databases.
    def escape_like(text) = text.gsub(/[!%_]/) { "!#{_1}" }

    def column(name)
      name = name.to_s
      raise ArgumentError, "not a column name: #{name.inspect}" unless name.match?(COLUMN)

      name
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

  # The same issues as a table: Issue.where(*sql) would run each query.
  where = QueryExample::Where.new(
    columns: { "status" => "status", "author" => "author", "label" => "label",
               "created" => "created_at", "comments" => "comments_count" },
    text_columns: %w[title body]
  )

  queries.each do |query|
    ast = QueryExample::Grammar.parse!(query)
    matches = issues.select(&QueryExample::Evaluator.predicate(ast)).map { _1[:id] }
    sql, *binds = where.call(ast)
    puts query, "  #{ast.inspect}", "  matches issues #{matches}", "  where #{sql.inspect}", "        #{binds}", ""
  end

  puts "--- Errors ---"
  ["created:>banana", "created:2026-02-30", "comments:3..", "status: open", "(bug OR crash",
   "milestone:v1"].each do |bad|
    where.call(QueryExample::Grammar.parse!(bad, formatter: QueryExample::ErrorFormatter.new))
  rescue Birman::ParseError, QueryExample::UnknownField => e
    puts e.message, ""
  end
end
