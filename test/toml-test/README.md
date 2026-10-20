# toml-test (a slice)

Test cases copied unchanged from the official TOML test suite,
<https://github.com/toml-lang/toml-test>, at commit
`ff49d109861c1ad25af53f687f2aef19ab650600` (2026-09-15). MIT licensed:
see `LICENSE` here, copied from that repository.

Only TOML 1.0 cases (from its `tests/files-toml-1.0.0` list), and only
about half of them: the spec's own examples, every case about tables
being defined twice or extended, and a few of each kind of value and
syntax error. The paths are toml-test's own, so adding a case is
copying its file (and, for a valid one, its `.json`) to the same place.

- `valid/**/*.toml` must parse, to the value its `.json` describes
  (toml-test's typed JSON: `{"type": "integer", "value": "42"}`).
- `invalid/**/*.toml` must not parse.

`test/test_toml_example.rb` runs them against `examples/toml.rb`. The
full 1.0 list (208 valid, 501 invalid) passed when this slice was cut.
