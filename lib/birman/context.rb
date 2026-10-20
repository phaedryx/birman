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

    # The expectations of a frame that hasn't failed anywhere yet. Shared
    # and frozen; fail_at replaces it rather than appending.
    NOTHING_EXPECTED = [].freeze

    # position: where the most recently entered rule started. When the
    # input nests too deeply for Ruby's stack, that's where it happened.
    attr_reader :input, :grammar, :furthest, :expected, :position, :isolated_furthest, :isolated_expected

    def initialize(input, grammar)
      @input = input
      @grammar = grammar
      @memo = {}
      @furthest = 0
      @expected = NOTHING_EXPECTED
      @token_ends = {}
    end

    # Where the parse begins: past whatever the ignore rule (if any)
    # matches at the start of the input.
    def start(ignore_rule) = (ignore_rule && Ref.new(ignore_rule).match(self, 0)&.pos) || 0

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
        @expected = @expected.frozen? ? [what] : @expected << what
      end
      nil
    end

    # Record a finished frame's expectations (a memo hit, a label, a
    # check) at pos. Ones already recorded there are skipped: a rule
    # reached from several alternatives at one position is merged in
    # once per alternative, and copying its whole list each time grew
    # it exponentially. Failure#expected is uniq'd anyway, so this
    # changes no error, only the work behind it. fail_at itself doesn't
    # check: it runs far more often, and repeats there grow only
    # linearly.
    def merge(pos, expected)
      expected.each { fail_at(pos, _1) unless pos == @furthest && @expected.include?(_1) }
    end

    # Run the block with fresh failure tracking starting at pos, then
    # restore the outer state, and return the block's result. What the
    # block recorded is left in isolated_furthest and isolated_expected
    # for the caller to keep or drop: Ref memoizes it, Label rewrites
    # it, Not throws it away. No arrays: this runs for every rule call.
    def isolate(pos)
      outer_furthest = @furthest
      outer_expected = @expected
      @furthest = pos
      @expected = NOTHING_EXPECTED
      result = yield
      @isolated_furthest = @furthest
      @isolated_expected = @expected
      result
    ensure
      @furthest = outer_furthest
      @expected = outer_expected
    end

    def commit_failure! = raise(Committed.new(@furthest, @expected.dup))

    # A positive lookahead: does matcher match at pos? Nothing is
    # consumed, and failures inside it describe input the parse never
    # moves past, so they're dropped. If it fails, that's recorded at
    # pos, as what it expected there or as the lookahead itself.
    def peek?(matcher, pos)
      result = isolate(pos) { lookahead { matcher.match(self, pos) } }
      return true if result

      furthest = isolated_furthest
      expected = isolated_expected

      if furthest == pos && expected.any?
        merge(pos, expected)
      else
        fail_at(pos, EBNF.expr(matcher.to_ast, EBNF::CHOICE))
      end
      false
    end

    # Rule name's memo entry at pos, computed by the block the first
    # time. Meeting the rule again at the same position while it is
    # still being matched means it reaches itself without consuming
    # input: left recursion, which would never terminate. That's a bug
    # in the grammar, not the input, so it raises.
    def memoize(name, pos, &)
      table = @memo[name] ||= {}
      entry = table[pos]
      return entry if entry && !entry.equal?(IN_PROGRESS)
      raise ArgumentError, "left recursion in rule :#{name}: it can reach itself without consuming input" if entry

      @position = pos
      compute(table, pos, &)
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

    # The memo is a Hash per rule, keyed by position, so no key arrays.
    def compute(table, pos)
      table[pos] = IN_PROGRESS
      table[pos] = yield
    ensure
      # A commit failure caught by a lookahead unwinds through here; the
      # rule may be tried again at this position afterwards.
      table.delete(pos) if table[pos].equal?(IN_PROGRESS)
    end
  end
end
