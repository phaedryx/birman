# frozen_string_literal: true

# Parses the same JSON with Ruby's JSON.parse (a C extension), Birman
# (examples/json.rb) and Parslet, the best-known Ruby PEG library.
#
#   ruby bench/json.rb   # not `bundle exec`: Parslet is installed inline

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "parslet", "~> 2.0"
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
  "Parslet" => ->(source) { ParsletJSON::Transform.new.apply(ParsletJSON::Parser.new.parse(source)) }
}

[100, 1_000].each do |records|
  source = document(records)
  expected = JSON.parse(source)
  puts "\n#{records} records, #{source.bytesize / 1024} KB"
  parsers.each do |name, parse|
    parse.call(document(5)) # warm up
    seconds, result = time { parse.call(source) }
    status = result == expected ? "" : "  (result differs from JSON.parse!)"
    puts "  #{name.ljust(11)} #{format("%<s>8.3f", s: seconds)}s#{status}"
  end
end
