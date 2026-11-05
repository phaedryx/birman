# frozen_string_literal: true

module Birman
  # The Context of a traced parse (see Grammar#parse's trace:). It is
  # chosen once per parse, so an untraced parse runs Context's methods
  # with no check for tracing anywhere. It records a Trace::Frame for
  # every rule call, and closes each in an ensure, so a commit failure
  # or a stack overflow unwinding through leaves none open.
  class TracingContext < Context
    def initialize(input, grammar, ignore_rule, left_recursion = grammar.left_recursion, from = 0)
      super
      @top = @frame = Trace::Frame.new(:parse, nil, nil, from)
      @parents = []
    end

    def memoize(name, pos, &)
      frame = open_frame(:rule, name, name.to_s, pos)
      entry = super
      frame.to = entry[0]&.pos
      entry
    ensure
      close_frame(frame)
    end

    # Leftover input, with consume: true: a last top-level node.
    def end_of_input(pos)
      frame = open_frame(:end_of_input, nil, "end of input", pos)
      super
    ensure
      close_frame(frame)
    end

    def fail_at(pos, what)
      @frame.fail(pos, what)
      super
    end

    # Call once, after the parse.
    def trace = Trace.build(@top, input, ignore_ref&.name)

    private

    def open_frame(kind, rule, description, pos)
      frame = Trace::Frame.new(kind, rule, description, pos)
      @frame.children << frame
      @parents.push(@frame)
      @frame = frame
    end

    # Its furthest is the furthest of its own failures and its children's.
    def close_frame(frame)
      return unless frame && @frame.equal?(frame)

      frame.children.each do |child|
        frame.furthest = child.furthest if child.furthest && (frame.furthest.nil? || child.furthest > frame.furthest)
      end
      @frame = @parents.pop
    end
  end
end
