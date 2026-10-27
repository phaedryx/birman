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

  def top_matcher(grammar) = grammar.new.matcher_for(:top)

  # The EBNF of the rules the root reaches: these grammars include
  # Whitespace without using it, so to_ebnf ends with its spacing rule.
  def reachable_ebnf(grammar) = grammar.to_ebnf.split("\n\n").first

  def seq_of_names = Birman::Seq.new([Birman::Str.new("a").as(:x), Birman::Str.new("b").as(:y)])

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

    parts = [Birman::Str.new("a")]
    [Birman::Seq.new(parts), Birman::Choice.new(parts), Birman::Pick.new(parts, 0)].each do |matcher|
      list = matcher.to_h.values.first
      assert list.frozen?, "#{matcher.class} keeps a mutable array"
    end
    refute parts.frozen?, "the caller's array is left alone"
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

    error = assert_raises(Birman::ParseError) { g.parse!("x", formatter: shouty) }
    assert_equal 'NOPE AT 0: "hi"', error.message
    assert_equal "hi", g.parse!("hi", formatter: shouty)
  end

  def test_failure_inspect_shows_only_the_start_of_the_input
    g = grammar { rule(:top) { str("hi") } }
    shown = g.parse("x" * 10_000).inspect
    assert_operator shown.size, :<, 200
    assert_includes shown, "pos=0"
  end

  def test_error_caret_lines_up_under_tabs
    g = grammar { rule(:top) { str("\t\t") >> str("x") } }
    caret_line = g.parse("\t\ty").message.lines.last
    assert_equal "  \t\t^", caret_line
  end

  # A second pass over the AST reports at a node's span.
  def test_failure_at_a_span
    g = grammar do
      const_set(:Word, node(:text))
      rule(:top) { sep_by(match(/\p{L}+/).to(self.class::Word), str("\n")) }
    end
    _, word = g.parse!("héllo\nwörld")
    failure = Birman::Failure.at(word.span, "wörld is not allowed")

    assert_pattern { failure => Birman::Failure(pos: 6, expected: [], committed: true, reason: "wörld is not allowed") }
    assert_equal "line 2, column 1: wörld is not allowed\n  wörld\n  ^", failure.message
    assert_raises(Birman::ParseError) { failure.value! }
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
    assert_equal %W[a\n b], grammar { rule(:top) { str("a\n") >> match(/^b/) } }.parse!("a\nb")
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
      rule(:top) { if_statement | other }
      rule(:if_statement) { token(keyword("if")) > token(match(/\d+/).label("condition")) }
      rule(:other) { match(/.*/) }
    end

    failure = g.parse("if oops")
    assert failure.committed
    assert_equal 3, failure.pos
    assert_equal ["condition"], failure.expected
  end

  def test_without_commit_choice_backtracks
    g = grammar do
      rule(:top) { if_statement | other }
      rule(:if_statement) { token(keyword("if")) >> token(match(/\d+/)) }
      rule(:other) { match(/.*/) }
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

  # Failing where the lookahead started, a commit failure says what it
  # expected there, as the same failure without the commit would.
  def test_a_commit_failure_where_a_lookahead_starts_says_what_it_expected
    committed = grammar do
      rule(:top) { either(seq(inner.present, "a"), "b") }
      rule(:inner) { seq(str("a").maybe, commit, str("c")) }
    end
    uncommitted = grammar do
      rule(:top) { either(seq(inner.present, "a"), "b") }
      rule(:inner) { seq(str("a").maybe, str("c")) }
    end
    ["", "x"].each do |input|
      assert_pattern { committed.parse(input) => Birman::Failure(pos: 0, expected: ['"a"', '"c"', '"b"'], committed: false) }
      assert_equal uncommitted.parse(input).expected, committed.parse(input).expected
    end
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

  def test_repetition_counts_one_empty_match
    g = grammar { rule(:top) { match(/a*/).rep(1) } }
    assert_equal [""], g.parse!(""), "an empty match is a match"
    assert_equal ["aaa"], g.parse!("aaa")

    g = grammar { rule(:top) { match(/a*/).maybe } }
    assert_equal "", g.parse!(""), "maybe keeps the empty match's value"
  end

  # --- Labels and quiet ---

  def test_label_replaces_failures_when_its_matcher_consumed_nothing
    g = grammar { rule(:top) { str("a").maybe.label("prefix") >> str("b") } }
    assert_equal ["prefix", '"b"'], g.parse("x").expected

    g = grammar { rule(:top) { str("a").rep.label("letters") >> str("b") } }
    assert_equal ['"a"', '"b"'], g.parse("ax").expected, "it consumed something, so the deeper error stays"
  end

  def test_label_replaces_low_level_expectations
    g = grammar { rule(:top) { (match(/\d+/) | match(/[a-z]+/)).label("value") } }
    assert_equal ["value"], g.parse("!").expected
  end

  def test_label_keeps_deeper_errors
    g = grammar { rule(:top) { (str("(") >> str(")")).label("group") } }
    assert_pattern { g.parse("(x") => Birman::Failure(pos: 1, expected: ['")"']) }
  end

  # Each level tries the one below in three alternatives, so a memo hit
  # merged its expectations in again every time: 3**depth entries for
  # two distinct ones ("!" and "?" at position 1).
  def nested_choices(depth)
    grammar(:"l#{depth}") do
      rule(:l0) { str("x") }
      (1..depth).each do |i|
        below = :"l#{i - 1}"
        rule(:"l#{i}") { either(seq(send(below), "!"), seq(send(below), "?"), send(below)) }
      end
    end
  end

  def test_memo_hits_do_not_repeat_expectations
    g = nested_choices(12)
    ctx = Birman::Context.new("x", g.new, g.ignore)
    Birman::Ref.new(:l12).match(ctx, 0)
    assert_equal 2, ctx.expected.size
    assert_equal ['"!"', '"?"'], ctx.expected
    assert_equal ['"!"', '"?"', "end of input"], g.parse("x.").expected
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

  def test_sep_by_with_a_trailing_separator
    g = grammar { rule(:top) { sep_by(match(/\d+/), str(","), trailing: true) } }
    assert_equal %w[1 2], g.parse!("1,2,")
    assert_equal %w[1 2], g.parse!("1,2")
    assert_equal [], g.parse!("")
    assert g.parse(",").failure?, "a separator needs an item before it"
    assert g.parse("1,,").failure?, "only one"
    assert_equal 'top = (/\d+/ ("," /\d+/)* ","?)? ;', reachable_ebnf(g)

    g = grammar { rule(:top) { sep_by1(match(/\d+/), str(","), trailing: true) } }
    assert_equal %w[1], g.parse!("1,")
    assert g.parse("").failure?
  end

  # After a separator, the item is expected (and, when trailing is
  # allowed, so is whatever follows the list).
  def test_errors_after_a_separator
    trailing, plain = [true, false].map do |trailing|
      grammar { rule(:top) { seq(str("["), sep_by(match(/\d+/).label("value"), str(","), trailing:), str("]")) } }
    end
    assert_pattern { trailing.parse("[1,2,x") => Birman::Failure(pos: 5, expected: ["value", '"]"']) }
    assert_equal %w[1 2], trailing.parse!("[1,2,]")[1]
    assert_pattern { plain.parse("[1,2,]") => Birman::Failure(pos: 5, expected: ["value"]) }
  end

  def test_a_trailing_separator_doesnt_stop_a_commit
    g = grammar { rule(:top) { sep_by(seq(str("a"), commit, str("b")), str(","), trailing: true) } }
    assert_equal [%w[a b]], g.parse!("ab,")
    assert_pattern { g.parse("ab,a") => Birman::Failure(pos: 4, expected: ['"b"'], committed: true) }
  end

  MOMENT = /(?<date>\d{4}-\d\d-\d\d)(?:T(?<time>\d\d:\d\d))?(?<offset>Z|[-+]\d\d:\d\d)?/

  def test_captures_are_a_hash_of_the_named_groups
    g = grammar { rule(:top) { match(MOMENT).captures } }
    assert_equal({ date: "1979-05-27", time: "07:32", offset: "Z" }, g.parse!("1979-05-27T07:32Z"))
    assert_equal({ date: "1979-05-27", time: nil, offset: nil }, g.parse!("1979-05-27"), "unmatched groups are nil")
    assert_equal({ date: "1979-05-27", time: nil, offset: "-07:00" }, g.parse!("1979-05-27-07:00"))
    assert_pattern { g.parse("1979") => Birman::Failure(pos: 0, expected: [^(MOMENT.inspect)]) }
    assert_equal "top = #{MOMENT.inspect} ;", reachable_ebnf(g)
  end

  def test_captures_build_nodes
    g = grammar do
      const_set(:Moment, node(:date, :time, :offset))
      rule(:top) { seq(str("at "), only(match(MOMENT).captures.to(self.class::Moment))) }
    end
    moment = g.parse!("at 1979-05-27T07:32")
    assert_equal ["1979-05-27", "07:32", nil], moment.to_h.values
    assert_equal "1979-05-27T07:32", moment.span.text
  end

  def test_captures_need_named_groups_each_named_once
    error = assert_raises(ArgumentError) { grammar { rule(:top) { match(/(\d+)-(\d+)/).captures } }.parse("1-2") }
    assert_match(/has no named groups/, error.message)
    error = assert_raises(ArgumentError) { grammar { rule(:top) { match(/(?<n>\d)|(?<n>x)/).captures } }.parse("1") }
    assert_match(/n more than once/, error.message)
  end

  def test_one_of_a_hash_maps_literals_to_values
    g = grammar do
      ignore :spacing
      rule(:top) { one_of("true" => true, "false" => false, "null" => nil).rep }
    end
    assert_equal [true, nil, false], g.parse!("true null false")
    g = grammar { rule(:top) { one_of("true" => true, "false" => false, "null" => nil) } }
    assert_equal ['"true"', '"false"', '"null"'], g.parse("maybe").expected
    assert g.parse("truex").failure?, "word-like keys are keywords"

    g = grammar { rule(:top) { one_of("<=" => :le, "<" => :lt) } }
    assert_equal :le, g.parse!("<="), "tried in the order given"
  end

  def test_sep_by_gives_a_fresh_array_each_time
    g = grammar { rule(:top) { sep_by(match(/\d+/), ",") } }
    first = g.parse!("")
    refute first.frozen?
    refute_same first, g.parse!("")
  end

  # --- Values without blocks ---

  def test_maybe_never_fails
    g = grammar { rule(:top) { str("a").maybe } }
    assert_nil g.parse!("")
    assert_equal "a", g.parse!("a")
    assert_kind_of Birman::Maybe, top_matcher(g)
    assert_equal 'top = "a"? ;', g.to_ebnf.lines.first.chomp
  end

  def test_means_replaces_the_value
    g = grammar { rule(:top) { seq(str("yes").means(true).as(:answer), "!") } }
    assert_equal({ answer: true }, g.parse!("yes!"))
    assert_equal 'top = "yes" "!" ;', g.to_ebnf.lines.first.chomp
  end

  def test_map_with_a_symbol_calls_that_method_on_the_value
    g = grammar { rule(:top) { match(/\d+/).as(:n).map(:to_i) } }
    assert_equal 42, g.parse!("42")
    assert_equal :to_i, top_matcher(g).method_name, "kept as data, not a Proc"
    assert_raises(ArgumentError) { Birman::Str.new("x").map(:to_s) { _1 } }
    assert_raises(ArgumentError) { Birman::Str.new("x").map }
  end

  def test_action_calls_a_grammar_method_with_the_value
    g = grammar do
      rule(:top) { seq(match(/\d+/).action(:double).as(:n), "!") }
      define_method(:double) { |text| text.to_i * 2 }
      private :double
    end
    assert_equal({ n: 84 }, g.parse!("42!"))

    tripled = Class.new(g) { def double(text) = text.to_i * 3 }
    assert_equal({ n: 126 }, tripled.parse!("42!"), "subclasses can override the method")
  end

  def test_names_pass_through_symbol_map_means_and_action
    g = grammar do
      rule(:top) { seq(match(/\d/).as(:a).map(:to_i), match(/x/).as(:b).means(true), match(/y/).as(:c).action(:up)) }
      define_method(:up) { |text| text.upcase }
    end
    assert_equal({ a: 1, b: true, c: "Y" }, g.parse!("1xy"))
  end

  # --- Checks ---

  # A grammar whose rules can check for even numbers and short arrays.
  def checking(&rules)
    grammar do
      class_eval(&rules)
      define_method(:even?) { |text| text.to_i.even? }
      define_method(:short?) { |items| items.size <= 2 ? items : nil }
      private :even?, :short?
    end
  end

  EVEN = "an even number"

  def test_check_accepts_or_rejects_the_value
    g = checking { rule(:top) { seq(match(/\d+/).check(:even?, EVEN).as(:n), str("!")) } }
    assert_equal({ n: "42" }, g.parse!("42!"))
    assert_pattern { g.parse("41!") => Birman::Failure(pos: 0, expected: [EVEN], committed: false) }

    g = checking { rule(:top) { seq(match(/\d+/).as(:n).check(:even?, EVEN), str("!")) } }
    assert_equal({ n: "42" }, g.parse!("42!"), "the name passes through")

    g = checking { rule(:top) { str("a").rep.check(:short?, "at most two") } }
    assert_equal %w[a a], g.parse!("aa"), "the value is the inner one, not the predicate's"
    assert_pattern { g.parse("aaa") => Birman::Failure(pos: 0, expected: ["at most two"]) }
  end

  def test_check_drops_inner_diagnostics_when_it_rejects
    g = checking { rule(:top) { str("a").rep.check(:short?, "at most two") >> str("b") } }
    assert_pattern { g.parse("aaab") => Birman::Failure(pos: 0, expected: ["at most two"]) }
    assert_pattern { g.parse("aac") => Birman::Failure(pos: 2, expected: ['"a"', '"b"']) }
  end

  def test_a_later_alternative_that_gets_further_owns_the_error
    g = checking do
      rule(:top) { either(match(/\d+/).check(:even?, EVEN) >> str("!"), str("41") >> str("?")) }
    end
    assert_pattern { g.parse("41!") => Birman::Failure(pos: 2, expected: ['"?"'], committed: false) }

    g = checking { rule(:top) { either(match(/\d+/).check(:even?, EVEN), str("x")) } }
    assert_pattern { g.parse("41") => Birman::Failure(pos: 0, expected: [EVEN, '"x"']) }
  end

  def test_a_committed_check_stops_the_parse_at_its_start
    g = checking { rule(:top) { either(str("n=") > match(/\d+/).check(:even?, EVEN), match(/.*/)) } }
    assert_equal %w[n= 42], g.parse!("n=42")
    assert_pattern { g.parse("n=41") => Birman::Failure(pos: 2, expected: [EVEN], committed: true) }
  end

  def test_present_then_check_commits_to_the_check
    g = checking do
      rule(:top) { either(match(/\d+/).present > match(/\d+/).check(:even?, EVEN), match(/.*/)) }
    end
    assert_equal [nil, "42"], g.parse!("42")
    assert_equal "x", g.parse!("x")
    assert_pattern { g.parse("41") => Birman::Failure(pos: 0, expected: [EVEN], committed: true) }
  end

  def test_checks_inside_lookaheads_stay_inside
    g = checking { rule(:top) { match(/\d+/).check(:even?, EVEN).absent >> str("x") } }
    assert_pattern { g.parse("41") => Birman::Failure(pos: 0, expected: ['"x"']) }

    g = checking { rule(:top) { (str("n") > match(/\d+/).check(:even?, EVEN)).absent >> match(/.*/) } }
    assert_equal [nil, "n41"], g.parse!("n41")

    g = checking { rule(:top) { (str("n") > match(/\d+/).check(:even?, EVEN)).present >> match(/.*/) } }
    assert_pattern { g.parse("n41") => Birman::Failure(pos: 0, committed: false) }

    g = checking { rule(:top) { (str("n") > match(/\d+/).check(:even?, EVEN)) & match(/.*/) } }
    assert_pattern { g.parse("n41") => Birman::Failure(pos: 0, committed: false) }
  end

  def test_an_outer_label_replaces_the_checks_label
    g = checking { rule(:top) { match(/\d+/).check(:even?, EVEN).label("count") } }
    assert_pattern { g.parse("41") => Birman::Failure(pos: 0, expected: ["count"]) }
  end

  def test_a_checked_rule_reached_twice_reports_the_same_failure
    g = checking do
      rule(:top) { either(even >> str("!"), even >> str("?")) }
      rule(:even) { match(/\d+/).check(:even?, EVEN) }
    end
    once = checking { rule(:top) { match(/\d+/).check(:even?, EVEN) >> str("!") } }
    assert_equal once.parse("41").expected, g.parse("41").expected
    assert_pattern { g.parse("41") => Birman::Failure(pos: 0, expected: [EVEN]) }
  end

  def test_checks_in_rep_and_maybe_end_the_loop_or_give_nil
    g = checking { rule(:top) { seq(match(/\d/).check(:even?, EVEN).rep, match(/\d*/)) } }
    assert_equal [%w[2 4], "56"], g.parse!("2456")

    g = checking { rule(:top) { seq(match(/\d/).check(:even?, EVEN).maybe, match(/\d*/)) } }
    assert_equal [nil, "3"], g.parse!("3")
  end

  def test_check_is_left_out_of_ebnf
    g = checking { rule(:top) { match(/\d+/).check(:even?, EVEN) } }
    assert_equal [:check, EVEN, [:pat, "/\\d+/"]], g.to_ast[:top]
    assert_equal "top = /\\d+/ ;", reachable_ebnf(g)
  end

  def test_library_rules_use_no_blocks
    g = grammar do
      include Birman::Rules::Comments
      include Birman::Rules::Numbers
      include Birman::Rules::Strings
      include Birman::Rules::Identifiers

      ignore :spacing
      keywords "if"
      rule(:top) do
        seq(number, string, identifier, keyword("if"), one_of("on" => true),
            sep_by(match(/\d/), ","), str("z").maybe)
      end
    end
    assert_empty matchers_in(g).grep(Birman::Map)
    assert_empty matchers_in(Calc::Grammar).grep(Birman::Map)
  end

  def test_only_makes_one_part_the_value_of_a_seq
    g = grammar do
      ignore :spacing
      rule(:top) { seq("[", commit, only(sep_by(match(/\d/), ",")), "]") }
    end
    assert_equal %w[1 2], g.parse!("[1, 2]")
    assert g.parse("[1, x]").committed, "commit still applies"
    assert_equal 'top     = "[" ~ (/\d/ ("," /\d/)*)? "]" ;', g.to_ebnf.lines.first.chomp
  end

  def test_only_passes_its_name_to_the_enclosing_seq
    g = grammar { rule(:top) { seq("f", seq("(", only(match(/\d/).as(:arg)), ")")) } }
    assert_equal({ arg: "1" }, g.parse!("f(1)"))
  end

  def test_only_is_used_once_inside_seq_without_other_names
    assert_raises(ArgumentError) { grammar { rule(:top) { seq(only("a"), only("b")) } }.parse("ab") }
    assert_raises(ArgumentError) { grammar { rule(:top) { seq(only("a"), match(/b/).as(:b)) } }.parse("ab") }
    error = assert_raises(ArgumentError) { grammar { rule(:top) { only("a") } }.parse("a") }
    assert_match(/inside seq/, error.message)
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

  # Regexps raise on invalid UTF-8, so it's a Failure before any rule
  # runs, at the first bad byte. Everything before that byte is valid,
  # so line and column count characters as usual.
  def test_invalid_utf8_is_a_failure_not_a_crash
    g = grammar { rule(:top) { match(/[^\n]*\n/).rep } }
    input = "ok\nab\xE3\x81c\xFF\n"
    failure = g.parse(input)
    assert_equal "invalid UTF-8", failure.reason
    assert_equal [5, 2, 3], [failure.pos, failure.line, failure.column]
    refute failure.committed
    assert_empty failure.expected

    error = assert_raises(Birman::ParseError) { g.parse!(input) }
    assert_match(/\Aline 2, column 3: invalid UTF-8\n  ab.*\n    \^\z/, error.message.b)
  end

  def test_invalid_input_in_other_encodings_names_the_encoding
    g = grammar { rule(:top) { match(/\w*/) } }
    assert_equal "invalid US-ASCII", g.parse("a\xFF".dup.force_encoding("US-ASCII")).reason
    assert_nil g.parse("\xFF".b).reason, "binary input is never invalid"
  end

  def test_left_recursion_is_reported_by_rule_name
    g = grammar do
      rule(:top) { either(seq(top, "+"), seq(sum, "-"), "1") }
      rule(:sum) { either(seq(sum, "*"), seq(top, "/"), "1") }
    end
    error = assert_raises(ArgumentError) { g.parse("1+1") }
    assert_match(/left recursion.*:top -> :top; :sum -> :sum/, error.message)

    g = grammar do
      rule(:top) { seq(other, "!") }
      rule(:other) { top }
    end
    error = assert_raises(ArgumentError) { g.parse("x!") }
    assert_match(/rules :top and :other, which/, error.message)
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

    base = grammar do
      rule(:top) { greeting }
      rule(:greeting) { str("hello") }
    end
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

  def test_an_overriding_rule_calls_the_included_rule_with_super
    g = Class.new do
      include Birman::Grammar
      include Birman::Rules::Numbers

      root :number
      rule(:number) { seq(super(), "..", super()) }
    end
    assert_equal [1, "..", 5], g.parse!("1..5")
    assert_equal [1.5, "..", 2.5], g.parse!("1.5..2.5")
    assert g.parse("1").failure?
  end

  # A rule is a method made with define_method, which can't pass its
  # arguments on implicitly: Ruby raises RuntimeError on a bare super.
  def test_a_bare_super_in_a_rule_says_to_write_super_with_parentheses
    g = Class.new do
      include Birman::Grammar
      include Birman::Rules::Numbers

      root :number
      rule(:number) { seq(super, "..", super) }
    end
    error = assert_raises(ArgumentError) { g.parse("1..5") }
    assert_equal "rule :number calls super without parentheses, which a rule can't, since rules are methods " \
                 "made with define_method; write super() to call the rule it overrides", error.message
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

  def test_to_ast_lists_reachable_rules_in_order_then_the_rest
    g = grammar do
      rule(:top)    { item.rep }
      rule(:item)   { str("x") | unused_by_top }
      rule(:unused_by_top) { str("y") }
      rule(:orphan) { str("z") }
    end

    assert_equal %i[top item unused_by_top spacing orphan], g.to_ast.keys
    assert_equal [:rep, 0, nil, %i[ref item]], g.to_ast[:top]
  end

  # A lexeme runs the ignore rule after its token. A literal is one too,
  # but its text is consumed first, so it's marked only when empty.
  def test_to_ast_marks_lexeme_rules_and_empty_literals
    g = grammar do
      rule(:top) { seq("", "let", num) }
      lexeme(:num) { match(/\d+/) }
    end
    assert_equal [:seq, nil, [[:lexeme, [:str, ""]], [:str, "let"], %i[ref num]]], g.to_ast[:top]
    assert_equal [:lexeme, [:pat, "/\\d+/"]], g.to_ast[:num]
    assert_equal "top = \"\" \"let\" num ;\nnum = /\\d+/ ;", reachable_ebnf(g)
  end

  def test_ebnf
    g = grammar do
      rule(:top)  { (str("let") > name >> str("=").maybe) | name.rep(1) }
      rule(:name) { match(/[a-z]+/).absent.absent }
    end

    assert_equal <<~EBNF.chomp, g.to_ebnf
      top  = "let" ~ name "="? / name+ ;
      name = !(!/[a-z]+/) ;

      spacing = /\\s*/ ;
    EBNF
  end

  # --- Nodes ---

  Pair = Birman.node(:left, :right)
  Leaf = Birman.node(:value)
  Empty = Birman.node

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

  # The position after a lexeme's spacing remembers where the token
  # ended, which is before an empty match made there, not inside it.
  def test_an_empty_node_after_a_lexeme_has_an_empty_span_there
    g = grammar do
      ignore :spacing
      lexeme(:num) { match(/\d+/) }
      rule(:top) { seq(num, seq.to(Empty)) }
    end
    _, empty = g.parse!("1   ")
    assert_equal ["", 4, 4], [empty.span.text, empty.span.from, empty.span.to]
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

  def test_nodes_with_no_fields_drop_the_value
    g = Class.new do
      include Birman::Grammar

      const_set(:Empty, node)
      root :top
      rule(:top) { seq("(", ")").to(self.class::Empty) }
    end

    empty = g.parse!("()")
    assert_equal g::Empty.new, empty
    assert_equal "()", empty.span.text
    assert_equal "(Empty)", empty.inspect
    assert_equal "()", empty.with.span.text
    matched = empty in [] # as `in Empty[]` does, with a constant to name it
    assert matched
    assert_empty empty.to_h
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

  def test_a_name_used_twice_in_a_seq_raises
    g = grammar { rule(:top) { seq(str("a").as(:x), str("b").as(:x)) } }
    error = assert_raises(ArgumentError) { g.parse("ab") }
    assert_match(/:x/, error.message)
  end

  def test_either_passes_on_a_name_all_its_alternatives_share
    g = grammar { rule(:top) { seq(either(str("a").as(:x), str("b").as(:x)), str("c").as(:y)) } }
    assert_equal({ x: "b", y: "c" }, g.parse!("bc"))

    g = grammar { rule(:top) { seq(either(str("a").as(:x), str("b").as(:w)), str("c").as(:y)) } }
    assert_equal({ y: "c" }, g.parse!("bc"), "alternatives named differently pass on no name")

    g = grammar { rule(:top) { seq(either(str("a").as(:x), str("b").as(:x)), str("c").as(:x)) } }
    assert_raises(ArgumentError) { g.parse("ac") }
  end

  def test_a_nested_seq_whose_names_would_be_dropped_raises
    error = assert_raises(ArgumentError) do
      grammar { rule(:top) { seq(seq(str("a").as(:x), str("b").as(:y)), str("c").as(:z)) } }.parse("abc")
    end
    assert_match(/:x, :y/, error.message)

    g = grammar { rule(:top) { seq(seq(str("a").as(:x)).label("ax"), str("c").as(:z)) } }
    assert_raises(ArgumentError, "names are seen through labels") { g.parse("ac") }

    g = grammar { rule(:top) { seq(str("[").as(:open), only(seq(str("a").as(:x))), "]") } }
    assert_raises(ArgumentError) { g.parse("[a]") }

    [
      seq_of_names.maybe, seq_of_names.quiet, Birman::Str.new("a").present & seq_of_names,
      Birman::Choice.new([seq_of_names, Birman::Str.new("b")]), Birman::Pat.new(/(?<x>a)b/).captures
    ].each do |part|
      g = grammar { rule(:top) { seq(part, str("c").as(:z)) } }
      assert_raises(ArgumentError, part.inspect) { g.parse("abc") }
    end
  end

  def test_a_nested_seq_inside_rep_whose_names_would_be_dropped_raises
    g = grammar { rule(:top) { seq(match(/\d/).as(:n), seq(",", match(/\d/).as(:n)).rep) } }
    error = assert_raises(ArgumentError) { g.parse("1,2,3") }
    assert_equal "a seq inside a seq would lose its names :n: list its parts in the outer seq, or name it with .as",
                 error.message

    g = grammar { rule(:top) { seq(match(/\d/).as(:a), seq(",", match(/\d/).as(:b)).rep) } }
    error = assert_raises(ArgumentError) { g.parse("1,2,3") }
    assert_match(/lose its names :b:/, error.message)

    [
      seq_of_names.rep.maybe, Birman::Choice.new([seq_of_names.rep, Birman::Str.new("z")]),
      seq_of_names.rep(1).label("pairs"), seq_of_names.maybe.rep,
      Birman::SepBy.new(item: seq_of_names, sep: Birman::Str.new(","))
    ].each do |part|
      g = grammar { rule(:top) { seq(part, str("c").as(:z)) } }
      error = assert_raises(ArgumentError, part.inspect) { g.parse("abc") }
      assert_match(/lose its names :x, :y/, error.message)
    end
  end

  def test_a_rep_keeps_its_names_where_nothing_drops_them
    g = grammar { rule(:top) { seq(match(/\d/).as(:a), seq(",", match(/\d/).as(:b)).rep.as(:rest)) } }
    assert_equal({ a: "1", rest: [{ b: "2" }, { b: "3" }] }, g.parse!("1,2,3"))

    g = grammar { rule(:top) { seq(match(/\d/).as(:a), seq(",", only(match(/\d/).as(:rest))).rep) } }
    assert_equal({ a: "1", rest: %w[2 3] }, g.parse!("1,2,3"))

    g = grammar { rule(:top) { seq(match(/\d/), seq(",", match(/\d/).as(:b)).rep) } }
    assert_equal ["1", [{ b: "2" }, { b: "3" }]], g.parse!("1,2,3")
  end

  def test_a_nested_seq_keeps_its_names_where_nothing_drops_them
    g = grammar { rule(:top) { seq(seq(str("a").as(:x), str("b").as(:y)).as(:p), str("c").as(:z)) } }
    assert_equal({ p: { x: "a", y: "b" }, z: "c" }, g.parse!("abc"))

    g = grammar { rule(:top) { seq(seq(str("a").as(:x), str("b").as(:y)), str("c")) } }
    assert_equal [{ x: "a", y: "b" }, "c"], g.parse!("abc")

    g = grammar do
      rule(:top) { seq(pair, str("c").as(:z)) }
      rule(:pair) { seq(str("a").as(:x), str("b").as(:y)) }
    end
    assert_equal({ z: "c" }, g.parse!("abc"), "a rule's names stay inside the rule")
  end

  def test_a_chain_of_sequence_operators_is_one_seq
    a, b, c = %w[a b c].map { Birman::Str.new(_1) }
    assert_equal Birman::Seq.new([a, b, c]), (a >> b) >> c
    assert_equal Birman::Seq.new([a, b, c]), a >> (b >> c)

    x, y, z = %w[a b c].zip(%i[x y z]).map { |text, key| Birman::Str.new(text).as(key) }
    [(x >> y) >> z, x >> (y >> z), x > (y >> z), (x >> y) > z].each do |m|
      assert_equal({ x: "a", y: "b", z: "c" }, grammar { rule(:top) { m } }.parse!("abc"), m.inspect)
    end

    g = grammar { rule(:top) { str("a") > str("b").as(:y) >> str("c").as(:z) } }
    assert_equal({ y: "b", z: "c" }, g.parse!("abc"))
    assert g.parse("abx").committed
  end

  def test_copies_of_a_seq_compose_as_it_does
    a, b, c = %w[a b c].map { Birman::Str.new(_1) }
    chain = a >> b
    [chain.with(commit_at: nil), chain.dup, chain.clone].each do |copy|
      assert_equal Birman::Seq.new([a, b, c]), copy >> c
      assert_equal 3, (copy >> c).parts.size, "#{copy.inspect} stays open"
    end
    assert_equal 2, (Birman::Seq.new([a, b]).with(commit_at: nil) >> c).parts.size, "and a closed one closed"
    refute chain.with(open: false).open?
    assert_same chain, chain.with
  end

  def test_sequence_operators_keep_a_seq_built_otherwise_whole
    g = grammar { rule(:top) { seq(str("a"), str("b")) >> str("c") } }
    assert_equal [%w[a b], "c"], g.parse!("abc"), "the same as seq(seq(a, b), c)"

    g = grammar { rule(:top) { (seq(str("a"), commit, str("b")) >> str("c")) | str("abd") } }
    assert_equal "abd", g.parse!("abd"), "the commit stays inside the left seq"

    g = grammar { rule(:top) { (str("a") >> seq(str("b"), commit, str("c"))) | str("ad") } }
    assert_equal "ad", g.parse!("ad"), "and inside the right one"

    g = grammar { rule(:top) { (str("a") > str("b")) >> str("c") } }
    assert_equal [%w[a b], "c"], g.parse!("abc"), "a > b is closed by its commit"

    g = grammar { rule(:top) { seq("[", only(match(/\d/)), "]") >> str("y") } }
    assert_equal %w[1 y], g.parse!("[1]y"), "only(...) still picks within its own seq"

    pair = seq_of_names
    assert_equal [{ x: "a", y: "b" }, "c"], grammar { rule(:top) { pair >> str("c") } }.parse!("abc")
    assert_equal grammar { rule(:top) { seq(pair, commit, str("c")) } }.parse!("abc"),
                 grammar { rule(:top) { pair > str("c") } }.parse!("abc")
  end

  def test_sequence_operators_raise_where_a_closed_seq_would_lose_names
    x, y, z = %w[a b c].map { Birman::Str.new(_1).as(_1.to_sym) }
    assert_raises(ArgumentError) { seq_of_names >> z }
    assert_raises(ArgumentError) { x >> seq_of_names }
    assert_raises(ArgumentError) { (x > y) >> z }
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

    assert_equal %w[go 5], g.parse!("go 5")
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

  def test_bare_strings_are_literals_everywhere
    g = grammar do
      ignore :spacing
      rule(:top)  { seq(semi, "x") }
      rule(:semi) { ";" }
    end
    assert_equal [";", "x"], g.parse!("; x"), "as a rule body"

    g = grammar do
      ignore :spacing
      rule(:top) { (either("a") >> "b") | "c" }
    end
    assert_equal %w[a b], g.parse!("a b "), "after >>"
    assert_equal "c", g.parse!("c "), "after |"

    g = grammar { rule(:top) { match(/x/) >> "if" >> match(/\w*/) } }
    assert g.parse("xiffy").failure?, "word-like literals are keywords after >> too"
  end

  def test_word_literals_are_keywords
    g = grammar { rule(:top) { seq("if", match(/\w+/)) } }
    assert g.parse("ifx").failure?
  end

  def test_nocase_matches_any_case_and_gives_the_literal_as_written
    g = grammar do
      ignore :spacing
      rule(:top) { seq(nocase("select"), match(/\w+/)) }
    end
    assert_equal %w[select x], g.parse!("SELECT x")
    assert_equal %w[select x], g.parse!("Select  x")
    assert_equal %w[select x], g.parse!("select x")
  end

  def test_nocase_word_literals_are_keywords
    g = grammar { rule(:top) { seq(nocase("if"), match(/\w*/)) } }
    assert g.parse("IFx").failure?, "a word-like nocase literal needs a boundary"
    assert_equal ["if", ""], g.parse!("If")

    g = grammar { rule(:top) { seq(nocase("<="), match(/\w+/)) } }
    assert_equal ["<=", "x"], g.parse!("<=x"), "punctuation needs no boundary"
  end

  def test_nocase_shows_in_to_ast_and_ebnf_with_an_i_suffix
    g = grammar do
      ignore :spacing
      rule(:top) { seq(nocase("select"), nocase(""), "from") }
    end
    assert_equal [:seq, nil, [[:istr, "select"], [:lexeme, [:istr, ""]], [:str, "from"]]], g.to_ast[:top]
    assert_equal 'top     = "select"i ""i "from" ;', g.to_ebnf.lines.first.chomp
  end

  def test_nocase_errors_say_the_literal_is_case_insensitive
    g = grammar { rule(:top) { either(nocase("select"), "from") } }
    f = g.parse("x")
    assert_equal ['"select"i', '"from"'], f.expected
    assert_equal 'line 1, column 1: expected "select"i or "from", found "x"', f.message.lines.first.chomp
    g = grammar { rule(:top) { nocase("select") } }
    assert_equal ['"select"i'], g.parse("selectx").expected, "the boundary failing is the literal failing"
  end

  # Case folding can change byte length (ß folds to SS), so the match
  # length comes from the regexp, not from the literal.
  def test_nocase_is_byte_correct_on_multibyte_text
    g = grammar { rule(:top) { seq(nocase("straße"), match(/\w+/)) } }
    assert_equal %w[straße x], g.parse!("STRASSEx")
    assert_equal %w[straße x], g.parse!("Straßex")
    assert_equal 'line 1, column 8: expected /\w+/, found end of input', g.parse("STRASSE").message.lines.first.chomp

    g = grammar { rule(:top) { seq(nocase("école"), str("!")) } }
    assert_equal %w[école !], g.parse!("ÉCOLE!")
    assert_equal 'line 1, column 6: expected "!", found "?"', g.parse("École?").message.lines.first.chomp
  end

  def test_nocase_works_wherever_a_matcher_goes
    g = grammar do
      ignore :spacing
      rule(:top) { seq(one_of(nocase("asc") => :up, nocase("desc") => :down), nulls) }
      rule(:nulls) { either(nocase("nulls"), "x") >> nocase("first") }
    end
    assert_equal [:up, %w[nulls first]], g.parse!("ASC Nulls FIRST")
    assert_equal [:down, %w[x first]], g.parse!("desc x first")
    assert_equal %w[a b], Birman.parse!(Birman.nocase("a") >> Birman.nocase("b"), "A B", ignore: /\s*/)
  end

  def test_nocase_needs_a_string
    error = assert_raises(ArgumentError) { Birman.nocase(:select) }
    assert_equal "nocase needs a String, got :select", error.message
    assert_raises(ArgumentError) { Birman.nocase(nil) }
  end

  def test_nocase_text_is_matched_literally_not_as_a_pattern
    g = grammar { rule(:top) { either(nocase("a.b"), nocase("(?x)"), nocase("c d"), nocase("#"), nocase("\\")) } }
    assert_equal "a.b", g.parse!("A.B")
    assert g.parse("axb").failure?
    assert_equal "(?x)", g.parse!("(?X)")
    assert_equal "c d", g.parse!("C D")
    assert_equal "#", g.parse!("#")
    assert_equal "\\", g.parse!("\\")
  end

  # Word-like means ASCII letters, digits and _, as for a literal: a
  # non-ASCII nocase literal gets no boundary, and the boundary is ASCII.
  def test_nocase_boundary_is_ascii_like_a_literals
    g = grammar { rule(:top) { seq(nocase("straße"), match(/\w*/)) } }
    assert_equal %w[straße N], g.parse!("STRASSEN")
    g = grammar { rule(:top) { seq(nocase("is"), match(/.*/)) } }
    assert_equal %w[is é], g.parse!("ISé")
    assert g.parse("ISe").failure?
  end

  def test_nocase_in_a_committed_seq_and_in_left_recursion
    g = grammar do
      ignore :spacing
      rule(:top) { seq(nocase("select"), commit, nocase("from")) }
    end
    f = g.parse("select x")
    assert f.committed
    assert_equal ['"from"i'], f.expected

    g = grammar do
      ignore :spacing
      rule(:top) { either(seq(top, nocase("or"), term), term) }
      lexeme(:term) { match(/[a-z]+/).label("term") }
    end
    assert_equal [%w[a or b], "or", "c"], g.parse!("a OR b Or c")
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

  def test_a_lexeme_built_outside_a_grammar_skips_the_grammars_spacing
    eq = Object.new.extend(Birman::Combinators).literal_matcher("=")
    g = grammar do
      ignore :spacing
      rule(:top) { seq(match(/\w+/), eq, match(/\w+/)) }
    end
    assert_equal %w[a = b], g.parse!("a=  b")
  end

  def test_a_lexeme_follows_the_ignore_rule_of_the_grammar_running_it
    tok = grammar do
      ignore :spacing
      lexeme(:tok) { match(/\d+/) }
    end.new.matcher_for(:tok)
    g = grammar do
      ignore :commas
      rule(:commas) { match(/,*/) }
      rule(:top) { tok.rep }
    end
    assert_equal %w[1 2 3], g.parse!("1,,2,3")
    assert g.parse("1 2").failure?, "spacing was the other grammar's ignore rule"
  end

  def test_a_subclass_sees_its_parents_ignore_change_after_parsing
    parent = grammar do
      ignore :spacing
      rule(:top) { seq("+", "-") }
    end
    child = Class.new(parent)
    assert_equal %w[+ -], child.parse!("+ -")

    parent.ignore nil
    assert child.parse("+ -").failure?
    assert_equal %w[+ -], child.parse!("+-")
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
    %i[match str keywords token].each do |name|
      error = assert_raises(ArgumentError) { grammar { rule(name) { str("x") } } }
      assert_match(/rule :#{name} would replace Birman::.*##{name}, which Birman relies on/, error.message)
    end
    %i[send class freeze].each do |name|
      error = assert_raises(ArgumentError) { grammar { rule(name) { str("x") } } }
      assert_match(/rule :#{name} would replace Object##{name}, a method every Ruby object has/, error.message)
    end
  end

  # Every private method Birman gives a grammar, so a new helper is
  # either reserved or fails here.
  def test_rule_names_cannot_replace_private_methods_birman_defines
    rule_modules = Birman::Rules.constants.map { Birman::Rules.const_get(_1) }
    birman = grammar { include(*rule_modules) }.ancestors.select { _1.name&.start_with?("Birman::") }
    owned = birman.flat_map do |mod|
      mod.private_instance_methods(false).grep_v(/\A__rule_/).map { [mod, _1] }
    end
    assert_includes owned, [Birman::Rules::Strings, :decode_escape]
    owned.each do |mod, name|
      error = assert_raises(ArgumentError, "#{mod}##{name}") do
        grammar do
          include(*rule_modules)

          rule(name) { str("x") }
        end
      end
      assert_match(/would replace #{mod}##{name}, which Birman relies on/, error.message)
    end
  end

  def test_rule_names_cannot_replace_the_grammars_own_public_methods
    error = assert_raises(ArgumentError) do
      grammar do
        def helper = "h" # rubocop:disable Lint/NestedMethodDefinition
        rule(:helper) { str("x") }
      end
    end
    assert_match(/rule :helper would replace .*#helper, a method of this grammar/, error.message)
  end

  def test_rule_names_can_reuse_private_kernel_methods_and_redefine_rules
    g = grammar do
      rule(:top)   { print }
      rule(:print) { str("a") }
      rule(:print) { str("b") }
    end
    assert_equal "b", g.parse!("b")
  end

  # A grammar's own private helpers are its to replace, as in any Ruby
  # class; so are rules from Birman's rule modules.
  def test_rule_names_can_replace_the_grammars_own_private_helpers_and_birmans_rules
    g = grammar do
      include Birman::Rules::Strings

      private def helper = "h" # rubocop:disable Lint/NestedMethodDefinition

      rule(:top)    { seq(helper, string) }
      rule(:helper) { str("a") }
      rule(:string) { str("b") }
    end
    assert_equal %w[a b], g.parse!("ab")
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

  def test_class_level_parses_build_each_rule_once
    builds = 0
    g = grammar do
      rule(:top) do
        builds += 1
        str("a")
      end
    end
    3.times { g.parse!("a") }
    assert_equal 1, builds

    g.class_eval { rule(:top) { str("b") } }
    assert_equal "b", g.parse!("b"), "redefining a rule takes effect"
  end

  def test_subclasses_can_clear_inherited_settings
    parent = grammar do
      ignore :spacing
      keywords "if"
    end
    child = Class.new(parent) do
      ignore nil
      keywords nil
    end
    assert_equal [nil, []], [child.ignore, child.keywords]
    assert_equal [:spacing, ["if"]], [parent.ignore, parent.keywords]
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
      "let = 4" => "expected identifier",
      "print (1 + 2" => 'expected operator or ")"',
      "print 1 +" => "expected expression",
      "let if = 1" => "expected identifier"
    }.each do |source, message|
      assert_includes Calc::Grammar.parse(source).message, message, source
    end
  end
end
