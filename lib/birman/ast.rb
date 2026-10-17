# frozen_string_literal: true

module Birman
  # Helpers for the plain-array ASTs that matchers produce via #to_ast:
  #
  #   [:str, "if"]  [:pat, "/\\d+/"]  [:ref, :expr]
  #   [:seq, commit_at, [parts...]]  [:choice, [alts...]]
  #   [:rep, min, max, inner]  [:not, inner]  [:and, inner]
  #   [:both, left, right]  [:action, inner]  [:label, name, inner]
  #   [:quiet, inner]
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
  # Actions and labels don't change what's accepted, so they're omitted.
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

    def expr(node, prec)
      case node
      in [:str, s]           then s.inspect
      in [:pat, source]      then source
      in [:ref, name]        then name.to_s
      in [:action, inner]    then expr(inner, prec)
      in [:label, _, inner]  then expr(inner, prec)
      in [:quiet, inner]     then expr(inner, prec)
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
