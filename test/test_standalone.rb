# frozen_string_literal: true

require "test_helper"

# Matchers built and run without a grammar class: Birman.seq and
# friends, and Birman.parse.
class StandaloneTest < Minitest::Test
  B = Birman

  def test_combinators_are_available_on_birman
    m = B.seq(B.str("a"), B.either(B.str("b"), B.match(/c/)).rep(1))
    assert_equal ["a", %w[b c]], B.parse!(m, "abc")
  end

  def test_combinators_dont_replace_existing_birman_methods
    assert_equal Birman::Nodes, Birman.method(:node).owner
    refute Birman.respond_to?(:literal_matcher), "literal_matcher needs a grammar"
  end

  def test_parse_returns_success_or_failure
    m = B.seq(B.str("a"), B.commit, B.str("b"))
    assert_equal Birman::Success.new(%w[a b]), B.parse(m, "ab")

    failure = B.parse(m, "ax")
    assert_kind_of Birman::Failure, failure
    assert_equal 1, failure.pos
    assert_equal ['"b"'], failure.expected
    assert failure.committed
  end

  def test_parse_requires_the_whole_input
    failure = B.parse(B.str("a"), "ab")
    assert_equal 1, failure.pos
    assert_equal ["end of input"], failure.expected
  end

  def test_parse_accepts_strings_and_regexps_as_matchers
    assert_equal "42", B.parse!(/\d+/, "42")
    assert_equal "a", B.parse!("a", "a")
  end

  def test_bad_input_never_raises
    assert_equal "invalid UTF-8", B.parse(B.str("a"), "a\xff").reason
  end

  def test_parse_bang_raises_a_parse_error_worded_by_the_formatter
    error = assert_raises(Birman::ParseError) { B.parse!(B.str("a"), "b") }
    assert_match(/expected "a"/, error.message)

    error = assert_raises(Birman::ParseError) do
      B.parse!(B.str("a"), "b", formatter: ->(f) { "nope at #{f.pos}" })
    end
    assert_equal "nope at 0", error.message
  end

  def test_literals_skip_the_ignore_matcher
    m = B.seq("let", "x", "=", B.match(/\d+/))
    assert_equal %w[let x = 1], B.parse!(m, "  let x = 1", ignore: /\s*/)
    assert B.parse(m, "let x = 1").failure?, "no ignore, no spacing"
  end

  def test_lexemes_built_outside_a_grammar_skip_the_ignore_matcher
    word = Birman::Lexeme.new(B.match(/\w+/))
    assert_equal %w[a b], B.parse!(B.seq(word, word), "a  b ", ignore: /\s*/)
    assert B.parse(B.seq(word, word), "a b").failure?, "no ignore, no spacing"
  end

  def test_ignore_accepts_any_matcher
    spacing = B.either(B.match(/\s+/), B.match(/#[^\n]*/)).rep
    assert_equal %w[a b], B.parse!(B.seq("a", "b"), "a # one\n b # two", ignore: spacing)
  end

  def test_word_like_literals_are_keywords
    m = B.seq("let", B.match(/\w+/))
    assert_equal %w[let x], B.parse!(m, "let x", ignore: /\s*/)
    assert B.parse(m, "letter", ignore: /\s*/).failure?
  end

  def test_a_rule_reference_raises_before_parsing
    m = B.seq(B.str("a"), Birman::Ref.new(:name)) | B.str("b")
    error = assert_raises(ArgumentError) { B.parse(m, "b") }
    assert_equal "undefined rule :name: a matcher run by Birman.parse can't refer to rules; " \
                 "define them in a grammar class", error.message
  end

  def test_a_rule_reference_in_ignore_raises_too
    error = assert_raises(ArgumentError) { B.parse(B.str("a"), "a", ignore: Birman::Ref.new(:spacing)) }
    assert_match(/undefined rule :spacing/, error.message)
  end

  def test_an_action_or_check_needing_a_grammar_method_raises_before_parsing
    m = B.str("x").action(:shout) | B.str("y")
    error = assert_raises(ArgumentError) { B.parse(m, "y") }
    assert_equal "undefined method :shout for .action: a matcher run by Birman.parse can only use " \
                 "Birman's own methods there; define yours in a grammar class", error.message

    error = assert_raises(ArgumentError) { B.parse(B.match(/\d+/).check(:even?, "even"), "2") }
    assert_match(/undefined method :even\? for \.check/, error.message)
  end

  def test_built_in_grammar_methods_still_work_in_actions
    assert_equal 2**70, B.parse!(B.match(/\d+/).action(:large_integer), (2**70).to_s)
    assert_equal 12, B.parse!(B.match(/\d+/).map(:to_i), "12")
  end

  def test_the_same_settings_reuse_one_grammar
    m = B.seq(B.str("a"), B.str("b"))
    assert_same Birman::Standalone.grammar(m, nil), Birman::Standalone.grammar(B.seq(B.str("a"), B.str("b")), nil)
    refute_same Birman::Standalone.grammar(m, nil), Birman::Standalone.grammar(m, /\s*/)
  end

  def test_case_equality_parses_a_string_with_the_matcher
    date = B.seq(B.match(/\d{4}/), "-", B.match(/\d\d/))
    assert_operator date, :===, "2026-10"
    refute_operator date, :===, "26-10", "a Failure is false"
    refute_operator date, :===, "2026-10-27", "the whole input must match"
  end

  def test_case_equality_works_in_case
    date = B.seq(B.match(/\d{4}/), "-", B.match(/\d\d/))
    word = B.match(/[a-z]+/)
    kind = lambda do |input|
      case input
      when date then :date
      when word then :word
      else :other
      end
    end
    assert_equal :date, kind.call("2026-10")
    assert_equal :word, kind.call("hello")
    assert_equal :other, kind.call("2026-10 hello")
  end

  def test_case_equality_doesnt_skip_spacing_around_bare_strings
    m = B.seq("(", ")")
    assert_operator m, :===, "()"
    refute_operator m, :===, "( )"
  end

  def test_case_equality_is_false_for_input_that_isnt_a_string
    m = B.str("a")
    refute_operator m, :===, nil
    refute_operator m, :===, 1
    refute_operator m, :===, :a
  end

  def test_case_equality_with_a_matcher_is_equality
    m = B.seq(B.str("a"), B.str("b"))
    assert_operator m, :===, B.seq(B.str("a"), B.str("b"))
    refute_operator m, :===, B.seq(B.str("a"), B.str("c"))
    refute_operator B.str("ab"), :===, B.seq(B.str("a"), B.str("b")), "a matcher isn't parsed, even if it would match"
  end

  def test_values_and_nodes_work
    pair = B.node(:key, :value)
    m = B.seq(B.match(/\w+/).as(:key), "=", B.match(/\d+/).map(:to_i).as(:value)).to(pair)
    result = B.parse!(m, " a= 1", ignore: /\s*/)
    assert_equal pair.new(key: "a", value: 1), result
    assert_equal "a= 1", result.span.text
  end

  def test_seq_and_sequence_operators_compose_as_in_a_grammar
    x, y, z = %w[a b c].zip(%i[x y z]).map { |text, key| B.str(text).as(key) }
    assert_equal({ x: "a", y: "b", z: "c" }, B.parse!(x >> (y >> z), "abc"), "a >> chain is one seq")
    assert_equal [%w[a b], "c"], B.parse!(B.seq(B.str("a"), B.str("b")) >> B.str("c"), "abc"), "a seq(...) is one part"
    assert_raises(ArgumentError) { B.seq(x, y) >> z }
    assert_equal "abd", B.parse!((B.seq(B.str("a"), B.commit, B.str("b")) >> B.str("c")) | B.str("abd"), "abd")
  end
end
