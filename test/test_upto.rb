# frozen_string_literal: true

require "test_helper"

# upto(t): everything up to the first place t matches, as text, leaving
# t for whatever comes next. For block comments, raw blocks and heredoc
# bodies, where seq(t.absent, any).rep would try t once per character.
class UptoTest < Minitest::Test
  B = Birman

  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace

      self.root(root)
      class_eval(&rules)
    end
  end

  def comment(terminator)
    grammar { rule(:top) { seq(str("/*"), upto(terminator), str("*/")) } }
  end

  # --- What it matches ---

  def test_value_is_the_text_before_the_terminator_which_is_left_for_the_next_part
    g = comment("*/")
    assert_equal ["/*", " a * b / c ", "*/"], g.parse!("/* a * b / c */")
  end

  def test_it_stops_at_the_first_terminator
    g = grammar { rule(:top) { seq(upto("*/"), str("*/"), match(/.*/m)) } }
    assert_equal [" a ", "*/", " b */"], g.parse!(" a */ b */")
  end

  def test_it_can_match_nothing
    assert_equal ["/*", "", "*/"], comment("*/").parse!("/**/")
    g = grammar { rule(:top) { seq(upto(";").rep, str(";")) } }
    assert_equal [[""], ";"], g.parse!(";")
  end

  def test_every_kind_of_terminator_gives_the_same_match
    terminators = ["*/", B.str("*/"), %r{\*/}, B.match(%r{\*/}), B.lit("*/"), B.either(B.str("*/"), B.str("-->")),
                   B.seq(B.str("*"), B.str("/"))]
    terminators.each do |t|
      g = comment(t)
      assert_equal ["/*", " é * / ", "*/"], g.parse!("/* é * / */"), t.inspect
      assert_equal 11, g.parse("/* é * / */", consume: false).pos, t.inspect
    end
  end

  def test_a_terminator_can_be_a_rule
    g = grammar do
      rule(:top) { seq(upto(stop), stop) }
      rule(:stop) { either(str("END"), str("STOP")) }
    end
    assert_equal ["a b ", "STOP"], g.parse!("a b STOP")
  end

  # A String is raw text, as str's: no keyword boundary, no spacing.
  # A matcher keeps its own meaning.
  def test_a_string_is_raw_text_not_a_literal
    g = grammar do
      ignore :spacing
      rule(:top) { seq(upto("end").as(:body), match(/.*/m).as(:rest)) }
    end
    assert_equal({ body: "", rest: "endless end" }, g.parse!("endless end"))

    g = grammar do
      ignore :spacing
      rule(:top) { seq(upto(keyword("end")).as(:body), match(/.*/m).as(:rest)) }
    end
    assert_equal({ body: "endless ", rest: "end" }, g.parse!("endless end"))
  end

  def test_a_regexp_sees_the_whole_input_so_line_anchors_and_lookbehind_work
    g = grammar { rule(:top) { seq(str("<<EOS\n"), upto(/^EOS$/), str("EOS")) } }
    assert_equal ["<<EOS\n", "a EOS\nb\n", "EOS"], g.parse!("<<EOS\na EOS\nb\nEOS")

    g = grammar { rule(:top) { seq(str("x"), upto(/(?<=x)y/), match(/.*/)) } }
    assert_equal ["x", "", "y"], g.parse!("xy")
    assert_equal %w[x ayx y], g.parse!("xayxy")
  end

  def test_positions_are_characters_with_multibyte_text
    g = grammar { rule(:top) { seq(upto(/→/).spanned, str("→"), upto("→").text) } }
    value = g.parse("añb→cé→d", consume: false)
    assert_equal 6, value.pos
    spanned, _, text = value.value
    assert_equal ["añb", 0, 3], [spanned.value, spanned.span.from, spanned.span.to]
    assert_equal "cé", text
  end

  # It's raw: spacing is skipped only by what comes after it (the
  # literal ";", not str(";")).
  def test_it_skips_no_spacing
    g = grammar do
      ignore :spacing
      rule(:top) { seq(upto(";"), str(";"), upto(";"), ";") }
    end
    assert_equal ["a b ", ";", " c ", ";"], g.parse!("a b ; c ;  ")
    assert_equal ["", ";", "  ", ";"], g.parse!(";  ;")
  end

  def test_a_line_comment_may_end_at_end_of_input
    g = grammar { rule(:top) { seq(str("#"), upto(/\n|\z/)) } }
    assert_equal ["#", " hi"], g.parse!("# hi")
    assert_equal ["#", " hi"], g.parse("# hi\nmore", consume: false).value
  end

  # --- Failure ---

  def test_an_unterminated_match_fails_at_end_of_input_expecting_the_terminator
    ["*/", %r{\*/}, B.lit("*/"), B.either(B.str("*/"), B.str("-->"))].each do |t|
      failure = comment(t).parse("/* é never closed")
      assert_equal 17, failure.pos, t.inspect
      assert_includes failure.message, "found end of input", t.inspect
    end
    assert_equal ['"*/"'], comment("*/").parse("/* x").expected
    assert_equal ["/\\*\\//"], comment(%r{\*/}).parse("/* x").expected
    assert_equal ['"*/"', '"-->"'], comment(B.either(B.str("*/"), B.str("-->"))).parse("/* x").expected
  end

  def test_a_terminator_labelled_is_expected_by_its_label
    failure = comment(B.str("*/").label("end of comment")).parse("/* x")
    assert_equal ["end of comment"], failure.expected
    assert_equal "line 1, column 5: expected end of comment, found end of input", failure.message.lines.first.chomp
  end

  def test_with_a_commit_an_unterminated_comment_stops_the_parse
    g = grammar do
      rule(:top) { either(seq(str("/*"), commit, upto("*/"), str("*/")), match(/.*/m)) }
    end
    failure = g.parse("/* x")
    assert failure.committed
    assert_equal [4, ['"*/"']], [failure.pos, failure.expected]
  end

  # Trying the terminator at each character isn't a failure of the
  # parse: a match records nothing, as a lookahead wouldn't.
  def test_a_successful_scan_records_no_expectations
    [B.str("*/"), B.seq(B.str("*"), B.str("/")), B.str("*/").label("end")].each do |t|
      g = grammar { rule(:top) { seq(str("/*"), upto(t), str("*/"), str("x")) } }
      failure = g.parse("/* * */y")
      assert_equal [7, ['"x"']], [failure.pos, failure.expected], t.inspect
    end
  end

  # As in a lookahead, a commit inside the terminator only means "not
  # here". Unterminated, what's expected is what the terminator expected
  # at the end, not what an earlier try got furthest with.
  def test_a_commit_inside_the_terminator_is_just_a_miss
    g = grammar { rule(:top) { seq(upto(seq(str("*"), commit, str("/"))), match(/.*/m)) } }
    assert_equal ["a *b ", "*/"], g.parse!("a *b */")
    assert_equal ['"*"'], g.parse("a *b *").expected
    refute g.parse("a *b *").committed
  end

  # --- Building it ---

  def test_anything_else_raises
    assert_raises(ArgumentError) { Birman.upto(42) }
    assert_raises(ArgumentError) { Birman.upto(nil) }
  end

  def test_it_works_without_a_grammar
    m = Birman.seq(Birman.upto("*/"), Birman.str("*/"))
    assert_equal [" x ", "*/"], Birman.parse!(m, " x */")
  end

  def test_upto_is_a_name_rules_cant_take
    error = assert_raises(ArgumentError) { grammar { rule(:upto) { str("x") } } }
    assert_match(/rule :upto would replace/, error.message)
  end

  def test_to_ast_and_to_ebnf
    g = grammar do
      rule(:top) { seq(str("/*"), upto("*/"), str("*/"), upto(/\n/), upto(either(str("a"), stop))) }
      rule(:stop) { str("z") }
    end
    assert_equal [:upto, [:str, "*/"]], Birman.upto("*/").to_ast
    assert_equal [:upto, [:pat, "/\\n/"]], Birman.upto(/\n/).to_ast
    assert_equal [:upto, [:choice, [[:str, "a"], %i[ref stop]]]], Birman.upto(Birman.str("a") | Birman::Ref.new(:stop)).to_ast
    assert_equal <<~EBNF.chomp, g.to_ebnf
      top  = "/*" ((!"*/" /./m)* &"*/") "*/" ((!/\\n/ /./m)* &/\\n/) ((!("a" / stop) /./m)* &("a" / stop)) ;
      stop = "z" ;

      spacing = /\\s*/ ;
    EBNF
  end
end
