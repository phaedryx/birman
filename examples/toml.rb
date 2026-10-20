# frozen_string_literal: true

# TOML 1.0 (https://toml.io/en/v1.0.0) as a Birman grammar, parsing
# straight to Ruby values: tables become Hashes, arrays Arrays, and
# strings, integers, floats and booleans themselves. Offset and local
# date-times become Times (a local one in the machine's time zone),
# local dates Dates, and local times TOMLExample::LocalTime, since Ruby
# has no class for a time of day.
#
# It reads a document in two passes. The grammar turns it into a flat
# list of statements: key = value pairs, [table] headers and [[array]]
# headers. Document then builds the Hash, enforcing the rules a grammar
# can't see (no key or table defined twice, inline tables and arrays
# closed to later additions, dates that exist), and reports a statement
# that breaks one at its line and column, from the statement's span.
#
#   ruby examples/toml.rb                  # a demo
#   ruby examples/toml.rb some/file.toml   # parse a file and pretty-print it

require "date"
require_relative "../lib/birman"

# The grammar, the second pass, and parse / parse! to run both.
module TOMLExample
  # A time of day with no date or offset (07:32:00). second is a
  # Rational when it has a fraction.
  LocalTime = Data.define(:hour, :minute, :second) do
    def to_s = Time.at((hour * 3600) + (minute * 60) + second, in: "UTC").strftime("%H:%M:%S.%N").sub(/\.?0+\z/, "")
  end

  # The first pass: the document as a flat list of statements.
  class Grammar
    include Birman::Grammar

    # Keys are Arrays of names: a.b.c is ["a", "b", "c"].
    Pair        = node(:key, :value)
    Table       = node(:key)
    ArrayTable  = node(:key)
    InlineTable = node(:pairs)
    # Date, time and offset as written; Document checks and converts them.
    Moment      = node(:date, :time, :offset)

    # Any of the four: 1979-05-27T07:32:00Z, 1979-05-27 07:32:00,
    # 1979-05-27, 07:32:00.
    TIME = /\d{2}:\d{2}:\d{2}(?:\.\d+)?/
    MOMENT = /(?<date>\d{4}-\d{2}-\d{2})(?:[Tt ](?<time>#{TIME})(?<offset>[Zz]|[+-]\d{2}:\d{2})?)?|(?<time>#{TIME})/

    root :document

    # Between tokens: spaces, tabs and a comment, never a newline. A
    # newline ends a statement, so the grammar says where one may go.
    # Comments can't hold control characters other than tab.
    ignore :blank
    rule(:blank) { match(/[ \t]*(?:#[^\x00-\x08\x0a-\x1f\x7f]*)?/).quiet }

    # Inside arrays, newlines are blank too.
    rule(:gap) { match(/(?:[ \t]|\r?\n|#[^\x00-\x08\x0a-\x1f\x7f]*)*/).quiet }

    # One statement to a line; blank and comment-only lines hold none.
    rule(:document) { seq(bom.maybe, only(sep_by(statement.maybe, newline)), eof).map(:compact) }

    lexeme(:bom)     { str("\uFEFF") }
    lexeme(:newline) { match(/\r?\n/).label("newline") }

    rule(:statement) { either(array_table, table, pair) }

    rule(:array_table) { seq("[[", commit, key.as(:key), "]]").to(ArrayTable) }
    rule(:table)       { seq("[", commit, key.as(:key), "]").to(Table) }
    rule(:pair)        { seq(key.as(:key), "=", commit, value.as(:value)).to(Pair) }

    # Dotted: a . "b c" . 'd'. Bare keys are any run of letters, digits,
    # _ and -, so true, 1234 and 1979-05-27 are keys too.
    rule(:key)        { sep_by1(simple_key, ".").label("key") }
    rule(:simple_key) { either(bare_key, basic_string, literal_string) }
    lexeme(:bare_key) { match(/[A-Za-z0-9_-]+/) }

    # Dates before numbers (1979 is the start of 1979-05-27), and floats
    # before integers.
    rule(:value) do
      either(string, moment, float, integer, one_of("true" => true, "false" => false), array, inline_table)
        .label("value")
    end

    # A trailing comma is fine, a leading or doubled one isn't.
    rule(:array) { seq("[", commit, gap, only(array_item.rep), "]").label("array") }
    rule(:array_item) { seq(only(value), gap, either(seq(",", gap), str("]").present)) }

    # On one line, and no trailing comma.
    rule(:inline_table) { seq("{", commit, only(sep_by(pair, ",")), "}").to(InlineTable).label("inline table") }

    # --- Strings ---

    rule(:string) { either(ml_basic_string, basic_string, ml_literal_string, literal_string).label("string") }

    lexeme(:basic_string) do
      seq(str('"'), commit, only(basic_part.rep), str('"').label("closing quote")).map(:join)
    end

    lexeme(:literal_string) do
      seq(str("'"), commit, only(match(/[^'\x00-\x08\x0a-\x1f\x7f]*/)), str("'").label("closing quote"))
    end

    # A newline straight after the opening quotes isn't part of the
    # string. Up to two quotes in a row are content, so """a"""" is a".
    lexeme(:ml_basic_string) do
      seq(str('"""'), commit, match(/\r?\n/).maybe, ml_basic_part.rep.as(:body),
          match(/"{3,5}/).label("closing quotes").as(:close)).action(:multiline)
    end

    lexeme(:ml_literal_string) do
      seq(str("'''"), commit, match(/\r?\n/).maybe, ml_literal_part.rep.as(:body),
          match(/'{3,5}/).label("closing quotes").as(:close)).action(:multiline)
    end

    rule(:basic_part) do
      either(match(/[^"\\\x00-\x08\x0a-\x1f\x7f]+/), escape).label("string character")
    end

    # A backslash at the end of a line trims it and the whitespace after.
    rule(:ml_basic_part) do
      either(match(/[^"\\\x00-\x08\x0a-\x1f\x7f]+/), match(/\r?\n/), escape,
             match(/\\[ \t]*\r?\n(?:[ \t]|\r?\n)*/).means(""), match(/"{1,2}(?!")/)).label("string character")
    end

    rule(:ml_literal_part) do
      either(match(/[^'\x00-\x08\x0a-\x1f\x7f]+/), match(/\r?\n/), match(/'{1,2}(?!')/)).label("string character")
    end

    ESCAPES = { "b" => "\b", "t" => "\t", "n" => "\n", "f" => "\f", "r" => "\r", '"' => '"', "\\" => "\\" }.freeze

    # \uXXXX and \UXXXXXXXX name any Unicode scalar value: not a
    # surrogate, nothing past 10FFFF.
    rule(:escape) do
      either(match(/\\[btnfr"\\]/).action(:short_escape),
             match(/\\u(?![dD][89a-fA-F])\h{4}|\\U(?!0000[dD][89a-fA-F])(?:000\h|0010)\h{4}/).action(:unicode_escape))
    end

    # --- Numbers and dates ---

    # Underscores only between digits; no leading zeros, and no sign on
    # 0x, 0o and 0b.
    lexeme(:integer) do
      match(/0x\h(?:_?\h)*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*|[+-]?(?:0|[1-9](?:_?\d)*)/).action(:integer_value)
    end

    lexeme(:float) do
      match(/[+-]?(?:inf|nan)|[+-]?(?:0|[1-9](?:_?\d)*)(?:\.\d(?:_?\d)*(?:[eE][+-]?\d(?:_?\d)*)?|[eE][+-]?\d(?:_?\d)*)/)
        .action(:float_value)
    end

    lexeme(:moment) { match(MOMENT).action(:moment_parts).to(Moment) }

    private

    def multiline(parts) = parts[:body].join + parts[:close][3..]

    def short_escape(text) = ESCAPES.fetch(text[1])
    def unicode_escape(text) = [large_integer(text[2..], 16)].pack("U")

    def integer_value(text) = large_integer(text.delete("_"))

    def float_value(text)
      case text.delete_prefix("+")
      when "inf" then Float::INFINITY
      when "-inf" then -Float::INFINITY
      when "nan", "-nan" then Float::NAN
      else Float(text.delete("_"))
      end
    end

    def moment_parts(text) = text.match(MOMENT).named_captures.transform_keys(&:to_sym)
  end

  # The second pass: builds the Hash from the grammar's statements.
  #
  # Every table and array it makes is recorded with how it was made,
  # which decides what may happen to it later:
  #   :implicit  a.b in a [a.b.c] header; may still get its own [a.b]
  #   :header    by its own [header], or an element of a [[header]]
  #   :dotted    by a dotted key (a.b = 1); no [a] header after that
  #   :inline    an inline table { ... }; closed once written
  #   :static    an array value [ ... ]; closed once written
  #   :tables    the array a [[header]] appends to
  class Document
    # A statement that breaks one of TOML's rules, with the span of the
    # statement.
    class Error < StandardError
      attr_reader :span

      def initialize(node, message)
        @span = node.span
        super(message)
      end
    end

    def initialize
      @kinds = {}.compare_by_identity
      @root = made({}, :header)
      @table = @root
    end

    def build(statements)
      statements.each do |statement|
        case statement
        in Grammar::Table then @table = define_table(statement)
        in Grammar::ArrayTable then @table = append_table(statement)
        in Grammar::Pair then assign(@table, statement)
        end
      end
      @root
    end

    private

    def made(container, kind)
      @kinds[container] = kind
      container
    end

    # [a.b]: a may exist, or is made, and a.b mustn't have been
    # defined, except as part of a header like [a.b.c].
    def define_table(header)
      parent = parent_table(header)
      name = header.key.last
      return parent[name] = made({}, :header) unless parent.key?(name)

      table = parent[name]
      already_defined(header, header.key) unless @kinds[table] == :implicit
      made(table, :header)
    end

    # [[a.b]]: a new table at the end of the a.b array.
    def append_table(header)
      parent = parent_table(header)
      name = header.key.last
      list = parent.key?(name) ? parent[name] : (parent[name] = made([], :tables))
      already_defined(header, header.key) unless @kinds[list] == :tables
      made({}, :header).tap { list << _1 }
    end

    # The table a header's key leads to, making missing ones. A path
    # through an array of tables goes into its last table.
    def parent_table(header)
      header.key[...-1].each_index.reduce(@root) do |table, i|
        name = header.key[i]
        child = table.key?(name) ? table[name] : (table[name] = made({}, :implicit))
        case @kinds[child]
        when :implicit, :header, :dotted then child
        when :tables then child.last
        when :inline, :static then unextendable(header, header.key[..i], child)
        else already_defined(header, header.key[..i])
        end
      end
    end

    # a.b.c = 1 makes a and a.b, or adds to ones earlier dotted keys
    # made; tables made any other way are out of its reach.
    def assign(table, pair)
      *path, name = pair.key
      target = path.each_index.reduce(table) { |t, i| dotted_table(t, pair, i) }
      already_defined(pair, pair.key) if target.key?(name)
      target[name] = value(pair.value)
    end

    def dotted_table(table, pair, index)
      name = pair.key[index]
      return table[name] = made({}, :dotted) unless table.key?(name)

      child = table[name]
      case @kinds[child]
      when :dotted, :implicit then made(child, :dotted)
      when :inline, :static then unextendable(pair, pair.key[..index], child)
      else already_defined(pair, pair.key[..index])
      end
    end

    def value(value)
      case value
      in Grammar::InlineTable(pairs) then made({}, :inline).tap { |table| pairs.each { assign(table, _1) } }
      in Grammar::Moment then Moments.convert(value)
      in Array then made(value.map { value(_1) }, :static)
      else value
      end
    end

    def already_defined(node, key) = raise Error.new(node, "#{dotted(key)} is already defined")

    def unextendable(node, key, container)
      what = container.is_a?(Hash) ? "an inline table" : "an array"
      raise Error.new(node, "#{dotted(key)} is #{what}, and can't be added to")
    end

    def dotted(key) = key.map { _1.match?(/\A[A-Za-z0-9_-]+\z/) ? _1 : _1.inspect }.join(".")
  end

  # Checks a Grammar::Moment and makes it a Time, Date or LocalTime.
  module Moments
    module_function

    def convert(moment)
      date = date(moment) if moment.date
      time = time(moment) if moment.time
      return LocalTime.new(**time) unless date
      return date unless time

      Time.new(date.year, date.month, date.day, *time.values, offset(moment))
    end

    def date(moment)
      year, month, day = moment.date.split("-").map { Integer(_1, 10) }
      invalid(moment, moment.date, "date") unless Date.valid_date?(year, month, day)
      Date.new(year, month, day)
    end

    # Seconds go up to 60, for a leap second.
    def time(moment)
      hour, minute, second = moment.time.split(":").map { _1.include?(".") ? Rational(_1) : Integer(_1, 10) }
      invalid(moment, moment.time, "time") unless hour < 24 && minute < 60 && second < 61
      { hour:, minute:, second: }
    end

    # Z, +HH:MM or -HH:MM as Time.new takes it; nil for local time.
    def offset(moment)
      text = moment.offset&.upcase
      return text if text.nil? || text == "Z"

      hours, minutes = text[1..].split(":").map { Integer(_1, 10) }
      invalid(moment, text, "offset") unless hours < 24 && minutes < 60
      text
    end

    def invalid(moment, text, what) = raise Document::Error.new(moment, "#{text} is not a real #{what}")
  end

  # Success(Hash) or Failure, from either pass: a Document error is a
  # Failure whose reason is the broken rule, at its statement's start.
  def self.parse(source)
    return invalid_utf8(source) unless source.valid_encoding?

    case Grammar.parse(source)
    in Birman::Success(statements) then Birman::Success.new(Document.new.build(statements))
    in failure then failure
    end
  rescue Document::Error => e
    Birman::Failure.new(input: source, pos: e.span.from, expected: [], committed: true, reason: e.message)
  end

  def self.parse!(source) = parse(source).value!

  def self.invalid_utf8(source)
    pos = source.each_char.find_index { !_1.valid_encoding? }
    Birman::Failure.new(input: source.scrub, pos:, expected: [], committed: true, reason: "invalid UTF-8")
  end
end

if __FILE__ == $PROGRAM_NAME
  require "pp"

  if ARGV.any?
    case TOMLExample.parse(File.read(ARGV.first))
    in Birman::Success(value) then pp value
    in Birman::Failure => failure
      warn failure.message
      exit 1
    end
  else
    pp TOMLExample.parse!(<<~TOML)
      # A TOML document
      title = "Birman"
      tags = ["peg", "packrat"]

      [owner]
      name = "Tad"
      dob = 1979-05-27T07:32:00-08:00

      [database]
      ports = [ 8000, 8001, 8002 ]
      limits = { cpu = 0.5, memory = 2_048 }
      enabled = true

      [[cats]]
      name = "Birman"
      coat.points = "seal"

      [[cats]]
      name = 'Siamese'
    TOML

    puts "\n--- Errors ---"
    ["a = ", "a = [1 2]", "a = { b = 1, }", "s = \"no end", "x = 1979-02-30",
     "[t]\na = 1\n[t]", "a.b = 1\na.b.c = 2", "p = { x = 1 }\np.y = 2"].each do |bad|
      puts TOMLExample.parse(bad).message, ""
    end
  end
end
