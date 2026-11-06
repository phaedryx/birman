# frozen_string_literal: true

require "test_helper"
require "pp"
require_relative "support/examples"

# parse(input, trace: true): the same result, with a Trace of the
# attempts that led to it.
class TraceTest < Minitest::Test
  # The README's Lists grammar, with map(:to_i) for map(&:to_i) so
  # to_ruby can compile it.
  class Lists
    include Birman::Grammar
    include Birman::Rules::Whitespace

    ignore :spacing
    root :list
    rule(:list) { seq("[", commit, only(sep_by(item, ",")), "]") }
    rule(:item) { either(match(/\d+/).map(:to_i), list) }
  end

  # A grammar whose root is :r, with the rules the block defines.
  def grammar(&)
    Class.new do
      include Birman::Grammar

      root :r
      class_eval(&)
    end
  end

  # Every node under node, node included, depth first. A stack, since
  # traces of deep input are deep.
  def nodes_of(node)
    out = []
    stack = [node]
    while (n = stack.pop)
      out << n
      stack.concat(n.children.reverse)
    end
    out
  end

  def test_untraced_results_have_no_trace
    assert_nil Lists.parse("[1]").trace
    assert_nil Lists.parse("[x]").trace
  end

  def test_trace_is_not_a_member
    traced = Lists.parse("[1]", trace: true)
    assert_instance_of Birman::Trace, traced.trace
    assert_equal Lists.parse("[1]"), traced
    assert_equal Lists.parse("[1]").inspect, traced.inspect
    assert_pattern { traced => Birman::Success([1]) }
    assert_equal Lists.parse("[x]"), Lists.parse("[x]", trace: true)
    assert_equal Lists.parse("[x]").inspect, Lists.parse("[x]", trace: true).inspect
  end

  def test_marshal_drops_the_trace
    [Lists.parse("[1]", trace: true), Lists.parse("[x]", trace: true)].each do |result|
      copy = Marshal.load(Marshal.dump(result))
      assert_equal result, copy
      assert_nil copy.trace
    end
  end

  def test_parse_bang_failure_carries_the_trace
    error = assert_raises(Birman::ParseError) { Lists.parse!("[x]", trace: true) }
    assert_instance_of Birman::Trace, error.failure.trace
    assert_equal Lists.parse("[x]").message, error.message
    assert_equal [1], Lists.parse!("[1]", trace: true)
  end

  def test_standalone_parse_takes_trace
    m = Birman.seq("a", "b")
    assert_instance_of Birman::Trace, Birman.parse(m, "ab", trace: true).trace
    error = assert_raises(Birman::ParseError) { Birman.parse!(m, "ax", trace: true) }
    refute_nil error.failure.trace
  end

  def test_invalid_utf8_gives_a_one_node_trace
    result = Lists.parse("[1\xFF]".dup.force_encoding("UTF-8"), trace: true)
    assert_equal "invalid UTF-8", result.reason
    assert_equal :input, result.trace.root.kind
    assert_equal 2, result.trace.root.from
    assert_empty result.trace.root.children
  end

  def test_rule_calls_are_recorded
    root = Lists.parse("[1]", trace: true).trace.root
    assert_equal :parse, root.kind
    assert_equal %i[spacing list], root.children.map(&:rule) # the spacing skipped at the start comes first
    list = root.children.last
    assert_equal [:rule, :list, 0, 3], [list.kind, list.rule, list.from, list.to]
    assert(nodes_of(list).any? { _1.rule == :item && _1.from == 1 && _1.to == 2 })
  end

  def test_leftover_input_is_an_end_of_input_node
    root = Lists.parse("[1] x", trace: true).trace.root
    assert_equal [:spacing, :list, nil], root.children.map(&:rule)
    assert_equal :end_of_input, root.children.last.kind
    assert_equal([4, nil, ["end of input"]], root.children.last.then { [_1.from, _1.to, _1.expected] })
  end

  def test_generated_parser_rejects_trace
    parser = Differential.load(Lists, "TracedListsParser")
    assert_raises(ArgumentError) { parser.new("[1]").parse(trace: true) }
  end

  # The root rule's node: the top node's children are the spacing
  # skipped at the start (with an ignore rule), the root rule's call,
  # and any end of input.
  def root_rule(result) = result.trace.root.children.find { _1.kind == :rule && _1.rule != :spacing }

  def test_lists_tree_records_rules_parts_and_leaves
    list = root_rule(Lists.parse("[1, [2, x], []]", trace: true))
    assert_equal [:rule, :list, 0, nil], [list.kind, list.rule, list.from, list.to]
    # the rule's body, a seq, is folded: its parts are list's children
    assert_equal ['"["', 'sep_by(item, ",")'], list.children.map(&:description)
    assert_equal [:leaf, 0, 1], [list.children[0].kind, list.children[0].from, list.children[0].to]
    item = list.children[1].children.find { _1.rule == :item && _1.from == 4 }
    assert_equal ["/\\d+/", "list"], item.children.map(&:description) # .map(:to_i) is transparent
    assert_equal 8, item.notes[:unwound_by_commit]
    inner = item.children.last
    close = inner.children.last
    assert_equal ['"]"', 6, { pos: 8, expected: ["/\\d+/", '"["'] }],
                 [close.description, close.from, close.notes[:committed]]
    assert_equal 8, list.furthest
  end

  Pair = Birman.node(:x, :y)

  def test_transparent_wrappers_get_no_node
    g = grammar { rule(:r) { seq(match(/a/).as(:x), match(/b/).text.as(:y)).to(Pair) } }
    r = root_rule(g.parse("ab", trace: true))
    assert_equal %w[/a/ /b/], r.children.map(&:description)
  end

  def test_a_nested_choice_gets_a_node_of_its_own
    g = grammar { rule(:r) { seq("(", either("+", "-")) } }
    r = root_rule(g.parse("(-", trace: true))
    assert_equal %i[leaf choice], r.children.map(&:kind)
    assert_equal([['"+"', nil], ['"-"', 2]], r.children.last.children.map { [_1.description, _1.to] })
  end

  def test_named_parts_and_nodes_survive_instrumentation
    [Examples::Lang::Grammar, JSONExample::Grammar, TOMLExample::Grammar].each do |g|
      instance = g.new
      instance.rules.each { instance.__traced_matcher_for(_1) } # must not raise
    end
  end

  def test_captures_and_custom_matchers_are_opaque_leaves
    custom = Class.new do
      include Birman::Matcher

      def match(_ctx, pos) = Birman::Match.new(pos, :c)
    end.new
    g = grammar { rule(:r) { seq(match(/(?<d>\d)/).captures, custom) } }
    r = root_rule(g.parse("1", trace: true))
    assert_equal %i[leaf leaf], r.children.map(&:kind)
  end

  def test_lookahead_children_are_marked_and_dont_reach
    g = grammar { rule(:r) { seq(match(/a/).absent, match(/b/)) } }
    r = root_rule(g.parse("a", trace: true))
    not_node = r.children.first
    assert_equal :not, not_node.kind
    assert(not_node.children.all? { _1.notes[:in_lookahead] })
    assert_nil not_node.notes[:in_lookahead]
  end

  def test_quiet_children_dont_reach
    g = grammar { rule(:r) { either(seq("(", ")").quiet, "[") } }
    r = root_rule(g.parse("(x", trace: true))
    assert_equal 1, r.children.first.children.first.furthest
    assert_nil r.children.first.furthest
  end

  def test_lookahead_catching_a_commit_is_labeled
    g = grammar { rule(:r) { either(seq("(", commit, ")").absent >> "(", "[") } }
    r = root_rule(g.parse("(x", trace: true))
    assert(nodes_of(r).any? { _1.kind == :not && _1.notes[:caught_commit] })
  end

  def test_check_rejection_is_labeled
    g = grammar do
      rule(:r) { match(/\d+/).check(:even?, "an even number") }
      define_method(:even?) { |text| text.to_i.even? }
    end
    r = root_rule(g.parse("3", trace: true))
    assert_equal :even?, r.children.first.notes[:rejected_by]
  end

  def test_positions_are_characters_on_non_ascii_input
    g = grammar { rule(:r) { seq(str("é"), str("x")) } }
    r = root_rule(g.parse("éy", trace: true))
    assert_equal [0, 1, 1, 1], [r.children[0].from, r.children[0].to, r.children[1].from, r.furthest]
  end

  def test_operators_record_operands_and_operators
    g = grammar do
      rule(:r) { operators(match(/\d/), { left: "+", node: Birman.node(:op, :left, :right) }) }
    end
    r = root_rule(g.parse("1+2", trace: true))
    assert_equal :operators, r.children.first.kind
    assert_equal %w[/\d/ "+" /\d/], r.children.first.children.map(&:description).first(3)
  end

  def test_too_deep_is_a_failure_with_a_trace
    result = JSONExample::Grammar.parse("[" * 3000, trace: true)
    assert_equal "input is nested too deeply", result.reason
    assert(nodes_of(result.trace.root).any? { _1.notes[:stack_ran_out] })
  end

  def test_memo_hit_is_a_labeled_leaf_with_its_origin
    g = grammar do
      rule(:r) { either(seq(word, "!"), seq(word, "?")) }
      rule(:word) { match(/[a-z]+/) }
    end
    r = root_rule(g.parse("hi.", trace: true))
    first, again = nodes_of(r).select { _1.rule == :word }
    assert_nil first.notes[:memo]
    assert again.notes[:memo]
    assert_empty again.children
    assert_same first, again.origin
    assert_equal [2, 2], [first.to, again.to]
  end

  def test_memo_hit_replays_what_it_expected
    g = grammar do
      rule(:r) { either(seq(word, "!"), seq(word, "?")) }
      rule(:word) { match(/[a-z]+/) }
    end
    again = nodes_of(root_rule(g.parse("1", trace: true))).select { _1.rule == :word }.last
    assert again.notes[:memo]
    assert_equal [0, ["/[a-z]+/"]], [again.furthest, again.expected]
  end

  def test_direct_left_recursion_rounds
    g = grammar do
      include Birman::Rules::Numbers

      rule(:r) { either(seq(r, "-", integer), integer) }
    end
    r = root_rule(g.parse("1-2-3", trace: true))
    rounds = r.children.select { _1.kind == :round }
    assert_equal r.children, rounds
    assert_equal([1, 2, 3, 4], rounds.map { _1.notes[:round] })
    assert_equal([nil, 1, 3, 5], rounds.map { _1.notes[:seed_end] })
    assert_equal [1, 3, 5, 1], rounds.map(&:to) # the last got no further; the third's is kept
    assert rounds.last.notes[:stopped]
    assert_equal([false, false, false], rounds[0..2].map { _1.notes.key?(:stopped) })
    seed = nodes_of(rounds[1]).find { _1.rule == :r && _1.notes[:seed] }
    assert_equal [0, 1], [seed.from, seed.to]
    failed_seed = nodes_of(rounds[0]).find { _1.rule == :r && _1.notes[:seed] }
    assert_nil failed_seed.to
    assert_equal 5, r.to
  end

  # r and b call each other before consuming anything, a cycle led by r;
  # both of r's alternatives call b where r starts.
  def indirect
    grammar do
      include Birman::Rules::Numbers

      rule(:r) { either(seq(b, "+", integer), seq(b, "-", integer), integer) }
      rule(:b) { r }
    end
  end

  def test_indirect_left_recursion_labels
    all = nodes_of(indirect.parse("1-2", trace: true).trace.root)
    again = all.find { _1.rule == :b && _1.notes[:this_round] }
    assert_equal [0, nil], [again.from, again.to]
    assert again.origin.notes.empty?
  end

  # The paper's lvalues (Medeiros et al.), entered at l: what l matches
  # with pp's final match is just "x", since pp has eaten the ".x"; it
  # takes its longest match from pp's rounds instead.
  def test_took_the_longest_is_labeled_when_it_changes_the_match
    g = grammar do
      rule(:r) { either(seq(pp, ".x"), "x") }
      rule(:pp) { either(seq(pp, "(n)"), r) }
    end
    r = root_rule(g.parse("x(n).x", trace: true))
    assert_equal [:pp, 6], [r.notes[:took_longest], r.to]
  end

  def test_took_the_longest_is_not_labeled_on_a_tie
    b = root_rule(indirect.parse("1+2", root: :b, trace: true))
    assert_equal [:b, nil, 3], [b.rule, b.notes[:took_longest], b.to]
  end

  # The spec's reference rendering: the README's Lists grammar, on input
  # with a committed failure, with the default filters.
  REFERENCE = <<~'TREE'
    list 1:1 ✗ committed at 1:9: expected /\d+/ or "[", found "x"
    ├─ "[" 1:1 ✓ → 1:2
    └─ sep_by(item, ",") 1:2 ✗ unwound by commit
       ├─ item 1:2 ✓ → 1:3
       ├─ "," 1:3 ✓ → 1:5
       └─ item 1:5 ✗ unwound by commit
          ├─ /\d+/ 1:5 ✗ found "["
          └─ list 1:5 ✗ unwound by commit
             ├─ "[" 1:5 ✓ → 1:6
             ├─ sep_by(item, ",") 1:6 ✓ → 1:7
             │  ├─ item 1:6 ✓ → 1:7
             │  ├─ "," 1:7 ✓ → 1:9
             │  └─ item 1:9 ✗
             │     ├─ /\d+/ 1:9 ✗ found "x"
             │     └─ list 1:9 ✗
             │        └─ "[" 1:9 ✗ found "x"
             └─ "]" 1:7 ✗ committed: expected /\d+/ or "[" at 1:9
  TREE

  def lists_trace = Lists.parse("[1, [2, x], []]", trace: true).trace

  def test_reference_rendering
    assert_equal REFERENCE, lists_trace.to_s
  end

  def test_rendering_twice_gives_the_same_text
    t = lists_trace
    assert_equal t.to_s, t.to_s
    t.to_s(all: true, hide: [])
    t.to_s(at: 1, depth: 2)
    assert_equal REFERENCE, t.to_s
  end

  def test_all_expands_every_node
    t = lists_trace
    assert_equal t.size - 1, t.to_s(all: true, hide: []).lines.size # every node but the top one
    assert_operator t.to_s(all: true).lines.size, :<, t.size - 1 # spacing hidden
    assert_includes t.to_s(all: true), "   ├─ item 1:2 ✓ → 1:3\n   │  └─ /\\d+/ 1:2 ✓ → 1:3\n"
  end

  def test_at_moves_the_expanded_path
    out = lists_trace.to_s(at: 1)
    assert_includes out, "   ├─ item 1:2 ✓ → 1:3\n   │  └─ /\\d+/ 1:2 ✓ → 1:3\n   ├─ \",\" 1:3 ✓ → 1:5\n"
    assert out.end_with?("   └─ item 1:5 ✗ unwound by commit\n")
  end

  def test_depth_caps_and_summarizes
    out = lists_trace.to_s(depth: 1)
    assert_match(/\A#{Regexp.escape(REFERENCE.lines.first(3).join)}   └─ … \(\d+ nodes\)\n\z/, out)
  end

  def test_success_defaults_to_four_levels
    out = Lists.parse("[[[[[[1]]]]]]", trace: true).trace.to_s
    assert_match(/\Alist 1:1 ✓ → 1:14\n/, out)
    depths = out.lines.map { _1[/\A[│ ├└─]*/].size / 3 }
    assert_equal 5, depths.max
    assert(out.lines.select { _1[/\A[│ ├└─]*/].size / 3 == 5 }.all? { _1.include?("… (") })
  end

  def test_hide_defaults_to_the_ignore_rule
    t = JSONExample::Grammar.parse("[1, ]", trace: true).trace
    refute_match(/\b#{JSONExample::Grammar.ignore}\b/, t.to_s)
    refute_match(/\b#{JSONExample::Grammar.ignore}\b/, t.to_s(all: true))
    assert_match(/\b#{JSONExample::Grammar.ignore}\b/, t.to_s(hide: [], all: true))
  end

  def test_memo_origin_hidden_in_a_lookahead_is_expanded_under_the_hit
    g = grammar do
      rule(:r) { seq(word.present, word, "!") }
      rule(:word) { match(/[a-z]+/) }
    end
    out = g.parse("hi?", trace: true).trace.to_s
    assert_match(/word 1:1 ✓ → 1:3 \(memo\)\n.*└─ first tried here, under &word\n.*└─ word 1:1 ✓ → 1:3\n/, out)
  end

  def test_left_recursion_renders_rounds
    g = grammar do
      include Birman::Rules::Numbers

      rule(:r) { either(seq(r, "-", integer), integer) }
    end
    out = g.parse("1-2-3", trace: true).trace.to_s(all: true)
    assert_includes out, "├─ round 1 (seed fails) ✓ → 1:2\n"
    assert_includes out, "├─ round 2 (seed ends at 1:2) ✓ → 1:4\n"
    assert_includes out, "└─ round 4 (seed ends at 1:6) ✓ → 1:2, no further: stops (keeps round 3)\n"
    assert_includes out, "r 1:1 ✓ → 1:2 (seed)\n"
    assert_includes out, "r 1:1 ✗ (seed fails)\n"
  end

  def test_too_deep_cuts_the_middle
    out = JSONExample::Grammar.parse("[" * 3000, trace: true).trace.to_s
    assert_match(/\Avalue 1:1 ✗ at 1:\d+: input is nested too deeply\n/, out)
    assert_match(/… \(\d+ levels\)/, out)
    assert_operator out.lines.size, :<, 80
  end

  def test_invalid_utf8_renders_one_line
    t = Lists.parse("[1\xFF]".dup.force_encoding("UTF-8"), trace: true).trace
    assert_equal "(input) ✗ invalid UTF-8 at 1:3\n", t.to_s
  end

  def test_standalone_root_renders_as_parse
    assert_match(/\Aparse 1:1 ✗/, Birman.parse(Birman.seq("(", ")"), "(x", trace: true).trace.to_s)
  end

  def test_inspect_is_short
    assert_equal "#<Birman::Trace #{lists_trace.size} nodes, failed at 1:9>", lists_trace.inspect
    assert_equal "#<Birman::Trace #{Lists.parse("[]", trace: true).trace.size} nodes, succeeded>",
                 Lists.parse("[]", trace: true).trace.inspect
  end

  def test_a_custom_matchers_unknown_ast_doesnt_break_a_traced_parse
    custom = Class.new do
      include Birman::Matcher

      def match(ctx, pos) = ctx.fail_at(pos, "custom")
      def to_ast = [:weird, 1]
    end.new
    g = grammar { rule(:r) { either(custom, "(") } }
    assert_equal g.parse("x"), g.parse("x", trace: true)
    assert_equal :leaf, root_rule(g.parse("x", trace: true)).children.first.kind
  end

  def test_leftover_input_puts_the_result_on_the_root_rules_line
    out = Lists.parse("[1] x", trace: true).trace.to_s
    assert_equal "list 1:1 ✓ → 1:5 at 1:5: expected end of input, found \"x\"\n", out.lines.first
    assert_equal "end of input 1:5 ✗\n", out.lines.last
  end

  def test_pretty_printing_a_node_is_short
    root = JSONExample::Grammar.parse("[" * 200, trace: true).trace.root
    assert_equal "#{root.inspect}\n", root.pretty_inspect
  end

  def test_a_rejecting_check_ignores_what_its_inner_match_expected
    g = grammar do
      rule(:r) { seq(match(/\d+/), match(/x/).maybe).check(:even?, "an even number") }
      define_method(:even?) { |parts| parts[0].to_i.even? }
    end
    check = root_rule(g.parse("3y", trace: true)).children.first
    assert_equal [0, ["an even number"]], [check.furthest, check.expected]
    assert_match(/check :even\? 1:1 ✗ expected an even number rejected by :even\?$/,
                 g.parse("3y", trace: true).trace.to_s)
  end

  def test_hide_takes_strings_too
    t = lists_trace
    assert_equal t.to_s(all: true, hide: %i[spacing item]), t.to_s(all: true, hide: %w[spacing item])
  end

  def test_a_failed_lookahead_says_what_it_expected
    g = grammar do
      rule(:r) { seq(word.present, word) }
      rule(:word) { match(/[a-z]+/) }
    end
    out = g.parse("1", trace: true).trace.to_s
    assert_match(%r{^[├└]─ &word 1:1 ✗ expected /\[a-z\]\+/$}, out)
  end

  def test_rules_comments_are_hidden_by_default
    g = grammar do
      include Birman::Rules::Comments

      ignore :spacing
      rule(:r) { seq("(", lexed, ")") }
      lexeme(:lexed) { match(/[a-z]+/) }
    end
    t = g.parse("( # note\n ab # more\n x", trace: true).trace
    refute_match(/spacing|comment/, t.to_s(all: true))
    assert_match(/spacing/, t.to_s(all: true, hide: []))
  end

  # Operators drops what its prefix operators expected, as if they were
  # quiet, so the trace wraps each in a quiet node.
  def test_operators_prefix_attempts_dont_reach
    g = grammar do
      rule(:r) do
        operators(match(/\d/), { prefix: seq("-", "-"), node: Birman.node(:op, :operand) },
                  { left: "+", node: Birman.node(:op, :left, :right) })
      end
    end
    result = g.parse("-x", trace: true)
    assert_equal 0, result.pos
    ops = root_rule(result).children.first
    prefix = ops.children.first
    assert_equal [:quiet, nil, 1], [prefix.kind, prefix.furthest, prefix.children.first.furthest]
    assert_equal 0, ops.furthest
  end

  # The guard against TracingContext drifting from Context and Ref: a
  # traced parse gives exactly the untraced result, except on input
  # nested deeper than a traced parse can go, which fails as too deep.
  Examples.all(Integer(ENV.fetch("TRACE_INPUTS", 60))).each do |example|
    define_method(:"test_tracing_#{example.name}_changes_no_result") do
      mismatches = example.inputs.uniq.filter_map do |input|
        want = Differential.interpreted(example.grammar, input, **example.options)
        got = Differential.interpreted(example.grammar, input, trace: true, **example.options)
        [input, want, got] unless want == got || got.include?('reason="input is nested too deeply"')
      end
      assert_empty mismatches.first(5), "#{mismatches.size} mismatches of #{example.inputs.uniq.size}"
    end
  end
end
