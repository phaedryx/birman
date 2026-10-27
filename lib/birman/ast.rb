# frozen_string_literal: true

module Birman
  # Helpers for the plain-array ASTs that matchers produce via #to_ast:
  #
  #   [:str, "if"]  [:istr, "if"]  [:pat, "/\\d+/"]  [:ref, :expr]
  #   [:seq, commit_at, [parts...]]  [:choice, [alts...]]
  #   [:rep, min, max, inner]  [:not, inner]  [:and, inner]
  #   [:both, left, right]  [:action, inner]  [:label, name, inner]
  #   [:check, name, inner]  [:quiet, inner]  [:lexeme, inner]
  #   [:text, inner]  [:spanned, inner]
  #
  # A lexeme is inner, then the grammar's ignore rule. Literals are
  # lexemes too, but show as [:str, text] (or [:istr, text] for a
  # case-insensitive one, see Combinators#nocase): the ignore rule runs
  # only after the text, so only an empty literal shows as [:lexeme, ...].
  module AST
    module_function

    # Rule names referenced in an AST, in first-use order.
    def refs(node)
      case node
      in [:ref, name] then [name]
      in Array then node.flat_map { refs(_1) }.uniq
      else []
      end
    end
  end

  # Prints a grammar AST in PEG-flavored EBNF:
  #
  #   a b  sequence    a / b  choice     ~  commit (rest must match)
  #   a*  a+  a?  a{2,3}    !a  not      &a  lookahead / guard
  #
  # Actions, labels, text and spanned don't change what's accepted, so
  # they're omitted.
  # Checks do, but by running Ruby on the value, which EBNF can't show
  # (`&{name}` would only repeat the error message), so they're omitted
  # too: the EBNF accepts a superset of what the grammar does.
  module EBNF
    module_function

    # Precedence levels, loosest to tightest.
    CHOICE = 0
    SEQ    = 1
    PREFIX = 2
    ATOM   = 3

    def call(rules)
      width = rules.keys.map { _1.to_s.size }.max
      rules.map { |name, ast| "#{name.to_s.ljust(width)} = #{expr(ast, CHOICE)} ;" }.join("\n")
    end

    # One branch per AST node type, so its size grows with the matcher set.
    def expr(node, prec) # rubocop:disable Metrics
      case node
      in [:str, s]           then s.inspect
      in [:istr, s]          then "#{s.inspect}i"
      in [:pat, source]      then source
      in [:ref, name]        then name.to_s
      in [:action, inner]    then expr(inner, prec)
      in [:label, _, inner]  then expr(inner, prec)
      in [:check, _, inner]  then expr(inner, prec)
      in [:quiet, inner]     then expr(inner, prec)
      in [:lexeme, inner]    then expr(inner, prec)
      in [:text | :spanned, inner] then expr(inner, prec)
      in [:both, [:not, guard], right]
        wrap("!#{expr(guard, ATOM)} #{expr(right, PREFIX)}", prec > SEQ)
      in [:choice, alts]     then wrap(alts.map { expr(_1, SEQ) }.join(" / "), prec > CHOICE)
      in [:seq, commit_at, parts]
        items = parts.map { expr(_1, PREFIX) }
        items.insert(commit_at, "~") if commit_at
        wrap(items.join(" "), prec > SEQ)
      in [:both, left, right] then wrap("&#{expr(left, ATOM)} #{expr(right, PREFIX)}", prec > SEQ)
      in [:not, inner]        then wrap("!#{expr(inner, ATOM)}", prec > PREFIX)
      in [:and, inner]        then wrap("&#{expr(inner, ATOM)}", prec > PREFIX)
      in [:rep, min, max, inner] then "#{expr(inner, ATOM)}#{suffix(min, max)}"
      end
    end

    def suffix(min, max)
      case [min, max]
      in [0, nil] then "*"
      in [1, nil] then "+"
      in [0, 1]   then "?"
      in [n, nil] then "{#{n},}"
      in [n, ^n]  then "{#{n}}"
      in [m, n]   then "{#{m},#{n}}"
      end
    end

    def wrap(text, parens) = parens ? "(#{text})" : text
  end
end
