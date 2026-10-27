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
gem "birman", "~> 0.3.0"
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
interpreter, `examples/leftcalc.rb` for its arithmetic written as left
recursion instead of `infix`, `examples/json.rb` for a full JSON parser (tested against
`JSON.parse`), `examples/toml.rb` for TOML 1.0 (tested against the
official toml-test suite), `examples/query.rb` for a GitHub-style
search query (lookahead, implicit AND, a custom error formatter) with
an evaluator that filters records and a compiler to SQL for
ActiveRecord's `where`, and `Grammar.to_ebnf` to print any grammar.

## Why not a regex?

A Ruby regex can match nested input with `\g<name>`, but it can't
build the structure (a capture keeps only its last match), and it
can't say what's wrong when the match fails.

```ruby
re = /\A(?<l>\[\s*(?:(?:\d+|\g<l>)(?:\s*,\s*(?:\d+|\g<l>))*)?\s*\])\z/
re.match?("[1, [2, 3], []]")      # => true
re.match("[1, [2, 3], []]")[:l]   # => "[1, [2, 3], []]"  (just the string back)
re.match?("[1, [2, 3]")           # => false              (no hint why)

class Lists
  include Birman::Grammar
  include Birman::Rules::Whitespace
  ignore :spacing
  root :list
  rule(:list) { seq("[", commit, only(sep_by(item, ",")), "]") }
  rule(:item) { either(match(/\d+/).map(&:to_i), list) }
end

Lists.parse("[1, [2, 3], []]")   # => Success([1, [2, 3], []])
puts Lists.parse("[1, [2, x], []]").message
# line 1, column 9: expected /\d+/ or "[", found "x"
#   [1, [2, x], []]
#           ^
```

## Building blocks

| Form                          | Meaning                                              |
|-------------------------------|------------------------------------------------------|
| `seq(a, b, c)`                | sequence                                             |
| `seq(a, commit, b, c)`        | after `a`, the rest must match or parsing stops here |
| `seq("[", only(x), "]")`      | value is just `x`; the rest must match but is dropped |
| `either(a, b, c)`             | ordered choice                                       |
| `one_of("true" => true, ...)` | one of these literals, producing its value (tried in order) |
| `nocase("select")`            | a literal in any case (`SELECT`, `Select`); value `"select"` |
| `x.as(:key)`                  | name a part; the sequence's value becomes a hash     |
| `x.to(Node)`                  | build a node from that hash (or from a single value) |
| `infix(operand, "+", "-", node: BinOp)` | left-associative binary operators; `BinOp` needs `op`, `left`, `right` fields |
| `parens(x)`, `between(o, c, x)` | wrapped                                            |
| `sep_by(x, ",")`, `sep_by1`   | separated lists                                      |
| `sep_by(x, ",", trailing: true)` | and one more `","` may end the list (not an empty one) |
| `match(re).captures`          | a hash of `re`'s named groups (`{date: "1979-05-27", time: nil}`; `nil` for a group that didn't match) |
| `.rep(min, max)`, `.maybe`    | repetition, optional                                 |
| `.absent`, `.present`         | negative / positive lookahead                        |
| `.map(:to_i)`                 | call that method on the value                        |
| `.action(:name)`              | pass the value to the grammar's method `name`        |
| `.check(:name, "label")`      | fail as "expected label" unless the grammar's method `name` accepts the value |
| `.means(v)`                   | the value is `v` (`lit("null").means(nil)`)          |
| `.map { }`                    | transform the value with a block (prefer the above)  |
| `.label("name")`              | "expected name" in errors                            |
| `.quiet`                      | never mention in errors                              |

Rules can be left-recursive, written the way a textbook grammar writes
left-associative operators (see [Left recursion](#left-recursion)):

```ruby
rule(:expr) { either(seq(expr.as(:left), either("+", "-").as(:op), term.as(:right)).to(BinOp), term) }
```

`1 - 2 - 3` parses as `(1 - 2) - 3`, the same tree
`infix(term, "+", "-", node: BinOp)` builds.

A name used twice in one `seq` raises `ArgumentError`, and so does a
`seq` of named parts (or `match(re).captures`) inside another whose
value would drop it, even through `maybe`, `rep`, `label`, `either` and
the like: list the parts in the outer `seq`, or name the inner one,
`seq(...).as(:pair)`. A name every alternative of an `either` shares
passes outward; alternatives named differently pass on none. A rule
keeps its names to itself, so using one inside a `seq` is always fine.

The operator forms still work for short rules: `a >> b` (sequence),
`a | b` (choice), `a & b` (guard), `a > b` (commit). Precedence, tightest
first: `>>`, `&`, `|`, `>`. A chain of `>>` is one sequence:
`a.as(:x) >> b.as(:y) >> c.as(:z)` is `seq(a.as(:x), b.as(:y), c.as(:z))`,
however it's grouped, and `a > b >> c` is `seq(a, commit, b, c)`. A seq
built any other way (by `seq(...)`, or with a commit or `only`) stays
one part, as it would in `seq`: `pair >> c` is `seq(pair, c)`.

## Literals, spacing, and lexemes

Declare `ignore :spacing` and whitespace (and comments, with
`Rules::Comments`) takes care of itself:

- Bare strings are **literals** wherever a matcher goes: in `seq`,
  `either`, `parens` and friends, as a rule body (`rule(:semi) { ";" }`),
  or after `>>`, `|`, `&` and `>`. They skip trailing spacing, and
  word-like ones (`"let"`) are keywords, so `"let"` won't match the
  start of `letter`.
- `nocase("select")` is a literal matched in any case: `SELECT`,
  `Select` and `select` all match, and its value is `"select"` as
  written in the grammar, so the rest of the grammar compares against
  one spelling (to keep the text as typed, use the raw
  `match(/select/i)`, which skips no spacing and has no boundary). It
  skips trailing spacing like any literal, and word-like ones (ASCII
  letters, digits and `_`) get the keyword boundary, so `nocase("is")`
  doesn't match the start of `island`. It shows as `"select"i` in
  errors and EBNF. Folding is Ruby's (`/i`): `nocase("école")` matches
  `ÉCOLE`, and the match is as long as the input, not the literal
  (`nocase("straße")` matches the seven bytes of `STRASSE`; a Spinel
  binary folds one character to one, see
  [Generating a parser](#generating-a-parser)). `keywords` and
  `Rules::Identifiers` are case-sensitive: a grammar whose keywords are
  `nocase` needs its own reserved-word check in its identifier rule.
- `str("...")` and `match(/.../)` are **raw**: exactly those characters,
  no skipping. `match(/.../).captures` is raw too, its value a hash of
  the named groups with Symbol keys, every name always present. Each
  name must be used once (`(?<n>a)|(?<n>b)` raises `ArgumentError`), and
  unnamed groups aren't included: Ruby stops capturing them once a group
  is named. `.to(Node)` builds a node from it like any hash.
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

## Left recursion

A rule can call itself before consuming anything, as grammars usually
write left-associative operators:

```ruby
rule(:expr) { either(seq(expr, "-", term).map { |l, _, r| l - r }, term) }
rule(:term) { either(seq(term, "*", integer).map { |l, _, r| l * r }, integer) }

parse!("5*4*2-5*9*2") # => -50, as ((5*4)*2) - ((5*9)*2)
```

`expr op term` is the left-associative form, the same shape `infix`
builds. Birman grows the match from a seed (Warth et al., 2008): it
tries the rule with its own call failing, then again with that call
returning the last match, for as long as the match gets further. So
each level is a value or node of its own, `((3-4)-5)`, and a node's
span covers its whole subexpression. A long chain uses no more stack
than a short one, and errors say what the last attempt needed
(`1-` expects an integer after the `-`). `to_ruby` generates parsers
that do the same.

The recursion can go through other rules too (indirect left
recursion), as when each level of precedence is split in two:

```ruby
rule(:sum)   { terms }
rule(:terms) { either(seq(sum, "-", term).map { |l, _, r| l - r }, term) }
```

Each cycle grows at one rule, its leader, as pegen does: the first rule
(in the order the grammar uses them) that every way round the cycle
passes through, here `sum`. While it grows, the cycle's other rules
are matched afresh each round, since what they match depends on how
far it has got.

- The rule needs an alternative that doesn't start with itself, its
  base case (`term` above), and the alternatives that do start with it
  come first. Tried first, `term` would win every round, so
  `either(term, seq(expr, "-", term))` could never grow past `3`. Either
  mistake in the rule's own `either` (not one nested inside a `seq`)
  raises `ArgumentError` on the first parse, or `to_ruby`, saying which: ``in left-recursive rule :expr, the alternative `term`
  comes before `expr "-" term`, so the rule can never grow past it``.
  In a cycle, any of its rules counts as the rule itself: one of them
  needs a base case, and in each, the alternatives that start with a
  rule of the cycle come first.
- `expr op expr`, with the rule on both sides, comes out
  right-associative: `3-4-5` is `3-(4-5)`. The call on the right grows
  to the end of the input before the left one can. Write `expr op term`.
- A cycle is grown only at its leader. While it grows, each of the
  cycle's other rules keeps its longest match from the rounds, and a
  parse that enters the cycle at one of them gets that: in
  `l ← p ".x" / "x"; p ← p "(n)" / l` (Medeiros et al., 2014), every
  way round passes through `p`, so `p` leads even when the parse starts
  at `l`, and `l` still matches all of `x(n).x`, as the paper's
  semantics give. (The rule's match with the leader's final one would
  be shorter: `p` has grown over the `.x`.) So an assignment target
  can be a member access, `member ← call "." name / atom`, though
  `call ← call "(" args ")" / member` leads. `parse(root:)` doesn't
  change which rule leads, so a generated parser agrees whatever rule
  it starts at. A cycle the grammar's root never reaches, only a
  `root:` rule does, takes the first rule that could lead by name.
- Where the paper grows whichever rule a call reaches, Birman grows
  only the leader, so what a cycle's rules match follows its growth,
  wherever the parse starts. Most grammars can't tell; three kinds can.
  With two rules that each have a base case of their own,
  `b ← c "<" / "<"; c ← b "<" / "<"` (`c` leads), a parse of `<<` at `b`
  matches `<`, which fits `c` matching both; the paper gives `b` both,
  which needs `c` to match only `<`. A rule whose match shrinks as the
  leader grows keeps its longer one from an earlier round: in
  `a ← b "<" / "<"; b ← a ">" / b "<" / "<"` (`b` leads), `a` matches
  all of `<<`, with `b` matching `<`, where the paper gives `<`, since
  `b` has grown over the second one. And a cycle a rule can go round
  without matching anything (`a ← b / "<"; b ← a / "<<"`, or one past
  only lookaheads or rules that can match nothing) has no single
  meaning: there `b` matches all of `<<`, and the paper `<`.
- Cycles with no rule in common (`a` and `b` each call themselves and
  each other) have nowhere to grow both from, so they raise
  `ArgumentError` on the first parse, or `to_ruby`, naming them:
  `left recursion through cycles with no rule in common isn't
  supported: :a -> :a; :b -> :b`.
- Left recursion through a custom matcher, which Birman can't see into,
  is caught only when the parse gets there.

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

## Without a grammar

For a one-off pattern, skip the class: the combinators are on `Birman`
too, and `Birman.parse` runs a matcher as a whole grammar.

```ruby
B = Birman
date = B.seq(B.match(/\d{4}/), "-", B.match(/\d\d/)).map { _1.join }

B.parse(date, "2026-10")    # => Success("2026-10")
B.parse!(date, "26-10")     # raises Birman::ParseError

B.parse(B.seq("let", B.match(/\w+/)), "let  x", ignore: /\s*/)
# => Success(["let", "x"])
```

`parse` returns `Success`/`Failure` and never raises on bad input, as
`Grammar.parse` does; `parse!` takes `formatter:` too. `ignore:` is a
matcher (a regexp, a string or any matcher) rather than a rule name,
since there's no grammar for a name to refer to; literals skip it, as
in a grammar with `ignore`, but `str` and `match` stay raw, so skip
spacing after them yourself if you need to. Matchers are values, so the grammar built
for one is cached and reused for an equal one.

A matcher works in `case` too: `===` parses the input as `parse` does
with no `ignore:`, true when all of it matches, false for a `Failure`
or anything that isn't a `String`. Another matcher compares equal, as
before, rather than being parsed.

```ruby
case "2026-10"
when date then :date
when B.match(/[a-z]+/) then :word
end                         # => :date
```

The cached grammar is reused here, so a `case` in a loop doesn't
rebuild it.

To drop the `Birman.` prefix, mix `Birman::Combinators` into a class
of your own: `extend` it for matchers held in constants, `include` it
for matchers built by instance methods.

```ruby
class Dates
  extend Birman::Combinators
  DATE = seq(match(/\d{4}/), "-", match(/\d\d/))
  def self.parse(s) = Birman.parse(DATE, s)
end
Dates.parse("2026-10")  # => Success(["2026", "-", "10"])

class Inst
  include Birman::Combinators
  def date = seq(match(/\d{4}/).as(:y), "-", match(/\d\d/).as(:m))
end
Birman.parse(Inst.new.date, "2026-10")  # => Success({y: "2026", m: "10"})
```

The class is just a namespace, not a grammar: matchers have no `parse`
of their own, so run them with `Birman.parse`, and bare strings skip
spacing only when you pass `ignore:`.

`rule` and `lexeme` aren't in `Combinators`, so anything named or
recursive, and `Birman::Rules` (`number`, `identifier`, ...), still
needs `include Birman::Grammar`; so do `keywords` and `.action`/`.check`
with methods of your own (`large_integer` works). A rule reference,
or an action or check naming a method of your own, raises
`ArgumentError` before parsing starts.

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
  `reason` set (see Limits), and so is invalid UTF-8: `reason` is
  "invalid UTF-8", at the first bad byte. Besides a String, `parse`
  takes anything with `read` (an IO, a StringIO, a File), read once from
  where it is and left open, or a Pathname, whose file is read as UTF-8;
  `Failure#input` and the positions are in terms of the String read.
  Anything else raises `ArgumentError`.
- `parse(input, root: :rule)` starts at any rule instead of the root,
  which is handy for testing one rule on its own. The rule needn't be
  reachable from the root; its left recursion is checked and grown as
  the root's is, whichever rule of a cycle it is (see
  [Left recursion](#left-recursion)). A name that isn't a rule (even
  `:send`, which is a method) raises `ArgumentError`, `undefined rule
  :send`.

  ```ruby
  Calc::Grammar.parse!("1 + 2 * 3", root: :sum)  # => (BinOp "+" (Num 1) ...)
  ```

- `parse(input, consume: false)` succeeds when a prefix of the input
  matches, rather than all of it, and fails only if the root does (the
  Failure never expects "end of input"). `Success#pos` says where the
  match ended, in characters: where its last token ended, before any
  spacing the grammar ignored after it, so the rest of the input is
  `input[result.pos..]`. Read a header, then stop (with a grammar of
  your own whose `:headers` rule reads them):

  ```ruby
  result = MailGrammar.parse(email, root: :headers, consume: false)
  body = email[result.pos..].sub(/\A\r?\n/, "")
  ```

  `pos` isn't a field of `Success` (it's left out of `==` and
  `inspect`, as a node's span is), so `in Birman::Success(value)` still
  matches.
- `parse(input, offset: n)` starts the parse at character `n` of the
  input instead of the first (Citrus's `offset:`), skipping ignored
  spacing there as it would at the start. Positions still count from
  the start of the input, so `Success#pos`, a `Failure`'s position and
  node spans point into the whole string. Read a header, then parse
  the body from where it ended:

  ```ruby
  header = MailGrammar.parse(email, root: :headers, consume: false)
  body = MailGrammar.parse(email, root: :body, offset: header.pos)
  ```

  The regexps see the whole input: `\A` matches only at 0, not at the
  offset, and a lookbehind can see what's before the offset, as if the
  whole document were being parsed. "End of input" is the real end. An
  offset that's negative or past the end raises `ArgumentError`. Invalid
  UTF-8 anywhere in the input is a `Failure`, before the offset too,
  since a regexp would refuse the whole string.
- `parse!`, the instance methods, `Birman.parse` (which takes
  `consume:` and `offset:` but not `root:`, since its matcher is the
  only rule) and generated parsers take the same options.
- `Failure#message(formatter)` takes anything with `#call(failure)`
- `Grammar.to_ast` and `Grammar.to_ebnf` for introspection
- Rules are methods, so they compose and override through `include`.
  Write your own rule module with `extend Birman::RuleSet`, or
  `include Birman::Grammar` in a module to share rules, nodes and
  combinators; any class that includes it is a grammar. Settings
  (`root`, `ignore`, `keywords`) still go on the class. A rule that
  overrides an included one can call it with `super()`, as in
  `rule(:number) { seq(super(), "..", super()) }`. It must be the
  parenthesised form: a bare `super` raises `ArgumentError` saying so,
  since Ruby can't pass arguments on implicitly from a `define_method`
  method.
- A rule can't be named after a method the grammar relies on (`send`,
  `class`, `match`, `token`, or a private helper in one of Birman's
  modules, like `Rules::Strings`'s `decode_escape`), nor after a public
  method of your own. Defining one raises `ArgumentError` saying whose
  method it would replace, instead of silently breaking the grammar.
  Redefining a rule is fine, and so is replacing your grammar's own
  private helpers.

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
  result = CalcParser::Parser.new($stdin).parse
  puts result.success? ? result.value.inspect : result.message
RUBY
File.write("calc_parser.rb", source)  # then: spinel calc_parser.rb -o calc
```

Its `parse` takes `consume:` and `offset:` as `Grammar#parse` does, and
`root:` for the rules you name when generating it (besides the grammar's
root, the only other rules kept whole in it):

```ruby
source = Calc::Grammar.to_ruby(namespace: "CalcParser", roots: [:sum])
CalcParser::Parser.new("1 + 2").parse(root: :sum)   # => Success
CalcParser::Parser.new("1 + 2").parse(root: :atom)  # ArgumentError
```

Nodes come out as plain classes under `<namespace>::BirmanRT::Node`,
with the same fields, `span`, `==` and `inspect`. Values transformed
with `.map(:sym)`, `.action(:name)` and `.means(v)` compile, as does
`.check(:name, "label")`: an action's (or check's) method is copied from
its source, with the grammar methods it calls
and the constants it reads (`Float::INFINITY` and `Float::NAN` too), so
copying needs the `prism` gem (bundled from Ruby 3.3). So is a node's
`initialize` that only gives fields defaults (see Nodes): each node the
generated parser builds gets the default for a field its value leaves
out, a new one each time, as in Ruby. The generator raises `Birman::Compiler::Error`, naming
the rule, for what it can't translate faithfully:

- `.map { }` blocks (their source is lost) and custom matcher classes
- regexps using `\A`, `^`, lookbehind, or `\b`/`\B` at their start:
  the generated parser scans from the current position, where those
  would see less of the input than the interpreter's do
- regexps with a wide `{m,n}` (more than 16 apart) alongside a
  lookaround, atomic group, backreference or lazy interval: Spinel's
  regexp engine tries every length on those, exponentially. Making the
  repeat atomic on its own, `(?>[a-z]{1,63})`, is allowed
- `.to(Node)` that may leave out a field with no default: named parts
  that miss one, or one value (or a value that may or may not be a Hash
  of fields) for a node with a field past its first that has none
- node classes with methods of their own (a `node(...) { }` body),
  except an `initialize` that takes exactly the fields as keywords,
  gives some literal defaults (nil, true, false, numbers, strings,
  symbols, and arrays and hashes of them) and only calls `super`, as
  `def initialize(name:, args: []) = super` does; and
  names that would clash in the generated code (a node called `Success`,
  a copied constant called `FAIL`, two copied constants of one name,
  rules `:a?` and `:a_3f`, which are both `a_3f` there)
- actions that call `super`, Birman's own API (`keywords`, rules), or
  classes the generated parser won't have, or that read a constant path
  other than `Float::INFINITY` and `Float::NAN` (`Math::PI`; copy it
  into a constant of the grammar)
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
nothing reads their value. The generated parser takes what `parse` takes (a
String, anything with `read`, or a Pathname), in UTF-8 or binary (other
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

Copied actions are exactly what you wrote, plus a `# @rbs name: untyped`
comment for each parameter, so Spinel takes a seq's mixed parts
(`[3, "*", 4]`) as they come. A method with optional, rest, keyword or
block parameters gets none: give an action that indexes mixed parts
plain parameters. Under Spinel, a string that
isn't valid UTF-8 (JSON's lone `\ud83d`) has the same bytes but
`inspect`s differently. Spinel's regexps fold case one character to
one: `nocase("école")` matches `ÉCOLE` in a binary as in Ruby, but
`nocase("straße")` matches `STRASSE` only in Ruby (whose `/i` folds ß
to ss), and the same goes for `match(/straße/i)`.

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
- **Left recursion on both sides.** `expr op expr` groups to the right
  (see [Left recursion](#left-recursion)); write `expr op term` for
  left-associative operators.
- **Changing rules after parsing.** `Grammar.parse` reuses one
  instance per class, so each rule is built once. Defining a rule or
  changing a setting on a class resets that class's instance, but a
  subclass that has already parsed keeps its own: it won't see a rule
  redefined later on its parent. Define rules before parsing, or call
  `Subclass.new.parse(input)` to get a fresh instance.

## Not yet

- Left recursion through cycles with no rule in common (see
  [Left recursion](#left-recursion)); give them a rule in common, or
  use `infix`.
- Railroad diagrams from `to_ast`

## Development

```sh
bin/setup           # install dependencies
bundle exec rake    # tests + rubocop
bundle exec rake spinel   # generated parsers compiled by Spinel vs the interpreter
                          # (SPINEL=/path/to/spinel; skipped if not found)
ruby examples/calc.rb
ruby examples/leftcalc.rb
ruby examples/json.rb
ruby examples/email.rb
ruby examples/toml.rb
ruby examples/query.rb
ruby bench/json.rb  # vs JSON.parse, Parslet, Treetop, Citrus (installs them);
                    # also to_ruby, and its Spinel binary if Spinel is found
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).

## The name

Birman is named for Alexander Birman, whose 1970 Ph.D. thesis, *The
TMG Recognition Schema*, was the origin of packrat parsing and parsing
expression grammars.

The cat in the logo is a Birman too.
