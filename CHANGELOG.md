## [Unreleased]

### Added

- `nocase("select")`, a literal matched in any case (Citrus's backtick
  strings): `SELECT`, `Select` and `select` all match. It's a literal
  otherwise, skipping trailing spacing, with the keyword boundary when
  word-like in ASCII (`nocase("is")` doesn't match the start of
  `island`), and usable wherever one goes
  (`one_of(nocase("asc") => :up)`). Its value is the text as written
  in the grammar, `"select"`, whatever case the input used. It folds
  as Ruby's `/i` does, and the match is as long as the input
  (`nocase("straße")` matches the seven bytes of `STRASSE`; a Spinel
  binary folds one character to one, so there it doesn't). Errors and
  `to_ebnf` show it as `"select"i`; `to_ast` has a new `[:istr, text]`
  node for it (`[:lexeme, [:istr, ""]]` when empty), nullable only
  when empty, and `to_ruby` generates it. Anything but a String raises
  `ArgumentError`.
- `parse(input, root: :rule)` starts at any rule instead of the
  grammar's root, reachable from it or not (Citrus's `root:`). That
  rule's left recursion is checked on its first parse and grown, and
  no cycle's leader depends on where the parse starts. A name that
  isn't a rule raises `ArgumentError`, `undefined rule :name`.
- `parse(input, consume: false)` succeeds when a prefix of the input
  matches (Citrus's `consume:`), and fails only if the root rule does,
  never expecting "end of input". `Birman.parse` and `Birman.parse!`
  take it too, but not `root:`.
- `Success#pos`, where the match ended, in characters, before any
  spacing ignored after its last token. It isn't a `Data` member, so
  `in Birman::Success(value)` and `==` are unchanged; a `Success` built
  by hand has none (`nil`).
- `parse(input, offset: n)` starts the parse at character `n` of the
  input (Citrus's `offset:`), past the ignored spacing there. Positions
  still count from the start of the input, `\A` matches only at 0, a
  lookbehind sees what's before the offset, and "end of input" is the
  real end. An offset outside the input raises `ArgumentError`
  (invalid input is still a `Failure` first). `parse!`, the instance
  methods, `Birman.parse` and `Birman.parse!` take it too.
- `to_ruby(roots: [...])` generates a parser whose `parse` takes
  `root:` (the grammar's root or one of `roots:`; anything else raises
  `ArgumentError`), `consume:` and `offset:`, giving the interpreter's
  results, `Success#pos` included.

### Fixed

- A generated parser's Spinel binary no longer raises `TypeError`
  ("cannot store Integer into an Array[String]") when an action, check,
  or a method they call indexes a seq's value whose parts have different
  types: `seq(int, "*", int).action(:multiply)` with
  `def multiply(parts) = parts[0] * parts[2]`. Spinel typed the
  parameter by the parts it could see and converted the Array on the
  call. Copied methods now say their parameters are untyped, in an
  inline RBS comment (`# @rbs parts: untyped`), so CRuby runs them as
  before. Methods with optional, rest, keyword or block parameters
  are left as written (Spinel ignores a signature with the first two).

## [0.3.0] - 2026-10-23

### Breaking

- **A chain of `>>` is one seq**, however it's grouped:
  `a.as(:x) >> (b.as(:y) >> c.as(:z))` gives `{x:, y:, z:}`, like
  `(a.as(:x) >> b.as(:y)) >> c.as(:z)`, and `a >> (b >> c)` gives
  `[a, b, c]`, not `[a, [b, c]]`. A seq built any other way
  (`seq(...)`, or with a `commit` or `only`) is one part on either side
  of `>>` or `>`, as in `seq(x, y)`: `seq(a, b) >> c` is `[[a, b], c]`
  rather than `[a, b, c]`, `(seq(a, commit, b) >> c) | d` backtracks
  when `c` fails instead of committing to it,
  `seq("[", only(x), "]") >> y` keeps `y`, and a stored
  `pair = seq(k.as(:k), v.as(:v))` gives `pair >> z` as `[{k:, v:}, z]`.
  Where a value changed, write the seq you mean: `seq(a, b, c)` for the
  flat one, `seq(a, commit, b, c)` to commit to `c`, or `a >> seq(b, c)`
  for `[a, [b, c]]`.
- **The first parse builds every rule reachable from the root and the
  ignore rule**, so a rule whose matcher can't be built (`.captures` on
  a pattern with no named groups, say) raises `ArgumentError` then, even
  if the input never reaches it. Fix or remove such rules. An undefined
  rule still raises only when reached.
- **`to_ast` has a `[:lexeme, inner]` node**: inner, then the ignore
  rule. Lexeme rules show as one (`lexeme(:num) { match(/\d+/) }` was
  `[:pat, "/\\d+/"]`), and so does an empty literal
  (`[:lexeme, [:str, ""]]`). Literals with text are still
  `[:str, text]`. Code that walks `to_ast` needs to handle the new node.
  `to_ebnf` is unchanged.
- **`left_recursion` can't be a rule name**: it's a method of every
  grammar now, and defining the rule raises `ArgumentError`. Rename it.

### Added

- Direct left recursion. A rule that calls itself before consuming
  input, `rule(:expr) { either(seq(expr, "-", term), term) }`, is grown
  from a seed (Warth et al., 2008), so `3-4-5` parses as `(3-4)-5`, with
  a node per level whose span covers it. Errors say what the last
  attempt needed (`1-` expects a term after the `-`), and `to_ruby`
  generates parsers that do the same. `expr op expr` groups to the
  right (`3-(4-5)`): see the README's Left recursion section. A
  left-recursive rule with no alternative that doesn't start with
  itself (it could never match), or with one before an alternative that
  does (it would never grow), raises `ArgumentError` on the first parse
  and in `to_ruby`, saying how to fix it.
- Indirect left recursion, through a cycle of rules
  (`sum -> terms -> sum`). Each cycle grows from a seed at its leader,
  as pegen does: the first rule that every way round it passes through.
  The checks above cover the whole cycle. A parse that enters a cycle
  at another rule gets a shorter match than growing from there would:
  see the README's Left recursion section.
- `examples/leftcalc.rb`: `examples/calc.rb` with its arithmetic written
  as left recursion instead of `infix`, giving the same trees.
- `Grammar.to_ruby(namespace:)` generates a standalone parser, as Ruby
  source Spinel can compile to a native binary, that agrees with
  `parse` on values, spans and errors. Differential tests check the
  README grammar, `examples/calc.rb` and `examples/json.rb` against the
  interpreter (`rake test`, and `rake spinel` for the compiled
  binaries). Actions and `.map(:name)` run even when nothing reads
  their value, as in the interpreter.
- Generated parsers support nodes whose `initialize` gives fields
  defaults, `node(:name, :args) { def initialize(name:, args: []) = super }`,
  as the README shows. Each node is built with the default for any
  field its value leaves out (named parts, captures, a single value, or
  a Hash known only at parse time), written where it's built so a `[]`
  default is a new Array for every node. The `initialize` must take
  exactly the fields as keywords, with literal defaults, and only call
  `super`; `to_ruby` refuses anything more, naming the node and what it
  does.
- Copied actions may read `Float::INFINITY` and `Float::NAN` (and
  `-Float::INFINITY`). Other constant paths are still refused.
- Matchers without a grammar class. The combinators are available on
  `Birman` (`Birman.seq`, `Birman.str`, `Birman.match`...), and
  `Birman.parse(matcher, input, ignore: nil)` and `Birman.parse!` run
  one as a whole grammar, returning `Success`/`Failure` as
  `Grammar.parse` does. `ignore:` takes a matcher, not a rule name. A
  matcher that refers to a rule, or whose `.action`/`.check` names a
  method only a grammar of your own would have, raises `ArgumentError`
  before parsing.
- `either` passes on a name all its alternatives share:
  `seq(either(a.as(:x), b.as(:x)), c.as(:y))` gives `{x:, y:}`.
  Generated parsers agree.
- `match(re).captures`: the value is a Hash of `re`'s named groups,
  `{date: "1979-05-27", time: nil}`, with Symbol keys, in order, and
  `nil` for a group that didn't match, so
  `match(MOMENT).captures.to(Moment)` needs no action re-matching the
  text. A regexp with no named groups, or a name used twice, raises
  `ArgumentError`. Generated parsers support it (reading the groups by
  number, as Spinel's scanner needs), building nodes from it directly.
- `sep_by(x, sep, trailing: true)` (and `sep_by1`) allows one separator
  after the last item, as in TOML's `[1, 2,]`. A list of none still
  can't be just a separator. After a trailing separator the item is
  still expected, so `[1, x` reports `expected value or "]"`; without
  `trailing`, `[1,]` still reports `expected value`. Generated parsers
  support it.
- `.check(:name, "label")`, a semantic predicate: the grammar's method
  `name` gets the value and returns truthy to accept it. A falsy result
  is an ordinary failure, "expected label", where the match began, so
  it backtracks (the furthest failure still wins) and commits only
  inside a committed `seq`. Generated parsers support it too.
- Ways to transform a value without a block, so a grammar can be plain
  data (groundwork for compiling grammars later):
  - `.map(:to_i)` calls that method on the value. The Symbol is kept,
    not turned into a Proc; from `.map(&:to_i)`, just delete the `&`.
  - `.action(:json_number)` passes the value to a grammar method, which
    may be private and which subclasses can override.
  - `.means(v)` replaces the value with `v`: `lit("null").means(nil)`.

  `.map { }` blocks still work.
- `Birman::Failure.at(span, reason)`, for checks made in a second pass
  over the AST: a committed `Failure` at the start of a node's span,
  whose message is the reason. The README's Checks section shows one.
- `large_integer(value, base = 0)`, for actions: `Integer`, but a
  generated parser's gives Bignums in a Spinel binary too, where
  `Integer`, `String#to_i`, `#hex` and `#oct` raise past 63 bits, or
  silently give 2**63 - 1 when Spinel can't tell the receiver's type.
  `to_ruby` refuses actions that call any of those (or `send` them by a
  computed name), and `.map(:hex)`, `.map(:oct)`, and `.map(:to_i)` on
  values that may not be Strings. `examples/json.rb` uses it for
  integers and `\u` escapes.
- `examples/email.rb`, RFC 5322 email addresses (addr-spec, with UTF-8
  and nested comments): a grammar with no ignore rule. It's checked
  against the generated parsers too.
- `examples/toml.rb`, TOML 1.0, parsing to Hashes, Times, Dates and the
  rest in two passes: the grammar reads a flat list of statements, and
  a second pass builds the Hash and rejects tables or keys defined
  twice, additions to inline tables and arrays, and dates that don't
  exist, reporting each at its node's span. It's tested against a slice
  of the official toml-test suite (`test/toml-test`), and its generated
  parser against the interpreter, Spinel binary too.
- `examples/query.rb`, a GitHub-style search query (lookahead, implicit
  AND, a custom error formatter), with an evaluator that filters
  records and a compiler to a SQL condition for ActiveRecord's `where`.

### Changed

- Left recursion is found from the grammar, not the input. A grammar
  with cycles that have no rule in common raises `ArgumentError` on its
  first parse, whatever the input, and so does `to_ruby`, naming them:
  `left recursion through cycles with no rule in common isn't
  supported: :a -> :a; :b -> :b (each rule can call the next without
  consuming input)`. Before, any left recursion raised, and only when
  some input reached it, naming one rule. Through a custom matcher with
  no `to_ast` it's still found only then, with the old message.
- Names can't be dropped silently. The same `.as` name twice in one
  `seq`, or a `seq` of named parts or a `.captures` (seen through
  `maybe`, `label`, `quiet`, `check`, `&`, `either`, `between` and
  `only`, but not `rep`, `sep_by` or a transform) inside a `seq` whose
  value would drop it, raises `ArgumentError` when the matcher is
  built. Name the inner seq with `.as`, or list its parts in the outer
  one. A rule reference still keeps its names to itself.
- `examples/toml.rb` reads `inf` and `nan` as `Float::INFINITY` and
  `Float::NAN`, and builds a local time as a `Moment` with no date (its
  `initialize` defaults `date` and `offset` to nil) rather than a
  separate `Clock` node.
- The library's own rules (`maybe`, `keyword`, `one_of`, `sep_by`,
  `Rules::Numbers`, `Rules::Strings`) and both examples no longer use
  blocks. EBNF output is unchanged; about 4% fewer allocations per JSON
  parse.
- Internal: the block matcher `Birman::Action` is now `Birman::Map`;
  `Birman::Action` is the `.action(:name)` matcher.

### Fixed

- A commit failure inside a rule, caught by `present` or a guard where
  the lookahead began, said only that the rule was expected
  (`expected r1 or "b"`), where the same failure without the commit,
  and the generated parser, said what the rule expected there
  (`expected "a", "c" or "b"`). Now it says that too.
- A lexeme (and a literal) skips the ignore rule of the grammar running
  it, as a bare string always has. Before, it kept the ignore rule of
  wherever it was built: none when built outside a grammar, another
  grammar's when reused, and a parent's old one in a subclass that had
  already parsed when the parent's `ignore` changed.
- `parse` raised `ArgumentError` on invalid UTF-8 (from the regexps).
  It's now a `Failure` at the first invalid byte, with `reason` "invalid
  UTF-8" (or "invalid US-ASCII", and so on, for input in other
  encodings), so `parse!` raises `ParseError`. The bytes before it are
  valid, so line and column point at it as usual. Generated parsers do
  the same.
- A rule reached from several alternatives at one position repeated its
  expectations on every memo hit, growing the list as 3^n (a 16-deep
  grammar took 7 seconds). Merging one in now skips expectations
  already recorded, in the interpreter and in generated parsers;
  `Failure#expected` and error messages are unchanged.
- A rule named after a private helper of one of Birman's rule modules
  (`Rules::Strings`'s `decode_escape`) silently replaced it; it now
  raises `ArgumentError`, as Grammar's and Combinators' private methods
  already did, and a test lists every private method Birman gives a
  grammar, so a new one can't slip through. The error now says why the
  name is taken: a method Birman relies on, one every Ruby object has,
  or one of the grammar's own.
- Generated parsers called the wrong method when a rule named `ref` or
  `skip` had a part named like another rule's method (rule `:ref`'s
  choice was `ref_pat`, as was rule `:pat`'s entry), and kept a rule's
  value in the same variable as a part of another rule (`:a_pat`'s and
  `:a`'s `a_pat`). Rules whose names meet in the generated parser (`:a?`
  and `:a_3f`) are refused, and copied action methods can no longer
  replace the runtime's `input` or `invalid_input`.
- A node with no fields, `Empty = node`, built with `.to` drops the
  value: `seq("(", ")").to(Empty)` gives `(Empty)` with its span.
  Before, `parse` raised `TypeError` when the value wasn't a Hash, and
  `to_ruby` refused it or, for `.means({})`, generated
  `Empty.new(, span(p, q))`, a syntax error.

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
