# frozen_string_literal: true

# [file]
# purpose = "The matcher types and the methods every matcher responds to"
# responsibility = "Matching at a byte position against a Context; building ASTs for EBNF"
# dependencies = ["Birman::Context", "StringScanner (via Context#scanner)"]
# pattern = "Immutable Data objects composed into a tree; packrat memoization at rule refs"
# public_api = "Birman::Matcher (operators and modifiers below); the Data classes are internal"
module Birman
  # [method."Birman.coerce"]
  # params = ["x: String | Regexp | Matcher"]
  # returns = "Matcher: String -> literal (Lit), Regexp -> raw pattern (Pat), matcher unchanged"
  # raises = ["ArgumentError (only(...) outside seq, or anything else)"]
  def self.coerce(x)
    case x
    when Matcher then x
    when String  then Lit.new(x)
    when Regexp  then Pat.new(x)
    when Only    then raise ArgumentError, "only(...) works inside seq, to make one part the seq's value"
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
  # [module.Matcher]
  # purpose = "Operators and modifiers shared by every matcher"
  # notes = "Arguments go through Birman.coerce, so bare strings are literals"
  module Matcher
    # [method.">>"]
    # params = ["other: String | Regexp | Matcher"]
    # returns = "Sequence of self then other: a chain of >> is one seq"
    # notes = "A seq from seq(...), or with a commit or only, is one part, as in seq(self, other)"
    def >>(other) = Seq.new(parts: [*inline_parts(self), *inline_parts(Birman.coerce(other))], open: true)

    # [method."|"]
    # params = ["other: String | Regexp | Matcher"]
    # returns = "Ordered choice: self, else other"
    def |(other) = Choice.new([self, Birman.coerce(other)])

    # Conjunction: self must match here (without consuming input),
    # then other is matched from the same spot. Value is other's.
    # [method."&"]
    # params = ["other: String | Regexp | Matcher"]
    # returns = "self as a guard (lookahead), then other from the same position"
    # value = "other's value"
    def &(other) = Both.new(self, Birman.coerce(other))

    # Commit: once self matches, everything after it must match too, or
    # parsing stops right here with an error instead of backtracking.
    # This is dry-logic's implication operator, applied to parsing.
    # [method.">"]
    # params = ["other: String | Regexp | Matcher"]
    # returns = "Sequence of self then other, committed after self (like seq(self, commit, other))"
    def >(other)
      left  = inline_parts(self)
      right = inline_parts(Birman.coerce(other))
      Seq.new([*left, *right], left.size)
    end

    # [method.rep]
    # params = ["min: Integer = 0", "max: Integer | nil = nil (unbounded)"]
    # returns = "Matcher for self repeated min..max times"
    # value = "Array of values; an empty first match counts once, then ends the loop"
    def rep(min = 0, max = nil) = Rep.new(self, min, max)

    # [method.maybe]
    # returns = "Optional self"
    # value = "self's value, or nil when absent"
    def maybe = Maybe.new(self)

    # [method.absent]
    # returns = "Negative lookahead: succeeds, consuming nothing, when self doesn't match here"
    # value = "nil"
    def absent = Not.new(self)

    # [method.present]
    # returns = "Positive lookahead: succeeds, consuming nothing, when self matches here"
    # value = "nil"
    def present = And.new(self)

    # Prefer a Symbol to a block: a Symbol is data a compiler can read,
    # while a block's source is lost and it can capture local variables.
    # [method.map]
    # params = ["method_name: Symbol, called on self's value", "or fn: block taking self's value"]
    # returns = "Matcher whose value is the method's (or block's) result (self's .as name is kept)"
    # raises = ["ArgumentError (both a Symbol and a block, or neither)"]
    def map(method_name = nil, &fn)
      return Send.new(self, method_name) if method_name && !fn
      return Map.new(self, fn) if fn && !method_name

      raise ArgumentError, "map takes a method name or a block (one, not both)"
    end

    # Pass the value to a method of the grammar, for real work such as
    # decoding escapes or parsing numbers. The method may be private,
    # and subclasses can override it.
    # [method.action]
    # params = ["method_name: Symbol, a grammar instance method taking one argument"]
    # returns = "Matcher whose value is grammar.method_name(self's value) (self's .as name is kept)"
    def action(method_name) = Action.new(self, method_name)

    # Reject a match the grammar can't accept for reasons a pattern
    # can't express (1979-02-30 isn't a date). The method may be
    # private, and, like an action, must depend only on the value: it
    # runs inside lookaheads, and its result is memoized with the rule.
    # A rejection is an ordinary failure where self began, so a choice
    # backtracks past it (and a later alternative that gets further
    # owns the error) unless an enclosing seq has committed.
    # [method.check]
    # params = ["method_name: Symbol, a grammar instance method taking one argument", "name: String"]
    # returns = "self, failing as \"expected <name>\" when grammar.method_name(self's value) is falsy"
    # value = "self's value (self's .as name is kept)"
    def check(method_name, name) = Check.new(self, method_name, name)

    # Replace the value with a constant: lit("null").means(nil). The
    # same object comes back from every match.
    # [method.means]
    # params = ["value: any object"]
    # returns = "Matcher whose value is always value (self's .as name is kept)"
    def means(value) = Const.new(self, value)

    # [method.label]
    # params = ["name: String"]
    # returns = "self, reported as \"expected <name>\" when it fails without consuming input"
    def label(name) = Label.new(self, name)

    # Never mention this matcher in error messages (for whitespace,
    # comments, and other things nobody wants to be told to type).
    # [method.quiet]
    # returns = "self, never mentioned in error messages"
    def quiet = Quiet.new(self)

    # Name this part of a sequence. A sequence with any named parts
    # produces a hash of just those parts instead of an array.
    # [method.as]
    # params = ["key: Symbol"]
    # returns = "self, named: the enclosing seq's value becomes a Hash of named parts"
    def as(key) = Named.new(self, key)

    # Build a node from the value: a hash of named parts becomes
    # keyword arguments; anything else fills the node's first field.
    # Nodes made with Birman.node get a source span.
    # [method.to]
    # params = ["node: node class (or any Data class)"]
    # returns = "Matcher whose value is node built from self's value"
    # value = "node.new(**hash), or node.new(first_field => value); with a span for node(...) classes"
    def to(node) = To.new(self, node)

    # The name given by #as, seen through wrappers like labels.
    def capture_key = nil

    private

    # Only a seq built by >> joins the enclosing one, and only if that
    # can't change what it means: a commit or only(...) would apply to the whole.
    def inline_parts(m) = m.is_a?(Seq) && m.open? && m.commit_at.nil? && m.only_at.nil? ? m.parts : [m]
  end

  # A bare string: a literal (see Combinators#literal_matcher). What a
  # literal matches depends on the grammar's ignore rule, so the grammar
  # supplies the real matcher when this one runs.
  Lit = Data.define(:text) do
    include Matcher

    def match(ctx, pos) = ctx.grammar.literal_matcher(text).match(ctx, pos)
    def to_ast = [:str, text]
  end

  # Exact string, nothing skipped (see Combinators#str).
  Str = Data.define(:str) do
    include Matcher

    # The error text is worked out once, not on every failed attempt.
    def initialize(str:)
      @expected = str.inspect.freeze
      super
    end

    def match(ctx, pos)
      scanner = ctx.scanner
      scanner.pos = pos
      scanner.match?(str) ? Match.new(pos + str.bytesize, str) : ctx.fail_at(pos, @expected)
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

    # [method.captures]
    # returns = "Matcher for the regexp whose value is a Hash of its named groups"
    # value = "{name: text} for each named group, in order (Symbol keys); nil for a group that didn't match"
    # raises = ["ArgumentError (no named groups, or a name used twice)"]
    def captures = Captures.new(self)

    def to_ast = [:pat, source]
  end

  # A regexp's named groups as a Hash (see Pat#captures). It does its
  # own scan, so nothing can move the scanner before the groups are read.
  Captures = Data.define(:pat) do
    include Matcher

    def initialize(pat:)
      twice, = pat.re.named_captures.find { |_, groups| groups.size > 1 }
      problem = pat.re.names.empty? ? "has no named groups" : twice && "names #{twice} more than once"
      raise ArgumentError, "captures needs groups named once each, (?<name>...): #{pat.source} #{problem}" if problem

      @names = pat.re.names.map(&:to_sym).freeze
      super
    end

    def match(ctx, pos)
      scanner = ctx.scanner
      scanner.pos = pos
      len = scanner.match?(pat.re) or return ctx.fail_at(pos, pat.source)
      Match.new(pos + len, @names.each_with_index.to_h { |name, i| [name, scanner[i + 1]] })
    end

    def to_ast = pat.to_ast
  end

  # Sequence: parts match in order. The value is an array, or a hash
  # of the named parts if any are named (see Matcher#as). Parts at
  # index `commit_at` and beyond are committed: if one fails, parsing stops.
  # A name used twice, or a nested seq's names the value would drop, raise.
  Seq = Data.define(:parts, :commit_at, :only_at) do
    include Matcher

    # Arrays are copied and frozen so a matcher is immutable all the way down.
    # `open` (built by >>, so a later >> extends it) isn't a member: it
    # changes how the seq composes, not what it matches, so == ignores it.
    def initialize(parts:, commit_at: nil, only_at: nil, open: false)
      check_names(parts, only_at)
      @open = open
      super(parts: parts.dup.freeze, commit_at:, only_at:)
    end

    def open? = @open

    def match(ctx, pos)
      values = Array.new(parts.size)
      parts.each_with_index do |part, i|
        r = part.match(ctx, pos) or return failed(ctx, part, pos, i)
        values[i] = r.value
        pos = r.pos
      end
      Match.new(pos, shape(values))
    end

    def to_ast = [:seq, commit_at, parts.map(&:to_ast)]

    # With only(...), the kept part's name (if any) passes outward.
    def capture_key = only_at && parts[only_at].capture_key

    # The names a part's value is a hash of, when the part has no name of
    # its own to carry that hash: seen through wrappers that keep the
    # value, but not into rep, sep_by or a transform, which reshape it.
    def self.names_inside(part) # rubocop:disable Metrics
      case part
      when Seq then part.only_at ? names_inside(part.parts[part.only_at]) : part.parts.filter_map(&:capture_key)
      when Pick then names_inside(part.parts[part.index])
      when Label, Quiet, Lexeme, Check, Maybe then names_inside(part.inner)
      when Both then names_inside(part.right)
      when Choice then part.alts.flat_map { names_inside(_1) }.uniq
      when Captures then part.pat.re.names.map(&:to_sym)
      else []
      end
    end

    private

    def check_names(parts, only_at)
      keys = parts.filter_map(&:capture_key)
      twice = keys.find { keys.count(_1) > 1 }
      raise ArgumentError, "a seq can't name two parts #{twice.inspect}" if twice

      if only_at
        check_dropped(parts.reject.with_index { |_, i| i == only_at })
      elsif keys.any?
        check_dropped(parts.reject(&:capture_key))
      end
    end

    # Parts the seq's value leaves out can't have names.
    def check_dropped(dropped)
      raise ArgumentError, "a seq with only(...) can't also name parts with .as" if dropped.any?(&:capture_key)

      hidden = dropped.flat_map { Seq.names_inside(_1) }
      return if hidden.empty?

      raise ArgumentError, "a seq inside a seq would lose its names #{hidden.map(&:inspect).join(", ")}: " \
                           "list its parts in the outer seq, or name it with .as"
    end

    def failed(ctx, part, pos, index)
      fail_committed!(ctx, part, pos) if commit_at && index >= commit_at
      nil
    end

    # If the failed part recorded nothing at or past pos (it's quiet,
    # or a negative lookahead), describe the part itself so the error
    # still says what was expected.
    def fail_committed!(ctx, part, pos)
      ctx.fail_at(pos, EBNF.expr(part.to_ast, EBNF::CHOICE)) if ctx.furthest < pos || ctx.expected.empty?
      ctx.commit_failure!
    end

    def shape(values)
      return values[only_at] if only_at

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

    def initialize(parts:, index:) = super(parts: parts.dup.freeze, index:)

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

  # Items separated by sep: at least one, or with min 0 possibly none.
  # The value is an array of the items (a new one each time, even when
  # empty), and the name (see Matcher#as) is the item's. With trailing,
  # a separator with no item after it ends the list and is kept in the
  # match; the item's failure there is still recorded, so whatever
  # comes next shares the error ("expected value or ]").
  SepBy = Data.define(:item, :sep, :min, :trailing) do
    include Matcher

    def initialize(item:, sep:, min: 1, trailing: false) = super

    def match(ctx, pos)
      r = item.match(ctx, pos) or return (min.zero? ? Match.new(pos, []) : nil)
      values = [r.value]
      pos = r.pos
      loop do
        s = sep.match(ctx, pos) or break
        r = item.match(ctx, s.pos)
        pos = s.pos if r.nil? && trailing
        break if r.nil? || r.pos == pos # an empty separator and item would loop forever

        values << r.value
        pos = r.pos
      end
      Match.new(pos, values)
    end

    def to_ast
      parts = [item.to_ast, [:rep, 0, nil, [:seq, nil, [sep.to_ast, item.to_ast]]]]
      parts << [:rep, 0, 1, sep.to_ast] if trailing
      list = [:seq, nil, parts]
      min.zero? ? [:rep, 0, 1, list] : list
    end

    def capture_key = item.capture_key
  end

  # Ordered choice: the first alternative that matches wins.
  Choice = Data.define(:alts) do
    include Matcher

    def initialize(alts:) = super(alts: alts.dup.freeze)

    def |(other) = with(alts: [*alts, Birman.coerce(other)])

    def match(ctx, pos)
      alts.each do |alt|
        r = alt.match(ctx, pos) and return r
      end
      nil
    end

    def to_ast = [:choice, alts.map(&:to_ast)]

    # A name every alternative has passes outward; differing names don't.
    def capture_key = alts.map(&:capture_key).uniq.then { _1.size == 1 ? _1.first : nil }
  end

  # Repetition with min/max; value is an array.
  Rep = Data.define(:inner, :min, :max) do
    include Matcher

    def match(ctx, pos)
      values = []
      while max.nil? || values.size < max
        r = inner.match(ctx, pos) or break
        # Matching nothing ends the loop (repeating it would never stop).
        # It still counts as the first match, so `x.rep(1)` and `x.maybe`
        # work when x can match empty; after real matches it's just the end.
        if r.pos == pos
          values << r.value if values.empty?
          break
        end

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
      r = ctx.isolate(pos) { ctx.lookahead { inner.match(ctx, pos) } }
      r ? nil : Match.new(pos, nil)
    end

    def to_ast = [:not, inner.to_ast]
  end

  # Positive lookahead: succeeds without consuming if inner matches.
  And = Data.define(:inner) do
    include Matcher

    def match(ctx, pos) = ctx.peek?(inner, pos) ? Match.new(pos, nil) : nil

    def to_ast = [:and, inner.to_ast]
  end

  # Conjunction (see Matcher#&).
  Both = Data.define(:left, :right) do
    include Matcher

    def match(ctx, pos) = ctx.peek?(left, pos) ? right.match(ctx, pos) : nil

    def to_ast = [:both, left.to_ast, right.to_ast]
  end

  # Optional (see Matcher#maybe): inner's value, or nil. Never fails.
  Maybe = Data.define(:inner) do
    include Matcher

    def match(ctx, pos) = inner.match(ctx, pos) || Match.new(pos, nil)
    def to_ast = [:rep, 0, 1, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # A successful match whose value is replaced: the shared shape of
  # Const, Map, Send and Action, each defining transform(value, ctx).
  module Transform
    include Matcher

    def match(ctx, pos)
      r = inner.match(ctx, pos) or return nil
      Match.new(r.pos, transform(r.value, ctx))
    end

    def to_ast = [:action, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # See Matcher#means.
  Const = Data.define(:inner, :constant) do
    include Transform

    def transform(_value, _ctx) = constant
  end

  # Transform the value with a block (see Matcher#map).
  Map = Data.define(:inner, :fn) do
    include Transform

    def transform(value, _ctx) = fn.call(value)
  end

  # Transform the value by calling one of its methods (see Matcher#map).
  Send = Data.define(:inner, :method_name) do
    include Transform

    def transform(value, _ctx) = value.public_send(method_name)
  end

  # Semantic action: pass the value to a grammar method (see Matcher#action).
  Action = Data.define(:inner, :method_name) do
    include Transform

    def transform(value, ctx) = ctx.grammar.__send__(method_name, value)
  end

  # Names a matcher for error messages. If inner fails (or succeeds
  # while consuming nothing) without getting past its starting
  # position, the error says "expected <name>"
  # instead of listing every low-level alternative. If it got further,
  # the deeper (more specific) error is kept.
  Label = Data.define(:inner, :name) do
    include Matcher

    def match(ctx, pos)
      result = ctx.isolate(pos) { inner.match(ctx, pos) }
      furthest = ctx.isolated_furthest
      expected = ctx.isolated_expected
      if furthest == pos && (result.nil? || (result.pos == pos && expected.any?))
        ctx.fail_at(pos, name)
      else
        ctx.merge(furthest, expected)
      end
      result
    end

    def to_ast = [:label, name, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # Semantic predicate (see Matcher#check). Like Label, inner runs
  # isolated, so a rejection can drop what inner recorded (a rep's
  # stopping point, say), as Not does, and report only its own name.
  Check = Data.define(:inner, :method_name, :name) do
    include Matcher

    def match(ctx, pos)
      result = ctx.isolate(pos) { inner.match(ctx, pos) }
      return ctx.fail_at(pos, name) if result && !ctx.grammar.__send__(method_name, result.value)

      ctx.merge(ctx.isolated_furthest, ctx.isolated_expected)
      result
    end

    def to_ast = [:check, name, inner.to_ast]
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
      Match.new(r.pos, Birman.build(node, fields, ctx, pos, r.pos))
    end

    def to_ast = [:action, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # A token: inner, then the ignore rule (usually spacing) of the
  # grammar running it, keeping inner's value. With no ignore rule it's
  # just inner. `source` is how a literal shows up in EBNF ("let"
  # rather than its internals).
  Lexeme = Data.define(:inner, :source) do
    include Matcher

    def initialize(inner:, source: nil) = super

    def match(ctx, pos)
      r = inner.match(ctx, pos) or return nil
      ignore = ctx.ignore_ref or return r

      s = ignore.match(ctx, r.pos) or return r
      ctx.ignored_after(r.pos, s.pos)
      Match.new(s.pos, r.value)
    end

    def to_ast = source ? [:str, source] : inner.to_ast
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
        left = Birman.build(node, fields, ctx, start, right.pos)
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
      ctx.isolate(pos) { inner.match(ctx, pos) }
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
      result, furthest, expected = ctx.memoize(name, pos) do
        r = ctx.isolate(pos) { ctx.grammar.matcher_for(name).match(ctx, pos) }
        [r, ctx.isolated_furthest, ctx.isolated_expected]
      end
      ctx.merge(furthest, expected)
      result
    end

    def to_ast = [:ref, name]
  end
end
