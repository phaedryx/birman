# frozen_string_literal: true

module Birman
  # Per-parse state: input, memo table, and failure tracking. It
  # mutates constantly, so it's a plain class rather than Data.
  #
  # Positions here, and in every matcher, are byte offsets: slicing a
  # non-ASCII string by character offset costs time proportional to
  # the offset, which made parsing quadratic. Failure and Span convert
  # back to characters for anything public.
  class Context # rubocop:disable Metrics/ClassLength
    # Marks a memo entry whose rule is still being matched.
    IN_PROGRESS = Object.new.freeze

    # The expectations of a frame that hasn't failed anywhere yet. Shared
    # and frozen; fail_at replaces it rather than appending.
    NOTHING_EXPECTED = [].freeze

    # position: where the most recently entered rule started. When the
    # input nests too deeply for Ruby's stack, that's where it happened.
    # ignore_ref: a Ref to the grammar's ignore rule, or nil. Lexemes
    # read it here, so the grammar running them decides what they skip.
    attr_reader :input, :grammar, :ignore_ref, :furthest, :expected, :position, :isolated_furthest, :isolated_expected

    # left_recursion: the grammar's analysis for the rule the parse starts
    # at (see Grammar#left_recursion). from: the byte offset it starts
    # at; nothing before it is matched, but positions count from 0.
    def initialize(input, grammar, ignore_rule, left_recursion = grammar.left_recursion, from = 0)
      @input = input
      @from = from
      @grammar = grammar
      @ignore_ref = ignore_rule && Ref.new(ignore_rule) # built once per parse, not per token
      @memo = {}
      @growing = left_recursion.leaders.then { _1 unless _1.empty? } # nil: nothing to look up
      @seeds = {}
      # { leader of other rules => { pos it grows at => this round's memo
      # for the other rules } }, and the same for their longest matches
      # over its latest growth there (see keep_longest)
      @rounds = left_recursion.leaders.values.tally.filter_map { |leader, n| [leader, {}] if n > 1 }.to_h
      @longest = @rounds.to_h { |leader, _| [leader, {}] }
      @furthest = from
      @expected = NOTHING_EXPECTED
      @token_ends = {}
    end

    # Where the parse begins: past whatever the ignore rule (if any)
    # matches at from.
    def start = @ignore_ref&.match(self, @from)&.pos || @from

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
    # time. The block returns [result, furthest, expected].
    #
    # A cycle of rules that call each other before consuming input (left
    # recursion) is grown from a seed at its leader (see
    # LeftRecursion#leaders and grow). While the leader grows at pos, the
    # cycle's other rules are memoized there in a table of the round's
    # own, not the memo: what they match there depends on the seed, which
    # changes every round. When it has grown, each of them keeps its
    # longest match from those rounds (see publish), so a parse that
    # enters the cycle at one of them, from outside, gets that (see
    # outside). (A match of theirs already in the memo there is final:
    # it was published, or made after the leader finished, or without
    # it.)
    # Every way back to a rule of the
    # cycle at pos passes through the leader's seed, so meeting any rule
    # again at the same position while it is still being matched means
    # it reaches itself without consuming input in a way the grammar's
    # ASTs don't show (through a custom matcher): that would never
    # terminate, and it's a bug in the grammar, not the input, so it
    # raises.
    def memoize(name, pos, &) # rubocop:disable Metrics
      table = @memo[name] ||= {}
      entry = table[pos]
      return entry if entry && !entry.equal?(IN_PROGRESS)

      leader = @growing&.[](name) # nil without left recursion: no further lookups
      round = @rounds[leader]&.[](pos) if leader
      return in_round(round, name, pos, &) if round && !leader.equal?(name)
      return seed(name, pos) if entry

      @position = pos
      return grow(name, table, pos, &) if leader.equal?(name)
      return outside(leader, name, table, pos, &) if leader

      compute(table, pos, &)
    end

    # Run a lookahead's inner match. A lookahead only asks whether
    # something would match here, so a commit failure inside it is an
    # ordinary failure (nil) rather than the end of the parse. What it
    # expected is kept, as generated parsers keep it: the frames it
    # unwound through restored what they started with, so without this a
    # failure where the lookahead began would only be named, not said.
    def lookahead
      yield
    rescue Committed => e
      @furthest = e.pos
      @expected = e.expected
      nil
    end

    private

    # The memo is a Hash per rule, keyed by position, so no key arrays.
    # (A round's table is keyed by rule instead.)
    def compute(table, key)
      table[key] = IN_PROGRESS
      table[key] = yield
    ensure
      # A commit failure caught by a lookahead unwinds through here; the
      # rule may be tried again at this position afterwards.
      table.delete(key) if table[key].equal?(IN_PROGRESS)
    end

    # A rule of a cycle whose leader grows at pos, memoized in the round's
    # table (keyed by rule): once a round, however many alternatives call
    # it, or a cycle of n rules with k alternatives each would take
    # k**(n - 1) matches a round. Back at itself without the leader's seed
    # between, it raises as memoize does. Its match may be the rule's
    # longest of the growth (see keep_longest).
    def in_round(round, name, pos, &)
      entry = round[name]
      return entry if entry && !entry.equal?(IN_PROGRESS)
      return seed(name, pos) if entry

      @position = pos
      keep_longest(name, pos, compute(round, name, &))
    end

    # The rule's longest match so far in its leader's growth at pos,
    # updated with this round's entry: its result if it gets further
    # than the longest so far (a failure is shortest; the first round's
    # counts), and its diagnostics folded in, as the leader's own are
    # over its rounds (see grow).
    def keep_longest(name, pos, entry)
      longest = @longest[@growing[name]][pos]
      best = longest[name]
      longest[name] = if best
                        result = (entry[0]&.pos || -1) > (best[0]&.pos || -1) ? entry[0] : best[0]
                        [result, *further(best[1..], entry[1], entry[2])]
                      else
                        entry
                      end
      entry
    end

    # The leader's growth at pos is done, with diagnostics from all its
    # rounds: the cycle's other rules keep their longest matches from
    # them, with those diagnostics folded in (the leader's attempts are
    # part of theirs), and in the memo if they have no entry there. A
    # parse that enters the cycle at one of them from outside gets that
    # match, as the paper's semantics (Medeiros et al. 2014) give; the
    # rule's match with the leader's final one may be shorter, since
    # that may already have taken what the rule needed.
    def publish(longest, pos, furthest, expected)
      longest.each do |rule, entry|
        entry = longest[rule] = [entry[0], *further([furthest, expected], entry[1], entry[2])]
        table = @memo[rule] ||= {}
        table[pos] = entry unless table.key?(pos)
      end
    end

    # A rule of a cycle entered from outside at pos: its match is
    # computed as any rule's is, and if that grew the leader at pos
    # (which happens only if its match reached the leader there) and the
    # leader's rounds reached it, its longest match from them (see
    # publish) replaces what it matched with the leader's final one.
    def outside(leader, name, table, pos, &)
      entry = compute(table, pos, &)
      return entry unless @memo[leader]&.key?(pos)

      table[pos] = @longest[leader][pos]&.[](name) || entry
    end

    # Seed-growing (Warth et al. 2008), at a cycle's leader only, as pegen
    # does. The rule is matched with its call to itself here failing,
    # then again with that call returning the last match (the seed), for
    # as long as the match gets further. It's a loop, so a longer chain
    # uses no more stack. The memo entry stays IN_PROGRESS until the end;
    # every way back to it passes through its seed. A leader of other
    # rules starts each round with an empty table for them at pos, and
    # the growth with an empty table of their longest matches, published
    # at the end (and read by outside after it).
    #
    # Each attempt's diagnostics are kept, not just the best one's: the
    # last attempt, which got no further, is usually the one that knows
    # what was missing ("1 +" expected a number after the "+").
    def grow(name, table, pos) # rubocop:disable Metrics
      seeds = @seeds[name] ||= {}
      seeds[pos] = best = [nil, pos, NOTHING_EXPECTED]
      table[pos] = IN_PROGRESS
      rounds = @rounds[name]
      longest = @longest[name]
      longest[pos] = {} if longest
      diagnostics = [pos, NOTHING_EXPECTED]
      # Not loop: its block adds frames to every level of nesting.
      while true # rubocop:disable Style/InfiniteLoop
        rounds[pos] = {} if rounds
        result, furthest, expected = yield
        diagnostics = further(diagnostics, furthest, expected)
        break unless result && result.pos > (best[0]&.pos || -1)

        seeds[pos] = best = [result, pos, NOTHING_EXPECTED]
      end
      publish(longest[pos], pos, *diagnostics) if longest
      table[pos] = [best[0], *diagnostics]
    ensure
      seeds&.delete(pos) # nil if the stack ran out before it was set
      rounds&.delete(pos)
      table.delete(pos) if table[pos].equal?(IN_PROGRESS)
    end

    # Two frames' diagnostics as one, as fail_at would: the further
    # position wins, and at the same one the expectations are merged.
    def further(diagnostics, furthest, expected)
      return [furthest, expected] if furthest > diagnostics[0]
      return diagnostics if furthest < diagnostics[0] || expected.empty?

      [furthest, diagnostics[1] | expected]
    end

    # The rule's match so far at pos, while it grows there. Its
    # diagnostics are grow's to keep, so it carries none.
    def seed(name, pos)
      @seeds[name]&.[](pos) || raise(ArgumentError,
                                     "left recursion in rule :#{name}: it can reach itself without consuming input")
    end
  end
end
