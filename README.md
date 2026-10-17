<p align="center">
  <img src="assets/birman.png" alt="Birman logo: a Birman cat's face" width="200">
</p>

# Birman

A small PEG parser library for Ruby 3.2+: module-based grammars,
immutable `Data` matchers and AST nodes with source spans, packrat
memoization, commit points, labels, and `Success`/`Failure` results.

## Installation

```sh
bundle add birman
```

```ruby
require "birman"

module Lang
  # A grammar is a class that includes Birman::Grammar. Each rule is a
  # method on it, so rules can call each other by name.
  class Grammar
    include Birman::Grammar

    # Ready-made rules: `spacing` (whitespace), `number` and `identifier`.
    include Birman::Rules::Whitespace
    include Birman::Rules::Numbers
    include Birman::Rules::Identifiers

    # AST nodes: immutable Data classes that also record where in the
    # input they came from (node.span).
    Let = node(:name, :value)
    Num = node(:value)

    # Parsing starts at this rule.
    root :let_statement

    # Match `spacing` after every literal and token, and throw it away,
    # so the rules below never have to mention whitespace.
    ignore :spacing

    # Reserved words: `identifier` won't accept "let" as a name.
    keywords "let"

    # let_statement: "let", a name, "=", a number. Reading left to right:
    #   "let"                  - a literal keyword ("let", not "letter")
    #   commit                 - after "let", this must be a let statement;
    #                            a mistake later is reported right there
    #   identifier.as(:name)   - match a name and save it as :name
    #   "="                    - another literal
    #   number.to(Num)         - match a number and wrap it in a Num node,
    #     .as(:value)            saved as :value
    #   .to(Let)               - build a Let from the saved :name and :value
    rule(:let_statement) do
      seq("let", commit, identifier.as(:name), "=", number.to(Num).as(:value)).to(Let)
    end
  end
end

# parse returns Success or Failure (bad input never raises), so
# pattern-match on the result.
# (parse! returns the value or raises Birman::ParseError instead.)
case Lang::Grammar.parse("let x = 42")
in Birman::Success(ast)   then p ast        # => (Let "x" (Num 42))
in Birman::Failure => f   then warn f.message
end
```

See `examples/calc.rb` for a complete small language with an
interpreter, and `Grammar.to_ebnf` to print any grammar.

## Building blocks

| Form                          | Meaning                                              |
|-------------------------------|------------------------------------------------------|
| `seq(a, b, c)`                | sequence                                             |
| `seq(a, commit, b, c)`        | after `a`, the rest must match or parsing stops here |
| `either(a, b, c)`             | ordered choice                                       |
| `x.as(:key)`                  | name a part; the sequence's value becomes a hash     |
| `x.to(Node)`                  | build a node from that hash (or from a single value) |
| `infix(operand, "+", "-", node: BinOp)` | left-associative binary operators; `BinOp` needs `op`, `left`, `right` fields |
| `parens(x)`, `between(o, c, x)` | wrapped                                            |
| `sep_by(x, ",")`, `sep_by1`   | separated lists                                      |
| `.rep(min, max)`, `.maybe`    | repetition, optional                                 |
| `.absent`, `.present`         | negative / positive lookahead                        |
| `.map { }`                    | transform the value                                  |
| `.label("name")`              | "expected name" in errors                            |
| `.quiet`                      | never mention in errors                              |

The operator forms still work for short rules: `a >> b` (sequence),
`a | b` (choice), `a & b` (guard), `a > b` (commit). Precedence, tightest
first: `>>`, `&`, `|`, `>`.

## Literals, spacing, and lexemes

Declare `ignore :spacing` and whitespace (and comments, with
`Rules::Comments`) takes care of itself:

- Strings passed to `seq`, `either`, `infix`, `parens` and friends are
  **literals**. They skip trailing spacing, and word-like ones
  (`"let"`) are keywords, so `"let"` won't match the start of `letter`.
- `str("...")` and `match(/.../)` are **raw**: exactly those characters,
  no skipping.
- Rules for tokens (numbers, names, strings) should be declared with
  **`lexeme`** instead of `rule`, so they skip trailing spacing too. The
  built-in `Birman::Rules` already do this.

## Commit

`seq("let", commit, name, "=", expr)` says: once `"let"` has matched,
this is definitely a let statement. If anything after `commit` fails,
the whole parse fails right there, with that error. No enclosing
`either`, `rep` or `maybe` gets to backtrack and try something else.
That reach is what keeps errors pointing at the real problem instead
of at whatever a looser alternative accepted.

- `rep` and `maybe` don't stop a commit. `seq("else", commit, expr).maybe`
  rejects `else` followed by garbage rather than quietly treating it as
  "no else clause".
- Lookaheads do. `x.absent`, `x.present` and the guard in `a & b` only
  ask whether `x` would match, so a commit failure inside them is just
  "no".
- `commit` can't come first in a `seq`. Nothing has matched yet, so
  there's nothing to be sure about.

This is Parsec-style commitment, not the choice-local "cut" from the
PEG literature.

## Nodes

`node(:a, :b)` (in any grammar class, from `extend Birman::Nodes`, or
as `Birman.node`) is `Data.define` plus:

- a `span` the parser fills in (`node.span.line`, `.column`, `.text`),
  which equality and pattern matching ignore
- s-expression `inspect`: `(BinOp "+" (Num 1) (Num 2))`

A node can define its own `initialize`, for example to give a field a
default: `node(:name, :args) { def initialize(name:, args: []) = super }`.
The parser and `with` set the span without going through it. (Passing
`span:` to `new` by hand only works for nodes without their own
`initialize`.) `span` can't be a field name, since every node already
has one.

## Pieces

- `Birman::Rules`: `Whitespace`, `Comments`, `Numbers`, `Strings`,
  `Identifiers`
- Grammar settings: `root`, `ignore`, `keywords`. Subclasses inherit
  them; pass `nil` to clear one (`ignore nil`, `keywords nil`)
- `Grammar.parse` returns `Success`/`Failure`; `parse!` raises `ParseError`
  (`parse!(input, formatter: f)` words it your way).
  Input nested too deeply for Ruby's stack (several hundred levels)
  is a `Failure` too, with `reason` set.
- `Failure#message(formatter)` takes anything with `#call(failure)`
- `Grammar.to_ast` and `Grammar.to_ebnf` for introspection
- Rules are methods, so they compose and override through `include`.
  Write your own rule module with `extend Birman::RuleSet`, or
  `include Birman::Grammar` in a module to share rules, nodes and
  combinators; any class that includes it is a grammar. Settings
  (`root`, `ignore`, `keywords`) still go on the class.
- A rule can't be named after a method the grammar relies on (`send`,
  `class`, `match`, `token`...). Defining one raises `ArgumentError`
  instead of silently breaking the grammar. Redefining a rule is fine.

## Not yet

- Left recursion. A rule that can reach itself without consuming input
  raises `ArgumentError` naming the rule; use `infix`, or
  `term (op term)*` with a fold, instead.
- Compiling grammars to Ruby methods for speed
- Railroad diagrams from `to_ast`

## Development

```sh
bin/setup          # install dependencies
bundle exec rake   # tests + rubocop
ruby examples/calc.rb
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).

## The name

Birman is named for Alexander Birman, whose 1970 Ph.D. thesis, *The
TMG Recognition Schema*, was the origin of packrat parsing and parsing
expression grammars.

The cat in the logo is a Birman too.
