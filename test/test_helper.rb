# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "birman"

require "minitest/autorun"

# Every matcher reachable from a grammar's rules, literals included.
def matchers_in(grammar_class)
  grammar = grammar_class.new
  queue = grammar.to_ast.keys.map { grammar.matcher_for(_1) }
  seen = []
  while (m = queue.shift)
    next if seen.include?(m)

    seen << m
    queue << grammar.literal_matcher(m.text) if m.is_a?(Birman::Lit)
    m.to_h.each_value { queue.concat(Array(_1).grep(Birman::Matcher)) }
  end
  seen
end
