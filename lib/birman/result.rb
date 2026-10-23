# frozen_string_literal: true

# [file]
# purpose = "What a parse returns"
# responsibility = "Success and Failure values, and the ParseError that parse! raises"
# pattern = "Result objects (Data), pattern-matchable"
module Birman
  # Internal: one matcher succeeded, ending at `pos` with `value`. A
  # plain class rather than Data: one is made for every successful
  # match, and Data.new allocates a keyword Hash each time.
  class Match
    attr_reader :pos, :value

    def initialize(pos, value)
      @pos = pos
      @value = value
    end
  end

  # Returned by Grammar#parse when the input parsed: all of it, or with
  # consume: false, a prefix of it.
  #
  # pos is where the match ended, as a character offset: where its last
  # token ended, before any spacing the grammar ignored after it (where
  # the root node's span ends). Like a node's span, it isn't a member,
  # so equality, inspect and `in Success(value)` leave it out. A Success
  # built by hand has none.
  # [class.Success]
  # purpose = "The input parsed (all of it, or a prefix with consume: false)"
  # fields = ["value: whatever the root rule produced"]
  # methods = ["pos -> Integer | nil (character offset where the match ended, before trailing ignored spacing)"]
  # usage = "case grammar.parse(input) in Birman::Success(value) then ..."
  Success = Data.define(:value) do
    # input and byte_pos: where the match ended, for pos, which converts
    # to characters only when asked. Set before super, which freezes it.
    def initialize(value:, input: nil, byte_pos: nil)
      @input = input
      @byte_pos = byte_pos
      super(value:)
    end

    def pos = @input && Birman.char_offset(@input, @byte_pos)

    # Data's own Marshal support would set the ivars after freezing.
    def marshal_dump = [value, @input, @byte_pos]
    def marshal_load(fields) = initialize(value: fields[0], input: fields[1], byte_pos: fields[2])

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
  #
  # Failure.at(span, reason) is one for a check made after parsing, on
  # the AST: it points at a node's span, committed, with no expected
  # list, so the message reads "line L, column C: reason".
  # [class.Failure]
  # purpose = "The input didn't parse"
  # fields = [
  # "input: String",
  # "pos: Integer (character offset of the furthest failure)",
  # "expected: Array of String (what would have matched there)",
  # "committed: Boolean (failed after a commit)",
  # "reason: String | nil (set when it isn't about expectations, e.g. nesting too deep)"
  # ]
  # methods = [
  # "Failure.at(span, reason) -> Failure at span's start (for checks after parsing)",
  # "line", "column", "found", "message(formatter)", "value!(formatter) -> raises ParseError"
  # ]
  Failure = Data.define(:input, :pos, :expected, :committed, :reason) do
    def self.at(span, reason) = new(input: span.input, pos: span.from, expected: [], committed: true, reason:)

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
