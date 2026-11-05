# frozen_string_literal: true

module Birman
  # The Context of a traced parse (see Grammar#parse's trace:). It is
  # chosen once per parse, so an untraced parse runs Context's methods
  # with no check for tracing anywhere. Each rule runs its instrumented
  # matcher (Grammar#__traced_matcher_for), whose Probes call probe, and
  # each call records a Trace::Frame. Frames close in an ensure, so a
  # commit failure or a stack overflow unwinding through leaves none
  # open.
  class TracingContext < Context # rubocop:disable Metrics/ClassLength
    def initialize(input, grammar, ignore_rule, left_recursion = grammar.left_recursion, from = 0)
      super
      @top = @frame = Trace::Frame.new(:parse, nil, nil, from)
      @parents = []
      @lookaheads = 0
      @first_calls = {}
    end

    # Context#memoize, with Ref#match's block run on the rule's
    # instrumented matcher instead: the same two steps, so the memo entry
    # is the same. A call that doesn't run the block was answered from a
    # table: the memo, a growth round's (in_round sets @hit) or the seed
    # (seed sets it).
    def memoize(name, pos) # rubocop:disable Metrics/MethodLength
      frame = open_frame(:rule, name, name.to_s, pos)
      computed = false
      @hit = :memo
      recording(frame) do
        entry = super(name, pos) do
          computed = true
          @first_calls[[name, pos]] ||= frame
          r = isolate(pos) { grammar.__traced_matcher_for(name).match(self, pos) }
          [r, isolated_furthest, isolated_expected]
        end
        frame.to = entry[0]&.pos
        answered(frame, name, pos, entry) unless computed
        entry
      end
    end

    # Called by Trace::Probe#match: inner's match, in a frame.
    def probe(probe, pos)
      frame = open_frame(probe.kind, nil, probe.description, pos)
      recording(frame) do
        r = yield
        frame.to = r&.pos
        frame.note(:rejected_by, probe.inner.method_name) if probe.kind == :check && r.nil? && frame.children.last&.to
        r
      end
    end

    # Leftover input, with consume: true: a last top-level node.
    def end_of_input(pos)
      frame = open_frame(:end_of_input, nil, "end of input", pos)
      super
    ensure
      close_frame(frame)
    end

    # Each expectation is recorded on the frame that has it. One merged
    # in from a finished frame (a rule's, as it returns) was recorded
    # where it was made.
    def fail_at(pos, what)
      @frame.fail(pos, what) unless @merging
      super
    end

    def merge(pos, expected)
      @merging = true
      super
    ensure
      @merging = false
    end

    # The part whose failure raises it is the frame's last child.
    def commit_failure!
      @frame.children.last&.note(:committed, { pos: furthest, expected: expected.dup })
      super
    end

    def lookahead
      @lookaheads += 1
      super do
        yield
      rescue Committed
        @frame.note(:caught_commit, true)
        raise
      end
    ensure
      @lookaheads -= 1
    end

    # Call once, after the parse.
    def trace = Trace.build(@top, input, ignore_ref&.name)

    private

    # One frame per growth round, numbered, with where the seed it
    # started from ended (nil: the first round's seed fails). The last
    # round is the one that got no further.
    def grow(name, table, pos)
      round = 0
      last = nil
      entry = super do
        round += 1
        last = open_frame(:round, nil, "round #{round}", pos)
        last.note(:round, round)
        last.note(:seed_end, @seeds[name][pos][0]&.pos)
        recording(last) { yield.tap { last.to = _1[0]&.pos } }
      end
      last&.note(:stopped, true)
      entry
    end

    def in_round(round, name, pos, &)
      entry = round[name]
      @hit = :this_round if entry && !entry.equal?(IN_PROGRESS)
      super
    end

    def seed(name, pos)
      @hit = :seed
      super
    end

    # A rule of a cycle entered from outside: whether it took the longest
    # match its leader's rounds kept, rather than the one it computed.
    def outside(leader, name, table, pos, &)
      entry = super
      @frame.note(:took_longest, leader) if entry.equal?(@longest[leader][pos]&.[](name))
      entry
    end

    # A call answered without computing: labeled with what answered it,
    # and with what it replays expecting.
    def answered(frame, name, pos, entry)
      if @hit == :seed
        frame.note(:seed, true)
        frame.note(:seed_end, entry[0]&.pos)
      else
        frame.note(@hit, true)
        frame.origin = @first_calls[[name, pos]]
      end
      entry[2].each { frame.fail(entry[1], _1) }
    end

    def open_frame(kind, rule, description, pos)
      frame = Trace::Frame.new(kind, rule, description, pos)
      frame.note(:in_lookahead, true) if @lookaheads.positive?
      @frame.children << frame
      @parents.push(@frame)
      @frame = frame
    end

    # Notes what unwinds through the frame, and closes it however the
    # block ends.
    def recording(frame)
      yield
    rescue Committed => e
      frame.note(:unwound_by_commit, e.pos)
      raise
    rescue SystemStackError
      frame.note(:stack_ran_out, true)
      raise
    ensure
      close_frame(frame)
    end

    def close_frame(frame)
      return unless frame && @frame.equal?(frame)

      frame.reach
      @frame = @parents.pop
    end
  end
end
