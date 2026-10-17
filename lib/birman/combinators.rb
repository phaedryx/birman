# frozen_string_literal: true

module Birman
  # Marker for seq: everything after it is committed (see Matcher#>).
  COMMIT = Object.new.tap { |o| def o.inspect = "Birman::COMMIT" }.freeze

  # Building blocks and parameterized rule factories, available in
  # every grammar. They're plain methods, so a module can override
  # them or add more.
  #
  # A bare string anywhere a matcher is expected (in seq or either, as
  # a rule body, after >> or |) is a literal: it skips trailing spacing
  # when the grammar declares `ignore`, and word-like ones are keywords.
  # Use str and match for exact, raw matching.
  module Combinators
    # --- Raw matchers ---

    def str(s)    = Str.new(s)
    def match(re) = Pat.new(re)
    def any       = Pat.new(/./m)
    def eof       = any.absent.label("end of input")
    def never     = Pat.new(/(?!)/)

    # A whole word: "if" matches in "if x" but not in "iffy".
    def keyword(word) = (str(word) >> match(/\w/).absent).map(&:first).label(word.inspect)

    # --- Literals and the readable forms ---

    # Anything usable as a matcher: strings become literals, regexps
    # raw patterns, and matchers pass through unchanged.
    def lit(x) = Birman.coerce(x)

    # The matcher a literal stands for: "let" is a keyword, "=" an exact
    # string, either way followed by the grammar's ignore rule. Built
    # once per grammar instance.
    def literal_matcher(text)
      (@literal_matchers ||= {})[text] ||= begin
        base = text.match?(/\A\w+\z/) ? keyword(text) : str(text)
        Lexeme.new(base, ignore_rule, text)
      end
    end

    # Sequence. Put `commit` where the construct becomes unambiguous:
    #   seq("let", commit, name.as(:name), "=", expr.as(:value))
    def seq(*items)
      commit_at = items.index(COMMIT)
      raise ArgumentError, "commit can't come first in a seq: nothing has matched yet" if commit_at&.zero?

      parts = items.reject { _1.equal?(COMMIT) }.map { lit(_1) }
      Seq.new(parts, commit_at)
    end

    def commit = COMMIT

    # Ordered choice: the first alternative that matches wins.
    def either(*alts) = alts.size == 1 ? lit(alts.first) : Choice.new(alts.map { lit(_1) })

    def one_of(*strings) = either(*strings)

    # Left-associative binary operators, folded into nodes:
    #   infix(product, "+", "-", node: BinOp)   # BinOp = node(:op, :left, :right)
    def infix(operand, *ops, node:) = Infix.new(Birman.coerce(operand), either(*ops).label("operator"), node)

    # One or more items separated by sep; value is an array of items.
    def sep_by1(item, sep) = SepBy.new(lit(item), lit(sep))

    # Zero or more items separated by sep.
    def sep_by(item, sep) = sep_by1(item, sep).maybe.map { _1 || [] }

    # inner wrapped in open/close; value is inner's.
    def between(open, close, inner) = Pick.new([lit(open), Birman.coerce(inner), lit(close)], 1)

    def parens(inner) = between("(", ")", inner)

    private

    def ignore_rule = self.class.respond_to?(:ignore) ? self.class.ignore : nil
  end
end
