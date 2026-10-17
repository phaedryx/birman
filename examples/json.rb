# frozen_string_literal: true

# JSON (RFC 8259) as a Birman grammar, parsing straight to Ruby values
# the way JSON.parse does: objects become Hashes, arrays Arrays, numbers
# Integers or Floats, and true/false/null true/false/nil.
#
#   ruby examples/json.rb                  # a demo
#   ruby examples/json.rb some/file.json   # parse a file and pretty-print it

require_relative "../lib/birman"

module JSONExample
  # The whole language: values, objects, arrays, strings and numbers.
  class Grammar
    include Birman::Grammar

    root :value

    # JSON allows exactly these four whitespace characters between
    # tokens, and nothing else (no comments).
    ignore :space
    rule(:space) { match(/[ \t\n\r]*/).quiet }

    rule(:value) do
      either(object, array, string, number,
             one_of("true" => true, "false" => false, "null" => nil)).label("value")
    end

    # Once "{" or "[" has matched, it can only be an object or array, so
    # commit: a mistake inside is reported where it is.
    rule(:object) { seq("{", commit, only(sep_by(member, ",")), "}").map(:to_h) }

    rule(:member) do
      seq(string.as(:key), commit, ":", value.as(:value)).action(:pair)
    end

    rule(:array) { seq("[", commit, only(sep_by(value, ",")), "]") }

    # Strings are matched with str and match, which are exact: inside the
    # quotes nothing is skipped. lexeme skips the spacing after the
    # closing quote.
    lexeme(:string) do
      seq(str('"'), commit, only(string_part.rep), str('"').label("closing quote"))
        .map(:join)
        .label("string")
    end

    ESCAPES = { '"' => '"', "\\" => "\\", "/" => "/",
                "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t" }.freeze

    rule(:string_part) do
      either(
        match(/[^"\\\x00-\x1f]+/), # plain characters
        match(/\\u[dD][89abAB]\h{2}\\u[dD][c-fC-F]\h{2}/).action(:surrogate_pair),
        match(/\\u\h{4}/).action(:unicode_escape),
        match(%r{\\["\\/bfnrt]}).action(:short_escape)
      ).label("string character")
    end

    # An integer unless it has a fraction or an exponent, as in JSON.parse.
    lexeme(:number) do
      match(/-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/).action(:json_number).label("number")
    end

    # Actions: rules hand their values to these by name (.action), so
    # the grammar holds no blocks. Private, so they don't look like rules.

    private

    def pair(member) = [member[:key], member[:value]]

    def json_number(text) = text.match?(/[.eE]/) ? Float(text) : Integer(text)

    # \" \\ \/ \b \f \n \r \t
    def short_escape(text) = ESCAPES.fetch(text[1])

    # \u00e9
    def unicode_escape(text) = [text[2, 4].hex].pack("U")

    # Characters outside the Basic Multilingual Plane (emoji, say) are
    # written as two \u escapes, a high and a low surrogate.
    def surrogate_pair(text)
      high = text[2, 4].hex
      low = text[8, 4].hex
      [0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)].pack("U")
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  require "pp"

  if ARGV.any?
    case JSONExample::Grammar.parse(File.read(ARGV.first))
    in Birman::Success(value) then pp value
    in Birman::Failure => failure
      warn failure.message
      exit 1
    end
  else
    pp JSONExample::Grammar.parse!(<<~JSON)
      {"name": "Birman", "tags": ["peg", "packrat"], "version": 0.1,
       "stable": false, "notes": null, "cat": "\\ud83d\\udc08"}
    JSON

    puts "\n--- Errors ---"
    ['{"a": 1,}', '{"a" 1}', "['single']", '"unterminated', "[1, 2"].each do |bad|
      puts JSONExample::Grammar.parse(bad).message, ""
    end
  end
end
