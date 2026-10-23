# frozen_string_literal: true

require "test_helper"
require_relative "support/examples"

# Parsers generated from the README grammar, examples/calc.rb (and
# left-recursive versions of it, direct and indirect), json.rb, email.rb
# and toml.rb, and Examples::Numbers agree with the interpreter under
# CRuby. `rake spinel`
# checks the same inputs against the parsers compiled by Spinel.
class CompiledExamplesTest < Minitest::Test
  COUNT = Integer(ENV.fetch("INPUTS", 600))

  Examples.all(COUNT).each do |example|
    define_method(:"test_#{example.name}_matches_the_interpreter") do
      parser = Differential.load(example.grammar, example.namespace, **example.to_ruby_options)
      mismatches = example.inputs.uniq.filter_map do |input|
        want = Differential.interpreted(example.grammar, input, **example.options)
        got = Differential.generated(parser, input, **example.options)
        [input, want, got] unless want == got
      end
      assert_empty mismatches.first(5), "#{mismatches.size} mismatches of #{example.inputs.uniq.size}"
    end
  end
end
