# frozen_string_literal: true

require "test_helper"

# Error recovery's result types: a Failure that lists every error found
# (and the value recovered past them), and the ErrorNode that marks where
# a recovery happened in the tree.
class RecoverTest < Minitest::Test
  def failure(pos: 0, expected: ["y"], input: "xxxxxxxx")
    Birman::Failure.new(input:, pos:, expected:, committed: false)
  end

  def test_failure_without_recovery_lists_itself_and_has_no_value
    f = failure
    assert_equal [f], f.errors
    assert_nil f.value
  end

  def test_recovered_failure_takes_the_first_errors_fields
    a5 = failure(pos: 5, expected: ["a"])
    b2 = failure(pos: 2, expected: ["b"])
    r = Birman::Failure.recovered([a5, b2], value: :v)
    assert_equal 2, r.pos
    assert_equal b2.expected, r.expected
    assert_equal [b2, a5], r.errors
    assert_equal :v, r.value
  end

  def test_recovered_sorts_stably
    a = failure(pos: 3, expected: ["a"])
    b = failure(pos: 3, expected: ["b"])
    assert_equal [a, b], Birman::Failure.recovered([a, b], value: nil).errors
  end

  def test_recovered_passes_the_trace_through
    trace = Object.new
    def trace.__finish(result) = (@finished = result)
    r = Birman::Failure.recovered([failure], value: nil, trace:)
    assert_same trace, r.trace
    assert_same r, trace.instance_variable_get(:@finished)
  end

  def test_errors_and_value_are_not_members
    plain = failure(pos: 2)
    r = Birman::Failure.recovered([plain, failure(pos: 4)], value: :v)
    assert_equal plain, r
    assert_equal plain.inspect, r.inspect
    assert_equal %i[input pos expected committed reason], r.to_h.keys
    case r
    in Birman::Failure(input:, pos:)
      assert_equal [plain.input, 2], [input, pos]
    end
  end

  def test_marshal_keeps_errors_and_value
    r = Birman::Failure.recovered([failure(pos: 4), failure(pos: 1)], value: [1, 2])
    back = Marshal.load(Marshal.dump(r))
    assert_equal r, back
    assert_equal r.errors, back.errors
    assert_equal [1, 2], back.value
    assert_nil back.trace
  end

  def test_marshal_of_a_plain_failure_still_lists_itself
    back = Marshal.load(Marshal.dump(failure))
    assert_equal [back], back.errors
    assert_nil back.value
  end

  def test_error_node_has_a_span_and_its_failure
    f = failure
    node = Birman::ErrorNode.new(failure: f)
    assert_equal "(ErrorNode #{f.inspect})", node.inspect
    assert_kind_of Birman::Node, node
    span = Birman::Span.new(input: "xx", byte_from: 0, byte_to: 1)
    assert_equal span, Birman::Node.new_with_span(Birman::ErrorNode, span, failure: f).span
  end

  def test_value_bang_raises_the_first_error_listing_all
    a = failure(pos: 5, expected: ["a"])
    b = failure(pos: 2, expected: ["b"])
    r = Birman::Failure.recovered([a, b], value: :v)
    err = assert_raises(Birman::ParseError) { r.value! }
    assert_equal Birman::ErrorFormatter.new.call(b), err.message
    assert_equal [b, a], err.failure.errors
  end

  # --- recover(to:) in a parse ---

  # Statements separated by ";": let commits after its keyword, print
  # doesn't, so a print that fails part-way is a plain failure past its
  # start.
  LANG = proc do
    rule(:statements) { seq(only(stmt.recover(to: ";")), ";").rep }
    rule(:stmt) { either(let_stmt, print_stmt) }
    rule(:let_stmt) { seq("let", commit, name.as(:name), "=", num.as(:value)) }
    rule(:print_stmt) { seq("print", num.as(:value)) }
    lexeme(:name) { /[a-z]+/ }
    lexeme(:num) { /\d+/ }
  end

  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace

      ignore :spacing
      self.root(root)
      class_eval(&LANG)
      class_eval(&rules) if rules
    end
  end

  def program = grammar(:statements)

  def test_valid_input_is_a_success_with_no_errors
    result = program.parse("let x = 1; print 2;")
    assert_instance_of Birman::Success, result
    assert_equal [{ name: "x", value: "1" }, { value: "2" }], result.value
  end

  def test_list_ending_at_a_brace_or_eof_is_not_an_error
    g = grammar { rule(:top) { seq("{", seq(stmt.recover(to: ";"), ";").rep, "}") } }
    assert_instance_of Birman::Success, g.parse("{ let x = 1; }")
    assert_instance_of Birman::Success, program.parse("print 2;")
  end

  def test_committed_failure_is_recovered_and_parsing_continues
    result = program.parse("let = 1; let y = 2; let 3; print 4;")
    assert_instance_of Birman::Failure, result
    assert_equal [4, 24], result.errors.map(&:pos)
    assert result.errors.all?(&:committed)
    value = result.value
    assert_kind_of Array, value
    assert_equal 4, value.size
    assert_instance_of Birman::ErrorNode, value[0]
    assert_instance_of Birman::ErrorNode, value[2]
    assert_equal({ name: "y", value: "2" }, value[1])
    assert_equal({ value: "4" }, value[3])
    assert_equal result.errors, [value[0].failure, value[2].failure]
  end

  def test_error_node_spans_from_the_start_to_the_sync_point
    value = program.parse("let = 1; let 3 ;").value
    assert_equal "let = 1", value[0].span.text
    assert_equal 0, value[0].span.from
    assert_equal "let 3", value[1].span.text # spacing before the sync point isn't in it
  end

  def test_sync_search_starts_at_the_failure_point
    g = grammar(:prints) do
      rule(:prints) { seq(only(bang.recover(to: ";")), ";").rep }
      rule(:bang) { seq("print", commit, "(", sep_by(num, ";"), ")", "!") }
    end
    result = g.parse("print (1; 2) @; print (3) !;")
    assert_equal [13], result.errors.map(&:pos)
    assert_equal ['"!"'], result.errors.first.expected
    assert_equal "print (1; 2) @", result.value[0].span.text
    assert_equal ["print", "(", ["3"], ")", "!"], result.value[1]
  end

  def test_no_sync_skips_to_end_of_input
    g = grammar { rule(:top) { stmt.recover(to: ";") } }
    result = g.parse("let = 1 2 3")
    assert_equal [4], result.errors.map(&:pos)
    assert_instance_of Birman::ErrorNode, result.value
    assert_equal "let = 1 2 3", result.value.span.text
  end

  def test_plain_failure_that_got_past_its_start_is_recovered
    result = program.parse("print x; print 2;")
    assert_equal [6], result.errors.map(&:pos)
    refute result.errors.first.committed
    assert_equal ["/\\d+/"], result.errors.first.expected
    assert_equal "print x", result.value[0].span.text
    assert_equal({ value: "2" }, result.value[1])
  end

  def test_first_error_is_the_failures_own_fields
    result = program.parse("let = 1; print x;")
    first = result.errors.first
    assert_equal [4, 15], result.errors.map(&:pos)
    assert_equal [first.pos, first.expected, first.committed, first.reason],
                 [result.pos, result.expected, result.committed, result.reason]
    assert_equal first.message, result.message
  end

  def test_parse_bang_raises_the_first_error
    err = assert_raises(Birman::ParseError) { program.parse!("let = 1; print x;") }
    assert_equal Birman::ErrorFormatter.new.call(err.failure.errors.first), err.message
    assert_equal [4, 15], err.failure.errors.map(&:pos)
  end

  def test_recover_with_a_regexp_or_rule_sync
    input = "let = 1 ; let y = 2; let 3; print 4;"
    syncs = [/;/, Birman.match(/;/), :semi, :stop]
    syncs.each do |sync|
      g = grammar(:synced) do
        rule(:semi) { ";" } # a literal, skipping spacing after it
        rule(:stop) { either(str(";"), str("}")) }
        rule(:synced) { seq(only(stmt.recover(to: sync.is_a?(Symbol) ? send(sync) : sync)), ";").rep }
      end
      result = g.parse(input)
      assert_equal [4, 25], result.errors.map(&:pos), sync.inspect
      assert_equal "let = 1", result.value[0].span.text, sync.inspect
      assert_equal 4, result.value.size, sync.inspect
    end
  end

  def test_consume_false_and_offset_with_recovery
    prefix = program.parse("let = 1; print 2; )))", consume: false)
    assert_instance_of Birman::Failure, prefix
    assert_equal [4], prefix.errors.map(&:pos)
    assert_equal({ value: "2" }, prefix.value[1])

    offset = program.parse("éé let = 1; print 2;", offset: 3)
    assert_equal [7], offset.errors.map(&:pos)
    assert_equal 3, offset.value[0].span.from
    assert_equal "let = 1", offset.value[0].span.text
  end

  def test_nested_recover_keeps_inner_errors
    g = grammar(:blocks) do
      rule(:blocks) { seq(only(block.recover(to: "}")), "}").rep }
      rule(:block) { seq("{", commit, statements, "done") }
    end
    result = g.parse("{ let = 1; print 2; oops } { print 3; done }")
    assert_equal [6, 20], result.errors.map(&:pos)
    assert result.errors.all?(&:committed)
    assert_equal "{ let = 1; print 2; oops", result.value[0].span.text
    assert_equal ["{", [{ value: "3" }], "done"], result.value[1]
  end

  def test_a_failure_after_recovering_lists_both
    result = program.parse("let = 1; print 2 print 3;")
    assert_equal [4, 17], result.errors.map(&:pos)
    assert_nil result.value
  end

  def test_a_recover_passes_names_through_as_its_inner_matcher_does
    g = grammar { rule(:top) { seq(seq(name.as(:n), num.as(:v)).recover(to: ";"), str(";").as(:end)) } }
    error = assert_raises(ArgumentError) { g.parse("x 1;") }
    assert_match(/would lose its names :n, :v/, error.message)
    g = grammar { rule(:top) { seq(num.as(:v).recover(to: ";"), ";") } }
    assert_equal({ v: "1" }, g.parse!("1;"))
  end

  # The commit keeps the recovered error when "!" fails (see
  # test_root_plain_failure_rolls_back_but_commit_keeps_them).
  def test_a_recovered_attempts_expectations_are_not_merged_outward
    g = grammar { rule(:top) { seq(stmt.recover(to: ";"), commit, "!") } }
    result = g.parse("let ;")
    assert_equal([[4, ["/[a-z]+/"]], [4, ['"!"']]], result.errors.map { [_1.pos, _1.expected] })
  end

  # --- Backtracking discards recovered errors ---

  # Each grammar below has an alternative that recovers (from "let = 1",
  # failing at 4) and is then thrown away, and another that matches
  # without errors: the parse is a Success only if the thrown-away
  # alternative took its error with it.

  Add = Birman.node(:op, :left, :right)
  Neg = Birman.node(:op, :operand)

  def assert_no_stale_errors(grammar_class, input)
    result = grammar_class.parse(input)
    assert_instance_of Birman::Success, result, -> { "stale errors at #{result.errors.map(&:pos)}" }
    result
  end

  def test_choice_backtracking_over_a_recovered_seq
    g = grammar { rule(:top) { seq(either(seq(stmt.recover(to: ";"), "!"), /let[^;]*/), ";") } }
    assert_no_stale_errors(g, "let = 1;")
  end

  def test_pick_failing_after_a_recovered_part
    g = grammar { rule(:top) { seq(either(between("(", ")", stmt.recover(to: ";")), /\([^;]*/), ";") } }
    assert_no_stale_errors(g, "(let = 1;")
  end

  def test_rep_below_min_after_a_recovered_pass
    g = grammar { rule(:top) { seq(either(seq(stmt.recover(to: ";"), ";").rep(2), /[^!]*/), "!") } }
    assert_no_stale_errors(g, "let = 1;!")
  end

  # The pass recovers, then finds no ";": the rep ends before it.
  def test_a_rep_pass_that_recovers_then_fails_leaves_no_error
    g = grammar { rule(:top) { seq(seq(stmt.recover(to: ";"), ";").rep, /.*/m) } }
    result = assert_no_stale_errors(g, "print 1; let = 1")
    assert_equal [[{ value: "1" }, ";"]], result.value[0]
  end

  def test_sep_by_dropped_separator_takes_its_errors
    g = grammar { rule(:top) { seq(sep_by("x", seq(stmt.recover(to: ";"), ";")), /.*/m) } }
    result = assert_no_stale_errors(g, "x let = 1; y")
    assert_equal ["x"], result.value[0]
  end

  # The separator after the last item is kept; the item after it, which
  # recovered and then failed, isn't.
  def test_sep_by_trailing_item_takes_its_errors
    g = grammar do
      rule(:top) { seq(sep_by(seq(stmt.recover(to: ";"), "!"), ",", trailing: true), /[^;]*/, ";") }
    end
    result = assert_no_stale_errors(g, "print 1 !, let = 1;")
    assert_equal [[{ value: "1" }, "!"]], result.value[0]
  end

  def test_check_rejection_takes_inner_errors
    g = grammar do
      rule(:top) { seq(either(stmt.recover(to: ";").check(:never?, "ok"), /[^;]*/), ";") }
      def never?(_value) = false # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_no_stale_errors(g, "let = 1;")
  end

  # An operator ("+" "+", recovering at a digit) matched, then its right
  # operand failed.
  def test_operators_dropped_operand_takes_the_operators_errors
    g = grammar do
      rule(:top) { seq(operators(num, { left: seq("+", commit, "+").recover(to: /\d/), node: Add }), /.*/m) }
    end
    result = assert_no_stale_errors(g, "1 + x")
    assert_equal "1", result.value[0]
  end

  # The inner climb (after "*") matches the looser operator, recovering,
  # and drops it for the outer climb, which matches it again: one error.
  def test_operators_dropped_looser_operator_reports_its_error_once
    g = grammar do
      rule(:top) do
        operators(num, { left: "*", node: Add }, { left: seq("+", commit, "+").recover(to: /\d/), node: Add })
      end
    end
    assert_equal [8], g.parse("1 * 2 + 3").errors.map(&:pos)
  end

  # A prefix operator that recovers and then has no operand, and one that
  # recovers matching nothing: both dropped for the bare operand.
  def test_operators_dropped_prefix_takes_its_errors
    g = grammar do
      rule(:top) { operators(either(num, /-\s*x/), { prefix: seq("-", commit, "-").recover(to: /\d/), node: Neg }) }
    end
    assert_no_stale_errors(g, "- x")
    g = grammar do
      rule(:top) { operators(num, { prefix: seq("", commit, "~").recover(to: /\d/), node: Neg }) }
    end
    assert_no_stale_errors(g, "5")
  end

  # An item that recovers matching nothing, after a real one: the rep
  # ends there, dropping it.
  def test_rep_drops_an_empty_recovered_match_after_real_ones
    g = grammar { rule(:top) { seq(either("@", seq("", commit, "~").recover(to: /\d/)).rep, /\d/) } }
    result = assert_no_stale_errors(g, "@5")
    assert_equal [["@"], "5"], result.value
  end

  def test_absent_and_present_discard_errors
    g = grammar { rule(:top) { seq(either(stmt.recover(to: ";").absent, /[^;]*/), ";") } }
    assert_no_stale_errors(g, "let = 1;")
    g = grammar { rule(:top) { seq(stmt.recover(to: ";").present, /[^;]*/, ";") } }
    assert_no_stale_errors(g, "let = 1;")
  end

  def test_upto_with_a_rule_terminator_discards_errors
    g = grammar do
      rule(:top) { seq(upto(term), /.*/m) }
      rule(:term) { stmt.recover(to: ";") }
    end
    result = assert_no_stale_errors(g, "abc let = 1;")
    assert_equal "abc ", result.value[0]
  end

  # The block recovers at "}" after its statement recovered (the outer
  # error is logged after the inner one, though it starts first); then
  # "end" fails and the regexp alternative matches instead.
  def test_backtracking_over_a_nested_recover
    g = grammar do
      rule(:top) { seq(either(seq(block.recover(to: "}"), "}", "end"), /[^!]*/), "!") }
      rule(:block) { seq("{", commit, statements, "done") }
    end
    assert_no_stale_errors(g, "{ let = 1; oops }!")
  end

  # A left-recursive rule grows by matching its body again at the same
  # position; the last round, which gets no further, backtracks over the
  # seed it took, but the seed (the match kept) keeps its error.
  def test_a_growth_rounds_backtracking_keeps_the_seeds_errors
    g = grammar(:expr) do
      rule(:expr) { either(seq(expr, "+", term), num) }
      rule(:term) { either(num, seq("(", commit, num, ")").recover(to: "+")) }
    end
    assert_equal [3], g.parse("1+(x").errors.map(&:pos)
    assert_equal [3], g.parse("1+(x+2").errors.map(&:pos)
  end

  # The kept item ends with a recover that matched nothing at ","; the
  # dropped separator starts there too, but only its own errors go.
  def test_a_dropped_separator_keeps_an_empty_error_before_it
    g = grammar { rule(:top) { seq(sep_by(seq("a", seq("", commit, "~").recover(to: ",")), ","), /.*/m) } }
    assert_equal [1], g.parse("a,").errors.map(&:pos)
  end

  # The root seq failing plainly is backtracking too, so only the final
  # failure is left; a commit failure doesn't backtrack, so the errors
  # recovered before it stay.
  def test_root_plain_failure_rolls_back_but_commit_keeps_them
    input = "{ let = 1; print 2;"
    plain = grammar { rule(:top) { seq("{", seq(stmt.recover(to: ";"), ";").rep, "}") } }.parse(input)
    assert_equal [19], plain.errors.map(&:pos)
    committed = grammar { rule(:top) { seq("{", commit, seq(stmt.recover(to: ";"), ";").rep, "}") } }.parse(input)
    assert_equal [6, 19], committed.errors.map(&:pos)
  end

  # --- The error log Context keeps ---

  def context(input)
    g = program.new
    Birman::Context.new(input, g, nil, g.left_recursion)
  end

  def error_at(ctx, from)
    failure = Birman::Failure.new(input: ctx.input, pos: from, expected: [], committed: true)
    Birman::Node.new_with_span(Birman::ErrorNode, ctx.span(from, from + 1), { failure: })
  end

  def test_the_log_is_nil_until_an_error_is_recorded
    ctx = context("abcdef")
    assert_nil ctx.recovered
    assert_nil ctx.log_mark
    refute ctx.recovered_since?(nil)
    ctx.rollback(nil) # nothing to roll back
    assert_nil ctx.recovered
  end

  # Marks are the log's length, so errors are dropped by when they were
  # recorded, not where they start: an inner error logged before the
  # outer one that starts first, say.
  def test_rollback_drops_the_errors_recorded_since_the_mark
    ctx = context("abcdef")
    before = ctx.log_mark
    inner, outer, later = [3, 1, 4].map { error_at(ctx, _1) }
    ctx.record(inner)
    ctx.record(outer)
    mark = ctx.log_mark
    refute ctx.recovered_since?(mark)
    ctx.record(later)
    assert ctx.recovered_since?(mark)
    ctx.rollback(mark)
    assert_equal [inner, outer], ctx.recovered
    assert ctx.recovered_since?(before)
    ctx.rollback(before)
    assert_empty ctx.recovered
    refute ctx.recovered_since?(before)
  end
end
