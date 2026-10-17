# frozen_string_literal: true

require "test_helper"
require_relative "../examples/calc"

class BirmanTest < Minitest::Test
  # Build a one-off grammar from a block of rules.
  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace
      self.root(root)
      class_eval(&rules)
    end
  end

  # --- Matchers ---

  def test_sequence_choice_and_repetition
    g = grammar { rule(:top) { (str("a") | str("b")).rep(1) >> str("!") } }
    assert_equal [%w[a b a], "!"], g.parse!("aba!")
    assert g.parse("!").failure?
  end

  def test_maybe_and_lookahead
    g = grammar { rule(:top) { str("-").maybe >> match(/\d+/) >> eof } }
    assert_equal ["-", "5", nil], g.parse!("-5")
    assert_equal [nil, "5", nil], g.parse!("5")
  end

  def test_conjunction_requires_both
    g = grammar { rule(:top) { match(/\w+/).present & match(/[a-z]+/) } }
    assert_equal "abc", g.parse!("abc")
    assert g.parse("!!").failure?
  end

  def test_matchers_are_immutable_data
    m = Birman::Str.new("x") >> "y"
    assert m.frozen?
    assert_equal m, Birman::Str.new("x") >> "y"
  end

  # --- Results ---

  def test_success_and_failure_pattern_match
    g = grammar { rule(:top) { str("hi") } }

    assert_pattern { g.parse("hi") => Birman::Success(value: "hi") }
    assert_pattern { g.parse("ho") => Birman::Failure(pos: 0, committed: false) }
  end

  def test_parse_bang_raises_with_formatted_message
    g = grammar { rule(:top) { str("hi") } }
    error = assert_raises(Birman::ParseError) { g.parse!("ho") }
    assert_match(/line 1, column 1: expected "hi", found "h"/, error.message)
    assert_kind_of Birman::Failure, error.failure
  end

  def test_custom_error_formatter
    g = grammar { rule(:top) { str("hi") } }
    shouty = ->(f) { "NOPE AT #{f.pos}: #{f.expected.join}" }
    assert_equal 'NOPE AT 0: "hi"', g.parse("x").message(shouty)
  end

  def test_trailing_input_is_an_error
    g = grammar { rule(:top) { str("a") } }
    assert_pattern { g.parse("ab") => Birman::Failure(pos: 1, expected: ["end of input"]) }
  end

  def test_extended_patterns_with_trailing_comments
    g = grammar { rule(:top) { match(/a # the letter a/x) } }
    assert_equal "a", g.parse!("a")
  end

  def test_patterns_see_text_before_the_current_position
    g = grammar { rule(:top) { str("a") >> match(/(?<=a)b/) } }
    assert_equal %w[a b], g.parse!("ab")

    g = grammar { rule(:top) { str("a") >> match(/^b/) } }
    assert g.parse("ab").failure?, "^ means start of line, not current position"
    assert_equal ["a\n", "b"], (grammar { rule(:top) { str("a\n") >> match(/^b/) } }).parse!("a\nb")
  end

  def test_non_ascii_input
    g = grammar { rule(:top) { seq(match(/\p{L}+/), " ", match(/\p{L}+/)) } }
    assert_equal ["héllo", " ", "wörld"], g.parse!("héllo wörld")

    g = grammar { rule(:top) { seq("é", "x") } }
    failure = g.parse("éy")
    assert_equal [1, 1, 2, '"y"'], [failure.pos, failure.line, failure.column, failure.found]
  end

  # --- Commit ---

  def test_commit_reports_the_error_inside_the_construct
    g = grammar do
      rule(:top)   { if_stmt | other }
      rule(:if_stmt) { (token(keyword("if")) > token(match(/\d+/).label("condition"))) }
      rule(:other) { match(/.*/) }
    end

    failure = g.parse("if oops")
    assert failure.committed
    assert_equal 3, failure.pos
    assert_equal ["condition"], failure.expected
  end

  def test_without_commit_choice_backtracks
    g = grammar do
      rule(:top)     { if_stmt | other }
      rule(:if_stmt) { token(keyword("if")) >> token(match(/\d+/)) }
      rule(:other)   { match(/.*/) }
    end

    assert_equal "if oops", g.parse!("if oops")
  end

  def test_a_successful_lookahead_leaves_no_errors_behind
    g = grammar { rule(:top) { str("a").rep.present >> str("b") } }
    assert_pattern { g.parse("aaac") => Birman::Failure(pos: 0, expected: ['"b"']) }

    g = grammar { rule(:top) { (str("a").rep & any) >> str("b") } }
    assert_pattern { g.parse("aaac") => Birman::Failure(pos: 1, expected: ['"b"']) }
  end

  def test_a_failed_lookahead_reports_at_its_own_position
    g = grammar { rule(:top) { str("x").present >> any } }
    assert_pattern { g.parse("y") => Birman::Failure(pos: 0, expected: ['"x"']) }

    g = grammar { rule(:top) { (str("a") >> str("b")) & any } }
    assert_pattern { g.parse("ac") => Birman::Failure(pos: 0, expected: ['"a" "b"']) }
  end

  def test_lookaheads_contain_commit_failures
    g = grammar { rule(:top) { (str("a") > str("b")).absent >> match(/.*/) } }
    assert_equal [nil, "ax"], g.parse!("ax")

    g = grammar { rule(:top) { (str("a") > str("b")).present >> match(/.*/) } }
    refute g.parse("ax").committed

    g = grammar { rule(:top) { (str("a") > str("b")) & match(/.*/) } }
    refute g.parse("ax").committed
  end

  def test_maybe_and_rep_keep_committing
    g = grammar { rule(:top) { (str("a") > str("b")).maybe >> str("ac") } }
    assert_pattern { g.parse("ac") => Birman::Failure(pos: 1, committed: true) }

    g = grammar { rule(:top) { (str("a") > str("b")).rep >> str("ac") } }
    assert_pattern { g.parse("abac") => Birman::Failure(pos: 3, committed: true) }
  end

  def test_commit_failure_on_a_silent_part_still_says_what_was_expected
    g = grammar { rule(:top) { str("a") > str("b").quiet } }
    assert_pattern { g.parse("ax") => Birman::Failure(pos: 1, expected: ['"b"'], committed: true) }

    g = grammar { rule(:top) { str("ab") > str("c").absent } }
    assert_pattern { g.parse("abc") => Birman::Failure(pos: 2, expected: ['!"c"'], committed: true) }
  end

  def test_commit_cannot_come_first
    g = grammar { rule(:top) { seq(commit, "a") } }
    error = assert_raises(ArgumentError) { g.parse("a") }
    assert_match(/commit/, error.message)
  end

  def test_commit_values_are_flat
    g = grammar { rule(:top) { str("a") > str("b") >> str("c") } }
    assert_equal %w[a b c], g.parse!("abc")
  end

  # --- Labels and quiet ---

  def test_label_replaces_low_level_expectations
    g = grammar { rule(:top) { (match(/\d+/) | match(/[a-z]+/)).label("value") } }
    assert_equal ["value"], g.parse("!").expected
  end

  def test_label_keeps_deeper_errors
    g = grammar { rule(:top) { (str("(") >> str(")")).label("group") } }
    assert_pattern { g.parse("(x") => Birman::Failure(pos: 1, expected: ['")"']) }
  end

  def test_quiet_hides_whitespace_from_errors
    g = grammar { rule(:top) { token("a") >> str("b") } }
    assert_equal ['"b"'], g.parse("a  x").expected
  end

  # --- Combinators ---

  def test_keyword_needs_a_word_boundary
    g = grammar { rule(:top) { keyword("if") >> match(/.*/) } }
    assert_equal ["if", " x"], g.parse!("if x")
    assert_equal ['"if"'], g.parse("iffy").expected
  end

  def test_sep_by
    g = grammar { rule(:top) { sep_by(match(/\d+/), token(",")) } }
    assert_equal %w[1 2 3], g.parse!("1, 2,3")
    assert_equal [], g.parse!("")
  end

  def test_between_and_one_of
    g = grammar { rule(:top) { between("[", "]", one_of("x", "y")) } }
    assert_equal "y", g.parse!("[y]")
  end

  def test_helpers_keep_sequence_items_whole
    g = grammar { rule(:top) { sep_by(str("a") >> str("b"), ",") } }
    assert_equal [%w[a b], %w[a b]], g.parse!("ab,ab")

    g = grammar { rule(:top) { between(str("<") >> str("["), "]", match(/\d/)) } }
    assert_equal "1", g.parse!("<[1]")

    g = grammar { rule(:top) { token(str("a") >> str("b")) } }
    assert_equal %w[a b], g.parse!("ab ")
  end

  def test_helpers_pass_named_items_through
    g = grammar { rule(:top) { sep_by(match(/\d/).as(:n), ",") } }
    assert_equal %w[1 2], g.parse!("1,2")

    g = grammar { rule(:top) { between("(", ")", match(/\d/).as(:n)) } }
    assert_equal "1", g.parse!("(1)")

    g = grammar { rule(:top) { token(str("a").as(:k)) } }
    assert_equal "a", g.parse!("a ")
  end

  def test_names_inside_helpers_reach_the_enclosing_seq
    g = grammar { rule(:top) { seq("f", parens(match(/\d/).as(:arg))) } }
    assert_equal({ arg: "1" }, g.parse!("f(1)"))

    g = grammar { rule(:top) { seq("[", sep_by(match(/\d/).as(:items), ","), "]") } }
    assert_equal({ items: %w[1 2] }, g.parse!("[1,2]"))
  end

  # --- Recursion limits ---

  def test_deep_nesting_is_a_failure_not_a_crash
    g = grammar { rule(:top) { either(parens(top), "x") } }
    failure = g.parse("#{"(" * 20_000}x#{")" * 20_000}")
    assert failure.failure?
    assert_match(/nested too deeply/, failure.message)
    assert_operator failure.pos, :>, 0
  end

  def test_left_recursion_is_reported_by_rule_name
    g = grammar do
      rule(:top) { either(seq(top, "+", "1"), "1") }
    end
    error = assert_raises(ArgumentError) { g.parse("1+1") }
    assert_match(/left recursion.*:top/, error.message)

    g = grammar do
      rule(:top) { seq(other, "!") }
      rule(:other) { either(top, "x") }
    end
    assert_raises(ArgumentError) { g.parse("x!") }
  end

  def test_a_rule_retried_after_a_contained_commit_is_not_left_recursion
    g = grammar do
      rule(:top) { committing.absent >> committing.maybe >> str("ac") }
      rule(:committing) { str("a") > str("b") }
    end
    assert g.parse("ac").committed
  end

  # --- Rule modules ---

  def test_rule_modules_compose_and_override
    loud = Module.new do
      extend Birman::RuleSet
      rule(:greeting) { str("HELLO") }
    end

    base = grammar { rule(:top) { greeting }; rule(:greeting) { str("hello") } }
    shouty = Class.new(base) { include loud }

    assert_equal "hello", base.parse!("hello")
    assert_equal "HELLO", shouty.parse!("HELLO"), "module rule overrides the inherited one"
    assert shouty.parse("hello").failure?
  end

  def test_included_module_supplies_rules
    g = Class.new do
      include Birman::Grammar
      include Birman::Rules::Numbers
      root :number
    end
    assert_equal 42, g.parse!("42")
    assert_in_delta 4.5, g.parse!("4.5")
  end

  def test_comments_override_whitespace
    g = Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace
      include Birman::Rules::Comments
      root :top
      rule(:top) { token("a").rep }
    end
    assert_equal %w[a a], g.parse!("a # first\n a # second")
  end

  def test_strings_with_escapes_and_unterminated_error
    g = Class.new do
      include Birman::Grammar
      include Birman::Rules::Strings
      root :string
    end

    assert_equal "tab\there \"quoted\"", g.parse!(%q("tab\there \"quoted\""))
    failure = g.parse(%("open))
    assert failure.committed
    assert_includes failure.expected, "closing quote"
  end

  def test_identifiers_reject_keywords
    g = Class.new do
      include Birman::Grammar
      include Birman::Rules::Identifiers
      root :identifier
      keywords "if"
    end

    assert_equal "iffy", g.parse!("iffy")
    assert_equal ["identifier"], g.parse("if").expected
  end

  # --- AST and EBNF ---

  def test_to_ast_lists_reachable_rules_in_order
    g = grammar do
      rule(:top)    { item.rep }
      rule(:item)   { str("x") | unused_by_top }
      rule(:unused_by_top) { str("y") }
      rule(:orphan) { str("z") }
    end

    assert_equal %i[top item unused_by_top], g.to_ast.keys
    assert_equal [:rep, 0, nil, [:ref, :item]], g.to_ast[:top]
  end

  def test_ebnf
    g = grammar do
      rule(:top)  { (str("let") > name >> str("=").maybe) | name.rep(1) }
      rule(:name) { match(/[a-z]+/).absent.absent }
    end

    assert_equal <<~EBNF.chomp, g.to_ebnf
      top  = "let" ~ name "="? / name+ ;
      name = !(!/[a-z]+/) ;
    EBNF
  end

  # --- Nodes ---

  Pair = Birman.node(:left, :right)
  Leaf = Birman.node(:value)

  def test_node_is_data_with_sexp_inspect
    pair = Pair.new(Leaf.new(1), Leaf.new("x"))
    assert_kind_of Data, pair
    assert pair.frozen?
    assert_equal '(Pair (Leaf 1) (Leaf "x"))', pair.inspect
    assert_pattern { pair => Pair(Leaf(1), Leaf("x")) }
  end

  def test_spans_count_characters_in_non_ascii_input
    g = grammar do
      const_set(:Word, node(:text))
      rule(:top) { seq(match(/\p{L}+\n?/), match(/\p{L}+/).to(self.class::Word)).map(&:last) }
    end

    span = g.parse!("héllo\nwörld").span
    assert_equal ["wörld", 6, 11, 2, 1], [span.text, span.from, span.to, span.line, span.column]
  end

  def test_spans_stop_before_ignored_comments
    let, = Calc::Grammar.parse!("let a = 1   # one\nprint a")
    assert_equal "let a = 1", let.span.text
    assert_equal "1", let.value.span.text

    sum, = Calc::Grammar.parse!("1 + 2 # three\n")
    assert_equal "1 + 2", sum.span.text
  end

  def test_span_is_ignored_by_equality_and_kept_by_with
    span = Birman::Span.new("abc", 1, 2)
    leaf = Leaf.new(value: 1, span:)
    assert_equal Leaf.new(1), leaf
    assert_equal span, leaf.with(value: 2).span
    assert_equal "line 1, column 2", span.to_s
  end

  def test_nodes_module_defines_nodes_in_place
    mod = Module.new do
      extend Birman::Nodes
      const_set(:Thing, node(:a, :b) { def sum = a + b })
    end
    assert_equal 3, mod::Thing.new(1, 2).sum
  end

  def test_nodes_with_their_own_initialize_still_get_spans
    g = Class.new do
      include Birman::Grammar
      const_set(:Pair, node(:left, :right) { def initialize(left:, right: "none") = super })
      root :top
      rule(:top) { match(/\w+/).as(:left).to(self.class::Pair) }
    end

    pair = g.parse!("abc")
    assert_equal g::Pair.new(left: "abc"), pair
    assert_equal "none", pair.right
    assert_equal "abc", pair.span.text
    assert_equal "abc", pair.with(right: "x").span.text
  end

  def test_span_is_not_a_field_name
    error = assert_raises(ArgumentError) { Birman.node(:span) }
    assert_match(/span/, error.message)
  end

  def test_grammars_define_nodes_without_extending_nodes
    g = Class.new do
      include Birman::Grammar
      const_set(:Num, node(:value))
      root :top
      rule(:top) { match(/\d+/).map(&:to_i).as(:value).to(self.class::Num) }
    end
    assert_equal g::Num.new(42), g.parse!("42")
  end

  # --- Captures and readable combinators ---

  def test_named_parts_make_a_hash
    g = grammar { rule(:top) { seq("[", match(/\d+/).as(:n), ",", match(/\d+/).as(:m), "]") } }
    assert_equal({ n: "1", m: "2" }, g.parse!("[1,2]"))
  end

  def test_as_sees_through_labels
    g = grammar { rule(:top) { seq(match(/\d+/).as(:n).label("number"), "!") } }
    assert_equal({ n: "7" }, g.parse!("7!"))
  end

  def test_as_survives_maybe_rep_and_map
    g = grammar { rule(:top) { seq(match(/\d/).as(:a), match(/x/).as(:b).maybe) } }
    assert_equal({ a: "1", b: "x" }, g.parse!("1x"))
    assert_equal({ a: "1", b: nil }, g.parse!("1"))

    g = grammar { rule(:top) { seq(match(/\d/).as(:a), match(/x/).as(:xs).rep) } }
    assert_equal({ a: "1", xs: %w[x x] }, g.parse!("1xx"))

    g = grammar { rule(:top) { seq(match(/\d/).as(:a).map(&:to_i), "!") } }
    assert_equal({ a: 1 }, g.parse!("1!"))
  end

  def test_to_builds_nodes_with_spans
    g = grammar do
      ignore :spacing
      rule(:top) { seq("pair", commit, leaf.as(:left), leaf.as(:right)).to(Pair) }
      lexeme(:leaf) { match(/\d+/).map(&:to_i).to(Leaf) }
    end

    pair = g.parse!("  pair 1   22  ")
    assert_equal Pair.new(Leaf.new(1), Leaf.new(22)), pair
    assert_equal "pair 1   22", pair.span.text
    assert_equal [1, 3], [pair.span.line, pair.span.column]
    assert_equal "22", pair.right.span.text
  end

  def test_seq_commit_and_either
    g = grammar do
      ignore :spacing
      rule(:top) { either(seq("go", commit, match(/\d+/)), "stop") }
    end

    assert_equal ["go", "5"], g.parse!("go 5")
    assert_equal "stop", g.parse!("stop")
    assert g.parse("go x").committed
  end

  def test_ignore_handles_literals_and_leading_whitespace_but_not_raw_str
    g = grammar do
      ignore :spacing
      rule(:top) { seq("a", "=", str("b"), "c") }
    end

    assert_equal %w[a = b c], g.parse!("  a = bc ")
    assert g.parse("a = b c").failure?, "str() is raw, so no whitespace after it"
  end

  def test_word_literals_are_keywords
    g = grammar { rule(:top) { seq("if", match(/\w+/)) } }
    assert g.parse("ifx").failure?
  end

  def test_lexemes_ignore_trailing_spacing
    g = Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace
      include Birman::Rules::Numbers
      root :top
      ignore :spacing
      rule(:top) { number.rep }
    end
    assert_equal [1, 2.5, 3], g.parse!(" 1  2.5\n3 ")
  end

  def test_infix_is_left_associative_with_spans
    g = grammar do
      ignore :spacing
      rule(:top) { infix(leaf, "-", node: Calc::Grammar::BinOp) }
      lexeme(:leaf) { match(/\d+/).map(&:to_i).to(Leaf) }
    end

    tree = g.parse!("10 - 4 - 3")
    assert_pattern { tree => Calc::Grammar::BinOp("-", Calc::Grammar::BinOp("-", Leaf(10), Leaf(4)), Leaf(3)) }
    assert_equal "10 - 4 - 3", tree.span.text
    assert_equal "10 - 4", tree.left.span.text
  end

  def test_infix_builds_nodes_by_field_name
    reordered = Birman.node(:left, :op, :right)
    g = grammar { rule(:top) { infix(match(/\d/), "+", node: reordered) } }
    tree = g.parse!("1+2")
    assert_equal ["1", "+", "2"], [tree.left, tree.op, tree.right]
  end

  def test_infix_rejects_nodes_without_op_left_right
    wrong = Birman.node(:a, :b, :c)
    g = grammar { rule(:top) { infix(match(/\d/), "+", node: wrong) } }
    assert_raises(ArgumentError) { g.parse("1+2") }
  end

  def test_parens
    g = grammar do
      ignore :spacing
      rule(:top) { parens(digits) }
      lexeme(:digits) { match(/\d+/) }
    end
    assert_equal "4", g.parse!("( 4 )")
    assert_equal ['")"'], g.parse("(4").expected
  end

  def test_rule_names_cannot_replace_methods_birman_relies_on
    %i[send class match str keywords token].each do |name|
      error = assert_raises(ArgumentError) { grammar { rule(name) { str("x") } } }
      assert_match(/rule :#{name} would replace/, error.message)
    end
  end

  def test_rule_names_can_reuse_private_kernel_methods_and_redefine_rules
    g = grammar do
      rule(:top)   { print }
      rule(:print) { str("a") }
      rule(:print) { str("b") }
    end
    assert_equal "b", g.parse!("b")
  end

  def test_grammar_can_be_shared_through_modules
    digits = Module.new do
      include Birman::Grammar
      rule(:digit) { match(/\d/) }
    end
    numbers = Module.new do
      include digits
      rule(:number) { digit.rep(1).map(&:join) }
    end
    g = Class.new do
      include numbers
      root :top
      rule(:top) { sep_by(number, ",") }
    end
    assert_equal %w[12 3], g.parse!("12,3")
  end

  def test_settings_are_inherited
    base = grammar do
      ignore :spacing
      keywords "a", "b"
      rule(:top) { str("x") }
    end
    child = Class.new(base)
    assert_equal [:top, :spacing, %w[a b]], [child.root, child.ignore, child.keywords]
  end

  def test_ebnf_shows_literals_plainly
    g = grammar do
      ignore :spacing
      rule(:top) { seq("let", commit, match(/\w+/).as(:name), "=", match(/\d+/)) }
    end
    assert_equal 'top     = "let" ~ /\w+/ "=" /\d+/ ;', g.to_ebnf.lines.first.chomp
  end

  # --- The example language, end to end ---

  def run_calc(source)
    out = StringIO.new
    statements = Calc::Grammar.parse!(source)
    Calc::Interpreter.new(out:).run(statements)
    out.string
  end

  def test_calc_program
    assert_equal "7\n3\nyes\n", run_calc(<<~CALC)
      let x = 1 + 2 * 3   # precedence
      print x
      print 10 - 4 - 3    # left-associative
      print if x - 7 then "no" else "yes"
    CALC
  end

  def test_calc_builds_a_data_ast
    assert_pattern do
      Calc::Grammar.parse!("let a = 1 + 2") =>
        [Calc::Grammar::Let(name: :a, value: Calc::Grammar::BinOp("+", Calc::Grammar::Num(1), Calc::Grammar::Num(2)))]
    end
  end

  def test_calc_runtime_errors_have_locations
    statements = Calc::Grammar.parse!("let a = 1\nprint a + b")
    error = assert_raises(Calc::RuntimeError) { Calc::Interpreter.new(out: StringIO.new).run(statements) }
    assert_equal "undefined variable `b` at line 2, column 11", error.message
  end

  def test_calc_errors
    {
      "let = 4"       => "expected identifier",
      "print (1 + 2"  => 'expected operator or ")"',
      "print 1 +"     => "expected expression",
      "let if = 1"    => "expected identifier"
    }.each do |source, message|
      assert_includes Calc::Grammar.parse(source).message, message, source
    end
  end
end
