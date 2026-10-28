# frozen_string_literal: true

require "test_helper"

# .text and .spanned: the source text, or the value with its span, of
# any sub-match, without wrapping it in a node.
class SpannedValuesTest < Minitest::Test
  Leaf = Birman.node(:value)

  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace

      self.root(root)
      class_eval(&rules)
    end
  end

  # --- .text ---

  def test_text_is_the_source_text_the_matcher_consumed
    g = grammar { rule(:top) { seq(match(/\d+/).map(:to_i), ".", match(/\d+/).map(:to_i)).text } }
    assert_equal "3.14", g.parse!("3.14")

    g = grammar { rule(:top) { seq(match(/\d+/), ".", match(/\d+/)).text.map(:to_f) } }
    assert_in_delta 3.14, g.parse!("3.14")
  end

  def test_text_stops_before_trailing_ignored_spacing_but_keeps_spacing_inside
    g = grammar do
      ignore :spacing
      lexeme(:name) { match(/\w+/) }
      rule(:top) { seq(seq("let", name).text.as(:head), "=") }
    end
    assert_equal({ head: "let  x" }, g.parse!("let  x   ="))
    assert_equal({ head: "let  x" }, g.parse!("  let  x   =  "))
  end

  def test_text_counts_in_bytes_of_the_input_as_written
    g = grammar { rule(:top) { seq(match(/h/), match(/é/)).text >> match(/.*/) } }
    assert_equal %w[hé llo], g.parse!("héllo")
  end

  def test_text_still_runs_the_actions_inside_it
    g = grammar do
      rule(:top) { match(/\d/).action(:odd).text }

      private

      def odd(text)
        large_integer(text).odd? ? text : raise(ArgumentError, "#{text} is even")
      end # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_equal "1", g.parse!("1")
    error = assert_raises(ArgumentError) { g.parse("2") }
    assert_equal "2 is even", error.message
  end

  # Lit and Nocase once had a member named text, whose reader hid this.
  def test_text_of_literals_is_the_input_as_typed
    g = grammar do
      ignore :spacing
      rule(:top) { seq(lit("let").text.as(:a), nocase("sel").text.as(:b)) }
    end
    assert_equal({ a: "let", b: "SEL" }, g.parse!("let SEL  "))
  end

  def test_text_composes_with_as_in_either_order
    g = grammar { rule(:top) { seq(match(/a+/).rep.as(:x).text, match(/b+/).text.as(:y)) } }
    assert_equal({ x: "aa", y: "bb" }, g.parse!("aabb"))
  end

  def test_text_of_a_rep_covers_every_repetition
    g = grammar { rule(:top) { match(/\d/).map(:to_i).rep(1).text } }
    assert_equal "123", g.parse!("123")
  end

  def test_text_of_a_maybe_that_matched_nothing_is_empty
    g = grammar { rule(:top) { seq(str("a"), str("b").maybe.text) } }
    assert_equal ["a", ""], g.parse!("a")
    assert_equal %w[a b], g.parse!("ab")
  end

  def test_text_of_an_either_is_the_winning_alternatives_text
    g = grammar { rule(:top) { either(seq(str("a"), str("b")), str("c")).text } }
    assert_equal "ab", g.parse!("ab")
    assert_equal "c", g.parse!("c")
  end

  # --- .spanned ---

  def test_spanned_pairs_the_value_with_its_span
    g = grammar do
      ignore :spacing
      lexeme(:num) { match(/\d+/).map(:to_i) }
      rule(:top) { seq("[", only(num.spanned), "]") }
    end

    spanned = g.parse!("[ 42 ]")
    assert_kind_of Birman::Spanned, spanned
    assert_equal 42, spanned.value
    assert_kind_of Birman::Span, spanned.span
    assert_equal ["42", 2, 4, 1, 3], [spanned.span.text, spanned.span.from, spanned.span.to,
                                      spanned.span.line, spanned.span.column]
    assert_equal Birman::Spanned.new(value: 42, span: Birman::Span.new("[ 42 ]", 2, 4)), spanned
  end

  def test_spanned_is_pattern_matchable
    spanned = Birman.parse!(Birman.match(/\d+/).map(:to_i).spanned, "42")
    assert_pattern { spanned => Birman::Spanned(value: 42, span: Birman::Span(byte_from: 0, byte_to: 2)) }
    assert_pattern { spanned => Birman::Spanned[42, Birman::Span["42", 0, 2]] }
    assert_pattern { spanned => { value: 42, span: Birman::Span } }
  end

  def test_spanned_composes_with_as_in_either_order
    g = grammar { rule(:top) { seq(match(/a+/).as(:x).spanned, match(/b+/).spanned.as(:y)) } }
    value = g.parse!("aabb")
    assert_equal %i[x y], value.keys
    assert_equal %w[aa aa], [value[:x].value, value[:x].span.text]
    assert_equal %w[bb bb], [value[:y].value, value[:y].span.text]
  end

  def test_spanned_of_a_rep_covers_every_repetition
    g = grammar do
      ignore :spacing
      lexeme(:digit) { match(/\d/).map(:to_i) }
      rule(:top) { seq("(", only(digit.rep.spanned), ")") }
    end
    spanned = g.parse!("( 1 2 3 )")
    assert_equal [1, 2, 3], spanned.value
    assert_equal "1 2 3", spanned.span.text
  end

  def test_spanned_of_a_maybe_that_matched_nothing_is_nil_with_an_empty_span_there
    g = grammar { rule(:top) { seq("a", str("b").maybe.spanned) } }
    _, spanned = g.parse!("a")
    assert_nil spanned.value
    assert_equal ["", 1, 1], [spanned.span.text, spanned.span.from, spanned.span.to]

    g = grammar { rule(:top) { seq("a", str("b").spanned.maybe) } }
    assert_equal ["a", nil], g.parse!("a")
  end

  def test_spanned_of_an_either_spans_the_winning_alternative
    g = grammar { rule(:top) { seq(match(/x*/), either(seq(str("a"), str("b")), str("c")).spanned) } }
    _, spanned = g.parse!("xxab")
    assert_equal [%w[a b], "ab", 2], [spanned.value, spanned.span.text, spanned.span.from]
  end

  def test_spanned_over_a_node_keeps_the_nodes_own_span
    g = grammar do
      ignore :spacing
      lexeme(:num) { match(/\d+/).map(:to_i) }
      rule(:top) { seq("=", only(num.to(Leaf).spanned)) }
    end
    spanned = g.parse!("= 7 ")
    assert_equal Leaf.new(7), spanned.value
    assert_equal spanned.value.span, spanned.span
  end

  # --- Introspection, standalone use, left recursion ---

  def test_text_and_spanned_show_in_to_ast_and_not_in_ebnf
    g = grammar { rule(:top) { seq(match(/a/).text, match(/b/).spanned.as(:b)) } }
    assert_equal [:seq, nil, [[:text, [:pat, "/a/"]], [:spanned, [:pat, "/b/"]]]], g.to_ast[:top]
    assert_equal "top = /a/ /b/ ;\n\nspacing = /\\s*/ ;", g.to_ebnf
  end

  def test_text_and_spanned_work_without_a_grammar
    b = Birman
    assert_equal "1-2", b.parse!(b.seq(b.match(/\d/), "-", b.match(/\d/)).text, "1-2")
    spanned = b.parse!(b.seq("let", b.match(/\w+/).spanned), "let  x", ignore: /\s*/).last
    assert_equal ["x", 5, 6], [spanned.value, spanned.span.from, spanned.span.to]
  end

  def test_left_recursion_is_seen_through_text_and_spanned
    g = grammar(:expr) do
      rule(:expr) { either(seq(expr, "+", num).text, num) }
      rule(:num) { match(/\d/).spanned.map(:value) }
    end
    assert_equal "1+2+3", g.parse!("1+2+3")
  end
end
