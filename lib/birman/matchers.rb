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

    # Case equality, so a matcher works in `case`: `when date then ...`
    # parses the input with self as the whole grammar, as Birman.parse
    # does (no ignore:, so bare strings don't skip spacing). Another
    # matcher compares equal, as before, rather than being parsed. The
    # grammar built for self is cached, so a `case` in a loop doesn't
    # rebuild it.
    # [method."==="]
    # params = ["input: String (parsed), Matcher (compared with ==), or anything else (false)"]
    # returns = "true when all of input parses as self, or input is an equal matcher; never raises"
    def ===(input)
      return self == input if input.is_a?(Matcher)
      return false unless input.is_a?(String)

      Birman.parse(self, input).success?
    end

    # Keep the source text instead of the value: what self consumed, as
    # a String, ending where a node's span would (before the spacing
    # ignored after its last token). Actions inside still run.
    # [method.text]
    # returns = "Matcher whose value is the source text self consumed (self's .as name is kept)"
    # value = "String: the input from where self began to where its last token ended"
    def text = Text.new(self)

    # Keep the value and where it came from: a Spanned(value, span),
    # with the Span a node would get.
    # [method.spanned]
    # returns = "Matcher whose value is Birman::Spanned(value:, span:) (self's .as name is kept)"
    # value = "Spanned(self's value, its Span); a maybe that matched nothing gives Spanned(nil, an empty span)"
    def spanned = SpannedMatcher.new(self)

    # The name given by #as, seen through wrappers like labels.
    def capture_key = nil

    private

    # Only a seq built by >> joins the enclosing one, and only if that
    # can't change what it means: a commit or only(...) would apply to the whole.
    def inline_parts(m) = m.is_a?(Seq) && m.open? && m.commit_at.nil? && m.only_at.nil? ? m.parts : [m]
  end

  # A bare string: a literal (see Combinators#literal_matcher). What a
  # literal matches depends on the grammar's ignore rule, so the grammar
  # supplies the real matcher when this one runs. The member is str, as
  # Str's: a member named text would hide Matcher#text.
  Lit = Data.define(:str) do
    include Matcher

    def match(ctx, pos) = ctx.grammar.literal_matcher(str).match(ctx, pos)
    # Its spacing comes after the text, so it's a lexeme only when empty.
    def to_ast = str.empty? ? [:lexeme, [:str, str]] : [:str, str]
  end

  # A literal in any case (see Combinators#nocase). As with Lit, the
  # grammar running it supplies the real matcher.
  Nocase = Data.define(:str) do
    include Matcher

    def match(ctx, pos) = ctx.grammar.nocase_matcher(str).match(ctx, pos)
    def to_ast = str.empty? ? [:lexeme, [:istr, str]] : [:istr, str]
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

    # Data#with rebuilds through initialize, which would close the copy.
    def with(**changes) = changes.empty? ? self : Seq.new(open: open?, **to_h, **changes)

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
    # value, and into rep and sep_by, which collect it; a transform consumes it.
    def self.names_inside(part) # rubocop:disable Metrics
      case part
      when Seq then part.only_at ? names_inside(part.parts[part.only_at]) : part.parts.filter_map(&:capture_key)
      when Pick then names_inside(part.parts[part.index])
      when Label, Quiet, Lexeme, Check, Maybe then names_inside(part.inner)
      when Rep then names_inside(part.inner)
      when SepBy then names_inside(part.item)
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
      ctx.settle_label(pos, name, result)
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
      fields = if r.value.is_a?(Hash) then r.value
               elsif node.members.empty? then {} # a node with no fields drops the value
               else { node.members.first => r.value }
               end
      Match.new(r.pos, Birman.build(node, fields, ctx, pos, r.pos))
    end

    def to_ast = [:action, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # See Matcher#text. The text ends where a node's span would.
  Text = Data.define(:inner) do
    include Matcher

    def match(ctx, pos)
      r = inner.match(ctx, pos) or return nil
      Match.new(r.pos, ctx.span(pos, r.pos).text)
    end

    def to_ast = [:text, inner.to_ast]
    def capture_key = inner.capture_key
  end

  # See Combinators#upto. An exact string or a regexp is found with one
  # byteindex, which sees the whole input as the scanner does; any other
  # terminator is tried as a lookahead at each character, its failures
  # dropped. Either way it's tried once more at the end of the input, as
  # a lookahead that records what it expected there when it fails.
  Upto = Data.define(:terminator) do
    include Matcher

    def match(ctx, pos)
      input = ctx.input
      stop = find(ctx, pos, input) || (input.bytesize if ctx.peek?(terminator, input.bytesize)) or return nil
      Match.new(stop, input.byteslice(pos, stop - pos))
    end

    def to_ast = [:upto, terminator.to_ast]

    private

    # Where the terminator first matches before the end, or nil.
    def find(ctx, pos, input)
      case terminator
      when Str then input.byteindex(terminator.str, pos)
      when Pat then input.byteindex(terminator.re, pos)
      else
        bytes = input.encoding == Encoding::BINARY # a character per byte, as any matches
        while pos < input.bytesize
          return pos if ctx.isolate(pos) { ctx.lookahead { terminator.match(ctx, pos) } }

          pos += 1
          pos += 1 while !bytes && pos < input.bytesize && input.getbyte(pos).between?(0x80, 0xBF)
        end
      end
    end
  end

  # See Matcher#spanned. Named for the matcher, since Spanned (nodes.rb)
  # is the value it produces.
  SpannedMatcher = Data.define(:inner) do
    include Matcher

    def match(ctx, pos)
      r = inner.match(ctx, pos) or return nil
      Match.new(r.pos, Spanned.new(r.value, ctx.span(pos, r.pos)))
    end

    def to_ast = [:spanned, inner.to_ast]
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

    # Shown as a lexeme unless it's a literal with text (see Lit#to_ast).
    def to_ast = source.to_s.empty? ? [:lexeme, inner.to_ast] : [:str, source]
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

  # A precedence table (see Combinators#operators): prefix, postfix and
  # left/right binary operators, climbed by rank. Rank 1 is the loosest
  # level, the highest the tightest. prefixes and suffixes are Entry
  # lists in the order they're tried; suffixes holds the postfix and
  # binary operators.
  Operators = Data.define(:operand, :prefixes, :suffixes) do
    include Matcher

    def match(ctx, pos) = climb(ctx, pos, 1)

    # An operand (with any prefix operators), then operators of rank
    # min or tighter, folded by fixity.
    def climb(ctx, pos, min)
      start = pos
      r = operand_at(ctx, pos) or return nil
      left = r.value
      pos = r.pos

      while (step = suffix_step(ctx, pos, min, left, start))
        left, pos = step
      end

      Match.new(pos, left)
    end

    # PRE* operand (POST / IN PRE* operand)*, with PRE and the whole
    # suffix loop left out when the table has none. Without postfix
    # operators the binary ones are grouped: (IN) PRE* operand, as
    # infix's AST.
    def to_ast
      pre = prefixes.empty? ? [] : [[:rep, 0, nil, [:quiet, choice_ast(prefixes)]]]
      post = suffixes.empty? ? [] : [[:rep, 0, nil, suffix_ast(pre)]]
      [:seq, nil, [*pre, operand.to_ast, *post]]
    end

    private

    def choice_ast(entries)
      matchers = entries.map(&:matcher)
      (matchers.size == 1 ? matchers.first : Choice.new(matchers)).to_ast
    end

    # One trip round the suffix loop, under the "operator" label.
    def suffix_ast(pre)
      tail = [*pre, operand.to_ast]
      return [:seq, nil, [labelled(choice_ast(suffixes)), *tail]] if suffixes.none? { _1.fixity == :postfix }

      alts = suffixes.map { _1.fixity == :postfix ? _1.matcher.to_ast : [:seq, nil, [_1.matcher.to_ast, *tail]] }
      labelled(alts.size == 1 ? alts.first : [:choice, alts])
    end

    def labelled(ast) = [:label, "operator", ast]

    # The operand slot: a prefix operator and its operand at the
    # operator's rank, else the bare operand (also when the prefixed
    # form fails).
    def operand_at(ctx, pos)
      entry, o = prefix_at(ctx, pos)
      if entry && (right = climb(ctx, o.pos, entry.rank))
        node = Birman.build(entry.node, { op: o.value, operand: right.value }, ctx, pos, right.pos)
        return Match.new(right.pos, node)
      end

      operand.match(ctx, pos)
    end

    # The first prefix operator matching at pos, as [entry, match]; one
    # that consumes nothing counts as no match. Failures are dropped, as
    # if the choice were quiet.
    def prefix_at(ctx, pos)
      found = nil
      ctx.isolate(pos) do
        prefixes.each do |entry|
          m = entry.matcher.match(ctx, pos) or next
          found = [entry, m] if m.pos > pos
          break
        end
      end
      found
    end

    # One more operator folded onto left, as [node, end], or nil to
    # stop before the operator (rank too loose, no right side, or
    # nothing consumed).
    def suffix_step(ctx, pos, min, left, start)
      entry, o = suffix_at(ctx, pos)
      return if entry.nil? || entry.rank < min

      fields, stop = suffix_fields(ctx, entry, o, left)
      return if stop.nil? || stop == pos

      [Birman.build(entry.node, fields, ctx, start, stop), stop]
    end

    # The node fields for the operator match hit folded onto left, and
    # where the node ends; nil if a binary operator has no right side.
    def suffix_fields(ctx, entry, hit, left)
      return [{ op: hit.value, operand: left }, hit.pos] if entry.fixity == :postfix

      right = climb(ctx, hit.pos, entry.fixity == :left ? entry.rank + 1 : entry.rank) or return
      [{ op: hit.value, left:, right: right.value }, right.pos]
    end

    # The first suffix operator matching at pos, as [entry, match], with
    # the failures a Label named "operator" around their choice records.
    # With no suffixes there is no choice to fail.
    def suffix_at(ctx, pos)
      return if suffixes.empty?

      found = nil
      ctx.isolate(pos) do
        suffixes.each do |entry|
          m = entry.matcher.match(ctx, pos) or next
          found = [entry, m]
          break
        end
      end
      ctx.settle_label(pos, "operator", found&.last)
      found
    end
  end

  # source is the operator as given, matcher its coercion to a matcher;
  # fixity is :prefix, :postfix, :left or :right.
  Operators::Entry = Data.define(:source, :matcher, :fixity, :rank, :node)

  # Table checking and ordering, kept here so Combinators gains no
  # private names a rule could collide with.
  Operators::FIXITIES = %i[prefix postfix left right].freeze
  Operators::NODE_FIELDS = { prefix: %i[op operand], postfix: %i[op operand], left: %i[op left right],
                             right: %i[op left right] }.freeze

  class << Operators
    # [fixity, operators, node] from one level of an operators table.
    def level(level)
      fixity = fixity_of(level)
      ops = level[fixity].is_a?(Array) ? level[fixity] : [level[fixity]]
      raise ArgumentError, "#{fixity}: needs at least one operator" if ops.empty?

      [fixity, ops, node_of(level, fixity)]
    end

    # Maximal munch: a String operator comes after every longer String
    # operator it is a prefix of. Otherwise entries keep their order,
    # matchers included.
    def munch_order(entries)
      rest = entries.dup
      ordered = []
      until rest.empty?
        pick = rest.index { |e| rest.none? { |o| shadows?(o, e) } } || 0
        ordered << rest.delete_at(pick)
      end
      ordered
    end

    private

    def shadows?(longer, entry)
      longer.source.is_a?(String) && entry.source.is_a?(String) &&
        longer.source.size > entry.source.size && longer.source.start_with?(entry.source)
    end

    def fixity_of(level)
      unless level.is_a?(Hash)
        raise ArgumentError, "an operators level is a Hash, like { left: \"+\", node: Node }: #{level.inspect}"
      end

      unknown = level.keys - [*Operators::FIXITIES, :node]
      raise ArgumentError, "unknown key #{unknown.first.inspect} in operators level #{level.inspect}" if unknown.any?

      fixities = level.keys & Operators::FIXITIES
      return fixities.first if fixities.size == 1

      raise ArgumentError, "an operators level needs exactly one of #{Operators::FIXITIES.join(", ")}: #{level.inspect}"
    end

    def node_of(level, fixity)
      node = level[:node] or raise ArgumentError, "an operators level needs a node: #{level.inspect}"
      want = Operators::NODE_FIELDS[fixity]
      unless node.respond_to?(:members) && node.members.sort == want.sort
        raise ArgumentError, "a #{fixity}: node needs exactly the fields #{want[0..-2].join(", ")} and #{want.last}, " \
                             "not #{node.respond_to?(:members) ? node.members.join(", ") : node.inspect}"
      end
      node
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
