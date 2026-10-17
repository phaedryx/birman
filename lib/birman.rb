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
end

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
