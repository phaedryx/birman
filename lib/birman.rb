# frozen_string_literal: true

# [file]
# purpose = "Entry point: require \"birman\" loads the whole library"
# dependencies = ["strscan (standard library)"]
# requires_ruby = ">= 3.2"

# A small PEG parser library for Ruby 3.2+.
#
#   Greeting = Birman.node(:name)
#
#   class MyGrammar
#     include Birman::Grammar
#     include Birman::Rules::Whitespace
#     include Birman::Rules::Identifiers
#
#     root :greeting
#     ignore :spacing
#     rule(:greeting) { seq("hello", commit, identifier.as(:name)).to(Greeting) }
#   end
#
#   case MyGrammar.parse("hello world")
#   in Birman::Success(value) then value
#   in Birman::Failure => f   then warn f.message
#   end
module Birman
  # The character offset of a byte offset into input. Free for ASCII
  # input (Ruby caches ascii_only?), linear otherwise; used once per
  # parse for a Failure, and only on demand for a Span.
  # [method."Birman.char_offset"]
  # params = ["input: String", "byte_pos: Integer"]
  # returns = "Integer: the character offset of byte_pos"
  def self.char_offset(input, byte_pos)
    input.ascii_only? ? byte_pos : input.byteslice(0, byte_pos).length
  end

  # The byte offset of a character offset into input (Grammar#parse's
  # offset:). Free for 0 and for ASCII input, linear otherwise; used
  # once per parse.
  # [method."Birman.byte_offset"]
  # params = ["input: String", "char_pos: Integer"]
  # returns = "Integer: the byte offset of char_pos"
  # raises = ["ArgumentError for a char_pos that isn't an Integer, or is negative or past the end of input"]
  def self.byte_offset(input, char_pos)
    raise ArgumentError, "offset must be an Integer, not #{char_pos.inspect}" unless char_pos.is_a?(Integer)
    return 0 if char_pos.zero?
    unless char_pos.positive? && char_pos <= input.length
      raise ArgumentError, "offset #{char_pos} is outside the input (0..#{input.length})"
    end

    input.ascii_only? ? char_pos : input[0, char_pos].bytesize
  end

  # The byte offset of the first byte in input that doesn't start a
  # valid character, or nil if input is valid. Grammar#parse fails
  # there before a regexp can raise on it. Ruby splits invalid bytes
  # into characters of their own, so everything before it is valid,
  # and a Failure's line and column count as usual.
  # [method."Birman.invalid_byte"]
  # params = ["input: String"]
  # returns = "Integer | nil: the byte offset of the first invalid byte"
  def self.invalid_byte(input)
    return if input.valid_encoding?

    pos = 0
    input.each_char do |char|
      return pos unless char.valid_encoding?

      pos += char.bytesize
    end
  end
end

require "strscan"

require_relative "birman/version"
require_relative "birman/result"
require_relative "birman/nodes"
require_relative "birman/context"
require_relative "birman/matchers"
require_relative "birman/rule_set"
require_relative "birman/combinators"
require_relative "birman/grammar"
require_relative "birman/standalone"
require_relative "birman/error_formatter"
require_relative "birman/ast"
require_relative "birman/left_recursion"
require_relative "birman/rules"
require_relative "birman/compiler"
