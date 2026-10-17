## [Unreleased]

## [0.2.0] - 2026-10-17

- **Added:** `one_of` takes a hash mapping literals to the values they
  produce: `one_of("true" => true, "false" => false, "null" => nil)`.
- **Added:** `only(x)` inside `seq` makes that part the sequence's
  whole value; the other parts must still match but are dropped:
  `seq("[", commit, only(sep_by(value, ",")), "]")`. Its `.as` name, if
  any, passes outward. Using it twice, mixing it with other `.as`
  names, or using it outside `seq` raises `ArgumentError`.
- **Changed:** a bare string is a literal everywhere a matcher goes, not
  just inside `seq`, `either` and the other helpers. A string used as a
  rule body (`rule(:semi) { ";" }`) or after `>>`, `|`, `&` or `>` now
  skips trailing spacing and, if word-like, is a keyword. Before, it
  matched exactly those characters, so `seq(semi, "x")` failed on
  `"; x"`. Use `str("...")` for the old exact match.

## [0.1.0] - 2026-10-17

First release: a small PEG parser library for Ruby 3.2+.

- **Grammars** are classes that `include Birman::Grammar`. Rules are
  methods (`rule(:name) { ... }`), so they compose and override through
  `include`, and a module that includes `Birman::Grammar` can share
  rules between grammars. Settings: `root`, `ignore` (a rule matched and
  discarded between tokens, usually `:spacing`) and `keywords`, all
  inherited and clearable with `nil`.
- **Combinators**: `seq`, `either`, `one_of`, `maybe`, `rep`,
  `absent`/`present`, `&` guards, `sep_by`, `between`, `parens`,
  left-associative `infix`, `label`, `quiet`, `map`, plus operator forms
  (`>>`, `|`, `&`, `>`). Bare strings in `seq`/`either` are literals that
  skip trailing spacing; word-like ones are keywords.
- **Captures and nodes**: `.as(:key)` names parts of a sequence and
  `.to(Node)` builds a node from them. `node(:a, :b)` defines immutable
  `Data` AST nodes with a source `span` (line, column, text), which
  equality ignores; nodes may define their own `initialize`.
- **Commit points**: `seq("let", commit, ...)` (or `a > b`) makes a
  failure after the commit end the parse with an error at that spot.
  Lookaheads contain commits; `rep` and `maybe` don't.
- **Packrat memoization**, with failure diagnostics replayed from the
  memo so cached results report errors correctly. Linear-time matching
  on non-ASCII input (byte offsets internally, character offsets in the
  API).
- **Results**: `parse` returns `Success`/`Failure` and doesn't raise on
  bad input, including input nested too deeply for Ruby's stack;
  `parse!` raises `ParseError`. Failures carry position, expectations
  and a pluggable formatter (`Failure#message(formatter)`,
  `parse!(input, formatter:)`).
- **Grammar mistakes fail loudly**: left recursion raises naming the
  rule, as do rule names that would replace a method the grammar relies
  on (`send`, `match`, `token`, ...) and a `commit` at the start of a
  `seq`.
- **Built-in rules**: `Birman::Rules::Whitespace`, `Comments`,
  `Numbers`, `Strings` and `Identifiers`.
- **Introspection**: `Grammar.to_ast` and `Grammar.to_ebnf`.
- `examples/calc.rb`: a small language with an interpreter, as a
  complete worked example.
