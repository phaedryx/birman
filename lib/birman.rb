# frozen_string_literal: true

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
  def self.char_offset(input, byte_pos)
    input.ascii_only? ? byte_pos : input.byteslice(0, byte_pos).length
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
require_relative "birman/error_formatter"
require_relative "birman/ast"
require_relative "birman/rules"
