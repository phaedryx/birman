# frozen_string_literal: true

require "test_helper"
require_relative "../examples/calc"
require_relative "../examples/json"
require_relative "../examples/query"
require_relative "../examples/toml"
require_relative "../examples/email"
require_relative "support/examples"

# Left recursion is found from the grammar itself, on the first parse,
# not only when some input happens to reach it. Each cycle is grown from
# a seed at its leader, a rule every way round it passes through (see
# test_left_recursion_growth.rb); cycles with no such rule raise.
class TestLeftRecursion < Minitest::Test
  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace

      self.root(root)
      class_eval(&rules)
    end
  end

  def assert_unsupported(message, klass, input = "x")
    error = assert_raises(ArgumentError) { klass.parse(input) }
    assert_equal "left recursion through cycles with no rule in common isn't supported: #{message} " \
                 "(each rule can call the next without consuming input)", error.message
  end

  # The rules found calling themselves, which the parse grows.
  def assert_direct(klass, rules = %i[top])
    analysis = klass.new.left_recursion
    assert_equal rules.map { [_1] }, analysis.cycles
    assert_equal rules.to_h { [_1, _1] }, analysis.leaders
  end

  # The cycles found, and the leader each member's cycle grows at.
  def assert_leaders(klass, leaders)
    analysis = klass.new.left_recursion
    assert_equal leaders.keys.group_by { leaders[_1] }.values.map(&:sort), analysis.cycles.map(&:sort)
    assert_equal leaders, analysis.leaders
  end

  def refute_left_recursion(klass, input = "x")
    klass.parse(input)
    assert_empty klass.new.left_recursion.cycles
  end

  def analysis(rules) = Birman::LeftRecursion.new(rules)

  # --- Found before any input reaches it ---

  def test_direct_left_recursion_parses
    g = grammar(:expr) do
      rule(:expr) { either(seq(expr, "+", num), num) }
      rule(:num) { match(/\d+/) }
    end
    assert_direct g, %i[expr]
    assert_equal [["1", "+", "2"], "+", "3"], g.parse!("1+2+3")
  end

  # With the rule's own call second, the first alternative would win
  # every round and the rule would never grow.
  def test_the_recursive_alternative_has_to_come_first
    g = grammar(:expr) do
      rule(:expr) { either(num, seq(expr, "+", num)) }
      rule(:num) { match(/\d+/) }
    end
    error = assert_raises(ArgumentError) { g.parse("1") }
    assert_match(/the alternative `num` comes before `expr "\+" num`/, error.message)
  end

  def test_indirect_left_recursion_parses
    g = grammar(:a) do
      rule(:a) { either(seq(b, "!"), "x") }
      rule(:b) { either(seq(a, "?"), "y") }
    end
    assert_leaders g, { a: :a, b: :a }
    assert_equal [["x", "?"], "!"], g.parse!("x?!")
    assert_equal [[["y", "!"], "?"], "!"], g.parse!("y!?!")
    assert_equal [["y", "!"], "?"], Class.new(g) { root :b }.parse!("y!?")
  end

  # Of the rules every way round the cycle passes through, the leader is
  # the one the grammar uses first.
  def test_the_leader_is_the_first_rule_every_cycle_passes_through
    g = grammar do
      rule(:top) { seq("(", b) }
      rule(:b) { either(seq(c, "!"), "x") }
      rule(:c) { seq(d, "?") }
      rule(:d) { b }
    end
    assert_leaders g, { b: :b, c: :b, d: :b }

    # :b calls itself too, so every cycle passes through it, not :a.
    g = grammar(:a) do
      rule(:a) { either(seq(b, "1"), "x") }
      rule(:b) { either(seq(b, "2"), seq(a, "3"), "y") }
    end
    assert_leaders g, { a: :b, b: :b }

    g = grammar do
      rule(:top) { either(seq(top, "1"), seq(b, "2"), "x") }
      rule(:b) { seq(top, "3") }
    end
    assert_leaders g, { top: :top, b: :top }
  end

  def test_every_cycle_gets_a_leader
    g = grammar do
      rule(:top) { either(seq(a, "!"), seq(b, "?"), seq(d, "#")) }
      rule(:a) { either(seq(a, "1"), "x") }
      rule(:b) { either(seq(c, "2"), "y") }
      rule(:c) { seq(b, "3") }
      rule(:d) { either(seq(e, "4"), "z") }
      rule(:e) { seq(d, "5") }
    end
    assert_leaders g, { a: :a, b: :b, c: :b, d: :d, e: :d }
  end

  # No one rule is in both :a -> :b -> :a and :c -> :d -> :c, so there is
  # nowhere to grow both from.
  def test_cycles_with_no_rule_in_common_raise
    g = grammar(:a) do
      rule(:a) { seq(b, "1") }
      rule(:b) { either(seq(a, "2"), seq(c, "3")) }
      rule(:c) { seq(d, "4") }
      rule(:d) { either(seq(c, "5"), seq(a, "6"), "x") }
    end
    assert_unsupported ":a -> :b -> :a; :c -> :d -> :c", g

    g = grammar(:a) do
      rule(:a) { either(seq(a, "1"), seq(b, "2"), "x") }
      rule(:b) { either(seq(b, "3"), seq(a, "4"), "y") }
    end
    assert_unsupported ":a -> :a; :b -> :b", g
  end

  def test_left_recursion_hidden_behind_a_nullable_prefix
    g = grammar do
      rule(:top) { either(seq(str("-").maybe, top, "!"), "x") }
    end
    assert_direct g

    g = grammar do
      rule(:top) { either(seq(str("-").rep, top, "!"), "x") }
    end
    assert_direct g
  end

  def test_left_recursion_behind_nullable_rules
    g = grammar do
      rule(:top) { either(seq(sign, top), "x") }
      rule(:sign) { either(str("-"), str("+"), seq(blank, blank)) }
      rule(:blank) { str("") }
    end
    assert_direct g
  end

  def test_left_recursion_behind_patterns_that_match_nothing
    g = grammar { rule(:top) { either(seq(match(/ */), top), "x") } }
    assert_direct g

    g = grammar { rule(:top) { either("x", seq(match(/ +/), top)) } }
    refute_left_recursion g
  end

  def test_a_pattern_that_never_matches_hides_no_left_recursion
    g = grammar { rule(:top) { either("x", seq(match(/(?=y)(?!y)/), top, "!")) } }
    refute_left_recursion g

    # never is a hook for subclasses to override.
    g = grammar do
      rule(:prefix) { never }
      rule(:top) { either(seq(prefix, top), "x") }
    end
    refute_left_recursion g
  end

  def test_a_rep_of_at_most_none_never_calls_its_inner
    g = grammar { rule(:top) { either(seq(top.rep(0, 0), "x"), "y") } }
    refute_left_recursion g, "x"
  end

  def test_left_recursion_behind_patterns_that_only_look
    [/(?=y)/, /(?!y)/, /(?<=y)/, /(?<!y)z?/, /\b/, /\B/, /\G/, /\Z/, /^/, /$/].each do |re|
      g = grammar { rule(:top) { either(seq(match(re), top, "!"), "x") } }
      assert_equal [[:top]], g.new.left_recursion.cycles, re.inspect
    end
  end

  def test_left_recursion_behind_lookaheads
    g = grammar { rule(:top) { either(seq(match(/y/).absent, top, "!"), "x") } }
    assert_direct g

    g = grammar { rule(:top) { either(seq(match(/y/).present, top, "!"), "x") } }
    assert_direct g

    g = grammar { rule(:top) { either(match(/y/) & top, "x") } }
    assert_direct g
  end

  # Inside a lookahead the rule's own call sees the seed too: a failure
  # first, then each match so far. An odd grammar; the results are
  # pinned, not designed.
  def test_a_lookahead_that_reenters_its_rule
    g = grammar { rule(:top) { either(top.absent >> str("x"), str("y")) } }
    assert_direct g
    assert_equal [nil, "x"], g.parse!("x")
    assert_equal "y", g.parse!("y")
    assert g.parse("xx").failure?
  end

  def test_left_recursion_through_wrappers
    node = Birman.node(:value)
    wrappers = {
      label: ->(m) { m.label("thing") },
      quiet: lambda(&:quiet),
      map: ->(m) { m.map(&:to_s) },
      send: ->(m) { m.map(:to_s) },
      means: ->(m) { m.means(1) },
      action: ->(m) { m.action(:itself) },
      check: ->(m) { m.check(:itself, "thing") },
      as: ->(m) { m.as(:x) },
      to: ->(m) { m.to(node) }
    }
    wrappers.each do |name, wrap|
      g = grammar { rule(:top) { either(seq(wrap.call(top), "!"), "x") } }
      assert_equal [[:top]], g.new.left_recursion.cycles, "through #{name}"
      assert g.parse("x!!").success?, "through #{name}" unless %i[action check].include?(name)
    end
  end

  def test_left_recursion_through_combinators
    g = grammar { rule(:top) { either(sep_by(top, ","), "x") } }
    assert_direct g

    g = grammar { rule(:top) { either(seq(top, commit, "!"), "x") } }
    assert_direct g

    g = grammar { rule(:top) { either(top > "!", "x") } }
    assert_direct g
  end

  # A lexeme runs the ignore rule where its token ends: where it began,
  # if the token was empty.
  def test_left_recursion_through_the_ignore_rule_after_an_empty_token
    g = grammar do
      ignore :sp
      rule(:top) { seq("", "x") }
      rule(:sp) { either(seq(top, "!"), match(/ */)) }
    end
    assert_leaders g, { top: :top, sp: :top }
    assert g.parse(" x").success?

    g = grammar do
      ignore :sp
      rule(:top) { seq(sign, "x") }
      lexeme(:sign) { match(/-?/) }
      rule(:sp) { either(seq(top, "!"), match(/ */)) }
    end
    assert_leaders g, { top: :top, sign: :top, sp: :top }
    assert g.parse("- x").success?
  end

  def test_tokens_that_consume_run_the_ignore_rule_after_input
    g = grammar do
      ignore :sp
      rule(:top) { seq("x", num) }
      lexeme(:num) { match(/\d+/) }
      rule(:sp) { either(seq(top, "!"), match(/ */)) }
    end
    refute_left_recursion g, "x1"
  end

  def test_the_ignore_rule_is_checked
    g = grammar do
      ignore :spacing
      rule(:top) { "x" }
      rule(:spacing) { either(seq(spacing, "#"), match(/\s*/)) }
    end
    assert_direct g, %i[spacing]
    assert g.parse(" #x").success?
  end

  def test_rules_nothing_reaches_are_not_checked
    g = grammar do
      rule(:top) { "x" }
      rule(:unused) { seq(unused, "x") }
    end
    refute_left_recursion g
  end

  def test_fixing_the_rule_lets_the_grammar_parse
    g = grammar do
      rule(:top) { either("x", seq(b, "!")) }
      rule(:b) { top }
    end
    assert_raises(ArgumentError) { g.parse("x") }
    assert_raises(ArgumentError, "the check isn't skipped on a later parse") { g.parse("x") }

    g.rule(:top) { either(seq("x", "!", top), "x") }
    assert g.parse("x!x").success?
  end

  def test_each_instance_is_checked
    g = grammar do
      rule(:top) { either("x", seq(b, "!")) }
      rule(:b) { top }
    end
    assert_raises(ArgumentError) { g.new.parse("x") }
    assert_raises(ArgumentError) { g.new.parse("x") }
  end

  def test_the_analysis_runs_once_per_instance
    g = grammar { rule(:top) { either(seq("x", "!", top), "x") } }.new
    g.parse("x")
    analysis = g.instance_variable_get(:@left_recursion)
    g.parse("x!x")
    assert_same analysis, g.instance_variable_get(:@left_recursion)
  end

  # The check's helpers are named so they don't take common rule names.
  def test_rules_can_be_named_like_what_a_check_would_do
    g = grammar do
      rule(:top) { seq(match_all, analyzable_asts, reachable_asts) }
      rule(:match_all) { str("a") }
      rule(:analyzable_asts) { str("b") }
      rule(:reachable_asts) { str("c") }
    end
    assert_equal %w[a b c], g.parse!("abc")

    error = assert_raises(ArgumentError) { grammar { rule(:left_recursion) { str("x") } } }
    assert_match(/would replace Birman::Grammar#left_recursion/, error.message)
  end

  def test_no_root_rule_is_still_reported
    g = Class.new { include Birman::Grammar }
    error = assert_raises(ArgumentError) { g.parse("x") }
    assert_match(/has no root rule/, error.message)
  end

  # --- Left-recursive rules that could never grow ---

  def assert_left_recursion_error(message, klass)
    ["x", "1", ""].each do |input|
      error = assert_raises(ArgumentError, input.inspect) { klass.parse(input) }
      assert_equal message, error.message
    end
    error = assert_raises(ArgumentError) { klass.to_ruby(namespace: "X") }
    assert_equal message, error.message
  end

  def test_a_left_recursive_rule_with_no_base_case
    message = "left-recursive rule :top has no alternative that doesn't start with :top, so it can never " \
              "match; add one that doesn't, as a base case"
    node = Birman.node(:op, :left, :right)
    [
      grammar { rule(:top) { seq(top, "-", match(/\d/)) } },
      grammar { rule(:top) { infix(top, "+", node:) } },
      grammar { rule(:top) { either(seq(top, "-"), seq(top, "+").label("sum")) } },
      grammar { rule(:top) { top.present & str("x") } },
      grammar { rule(:top) { seq(str("~").maybe, top, "!").to(Birman.node(:value)) } }
    ].each { assert_left_recursion_error message, _1 }
  end

  # A base case can start with something that matches nothing, or call
  # the rule after consuming input.
  def test_base_cases_that_do_not_start_with_the_rule
    [
      grammar { rule(:top) { either(seq(top, "-"), seq(str("~").maybe, "x")) } },
      grammar { rule(:top) { either(seq(top, "-"), seq("(", top, ")")) } },
      grammar { rule(:top) { either(seq(top, "-"), top.rep(0, 1) >> "x") } },
      grammar { rule(:top) { either(top.absent >> str("x"), str("y")) } }
    ].each { assert_direct _1 }
  end

  def test_an_alternative_before_the_recursive_one_shadows_it
    g = grammar do
      rule(:top) { either(parens(top), seq(top, "-", num), num) }
      rule(:num) { match(/\d/) }
    end
    assert_left_recursion_error "in left-recursive rule :top, the alternative `\"(\" top \")\"` comes before " \
                                "`top \"-\" num`, so the rule can never grow past it; put the alternatives that " \
                                "start with :top first", g

    g = grammar do
      rule(:top) { either(num, seq(top, "+", num)).to(Birman.node(:value)).quiet }
      rule(:num) { match(/\d/) }
    end
    assert_left_recursion_error "in left-recursive rule :top, the alternative `num` comes before " \
                                "`top \"+\" num`, so the rule can never grow past it; put the alternatives that " \
                                "start with :top first", g
  end

  def test_the_recursive_alternatives_first_is_fine
    g = grammar do
      rule(:top) { either(seq(top, "-", num), seq(top, "+", num), parens(top), num) }
      rule(:num) { match(/\d/) }
    end
    assert_direct g
    assert_equal [["1", "-", "2"], "+", "3"], g.parse!("(1)-2+3")

    assert_direct Examples::LeftCalc::Grammar, %i[sum product]

    # Only the rule's own choice: one nested inside a seq isn't checked.
    g = grammar do
      rule(:top) { either(seq(top, either("-", seq("x", top)), num), num) }
      rule(:num) { match(/\d/) }
    end
    assert_direct g
  end

  def test_a_cycle_with_no_base_case
    message = "left-recursive rules :x -> :expr -> :x have no alternative that doesn't start with one of " \
              "them, so they can never match; add one that doesn't, as a base case"
    [
      grammar(:x) do
        rule(:x) { expr }
        rule(:expr) { seq(x, "-", match(/\d/)) }
      end,
      grammar(:x) do
        rule(:x) { either(seq(x, "+"), expr) }
        rule(:expr) { either(seq(x, "-"), seq(x, "*").label("product")) }
      end
    ].each { assert_left_recursion_error message, _1 }

    # One base case anywhere round the cycle is enough.
    g = grammar(:x) do
      rule(:x) { expr }
      rule(:expr) { either(seq(x, "-", term), term) }
      rule(:term) { match(/\d/) }
    end
    assert_leaders g, { x: :x, expr: :x }
  end

  # Any rule of the cycle counts as the rule itself: an alternative that
  # starts with none of them can't come before one that does.
  def test_an_alternative_before_one_that_calls_the_cycle_shadows_it
    g = grammar(:x) do
      rule(:x) { expr }
      rule(:expr) { either(num, seq(x, "-", num)) }
      rule(:num) { match(/\d/) }
    end
    assert_left_recursion_error "in left-recursive rule :expr, the alternative `num` comes before " \
                                "`x \"-\" num`, so the rule can never grow past it; put the alternatives that " \
                                "start with :x or :expr first", g

    g = grammar(:x) do
      rule(:x) { either(num, seq(x, "+", num), seq(expr, "*", num)).quiet }
      rule(:expr) { either(seq(x, "-", num), num) }
      rule(:num) { match(/\d/) }
    end
    assert_left_recursion_error "in left-recursive rule :x, the alternative `num` comes before " \
                                "`x \"+\" num`, so the rule can never grow past it; put the alternatives that " \
                                "start with :x or :expr first", g
  end

  # --- Not left recursion ---

  def test_right_recursion_and_recursion_after_input_are_fine
    g = grammar { rule(:top) { either(seq("x", top), "x") } }
    refute_left_recursion g, "xxx"

    g = grammar(:expr) do
      rule(:expr) { either(parens(expr), match(/\d+/)) }
    end
    refute_left_recursion g, "((1))"
  end

  def test_a_literal_is_not_nullable_even_with_ignore_after_it
    g = grammar do
      ignore :spacing
      rule(:top) { either(seq("x", top), "y") }
    end
    refute_left_recursion g, "x x y"
  end

  def test_infix_on_another_rule_is_fine
    node = Birman.node(:op, :left, :right)
    g = grammar do
      rule(:top) { infix(atom, "+", node:) }
      rule(:atom) { either(match(/\d+/), parens(top)) }
    end
    refute_left_recursion g, "1+(2+3)"
  end

  def test_the_example_grammars_are_not_left_recursive
    examples = {
      Calc::Grammar => "1 + 2 * (3 - 4)", JSONExample::Grammar => '{"a": [1, true]}',
      QueryExample::Grammar => "title:cat dog", TOMLExample::Grammar => "a = 1\n[t]\nb = 'x'\n",
      EmailExample::Grammar => "a@example.com"
    }
    examples.each do |g, input|
      assert g.new.parse(input).success?, g.name
      assert_empty Birman::LeftRecursion.new(g.to_ast).cycles, g.name
    end
  end

  def test_matchers_without_an_ast_are_skipped
    custom = Data.define(:x) do
      include Birman::Matcher

      def match(_ctx, pos) = Birman::Match.new(pos + 1, x)
    end
    g = grammar { rule(:top) { seq(custom.new(1), "!") } }
    assert_equal [1, "!"], g.parse!("x!")
  end

  def test_left_recursion_hidden_by_a_custom_matcher_is_still_caught_while_parsing
    nothing = Data.define do
      include Birman::Matcher

      def match(_ctx, pos) = Birman::Match.new(pos, nil)
    end
    g = grammar { rule(:top) { either(seq(nothing.new, top, "!"), "x") } }
    error = assert_raises(ArgumentError) { g.parse("x") }
    assert_equal "left recursion in rule :top: it can reach itself without consuming input", error.message
  end

  def test_every_reachable_rule_is_built_on_the_first_parse
    g = grammar do
      rule(:top) { either("x", bad) }
      rule(:bad) { match(/x/).captures }
    end
    error = assert_raises(ArgumentError) { g.parse("x") }
    assert_match(/captures needs groups named/, error.message)
  end

  def test_an_undefined_rule_is_still_reported_only_when_reached
    g = grammar { rule(:top) { either("x", Birman::Ref.new(:missing)) } }
    assert g.parse("x").success?
    error = assert_raises(ArgumentError) { g.parse("y") }
    assert_equal "undefined rule :missing", error.message
  end

  # --- The analysis ---

  def test_nullability_of_each_node_type
    nullable = [
      [:str, ""], [:pat, "/ */"], [:pat, "/a?/i"], [:pat, "/\\A/"], [:pat, "/(?=a)/"],
      [:pat, "/(?<!a)b?/"], [:pat, "/(?=(?:a|[)]))\\b/"], [:pat, "/(?!a)*/"], [:pat, "/(?=a) # x\n/x"],
      [:seq, nil, []], [:seq, 1, [[:str, ""], [:rep, 0, nil, [:str, "a"]]]],
      [:choice, [[:str, "a"], [:str, ""]]],
      [:rep, 0, nil, [:str, "a"]], [:rep, 0, 1, [:str, "a"]], [:rep, 2, nil, [:pat, "/a*/"]],
      [:not, [:str, "a"]], [:and, [:str, "a"]], [:both, [:str, "a"], [:str, ""]],
      [:action, [:str, ""]], [:label, "x", [:str, ""]], [:check, "x", [:str, ""]], [:quiet, [:str, ""]],
      [:lexeme, [:str, ""]]
    ]
    non_nullable = [
      [:str, "a"], [:pat, "/a+/"], [:pat, "/a/x"], [:pat, "/\\/+/"],
      [:pat, "/(?=a)a/"], [:pat, "/a(?!b)/"], [:pat, "/[(?=]/"], [:pat, "/\\(?=a/"], [:pat, "/[\\]^]/"],
      [:pat, "/\\\\b/"], [:pat, "/a # (?=b) [\n/x"], [:pat, "/(?#(?=)a/"], [:pat, "/(?=(a))\\1/"],
      [:seq, nil, [[:str, ""], [:str, "a"]]], [:choice, [[:str, "a"], [:str, "b"]]], [:choice, []],
      [:rep, 1, nil, [:str, "a"]], [:both, [:str, ""], [:str, "a"]],
      [:action, [:str, "a"]], [:label, "x", [:str, "a"]], [:check, "x", [:str, "a"]], [:quiet, [:str, "a"]],
      [:lexeme, [:str, "a"]]
    ]
    a = analysis({ top: [:str, "a"] })
    nullable.each { assert a.nullable_node?(_1), "#{_1.inspect} is nullable" }
    non_nullable.each { refute a.nullable_node?(_1), "#{_1.inspect} isn't nullable" }
  end

  def test_nullability_reaches_a_fixpoint_over_rules
    a = analysis({
                   top: [:seq, nil, [%i[ref b], [:str, "x"]]],
                   b: [:choice, [[:seq, nil, [%i[ref c], [:str, "y"]]], %i[ref d]]],
                   c: [:seq, nil, [%i[ref b], [:str, "z"]]],
                   d: [:rep, 0, nil, [:str, "w"]],
                   loop: [:seq, nil, [%i[ref loop]]]
                 })
    assert a.nullable?(:b)
    assert a.nullable?(:d)
    refute a.nullable?(:c)
    refute a.nullable?(:top)
    refute a.nullable?(:loop), "a rule that only calls itself never matches, so isn't nullable"
    refute a.nullable?(:undefined)
  end

  def test_an_empty_lexeme_calls_the_ignore_rule_if_there_is_one
    rules = { top: [:seq, nil, [[:lexeme, [:str, ""]], [:lexeme, [:str, "a"]], [:lexeme, %i[ref b]]]], b: [:str, "b"] }
    assert_equal [], analysis(rules).left_calls(:top)
    assert_equal %i[sp], Birman::LeftRecursion.new(rules, ignore: :sp).left_calls(:top)

    rules = { top: [:lexeme, %i[ref b]], b: [:pat, "/b?/"] }
    assert_equal %i[b sp], Birman::LeftRecursion.new(rules, ignore: :sp).left_calls(:top)
  end

  # Assertions side by side hold at one position, so a pair that
  # contradicts there never matches; anything between them, or a
  # quantifier on one, and they may hold apart.
  def test_patterns_whose_assertions_contradict_never_match_empty
    a = analysis({ top: [:str, "a"] })
    never = ["/(?=a)(?!a)/", "/(?!a)(?=a)/", "/(?<=a)(?<!a)/", "/\\b\\B/", "/x|(?=a)^(?!a)/",
             "/(?=[ab])(?!(?=[ab]))(?![ab])/"]
    never.each do |source|
      refute a.nullable_node?([:pat, source]), source
      refute Regexp.new(source[1...-1]).match?("aa a"), "#{source} never matches anything"
    end

    maybe = ["/(?=a)(?=a)/", "/(?=a)|(?!a)/", "/(?=a)(?:)(?!a)/", "/(?=a)(?!a)?/", "/(?=a)(?!b)/",
             "/(?=a)(?<!a)/", "/(?=a)(?!(?:a))/"]
    maybe.each { assert a.nullable_node?([:pat, _1]), _1 }
  end

  # A negative lookaround of what always matches empty never holds.
  def test_negative_lookarounds_of_the_empty_match_never_hold
    a = analysis({ top: [:str, "a"] })
    ["/(?!)/", "/(?<!)/", "/(?!a*)/", "/(?!(?:))/", "/x?(?!a?)/"].each do |source|
      refute a.nullable_node?([:pat, source]), source
    end
    ["/(?!$)/", "/(?!(?=a))/", "/(?!a)/", "/(?=)/", "/(?<=)/"].each { assert a.nullable_node?([:pat, _1]), _1 }
  end

  # Taking out (?=(\w)) would make \2 name (y?), which can be empty.
  def test_backreferences_keep_naming_the_groups_they_named
    a = analysis({ top: [:str, "a"] })
    refute a.nullable_node?([:pat, "/(?=(\\w))(x)?(y?)\\2/"])
  end

  def test_left_calls_stop_after_the_first_part_that_consumes
    a = analysis({
                   top: [:seq, nil, [[:rep, 0, 1, %i[ref a]], [:not, %i[ref b]], %i[ref c], %i[ref d]]],
                   a: [:str, "a"], b: [:str, "b"], c: [:str, "c"], d: [:str, "d"]
                 })
    assert_equal %i[a b c], a.left_calls(:top)
  end

  def test_sccs_and_leaders_for_left_recursion_support
    a = analysis({
                   top: [:seq, nil, [%i[ref expr], [:str, ";"]]],
                   expr: [:choice, [[:seq, nil, [%i[ref term], [:str, "+"]]], %i[ref term]]],
                   term: [:choice, [[:seq, nil, [%i[ref expr], [:str, "-"]]], %i[ref num]]],
                   num: [:pat, "/\\d+/"],
                   self_ref: [:seq, nil, [%i[ref self_ref], [:str, "x"]]]
                 })
    assert_equal [%i[expr term], %i[self_ref]], a.cycles
    assert a.left_recursive?(:expr)
    assert a.left_recursive?(:self_ref)
    refute a.left_recursive?(:top)
    refute a.left_recursive?(:num)
    assert_equal :expr, a.leader(:term)
    assert_equal :expr, a.leader(:expr)
    assert_nil a.leader(:top)
    assert_equal({ expr: :expr, term: :expr, self_ref: :self_ref }, a.leaders)
    assert_equal %i[expr term], a.cycle(:term)
  end
end
