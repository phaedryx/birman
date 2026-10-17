# frozen_string_literal: true

# [file]
# purpose = "AST nodes with source spans"
# responsibility = "node(...) classes, Span, and building nodes during a parse"
# pattern = "Data classes plus a mixin"
module Birman
  # Where a node came from in the source. Stored as byte offsets (see
  # Context); from, to, line and column count characters.
  # [class.Span]
  # purpose = "Where a node came from in the input"
  # fields = ["input: String", "byte_from, byte_to: Integer (byte offsets)"]
  # methods = ["from, to: character offsets", "text", "line", "column", "to_s => \"line L, column C\""]
  Span = Data.define(:input, :byte_from, :byte_to) do
    def from   = Birman.char_offset(input, byte_from)
    def to     = Birman.char_offset(input, byte_to)
    def text   = input.byteslice(byte_from...byte_to)
    def line   = before.count("\n") + 1
    def column = before.length - (before.rindex("\n") || -1)
    def to_s   = "line #{line}, column #{column}"
    def inspect = "#<Birman::Span #{line}:#{column} #{text.inspect}>"

    private

    def before = input.byteslice(0, byte_from)
  end

  # Mixed into every class made with Nodes#node. Adds an optional
  # source span that the parser fills in. The span is deliberately
  # not a Data member, so equality and pattern matching ignore it:
  # `in Num(value)` still works, and two nodes with the same contents
  # are equal wherever they came from.
  # [module.Node]
  # purpose = "Mixed into every node(...) class"
  # adds = ["span (ignored by == and pattern matching)", "with(**changes) keeping the span", "s-expression inspect"]
  module Node
    attr_reader :span

    # node_class.new(**fields) with a span. The span is set before
    # initialize runs rather than passed to it, so a node can define
    # its own initialize (for field defaults, say) without knowing
    # about spans.
    def self.new_with_span(node_class, span, fields)
      node = node_class.allocate
      node.instance_variable_set(:@span, span)
      node.__send__(:initialize, **fields)
      node
    end

    # span: is still accepted here, for building nodes by hand.
    def initialize(span: nil, **fields)
      @span = span if span
      super(**fields)
    end

    def with(**changes) = Node.new_with_span(self.class, span, to_h.merge(changes))

    # S-expression style: (BinOp "+" (Num 1) (Num 2))
    def inspect
      name = self.class.name&.split("::")&.last || "node"
      "#{["(#{name}", *to_h.values.map(&:inspect)].join(" ")})"
    end

    def pretty_print(q) = q.text(inspect)
  end

  # Extend a module with this to define AST nodes:
  #
  #   module MyLang
  #     extend Birman::Nodes
  #     Num = node(:value)
  #   end
  #
  # Also available as Birman.node.
  # [module.Nodes]
  # purpose = "Provides node(...); grammars get it automatically, other modules can extend it"
  module Nodes
    # [method.node]
    # params = ["*members: Symbol (field names; not :span)", "body: optional block of methods (may define initialize)"]
    # returns = "A Data class including Birman::Node"
    # raises = ["ArgumentError if a field is named span"]
    def node(*members, &body)
      raise ArgumentError, "a node can't have a field named span: every node already has one" if members.include?(:span)

      Data.define(*members) do
        include Node

        class_eval(&body) if body
      end
    end
  end

  extend Nodes

  # Build a node (or any Data class) from a hash of fields, attaching a
  # span when the class supports one. The span ends where the last
  # token did, leaving out spacing the ignore rule consumed after it;
  # any whitespace consumed some other way (Rules' token helper, say)
  # is trimmed too.
  def self.build(node, fields, ctx, from, to)
    return node.new(**fields) unless node.include?(Node)

    to = ctx.token_end(to)
    span = Span.new(ctx.input, from, from + ctx.input.byteslice(from, to - from).rstrip.bytesize)
    Node.new_with_span(node, span, fields)
  end
end
