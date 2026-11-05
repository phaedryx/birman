# frozen_string_literal: true

# [file]
# purpose = "What parse(input, trace: true) attaches to its result"
# responsibility = "The attempt tree of one parse: built as Frames while parsing, frozen into Nodes after"
# pattern = "A mutable builder (Frame) frozen once into Data (Node), without recursion"
module Birman
  # The attempts a traced parse made (see Grammar#parse's trace:): every
  # rule call, alternative, part and literal tried, with where each
  # began and ended. It's built by TracingContext, and frozen when the
  # result it belongs to is made.
  # [class.Trace]
  # purpose = "The attempt tree of one traced parse"
  # methods = ["root -> Trace::Node", "size -> Integer (nodes)", "to_s(at:, all:, depth:, hide:) -> String",
  #            "inspect -> String (short)"]
  class Trace
    # One attempt. from, to and furthest are character offsets; to is nil
    # if it failed, and furthest nil if nothing failed inside it.
    # expected is what this node itself recorded at furthest. notes is a
    # frozen Hash (see the README's "Tracing a parse" for what each
    # means). origin: for a memo hit, the Node of the call that computed
    # it.
    # [class.Node]
    # fields = ["kind: Symbol", "rule: Symbol | nil", "description: String", "from: Integer",
    #           "to: Integer | nil", "furthest: Integer | nil", "expected: Array of String", "notes: Hash",
    #           "children: Array of Node", "origin: Node | nil"]
    Node = Data.define(:kind, :rule, :description, :from, :to, :furthest, :expected, :notes, :children, :origin) do
      # The whole subtree would be printed, and a memo hit's origin with
      # it: far too much for a console.
      def inspect
        to_part = to ? " → #{to}" : " ✗"
        "#<Birman::Trace::Node #{kind} #{description} #{from}#{to_part} #{children.size} children>"
      end
    end

    # A node while the parse is running: opened when an attempt begins,
    # closed when it ends. Positions are byte offsets until frozen.
    class Frame
      attr_accessor :to, :furthest
      attr_reader :kind, :rule, :description, :from, :children, :notes, :expected
      attr_writer :origin

      def initialize(kind, rule, description, from)
        @kind = kind
        @rule = rule
        @description = description
        @from = from
        @to = nil
        @furthest = nil
        @expected = []
        @notes = {}
        @children = []
        @origin = nil
      end

      def note(key, value) = @notes[key] = value

      # As it closes: its furthest becomes the furthest of its own
      # failures and its children's, leaving out lookaheads' and, under
      # quiet, everything.
      def reach
        return if kind == :quiet

        children.each do |child|
          next if child.furthest.nil? || child.notes[:in_lookahead]

          @furthest = child.furthest if @furthest.nil? || child.furthest > @furthest
        end
      end

      # Something this frame itself expected at pos; only the furthest
      # position's are kept, as Context#fail_at keeps them.
      def fail(pos, what)
        if @furthest.nil? || pos > @furthest
          @furthest = pos
          @expected = [what]
        elsif pos == @furthest
          @expected << what unless @expected.include?(what)
        end
      end

      # The frame's Node and every one below it, built bottom-up with an
      # explicit stack: a trace of deeply nested input is as deep as
      # Ruby's stack was. chars maps byte offsets to character offsets.
      def freeze_tree(chars)
        built = {}.compare_by_identity
        stack = [[self, false]]
        until stack.empty?
          frame, ready = stack.pop
          if ready
            built[frame] = frame.node(chars, frame.children.map { built.delete(_1) }.freeze)
          else
            stack << [frame, true]
            frame.children.each { stack << [_1, false] }
          end
        end
        built[self]
      end

      def node(chars, children)
        Node.new(kind:, rule:, description:, from: chars[from], to: to && chars[to],
                 furthest: furthest && chars[furthest], expected: expected.uniq.freeze,
                 notes: char_notes(chars).freeze, children:, origin: nil)
      end

      # The byte offsets the notes hold.
      def note_offsets
        [notes[:unwound_by_commit], notes[:seed_end], notes.dig(:committed, :pos)].compact
      end

      private

      def char_notes(chars)
        notes.to_h do |key, value|
          case key
          when :unwound_by_commit, :seed_end then [key, value && chars[value]]
          when :committed then [key, { pos: chars[value[:pos]], expected: value[:expected].uniq.freeze }.freeze]
          else [key, value]
          end
        end
      end
    end

    # A trace with only its top node: input with invalid bytes, which no
    # rule ever saw. bad is the character offset of the first.
    def self.invalid_input(input, bad, ignore)
      node = Node.new(kind: :input, rule: nil, description: "(input)", from: bad, to: nil, furthest: bad,
                      expected: [].freeze, notes: {}.freeze, children: [].freeze, origin: nil)
      new(node, input, ignore)
    end

    # { byte offset => character offset } for each of bytes, found in one
    # walk of the input rather than one walk per offset.
    def self.char_offsets(input, bytes)
      return Hash.new { |_, b| b } if input.ascii_only?

      table = {}
      sorted = bytes.uniq.sort
      byte = 0
      input.each_char.with_index do |c, char|
        table[sorted.shift] = char while sorted.first&.<=(byte)
        break if sorted.empty?

        byte += c.bytesize
      end
      sorted.each { table[_1] = input.size }
      table
    end

    # Every byte offset a frame below top records.
    def self.offsets(top)
      out = []
      stack = [top]
      while (f = stack.pop)
        out << f.from
        out << f.to if f.to
        out << f.furthest if f.furthest
        out.concat(f.note_offsets)
        stack.concat(f.children)
      end
      out
    end

    def self.build(top, input, ignore)
      new(top.freeze_tree(char_offsets(input, offsets(top))), input, ignore)
    end

    attr_reader :root, :input, :ignore, :result

    def initialize(root, input, ignore)
      @root = root
      @input = input
      @ignore = ignore
      @result = nil
    end

    # Internal: called by Success and Failure as they're made. The trace
    # needs its result to render, and is complete once it has it.
    def __finish(result)
      @result = result
      freeze
    end

    def size = Trace.count(root)

    def self.count(node)
      n = 0
      stack = [node]
      while (x = stack.pop)
        n += 1
        stack.concat(x.children)
      end
      n
    end
  end
end
