# frozen_string_literal: true

# [file]
# purpose = "The combinators available inside every rule body"
# responsibility = "Building matchers: raw strings and patterns, literals, sequences, choices, lists, wrappers"
# dependencies = ["Birman::Matcher", "matchers.rb (Seq, Choice, Pick, SepBy, Infix, Lexeme)"]
# pattern = "Parser combinators (PEG)"
module Birman
  # Marker for seq: everything after it is committed (see Matcher#>).
  COMMIT = Object.new.tap { |o| def o.inspect = "Birman::COMMIT" }.freeze

  # Marks the part of a seq that becomes its whole value (see #only).
  Only = Data.define(:matcher)

  # Building blocks and parameterized rule factories, available in
  # every grammar. They're plain methods, so a module can override
  # them or add more.
  #
  # A bare string anywhere a matcher is expected (in seq or either, as
  # a rule body, after >> or |) is a literal: it skips trailing spacing
  # when the grammar declares `ignore`, and word-like ones are keywords.
  # Use str and match for exact, raw matching.
  # [module.Combinators]
  # purpose = "Matcher-building methods mixed into every grammar (via Birman::Grammar)"
  # input = "Strings (literals), Regexps (raw patterns) and matchers"
  # output = "Immutable matcher objects; nothing is matched until Grammar#parse"
  # notes = "Method names here are reserved: a rule can't share one"
  module Combinators
    # --- Raw matchers ---

    # [method.str]
    # params = ["s: String"]
    # returns = "Matcher that matches exactly s; never skips spacing, never a keyword"
    # value = "s"
    def str(s) = Str.new(s)

    # [method.match]
    # params = ["re: Regexp (anchored at the current position; \\A, ^ and lookbehind see the whole input)"]
    # returns = "Matcher for the regexp; raw, nothing skipped"
    # value = "the matched text"
    def match(re) = Pat.new(re)

    # [method.any]
    # returns = "Matcher for any one character, newlines included"
    def any = Pat.new(/./m)

    # [method.eof]
    # returns = "Matcher that succeeds only at the end of the input, consuming nothing"
    def eof = any.absent.label("end of input")

    # [method.never]
    # returns = "Matcher that always fails (a placeholder for an empty choice)"
    def never = Pat.new(/(?!)/)

    # A whole word: "if" matches in "if x" but not in "iffy".
    # [method.keyword]
    # params = ["word: String"]
    # returns = "Matcher for word when not followed by a word character"
    # value = "word"
    def keyword(word) = Pick.new([str(word), match(/\w/).absent], 0).label(word.inspect)

    # --- Literals and the readable forms ---

    # Anything usable as a matcher: strings become literals, regexps
    # raw patterns, and matchers pass through unchanged.
    # [method.lit]
    # params = ["x: String | Regexp | Matcher"]
    # returns = "A matcher: String -> literal, Regexp -> raw pattern, matcher unchanged"
    # raises = ["ArgumentError (anything else, or only(...) outside seq)"]
    def lit(x) = Birman.coerce(x)

    # The matcher a literal stands for: "let" is a keyword, "=" an exact
    # string, either way followed by the ignore rule of the grammar
    # running it. Built once per grammar instance.
    # [method.literal_matcher]
    # params = ["text: String"]
    # returns = "The matcher a literal stands for: keyword or exact string, then the ignore rule"
    # side_effects = ["Caches the matcher on the grammar instance"]
    # notes = "Called by Lit at match time; rarely needed directly"
    def literal_matcher(text)
      (@literal_matchers ||= {})[text] ||= begin
        base = text.match?(/\A\w+\z/) ? keyword(text) : str(text)
        Lexeme.new(base, text)
      end
    end

    # A literal matched in any case: nocase("select") matches SELECT,
    # Select or select. Like a literal, it skips trailing spacing and a
    # word-like one (ASCII letters, digits and _) is a keyword. Its value
    # is the text as written here ("select"), not as matched.
    # [method.nocase]
    # params = ["text: String"]
    # returns = "Matcher for text in any case: a literal (spacing skipped, word-like ones are keywords)"
    # value = "text, as written in the grammar, whatever case the input used"
    # raises = ["ArgumentError (anything but a String)"]
    def nocase(text)
      raise ArgumentError, "nocase needs a String, got #{text.inspect}" unless text.is_a?(String)

      Nocase.new(text)
    end

    # The matcher a case-insensitive literal stands for (see nocase): the
    # text as a /i pattern, with a keyword boundary when word-like, then
    # the ignore rule. Built once per grammar instance, as literal_matcher.
    # [method.nocase_matcher]
    # params = ["text: String"]
    # returns = "What nocase(text) stands for: a /i pattern, keyword-bounded when word-like, then the ignore rule"
    # side_effects = ["Caches the matcher on the grammar instance"]
    # notes = "Called by Nocase at match time; rarely needed directly"
    def nocase_matcher(text)
      (@nocase_matchers ||= {})[text] ||= begin
        word = text.match?(/\A\w+\z/)
        re = Regexp.new("#{Regexp.escape(text)}#{"(?!\\w)" if word}", Regexp::IGNORECASE)
        Lexeme.new(Pat.new(re, "#{text.inspect}i").means(text))
      end
    end

    # Sequence. Put `commit` where the construct becomes unambiguous:
    #   seq("let", commit, name.as(:name), "=", expr.as(:value))
    # [method.seq]
    # params = ["*items: String | Regexp | Matcher | commit | only(...)"]
    # returns = "Matcher for the items in order"
    # value = "Array of item values; a Hash of the .as-named parts if any; the only(...) part's value if used"
    # raises = ["ArgumentError (commit first; more than one only; only mixed with .as names)",
    #           "ArgumentError (a name used twice; a nested seq's names the value would drop)"]
    def seq(*items)
      commit_at = items.index(COMMIT)
      raise ArgumentError, "commit can't come first in a seq: nothing has matched yet" if commit_at&.zero?

      parts = items.reject { _1.equal?(COMMIT) }
      only_at = only_index(parts)
      Seq.new(parts.map { _1.is_a?(Only) ? _1.matcher : lit(_1) }, commit_at, only_at)
    end

    # [method.commit]
    # returns = "Marker for seq: if anything after it fails, the whole parse fails there"
    # notes = "Lookaheads contain a commit failure; rep and maybe don't"
    def commit = COMMIT

    # Inside seq, makes this part the seq's whole value; the rest still
    # has to match but is dropped:
    #   seq("[", commit, only(sep_by(value, ",")), "]")   # => [...]
    # [method.only]
    # params = ["x: String | Regexp | Matcher"]
    # returns = "Marker for seq making x's value the seq's whole value"
    # notes = "x's .as name, if any, passes to the enclosing seq"
    def only(x) = Only.new(lit(x))

    # Ordered choice: the first alternative that matches wins.
    # [method.either]
    # params = ["*alts: String | Regexp | Matcher"]
    # returns = "Ordered choice: the first alternative that matches wins"
    # value = "The winning alternative's value (a name all the alternatives share passes outward)"
    def either(*alts) = alts.size == 1 ? lit(alts.first) : Choice.new(alts.map { lit(_1) })

    # One of several literals. Given a hash, each literal produces its
    # value: one_of("true" => true, "null" => nil). They're tried in
    # order, so put longer ones first ("<=" before "<").
    # [method.one_of]
    # params = ["*choices: String literals", "or one Hash of literal => value"]
    # returns = "Ordered choice of the literals"
    # value = "The matched literal, or its Hash value"
    def one_of(*choices)
      return either(*choices) unless choices in [Hash => table]

      either(*table.map { |text, value| lit(text).means(value) })
    end

    # Left-associative binary operators, folded into nodes:
    #   infix(product, "+", "-", node: BinOp)   # BinOp = node(:op, :left, :right)
    # [method.infix]
    # params = ["operand: Matcher", "*ops: String literals", "node: node class with op, left, right fields"]
    # returns = "Matcher for operand (op operand)*, folded left-associatively"
    # value = "operand's value, or nested node instances with spans"
    # raises = ["ArgumentError at parse time if node lacks op/left/right"]
    def infix(operand, *ops, node:) = Infix.new(Birman.coerce(operand), either(*ops).label("operator"), node)

    # One or more items separated by sep; value is an array of items.
    # With trailing: true, one separator may follow the last item:
    #   seq("[", only(sep_by(value, ",", trailing: true)), "]")   # [1, 2,]
    # [method.sep_by1]
    # params = ["item: String | Regexp | Matcher", "sep: String | Regexp | Matcher", "trailing: Boolean = false"]
    # returns = "Matcher for one or more items separated by sep (and, if trailing, maybe one more sep)"
    # value = "Array of item values (item's .as name passes outward)"
    def sep_by1(item, sep, trailing: false) = SepBy.new(lit(item), lit(sep), 1, trailing)

    # Zero or more items separated by sep. A trailing separator needs an
    # item before it: "," alone isn't an empty list.
    # [method.sep_by]
    # params = ["item: String | Regexp | Matcher", "sep: String | Regexp | Matcher", "trailing: Boolean = false"]
    # returns = "Matcher for zero or more items separated by sep (and, if trailing, maybe one more sep)"
    # value = "Array of item values, [] when there are none"
    def sep_by(item, sep, trailing: false) = SepBy.new(lit(item), lit(sep), 0, trailing)

    # inner wrapped in open/close; value is inner's.
    # [method.between]
    # params = ["open: String | Matcher", "close: String | Matcher", "inner: Matcher"]
    # returns = "Matcher for open inner close"
    # value = "inner's value (inner's .as name passes outward)"
    def between(open, close, inner) = Pick.new([lit(open), Birman.coerce(inner), lit(close)], 1)

    # [method.parens]
    # params = ["inner: Matcher"]
    # returns = "between(\"(\", \")\", inner)"
    def parens(inner) = between("(", ")", inner)

    private

    def only_index(parts)
      indexes = parts.each_index.select { parts[_1].is_a?(Only) }
      raise ArgumentError, "a seq can have only one only(...)" if indexes.size > 1

      indexes.first
    end

    def ignore_rule = self.class.respond_to?(:ignore) ? self.class.ignore : nil
  end

  # Birman.seq, Birman.str and the rest, for building matchers outside a
  # grammar (see Birman.parse). literal_matcher and nocase_matcher stay
  # private: they're what a grammar runs for a literal, and Birman isn't one.
  extend Combinators

  singleton_class.send(:private, :literal_matcher, :nocase_matcher)
end
