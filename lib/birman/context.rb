# frozen_string_literal: true

module Birman
  # Per-parse state: input, memo table, and failure tracking. It
  # mutates constantly, so it's a plain class rather than Data.
  #
  # Positions here, and in every matcher, are byte offsets: slicing a
  # non-ASCII string by character offset costs time proportional to
  # the offset, which made parsing quadratic. Failure and Span convert
  # back to characters for anything public.
  class Context
    # Marks a memo entry whose rule is still being matched.
    IN_PROGRESS = Object.new.freeze

    # position: where the most recently entered rule started. When the
    # input nests too deeply for Ruby's stack, that's where it happened.
    attr_reader :input, :grammar, :memo, :furthest, :expected, :position

    def initialize(input, grammar)
      @input = input
      @grammar = grammar
      @memo = {}
      @furthest = 0
      @expected = []
      @token_ends = {}
    end

    # A lexeme ended at token_end, then the ignore rule consumed spacing
    # (whitespace, comments) up to pos. Spans use this to stop at the
    # token instead of including what was ignored after it.
    def ignored_after(token_end, pos)
      @token_ends[pos] = token_end if pos > token_end
    end

    # Where the last token ended, for a match that ended at pos.
    def token_end(pos) = @token_ends.fetch(pos, pos)

    # fixed_anchor: \A, ^ and lookbehind see the whole input, not just
    # the text from the current position on.
    def scanner = @scanner ||= StringScanner.new(input, fixed_anchor: true)

    # Record that something was expected at pos. Only the furthest
    # position matters: that's where the parser got stuck.
    def fail_at(pos, what)
      if pos > @furthest
        @furthest = pos
        @expected = [what]
      elsif pos == @furthest
        @expected << what
      end
      nil
    end

    def merge(pos, expected) = expected.each { fail_at(pos, _1) }

    # Run the block with fresh failure tracking starting at pos, then
    # restore the outer state. Returns [result, furthest, expected] so
    # the caller decides what to keep: Ref memoizes it, Label rewrites
    # it, Not throws it away.
    def isolate(pos)
      outer = [@furthest, @expected]
      @furthest = pos
      @expected = []
      result = yield
      [result, @furthest, @expected]
    ensure
      @furthest, @expected = outer
    end

    def commit_failure! = raise(Committed.new(@furthest, @expected.dup))

    # Rule name's memo entry at pos, computed by the block the first
    # time. Meeting the rule again at the same position while it is
    # still being matched means it reaches itself without consuming
    # input: left recursion, which would never terminate. That's a bug
    # in the grammar, not the input, so it raises.
    def memoize(name, pos, &)
      key = [name, pos]
      entry = @memo[key]
      return entry if entry && !entry.equal?(IN_PROGRESS)
      raise ArgumentError, "left recursion in rule :#{name}: it can reach itself without consuming input" if entry

      @position = pos
      compute(key, &)
    end

    # Run a lookahead's inner match. A lookahead only asks whether
    # something would match here, so a commit failure inside it is an
    # ordinary failure (nil) rather than the end of the parse.
    def lookahead
      yield
    rescue Committed
      nil
    end

    private

    def compute(key)
      @memo[key] = IN_PROGRESS
      @memo[key] = yield
    ensure
      # A commit failure caught by a lookahead unwinds through here; the
      # rule may be tried again at this position afterwards.
      @memo.delete(key) if @memo[key].equal?(IN_PROGRESS)
    end
  end
end
