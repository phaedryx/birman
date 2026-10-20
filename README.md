<p align="center">
  <img src="assets/birman.png" alt="Birman logo: a Birman cat's face" width="200">
</p>

# Birman

[![Gem Version](https://img.shields.io/gem/v/birman)](https://rubygems.org/gems/birman)
[![CI](https://github.com/phaedryx/birman/actions/workflows/main.yml/badge.svg)](https://github.com/phaedryx/birman/actions/workflows/main.yml)

A small PEG parser library for Ruby 3.2+: module-based grammars,
immutable `Data` matchers and AST nodes with source spans, packrat
memoization, commit points, labels, and `Success`/`Failure` results.

## Installation

```sh
bundle add birman
```

or in your Gemfile:

```ruby
gem "birman", "~> 0.2.2"
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
interpreter, `examples/json.rb` for a full JSON parser (tested against
`JSON.parse`), and `Grammar.to_ebnf` to print any grammar.

## Building blocks

| Form                          | Meaning                                              |
|-------------------------------|------------------------------------------------------|
| `seq(a, b, c)`                | sequence                                             |
| `seq(a, commit, b, c)`        | after `a`, the rest must match or parsing stops here |
| `seq("[", only(x), "]")`      | value is just `x`; the rest must match but is dropped |
| `either(a, b, c)`             | ordered choice                                       |
| `one_of("true" => true, ...)` | one of these literals, producing its value (tried in order) |
| `x.as(:key)`                  | name a part; the sequence's value becomes a hash     |
| `x.to(Node)`                  | build a node from that hash (or from a single value) |
| `infix(operand, "+", "-", node: BinOp)` | left-associative binary operators; `BinOp` needs `op`, `left`, `right` fields |
| `parens(x)`, `between(o, c, x)` | wrapped                                            |
| `sep_by(x, ",")`, `sep_by1`   | separated lists                                      |
| `sep_by(x, ",", trailing: true)` | and one more `","` may end the list (not an empty one) |
| `.rep(min, max)`, `.maybe`    | repetition, optional                                 |
| `.absent`, `.present`         | negative / positive lookahead                        |
| `.map(:to_i)`                 | call that method on the value                        |
| `.action(:name)`              | pass the value to the grammar's method `name`        |
| `.check(:name, "label")`      | fail as "expected label" unless the grammar's method `name` accepts the value |
| `.means(v)`                   | the value is `v` (`lit("null").means(nil)`)          |
| `.map { }`                    | transform the value with a block (prefer the above)  |
| `.label("name")`              | "expected name" in errors                            |
| `.quiet`                      | never mention in errors                              |

The operator forms still work for short rules: `a >> b` (sequence),
`a | b` (choice), `a & b` (guard), `a > b` (commit). Precedence, tightest
first: `>>`, `&`, `|`, `>`.

## Literals, spacing, and lexemes

Declare `ignore :spacing` and whitespace (and comments, with
`Rules::Comments`) takes care of itself:

- Bare strings are **literals** wherever a matcher goes: in `seq`,
  `either`, `parens` and friends, as a rule body (`rule(:semi) { ";" }`),
  or after `>>`, `|`, `&` and `>`. They skip trailing spacing, and
  word-like ones (`"let"`) are keywords, so `"let"` won't match the
  start of `letter`.
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
- Neither does a trailing separator. `sep_by(x, ",", trailing: true)`
  ends the list at a last `","` only when the `x` after it fails
  without committing.
- Lookaheads do. `x.absent`, `x.present` and the guard in `a & b` only
  ask whether `x` would match, so a commit failure inside them is just
  "no".
- `commit` can't come first in a `seq`. Nothing has matched yet, so
  there's nothing to be sure about.

This is Parsec-style commitment, not the choice-local "cut" from the
PEG literature.

## Checks

An action can only return a value, and raising escapes `parse`, so an
action can't turn a match down. `.check` can:

```ruby
rule(:date) { match(/\d{4}-\d\d-\d\d/).check(:real_date?, "a real date") }

private

def real_date?(text) = Date.valid_date?(*text.split("-").map(&:to_i))
```

The method (it may be private) gets the value and returns truthy to
accept it; the value passes through unchanged. A falsy result is an
ordinary failure, "expected a real date", where the match began, and
whatever the inner match recorded (a `rep`'s stopping point, say) is
dropped. (This example uses `Date` and `to_i`, so it won't go into a
generated parser; see below.)

- It backtracks like any failure. The furthest failure still wins, so
  if a later alternative gets further (`1979` matching a number before
  `-02-30` trips it up), that alternative owns the error.
- Inside `rep` it ends the loop, and inside `maybe` it gives `nil`.
- It commits only when an enclosing `seq` already has:
  `seq("on", commit, date)` stops at the rejected date. To commit to the
  check itself, look first: `pattern.present > pattern.check(...)`.
- An outer `.label` at the same position replaces its label.
- Like actions, the method must depend only on the value: it also runs
  inside lookaheads, and its result is memoized with the rule.

Some checks need more than one value: a name defined twice, a `break`
outside a loop. Make those in a second pass over the AST, and report
one at the node it's about with `Birman::Failure.at(node.span, reason)`.
It's a `Failure` like `parse` returns, committed, with `reason` as
its message:

```ruby
def self.check(program)
  seen = {}
  program.each do |let|
    return Birman::Failure.at(let.span, "#{let.name} is already defined") if seen[let.name]

    seen[let.name] = true
  end
  Birman::Success.new(program)
end

case Grammar.parse(source)
in Birman::Success(program) then check(program)
in failure then failure
end
# line 2, column 1: x is already defined
#   let x = 2
#   ^
```

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
  Input nested too deeply for Ruby's stack is a `Failure` too, with
  `reason` set (see Limits).
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

## Generating a parser

`Grammar.to_ruby` writes a standalone parser: Ruby source with no
dependency on Birman that gives exactly the results `parse` gives
(values, spans, error positions, expected lists and messages).

```ruby
File.write("calc_parser.rb", Calc::Grammar.to_ruby(namespace: "CalcParser"))
require_relative "calc_parser"
CalcParser::Parser.new("print 1 + 2").parse   # => Success or Failure
```

The output is written in the Ruby subset that
[Spinel](https://github.com/matz/spinel) compiles to a native binary.
Add an entry point and compile it:

```ruby
source = Calc::Grammar.to_ruby(namespace: "CalcParser") + <<~RUBY
  result = CalcParser::Parser.new($stdin.read).parse
  puts result.success? ? result.value.inspect : result.message
RUBY
File.write("calc_parser.rb", source)  # then: spinel calc_parser.rb -o calc
```

Nodes come out as plain classes under `<namespace>::BirmanRT::Node`,
with the same fields, `span`, `==` and `inspect`. Values transformed
with `.map(:sym)`, `.action(:name)` and `.means(v)` compile, as does
`.check(:name, "label")`: an action's (or check's) method is copied from
its source, with the grammar methods it calls
and the constants it reads, so copying needs the `prism` gem (bundled
from Ruby 3.3). The generator raises `Birman::Compiler::Error`, naming
the rule, for what it can't translate faithfully:

- `.map { }` blocks (their source is lost) and custom matcher classes
- regexps using `\A`, `^`, lookbehind, or `\b`/`\B` at their start:
  the generated parser scans from the current position, where those
  would see less of the input than the interpreter's do
- regexps with a wide `{m,n}` (more than 16 apart) alongside a
  lookaround, atomic group, backreference or lazy interval: Spinel's
  regexp engine tries every length on those, exponentially. Making the
  repeat atomic on its own, `(?>[a-z]{1,63})`, is allowed
- `.to(Node)` on a value that may or may not be a Hash of fields
- node classes with methods of their own (a `node(...) { }` body), and
  names that would clash in the generated code (a node called `Success`,
  a copied constant called `FAIL`, two copied constants of one name)
- actions that call `super`, Birman's own API (`keywords`, rules), or
  classes the generated parser won't have
- actions that call `Integer(...)`, `.hex`, `.oct` or `.to_i` (on
  anything but an Integer literal, since a receiver's type can't be
  told), or name them (`map(&:to_i)`): past 63 bits, in a Spinel
  binary they raise or, where Spinel can't tell the receiver is a
  String, silently give 2**63 - 1. Use `large_integer(text)` or
  `large_integer(text, base)` (`16` for `hex`, `8` for `oct`), which
  Birman gives every grammar: it is `Integer(text, base)` in Ruby, and
  in the generated parser it returns Bignums under Spinel too (from
  Floats as well: exactly, as Ruby's `Integer` does). `.map(:to_i)` is
  fine on a String, an optional String (`.maybe`; nil is 0) or an
  Integer; `.map(:hex)`, `.map(:oct)`, and `.map(:to_i)` on anything
  else are refused, as are `send` and `method` with a name that isn't
  a literal symbol. This is a net for the common forms, not a proof:
  `Float(text).round`, `text.to_f.to_int` and whatever else slips past
  it may raise, or give a wrong number without a word. `large_integer`
  takes Integer bases and Floats (truncated) as Ruby does; Rational and
  NaN bases differ (`TypeError`, `FloatDomainError`), a base that isn't
  a number raises `TypeError` as in Ruby 3.3+ (3.2's `Integer` ignores
  it), and in a binary negative bases (Ruby's "prefix or this base")
  raise

```ruby
def json_number(text) = text.match?(/[.eE]/) ? Float(text) : large_integer(text)
```

Actions and `.map(:name)` always run, as in the interpreter, even when
nothing reads their value. The generated parser reads UTF-8 or binary input (other
encodings raise `ArgumentError`). It also nests deeper before reporting
"input is nested too deeply": its methods use less stack than the
interpreter's matchers, and a Spinel binary has a 64 MB stack (JSON
arrays nest about 55,000 deep), so input that fails with the interpreter
can parse when compiled. One limit runs the other way: Spinel allows 64
`begin` blocks active at once (and exits the process past that), and
each lookahead (`absent`, `present`, `&`) holds one while its inner
matcher runs. So lookaheads nested more than 56 deep are a Failure,
"input is nested too deeply". To allow more, build with a bigger stack
and say so when generating:

```ruby
File.write("p.rb", G.to_ruby(namespace: "P", lookahead_depth: 4000))
# spinel p.rb -o p --cc="cc -DSP_EXC_STACK_MAX=4096"
```

Copied actions are exactly what you wrote. Under Spinel, a string that
isn't valid UTF-8 (JSON's lone `\ud83d`) has the same bytes but
`inspect`s differently.

## Limits

- **Deep nesting.** Each level of nesting in the input uses Ruby
  stack. With default settings a simple nested grammar handles about
  750 levels on the main thread, but only about 250 on other threads
  (Puma, Sidekiq, `Thread.new`). Past that, `parse` returns a `Failure`
  whose `reason` is "input is nested too deeply". To allow more, raise
  Ruby's thread stack sizes when starting the process:

  ```sh
  RUBY_THREAD_VM_STACK_SIZE=16777216 RUBY_THREAD_MACHINE_STACK_SIZE=67108864 ruby app.rb
  ```

  That took the same grammar to about 12,000 levels on a thread. The
  main thread gets less (about 2,000), because its machine stack comes
  from the operating system (`ulimit -s`).
- **Changing rules after parsing.** `Grammar.parse` reuses one
  instance per class, so each rule is built once. Defining a rule or
  changing a setting on a class resets that class's instance, but a
  subclass that has already parsed keeps its own: it won't see a rule
  redefined later on its parent. Define rules before parsing, or call
  `Subclass.new.parse(input)` to get a fresh instance.

## Not yet

- Left recursion. A rule that can reach itself without consuming input
  raises `ArgumentError` naming the rule; use `infix`, or
  `term (op term)*` with a fold, instead.
- Railroad diagrams from `to_ast`

## Development

```sh
bin/setup           # install dependencies
bundle exec rake    # tests + rubocop
bundle exec rake spinel   # generated parsers compiled by Spinel vs the interpreter
                          # (SPINEL=/path/to/spinel; skipped if not found)
ruby examples/calc.rb
ruby examples/json.rb
ruby examples/email.rb
ruby bench/json.rb  # vs JSON.parse, Parslet, Treetop, Citrus (installs them)
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).

## The name

Birman is named for Alexander Birman, whose 1970 Ph.D. thesis, *The
TMG Recognition Schema*, was the origin of packrat parsing and parsing
expression grammars.

The cat in the logo is a Birman too.
