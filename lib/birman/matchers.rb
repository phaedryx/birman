# frozen_string_literal: true

module Birman
  def self.coerce(x)
    case x
    when Matcher then x
    when String  then Str.new(x)
    when Regexp  then Pat.new(x)
    else raise ArgumentError, "can't make a matcher from #{x.inspect}"
    end
  end

  # Combinator operators, mixed into every matcher type.
  #
  # Ruby's operator precedence shapes the notation, tightest first:
  #
  #   >>   sequence
  #   &    conjunction
  #   |    ordered choice
  #   >    commit
  #
  # So `a > b >> c` means `a > (b >> c)`, and a commit inside a choice
  # needs parentheses: `(keyword("if") > body) | other`.
  module Matcher
    def >>(other) = Seq.new([self, Birman.coerce(other)])
    def |(other)  = Choice.new([self, Birman.coerce(other)])

    # Conjunction: self must match here (without consuming input),
    # then other is matched from the same spot. Value is other's.
    def &(other) = Both.new(self, Birman.coerce(other))

    # Commit: once self matches, everything after it must match too, or
    # parsing stops right here with an error instead of backtracking.
    # This is dry-logic's implication operator, applied to parsing.
    def >(other)
      left  = uncommitted_parts(self)
      right = uncommitted_parts(Birman.coerce(other))
      Seq.new([*left, *right], left.size)
    end

    def rep(min = 0, max = nil) = Rep.new(self, min, max)
    def maybe       = rep(0, 1).map(&:first)
    def absent      = Not.new(self)
    def present     = And.new(self)
    def map(&fn)    = Action.new(self, fn)
    def label(name) = Label.new(self, name)

    # Never mention this matcher in error messages (for whitespace,
    # comments, and other things nobody wants to be told to type).
    def quiet = Quiet.new(self)

    # Name this part of a sequence. A sequence with any named parts
    # produces a hash of just those parts instead of an array.
    def as(key) = Named.new(self, key)

    # Build a node from the value: a hash of named parts becomes
    # keyword arguments; anything else fills the node's first field.
    # Nodes made with Birman.node get a source span.
    def to(node) = To.new(self, node)

    # The name given by #as, seen through wrappers like labels.
    def capture_key = nil

    private

    def uncommitted_parts(m) = m.is_a?(Seq) && m.commit_at.nil? ? m.parts : [m]
  end

  # Literal string.
  Str = Data.define(:str) do
    include Matcher

    def match(ctx, pos)
      if ctx.input.byteslice(pos, str.bytesize) == str
        Match.new(pos + str.bytesize, str)
      else
        ctx.fail_at(pos, str.inspect)
      end
    end

    def to_ast = [:str, str]
  end

  # Regex, anchored at the current position with \G.
  Pat = Data.define(:re, :source) do
    include Matcher

    def initialize(re:, source: re.inspect) = super

    def match(ctx, pos)
      scanner = ctx.scanner
      scanner.pos = pos
      len = scanner.match?(re) or return ctx.fail_at(pos, source)
      Match.new(pos + len, scanner.matched)
    end

    def to_ast = [:pat, source]
  end

  # Sequence: parts match in order. The value is an array, or a hash
  # of the named parts if any are named (see Matcher#as). Parts at
  # index `commit_at` and beyond are committed: if one fails, parsing stops.
  Seq = Data.define(:parts, :commit_at) do
    include Matcher

    def initialize(parts:, commit_at: nil) = super

    def >>(other) = with(parts: [*parts, Birman.coerce(other)])

    def match(ctx, pos)
      values = parts.each_with_index.map do |part, i|
        r = part.match(ctx, pos)
        unless r
          fail_committed!(ctx, part, pos) if commit_at && i >= commit_at
          return nil
        end
        pos = r.pos
        r.value
      end
      Match.new(pos, shape(values))
    end

    def to_ast = [:seq, commit_at, parts.map(&:to_ast)]

    private

    # If the failed part recorded nothing at or past pos (it's quiet,
    # or a negative lookahead), describe the part itself so the error
    # still says what was expected.
    def fail_committed!(ctx, part, pos)
      ctx.fail_at(pos, EBNF.expr(part.to_ast, EBNF::CHOICE)) if ctx.furthest < pos || ctx.expected.empty?
      ctx.commit_failure!
    end

    def shape(values)
      keys = parts.map(&:capture_key)
      return values if keys.none?

      keys.zip(values).select(&:first).to_h
    end
  end

  # Parts in order, keeping only the value (and the name, see
  # Matcher#as) of the part at index. Unlike Seq it never flattens
  # or reshapes, so the kept part comes through as it was.
  Pick = Data.define(:parts, :index) do
    include Matcher

    def match(ctx, pos)
      value = nil
      parts.each_with_index do |part, i|
        r = part.match(ctx, pos) or return nil
        value = r.value if i == index
        pos = r.pos
      end
      Match.new(pos, value)
    end

    def to_ast = [:seq, nil, parts.map(&:to_ast)]
    def capture_key = parts[index].capture_key
  end

  # One or more items separated by sep. The value is an array of the
  # items, and the name (see Matcher#as) is the item's.
  SepBy = Data.define(:item, :sep) do
    include Matcher

    def match(ctx, pos)
      r = item.match(ctx, pos) or return nil
      values = [r.value]
      pos = r.pos
      loop do
        s = sep.match(ctx, pos) or break
        r = item.match(ctx, s.pos) or break
        break if r.pos == pos # an empty separator and item would loop forever

        values << r.value
        pos = r.pos
      end
      Match.new(pos, values)
    end

    def to_ast = [:seq, nil, [item.to_ast, [:rep, 0, nil, [:seq, nil, [sep.to_ast, item.to_ast]]]]]
    def capture_key = item.capture_key
  end

  # Ordered choice: the first alternative that matches wins.
  Choice = Data.define(:alts) do
    include Matcher

    def |(other) = with(alts: [*alts, Birman.coerce(other)])

    def match(ctx, pos)
      alts.each do |alt|
        r = alt.match(ctx, pos) and return r
      end
      nil
    end

    def to_ast = [:choice, alts.map(&:to_ast)]
  end

  # Repetition with min/max; value is an array.
  Rep = Data.define(:inner, :min, :max) do
    include Matcher

    def match(ctx, pos)
      values = []
      while max.nil? || values.size < max
        r = inner.match(ctx, pos) or break
        break if r.pos == pos # an empty match would loop forever
        values << r.value
        pos = r.pos
      end
      values.size >= min ? Match.new(pos, values) : nil
    end

    def to_ast = [:rep, min, max, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # Negative lookahead. The inner attempt's failures are discarded,
  # since failing is exactly what we hoped for.
  Not = Data.define(:inner) do
    include Matcher

    def match(ctx, pos)
      r, = ctx.isolate(pos) { ctx.lookahead { inner.match(ctx, pos) } }
      r ? nil : Match.new(pos, nil)
    end

    def to_ast = [:not, inner.to_ast]
  end

  # Positive lookahead: succeeds without consuming if inner matches.
  And = Data.define(:inner) do
    include Matcher

    def match(ctx, pos) = ctx.lookahead { inner.match(ctx, pos) } ? Match.new(pos, nil) : nil

    def to_ast = [:and, inner.to_ast]
  end

  # Conjunction (see Matcher#&).
  Both = Data.define(:left, :right) do
    include Matcher

    def match(ctx, pos) = ctx.lookahead { left.match(ctx, pos) } && right.match(ctx, pos)

    def to_ast = [:both, left.to_ast, right.to_ast]
  end

  # Semantic action: transform the value of a successful match.
  Action = Data.define(:inner, :fn) do
    include Matcher

    def match(ctx, pos)
      r = inner.match(ctx, pos) or return nil
      r.with(value: fn.call(r.value))
    end

    def to_ast = [:action, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # Names a matcher for error messages. If inner fails without getting
  # past its starting position, the error says "expected <name>"
  # instead of listing every low-level alternative. If it got further,
  # the deeper (more specific) error is kept.
  Label = Data.define(:inner, :name) do
    include Matcher

    def match(ctx, pos)
      result, furthest, expected = ctx.isolate(pos) { inner.match(ctx, pos) }
      if result.nil? && furthest == pos
        ctx.fail_at(pos, name)
      else
        ctx.merge(furthest, expected)
      end
      result
    end

    def to_ast = [:label, name, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # See Matcher#as. Passes the value through; the enclosing Seq reads
  # the key.
  Named = Data.define(:inner, :key) do
    include Matcher

    def match(ctx, pos) = inner.match(ctx, pos)
    def to_ast = inner.to_ast
    def capture_key = key
  end

  # See Matcher#to.
  To = Data.define(:inner, :node) do
    include Matcher

    def match(ctx, pos)
      r = inner.match(ctx, pos) or return nil
      fields = r.value.is_a?(Hash) ? r.value : { node.members.first => r.value }
      r.with(value: Birman.build(node, fields, ctx.input, pos, r.pos))
    end

    def to_ast = [:action, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # A token: inner, then the grammar's ignore rule (usually spacing),
  # keeping inner's value. With no ignore rule it's just inner. `display`
  # is how a literal shows up in EBNF ("let" rather than its internals).
  Lexeme = Data.define(:inner, :ignore, :display) do
    include Matcher

    def initialize(inner:, ignore:, display: nil) = super

    def match(ctx, pos)
      r = inner.match(ctx, pos) or return nil
      return r unless ignore

      s = Ref.new(ignore).match(ctx, r.pos)
      s ? Match.new(s.pos, r.value) : r
    end

    def to_ast = display ? [:str, display] : inner.to_ast
    def capture_key = inner.capture_key
  end

  # Left-associative binary operators: operand (op operand)*, folded
  # into nodes built as node.new(op:, left:, right:), so the node needs
  # exactly those fields, in any order.
  # Each node's span covers its whole subexpression.
  Infix = Data.define(:operand, :op, :node) do
    include Matcher

    def match(ctx, pos)
      start = pos
      r = operand.match(ctx, pos) or return nil
      left = r.value
      pos = r.pos

      loop do
        o = op.match(ctx, pos) or break
        right = operand.match(ctx, o.pos) or break
        fields = { op: o.value, left:, right: right.value }
        left = Birman.build(node, fields, ctx.input, start, right.pos)
        pos = right.pos
      end

      Match.new(pos, left)
    end

    def to_ast
      [:seq, nil, [operand.to_ast, [:rep, 0, nil, [:seq, nil, [op.to_ast, operand.to_ast]]]]]
    end
  end

  # See Matcher#quiet.
  Quiet = Data.define(:inner) do
    include Matcher

    def match(ctx, pos)
      result, = ctx.isolate(pos) { inner.match(ctx, pos) }
      result
    end

    def to_ast = [:quiet, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # A reference to a named rule, resolved through the grammar carried
  # in the context. Each (rule, position) is parsed once and memoized
  # along with its diagnostics: packrat parsing.
  Ref = Data.define(:name) do
    include Matcher

    def match(ctx, pos)
      result, furthest, expected = ctx.memo[[name, pos]] ||=
        ctx.isolate(pos) { ctx.grammar.matcher_for(name).match(ctx, pos) }
      ctx.merge(furthest, expected)
      result
    end

    def to_ast = [:ref, name]
  end
end
