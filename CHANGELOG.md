## [Unreleased]

- **Added:** `Grammar.to_ruby(namespace:)` generates a standalone
  parser, as Ruby source Spinel can compile to a native binary, that
  agrees with `parse` on values, spans and errors. Differential tests
  check the README grammar, `examples/calc.rb` and `examples/json.rb`
  against the interpreter (`rake test`, and `rake spinel` for the
  compiled binaries).
- **Added:** ways to transform a value without a block, so a grammar
  can be plain data (groundwork for compiling grammars later):
  - `.map(:to_i)` calls that method on the value. The Symbol is kept,
    not turned into a Proc; from `.map(&:to_i)`, just delete the `&`.
  - `.action(:json_number)` passes the value to a grammar method,
    which may be private and which subclasses can override.
  - `.means(v)` replaces the value with `v`: `lit("null").means(nil)`.

  `.map { }` blocks still work.
- The library's own rules (`maybe`, `keyword`, `one_of`, `sep_by`,
  `Rules::Numbers`, `Rules::Strings`) and both examples no longer use
  blocks. EBNF output is unchanged; about 4% fewer allocations per
  JSON parse.
- Internal: the block matcher `Birman::Action` is now `Birman::Map`;
  `Birman::Action` is the `.action(:name)` matcher.

## [0.2.2] - 2026-10-17

- **Faster:** about 1.75x on the JSON benchmark (159 KB: 0.37s to 0.21s),
  from allocating 60% fewer objects per parse: no temporary arrays in
  failure tracking, a per-rule memo table instead of `[rule, pos]` keys,
  a plain `Match` class instead of `Data`, and literals checked in place
  instead of sliced out. No API changes.
- API documentation as TOML comment blocks in `lib/`, and a Limits
  section in the README.

## [0.2.1] - 2026-10-17

- **Fixed:** `rep` and `maybe` over something that can match empty.
  An empty first match now counts, so `match(/a*/).rep(1)` accepts `""`
  and `match(/a*/).maybe` gives `""` instead of `nil`. After real
  matches, an empty one still just ends the repetition. (A plain
  `.rep` over such a matcher now gives `[""]` on empty input, not `[]`.)
- **Fixed:** a `label` now replaces the low-level expectations when its
  matcher succeeds without consuming anything, as it already did when
  the matcher failed: `str("a").maybe.label("prefix") >> str("b")` on
  `"x"` reports `expected prefix or "b"`.

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
