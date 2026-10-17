# frozen_string_literal: true

# [file]
# purpose = "What a parse returns"
# responsibility = "Success and Failure values, and the ParseError that parse! raises"
# pattern = "Result objects (Data), pattern-matchable"
module Birman
  # Internal: one matcher succeeded, ending at `pos` with `value`.
  Match = Data.define(:pos, :value)

  # Returned by Grammar#parse when the whole input parsed.
  # [class.Success]
  # purpose = "The whole input parsed"
  # fields = ["value: whatever the root rule produced"]
  # usage = "case grammar.parse(input) in Birman::Success(value) then ..."
  Success = Data.define(:value) do
    def success? = true
    def failure? = false
    def value!(_formatter = nil) = value
  end

  # Returned by Grammar#parse when it didn't. Pure data: rendering it
  # as text is the ErrorFormatter's job.
  #
  # committed: true when a match after a commit (>) failed, meaning the
  # parser knew exactly which construct it was in and stopped there.
  #
  # reason: set when the failure isn't about what was expected, such as
  # input nested too deeply for Ruby's stack.
  # [class.Failure]
  # purpose = "The input didn't parse"
  # fields = [
  # "input: String",
  # "pos: Integer (character offset of the furthest failure)",
  # "expected: Array of String (what would have matched there)",
  # "committed: Boolean (failed after a commit)",
  # "reason: String | nil (set when it isn't about expectations, e.g. nesting too deep)"
  # ]
  # methods = ["line", "column", "found", "message(formatter)", "value!(formatter) -> raises ParseError"]
  Failure = Data.define(:input, :pos, :expected, :committed, :reason) do
    def initialize(input:, pos:, expected:, committed:, reason: nil) = super

    def success? = false
    def failure? = true
    def value!(formatter = ErrorFormatter.new) = raise ParseError.new(self, formatter)

    def line   = input[0, pos].count("\n") + 1
    def column = pos - (input[0, pos].rindex("\n") || -1)
    def found  = input[pos]&.inspect || "end of input"

    def message(formatter = ErrorFormatter.new) = formatter.call(self)

    # The input can be any size, so only its start is shown.
    def inspect
      shown = input.size > 40 ? "#{input[0, 40]}..." : input
      fields = ["pos=#{pos}", "expected=#{expected.inspect}", "committed=#{committed}"]
      fields << "reason=#{reason.inspect}" if reason
      "#<data Birman::Failure #{fields.join(" ")} input=#{shown.inspect}>"
    end
  end

  # Raised by parse! (and Failure#value!) with the formatted message.
  # [class.ParseError]
  # purpose = "Raised by parse! and Failure#value!"
  # fields = ["failure: Birman::Failure", "message: formatted by the formatter given"]
  class ParseError < StandardError
    attr_reader :failure

    def initialize(failure, formatter = ErrorFormatter.new)
      @failure = failure
      super(formatter.call(failure))
    end
  end

  # Internal: raised when a match after a commit fails. Carries the diagnostics from
  # the moment of failure. Grammar#parse turns it into a Failure.
  class Committed < StandardError
    attr_reader :pos, :expected

    def initialize(pos, expected)
      @pos = pos
      @expected = expected
      super("committed failure at #{pos}")
    end
  end
end
