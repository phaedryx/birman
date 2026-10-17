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
  class Grammar
    include Birman::Grammar
    include Birman::Rules::Whitespace
    include Birman::Rules::Numbers
    include Birman::Rules::Identifiers

    Let = node(:name, :value)
    Num = node(:value)

    root :let_stmt
    skip :sp
    keywords "let"

    rule(:let_stmt) { seq("let", commit, identifier.as(:name), "=", number.to(Num).as(:value)).to(Let) }
  end
end

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

## Literals, skip, and lexemes

Declare `skip :sp` and whitespace takes care of itself:

- Strings passed to `seq`, `either`, `infix`, `parens` and friends are
  **literals**. They skip trailing whitespace, and word-like ones
  (`"let"`) are keywords, so `"let"` won't match the start of `letter`.
- `str("...")` and `match(/.../)` are **raw**: exactly those characters,
  no skipping.
- Rules for tokens (numbers, names, strings) should be declared with
  **`lexeme`** instead of `rule`, so they skip whitespace too. The
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
- Grammar settings: `root`, `skip`, `keywords` (all inherited)
- `Grammar.parse` returns `Success`/`Failure`; `parse!` raises `ParseError`
- `Failure#message(formatter)` takes anything with `#call(failure)`
- `Grammar.to_ast` and `Grammar.to_ebnf` for introspection
- Rules are methods, so they compose and override through `include`.
  Write your own rule module with `extend Birman::RuleSet`, or
  `include Birman::Grammar` in a module to share rules, nodes and
  combinators; any class that includes it is a grammar. Settings
  (`root`, `skip`, `keywords`) still go on the class.
- A rule can't be named after a method the grammar relies on (`send`,
  `class`, `match`, `token`...). Defining one raises `ArgumentError`
  instead of silently breaking the grammar. Redefining a rule is fine.

## Not yet

- Left recursion (use `infix`, or `term (op term)*` with a fold)
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
