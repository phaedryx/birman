# frozen_string_literal: true

require "test_helper"

# Error recovery's result types: a Failure that lists every error found
# (and the value recovered past them), and the ErrorNode that marks where
# a recovery happened in the tree.
class RecoverTest < Minitest::Test
  def failure(pos: 0, expected: ["y"], input: "xxxxxxxx")
    Birman::Failure.new(input:, pos:, expected:, committed: false)
  end

  def test_failure_without_recovery_lists_itself_and_has_no_value
    f = failure
    assert_equal [f], f.errors
    assert_nil f.value
  end

  def test_recovered_failure_takes_the_first_errors_fields
    a5 = failure(pos: 5, expected: ["a"])
    b2 = failure(pos: 2, expected: ["b"])
    r = Birman::Failure.recovered([a5, b2], value: :v)
    assert_equal 2, r.pos
    assert_equal b2.expected, r.expected
    assert_equal [b2, a5], r.errors
    assert_equal :v, r.value
  end

  def test_recovered_sorts_stably
    a = failure(pos: 3, expected: ["a"])
    b = failure(pos: 3, expected: ["b"])
    assert_equal [a, b], Birman::Failure.recovered([a, b], value: nil).errors
  end

  def test_recovered_passes_the_trace_through
    trace = Object.new
    def trace.__finish(result) = (@finished = result)
    r = Birman::Failure.recovered([failure], value: nil, trace:)
    assert_same trace, r.trace
    assert_same r, trace.instance_variable_get(:@finished)
  end

  def test_errors_and_value_are_not_members
    plain = failure(pos: 2)
    r = Birman::Failure.recovered([plain, failure(pos: 4)], value: :v)
    assert_equal plain, r
    assert_equal plain.inspect, r.inspect
    assert_equal %i[input pos expected committed reason], r.to_h.keys
    case r
    in Birman::Failure(input:, pos:)
      assert_equal [plain.input, 2], [input, pos]
    end
  end

  def test_marshal_keeps_errors_and_value
    r = Birman::Failure.recovered([failure(pos: 4), failure(pos: 1)], value: [1, 2])
    back = Marshal.load(Marshal.dump(r))
    assert_equal r, back
    assert_equal r.errors, back.errors
    assert_equal [1, 2], back.value
    assert_nil back.trace
  end

  def test_marshal_of_a_plain_failure_still_lists_itself
    back = Marshal.load(Marshal.dump(failure))
    assert_equal [back], back.errors
    assert_nil back.value
  end

  def test_error_node_has_a_span_and_its_failure
    f = failure
    node = Birman::ErrorNode.new(failure: f)
    assert_equal "(ErrorNode #{f.inspect})", node.inspect
    assert_kind_of Birman::Node, node
    span = Birman::Span.new(input: "xx", byte_from: 0, byte_to: 1)
    assert_equal span, Birman::Node.new_with_span(Birman::ErrorNode, span, failure: f).span
  end

  def test_value_bang_raises_the_first_error_listing_all
    a = failure(pos: 5, expected: ["a"])
    b = failure(pos: 2, expected: ["b"])
    r = Birman::Failure.recovered([a, b], value: :v)
    err = assert_raises(Birman::ParseError) { r.value! }
    assert_equal Birman::ErrorFormatter.new.call(b), err.message
    assert_equal [b, a], err.failure.errors
  end
end
