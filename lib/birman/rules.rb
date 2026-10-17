# frozen_string_literal: true

module Birman
  # A standard library of rule modules. Include the ones you need;
  # later includes override earlier ones (Comments replaces
  # Whitespace's `spacing`, for example).
  #
  # Value rules (number, string, identifier) are lexemes: in a grammar
  # that declares `ignore :spacing`, they skip trailing spacing on their own.
  module Rules
    # Whitespace as the `spacing` rule, plus a `token` helper for grammars
    # that don't declare `ignore`.
    module Whitespace
      extend RuleSet

      rule(:spacing) { match(/\s*/).quiet }

      # A matcher followed by whitespace. Only needed in grammars that
      # don't declare `ignore`.
      def token(m) = Pick.new([Birman.coerce(m), spacing], 0)
    end

    # Whitespace including comments. Works on its own or after
    # Whitespace. Override comment_pattern for other comment syntaxes.
    module Comments
      extend RuleSet

      rule(:spacing) { (match(/\s+/) | comment).rep.quiet }
      rule(:comment) { match(comment_pattern).label("comment") }

      def comment_pattern = /#[^\n]*/
      def token(m) = Pick.new([Birman.coerce(m), spacing], 0)
    end

    # Integers and floats, as Ruby numbers.
    module Numbers
      extend RuleSet

      lexeme(:integer) { match(/\d+/).map(&:to_i).label("integer") }
      lexeme(:float)   { match(/\d+\.\d+/).map(&:to_f).label("float") }
      lexeme(:number)  { (float | integer).label("number") }
    end

    # Double-quoted strings with backslash escapes. The opening quote
    # commits, so an unterminated string is reported where it breaks.
    module Strings
      extend RuleSet

      ESCAPES = { "n" => "\n", "t" => "\t", "r" => "\r", "0" => "\0" }.freeze

      lexeme(:string) do
        (str('"') > (string_part.rep >> str('"').label("closing quote")))
          .map { |(_, parts, _)| parts.join }
          .label("string")
      end

      rule(:string_part) do
        (match(/\\./).map { ESCAPES.fetch(_1[1], _1[1]) } |
          match(/[^"\\\n]+/)).label("string character")
      end
    end

    # Identifiers that can't be reserved words. Declare those in the
    # grammar with `keywords "if", "then", ...`.
    module Identifiers
      extend RuleSet

      lexeme(:identifier) { (reserved_word.absent & match(/[A-Za-z_]\w*/)).label("identifier") }

      rule(:reserved_word) do
        next never if keywords.empty?

        match(/(?:#{keywords.map { Regexp.escape(_1) }.join("|")})\b/)
      end
    end
  end
end
