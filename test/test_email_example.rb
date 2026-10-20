# frozen_string_literal: true

require "test_helper"
require_relative "../examples/email"

# The email example parses RFC 5322 addr-specs into nodes.
class TestEmailExample < Minitest::Test
  G = EmailExample::Grammar

  def address(local, domain) = G::Address.new(local:, domain:)
  def host(*labels) = G::Host.new(labels:)

  VALID = {
    "jo@example.com" => ["jo", %w[example com]],
    "first.last+tag@sub.example.org" => ["first.last+tag", %w[sub example org]],
    "!#$%&'*+/=?^_`{|}~-@x.io" => ["!#$%&'*+/=?^_`{|}~-", %w[x io]],
    '"jo smith"@example.com' => ["jo smith", %w[example com]],
    '"a\\"b\\\\c"@x' => ["a\"b\\c", ["x"]],
    "\"fold\r\n here\"@x" => ["fold here", ["x"]],
    "jo (a (nested) comment) @ (here) example.com (end)" => ["jo", %w[example com]],
    "jö@xn--bcher-kva.example" => ["jö", ["xn--bcher-kva", "example"]],
    "a@#{"b" * 63}.c" => ["a", ["b" * 63, "c"]]
  }.freeze

  INVALID = [
    "", "jo", "jo@", "@example.com", "jo..x@example.com", ".jo@example.com", "jo.@example.com",
    "jo@-example.com", "jo@example-.com", "jo@exa_mple.com", "jo@example..com", "\"unclosed@example.com",
    "jo(oops@example.com", "jo@[1.2.3.4", "jo@#{"b" * 64}.c", "jo@#{(["a" * 63] * 4).join(".")}",
    "jo smith@example.com", "jo@bücher.example"
  ].freeze

  def test_valid_addresses
    VALID.each do |source, (local, labels)|
      assert_equal address(local, host(*labels)), G.parse!(source), source
    end
  end

  def test_domain_literals
    assert_equal address("jo", G::IPv4.new(octets: [192, 168, 0, 1])), G.parse!("jo@[192.168.0.1]")
    assert_equal address("jo", G::Literal.new(text: "1.2.3.256")), G.parse!("jo@[1.2.3.256]")
    assert_equal address("jo", G::Literal.new(text: "IPv6:::1")), G.parse!("jo@[ IPv6:::1 ]")
  end

  def test_invalid_addresses
    INVALID.each { assert G.parse(_1).failure?, "#{_1.inspect} should not parse" }
  end

  def test_spans_cover_the_address_without_trailing_comments
    value = G.parse!("jo@example.com (c)")
    assert_equal "jo@example.com (c)", value.span.text
    assert_equal "example.com", value.domain.span.text
  end

  def test_errors_point_where_the_address_breaks
    assert_equal 11, G.parse("jo@example..com").pos

    failure = G.parse("jo@ ")
    assert_equal 4, failure.pos
    assert failure.committed, "past the @, a bad domain is an error, not a backtrack"
  end
end
