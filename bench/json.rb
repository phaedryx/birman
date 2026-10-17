# frozen_string_literal: true

# Parses the same JSON with Ruby's JSON.parse (a C extension), Birman
# (examples/json.rb), and three other Ruby PEG libraries: Parslet,
# Treetop and Citrus. Each grammar below is written in that library's
# own style. To keep them short, the other libraries hand string
# escapes to JSON.parse; Birman decodes them itself.
#
#   ruby bench/json.rb   # not `bundle exec`: Parslet is installed inline

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "parslet", "~> 2.0"
  gem "treetop", "~> 1.6"
  gem "citrus", "~> 3.0"
end

require "json"
require_relative "../examples/json"

# JSON in Parslet: a parser, and a transform from its tree to Ruby values.
module ParsletJSON
  # The grammar.
  class Parser < Parslet::Parser
    rule(:space)   { match('[ \t\n\r]').repeat }
    rule(:value)   { (object | array | string | number | keyword) >> space }
    rule(:keyword) { str("true").as(:yes) | str("false").as(:no) | str("null").as(:null) }

    rule(:object) do
      str("{") >> space >> (pair >> (str(",") >> space >> pair).repeat).maybe.as(:object) >> str("}")
    end
    rule(:pair)  { string.as(:key) >> space >> str(":") >> space >> value.as(:value) }
    rule(:array) { str("[") >> space >> (value >> (str(",") >> space >> value).repeat).maybe.as(:array) >> str("]") }

    rule(:string) do
      str('"') >> ((str("\\") >> any) | (str('"').absent? >> any)).repeat.as(:string) >> str('"')
    end
    rule(:number) do
      (str("-").maybe >> (str("0") | (match("[1-9]") >> match("[0-9]").repeat)) >>
        (str(".") >> match("[0-9]").repeat(1)).maybe >>
        (match("[eE]") >> match("[+-]").maybe >> match("[0-9]").repeat(1)).maybe).as(:number)
    end

    rule(:document) { space >> value }
    root :document
  end

  # Its tree to Ruby values.
  class Transform < Parslet::Transform
    rule(yes: simple(:_)) { true }
    rule(no: simple(:_)) { false }
    rule(null: simple(:_)) { nil }
    rule(number: simple(:n)) { n.to_s.match?(/[.eE]/) ? Float(n.to_s) : Integer(n.to_s) }
    rule(string: simple(:s)) { JSON.parse("\"#{s}\"") }
    rule(string: sequence(:s)) { "" }
    rule(key: simple(:key), value: subtree(:value)) { [key, value] }
    rule(array: subtree(:items)) { Array(items.is_a?(Array) ? items : [items].compact) }
    rule(object: subtree(:pairs)) { (pairs.is_a?(Array) ? pairs : [pairs].compact).to_h }
  end
end

# Treetop compiles this grammar to a TreetopJSONParser class.
# Citrus defines CitrusJSON.
Treetop.load_from_string(<<~'TT')
  grammar TreetopJSON
    rule document
      space value space { def to_ruby; value.to_ruby; end }
    end
    rule value
      object / array / string / number / json_true / json_false / json_null
    end
    rule object
      '{' space members:members? space '}' { def to_ruby; members.empty? ? {} : members.to_ruby; end }
    end
    rule members
      first:pair rest:(space ',' space pair)* {
        def to_ruby; ([first] + rest.elements.map(&:pair)).to_h(&:to_ruby); end
      }
    end
    rule pair
      string space ':' space value { def to_ruby; [string.to_ruby, value.to_ruby]; end }
    end
    rule array
      '[' space items:items? space ']' { def to_ruby; items.empty? ? [] : items.to_ruby; end }
    end
    rule items
      first:value rest:(space ',' space value)* {
        def to_ruby; [first.to_ruby] + rest.elements.map { |e| e.value.to_ruby }; end
      }
    end
    rule string
      '"' ('\\' . / !'"' .)* '"' { def to_ruby; JSON.parse(text_value); end }
    end
    rule number
      '-'? ('0' / [1-9] [0-9]*) ('.' [0-9]+)? ([eE] [+-]? [0-9]+)? {
        def to_ruby; text_value.match?(/[.eE]/) ? Float(text_value) : Integer(text_value); end
      }
    end
    rule json_true
      'true' { def to_ruby; true; end }
    end
    rule json_false
      'false' { def to_ruby; false; end }
    end
    rule json_null
      'null' { def to_ruby; nil; end }
    end
    rule space
      [ \t\n\r]*
    end
  end
TT

Citrus.eval(<<~'CI')
  grammar CitrusJSON
    rule document
      (space value space) { capture(:value).value }
    end
    rule value
      object | array | string | number | json_true | json_false | json_null
    end
    rule object
      ('{' space members? space '}') { (m = capture(:members)) ? m.value : {} }
    end
    rule members
      (pair (space ',' space pair)*) { captures(:pair).map(&:value).to_h }
    end
    rule pair
      (string space ':' space value) { [capture(:string).value, capture(:value).value] }
    end
    rule array
      ('[' space items? space ']') { (i = capture(:items)) ? i.value : [] }
    end
    rule items
      (value (space ',' space value)*) { captures(:value).map(&:value) }
    end
    rule string
      ('"' ('\\' . | !'"' .)* '"') { JSON.parse(to_s) }
    end
    rule number
      ('-'? ('0' | [1-9] [0-9]*) ('.' [0-9]+)? ([eE] [+-]? [0-9]+)?) { to_s.match?(/[.eE]/) ? Float(to_s) : Integer(to_s) }
    end
    rule json_true
      'true' { true }
    end
    rule json_false
      'false' { false }
    end
    rule json_null
      'null' { nil }
    end
    rule space
      [ \t\n\r]*
    end
  end
CI

def document(records)
  JSON.generate(Array.new(records) do |i|
    { "id" => i, "name" => "user #{i}", "email" => "user#{i}@example.com", "score" => i * 1.5,
      "active" => i.even?, "note" => nil, "tags" => %w[a b c].take((i % 3) + 1),
      "address" => { "city" => "Springfield", "zip" => format("%05d", i) } }
  end)
end

def time
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  [Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, result]
end

parsers = {
  "JSON.parse" => ->(source) { JSON.parse(source) },
  "Birman" => ->(source) { JSONExample::Grammar.parse!(source) },
  "Parslet" => ->(source) { ParsletJSON::Transform.new.apply(ParsletJSON::Parser.new.parse(source)) },
  "Treetop" => ->(source) { TreetopJSONParser.new.parse(source).to_ruby },
  "Citrus" => ->(source) { CitrusJSON.parse(source, root: :document).value }
}

[100, 1_000].each do |records|
  source = document(records)
  expected = JSON.parse(source)
  puts "\n#{records} records, #{source.bytesize / 1024} KB"
  parsers.each do |name, parse|
    # Citrus parses in linear time, but building values through its
    # captures API grew quadratically in every style tried here (159 KB
    # took two minutes), so it only runs on the small document.
    next puts "  #{name.ljust(11)} skipped (value building scales quadratically)" if name == "Citrus" && records > 100

    parse.call(document(5)) # warm up
    seconds, result = time { parse.call(source) }
    status = result == expected ? "" : "  (result differs from JSON.parse!)"
    puts "  #{name.ljust(11)} #{format("%<s>8.3f", s: seconds)}s#{status}"
  end
end
