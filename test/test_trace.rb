# frozen_string_literal: true

require "test_helper"
require_relative "support/examples"

# parse(input, trace: true): the same result, with a Trace of the
# attempts that led to it.
class TraceTest < Minitest::Test
  # The README's Lists grammar, with map(:to_i) for map(&:to_i) so
  # to_ruby can compile it.
  class Lists
    include Birman::Grammar
    include Birman::Rules::Whitespace

    ignore :spacing
    root :list
    rule(:list) { seq("[", commit, only(sep_by(item, ",")), "]") }
    rule(:item) { either(match(/\d+/).map(:to_i), list) }
  end

  # A grammar whose root is :r, with the rules the block defines.
  def grammar(&)
    Class.new do
      include Birman::Grammar

      root :r
      class_eval(&)
    end
  end

  # Every node under node, node included, depth first. A stack, since
  # traces of deep input are deep.
  def nodes_of(node)
    out = []
    stack = [node]
    while (n = stack.pop)
      out << n
      stack.concat(n.children.reverse)
    end
    out
  end

  def test_untraced_results_have_no_trace
    assert_nil Lists.parse("[1]").trace
    assert_nil Lists.parse("[x]").trace
  end

  def test_trace_is_not_a_member
    traced = Lists.parse("[1]", trace: true)
    assert_instance_of Birman::Trace, traced.trace
    assert_equal Lists.parse("[1]"), traced
    assert_equal Lists.parse("[1]").inspect, traced.inspect
    assert_pattern { traced => Birman::Success([1]) }
    assert_equal Lists.parse("[x]"), Lists.parse("[x]", trace: true)
    assert_equal Lists.parse("[x]").inspect, Lists.parse("[x]", trace: true).inspect
  end

  def test_marshal_drops_the_trace
    [Lists.parse("[1]", trace: true), Lists.parse("[x]", trace: true)].each do |result|
      copy = Marshal.load(Marshal.dump(result))
      assert_equal result, copy
      assert_nil copy.trace
    end
  end

  def test_parse_bang_failure_carries_the_trace
    error = assert_raises(Birman::ParseError) { Lists.parse!("[x]", trace: true) }
    assert_instance_of Birman::Trace, error.failure.trace
    assert_equal Lists.parse("[x]").message, error.message
    assert_equal [1], Lists.parse!("[1]", trace: true)
  end

  def test_standalone_parse_takes_trace
    m = Birman.seq("a", "b")
    assert_instance_of Birman::Trace, Birman.parse(m, "ab", trace: true).trace
    error = assert_raises(Birman::ParseError) { Birman.parse!(m, "ax", trace: true) }
    refute_nil error.failure.trace
  end

  def test_invalid_utf8_gives_a_one_node_trace
    result = Lists.parse("[1\xFF]".dup.force_encoding("UTF-8"), trace: true)
    assert_equal "invalid UTF-8", result.reason
    assert_equal :input, result.trace.root.kind
    assert_equal 2, result.trace.root.from
    assert_empty result.trace.root.children
  end

  def test_rule_calls_are_recorded
    root = Lists.parse("[1]", trace: true).trace.root
    assert_equal :parse, root.kind
    assert_equal %i[spacing list], root.children.map(&:rule) # the spacing skipped at the start comes first
    list = root.children.last
    assert_equal [:rule, :list, 0, 3], [list.kind, list.rule, list.from, list.to]
    assert(nodes_of(list).any? { _1.rule == :item && _1.from == 1 && _1.to == 2 })
  end

  def test_leftover_input_is_an_end_of_input_node
    root = Lists.parse("[1] x", trace: true).trace.root
    assert_equal [:spacing, :list, nil], root.children.map(&:rule)
    assert_equal :end_of_input, root.children.last.kind
    assert_equal([4, nil, ["end of input"]], root.children.last.then { [_1.from, _1.to, _1.expected] })
  end

  def test_generated_parser_rejects_trace
    parser = Differential.load(Lists, "TracedListsParser")
    assert_raises(ArgumentError) { parser.new("[1]").parse(trace: true) }
  end

  # The guard against TracingContext drifting from Context and Ref: a
  # traced parse gives exactly the untraced result.
  Examples.all(Integer(ENV.fetch("TRACE_INPUTS", 60))).each do |example|
    define_method(:"test_tracing_#{example.name}_changes_no_result") do
      mismatches = example.inputs.uniq.filter_map do |input|
        want = Differential.interpreted(example.grammar, input, **example.options)
        got = Differential.interpreted(example.grammar, input, trace: true, **example.options)
        [input, want, got] unless want == got
      end
      assert_empty mismatches.first(5), "#{mismatches.size} mismatches of #{example.inputs.uniq.size}"
    end
  end
end
