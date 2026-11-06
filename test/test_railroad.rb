# frozen_string_literal: true

require "test_helper"

# to_svg and to_html: railroad diagrams drawn from to_ast.
class RailroadTest < Minitest::Test
  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar

      self.root(root) if root
      class_eval(&rules)
    end
  end

  # The SVG for one AST, as a rule's diagram would draw it.
  def svg(ast) = Birman::Railroad.svg(:r, ast)

  def test_to_svg_draws_the_root_rule_as_a_standalone_svg
    g = grammar do
      rule(:top)   { seq("let", other) }
      rule(:other) { str("x") }
    end
    svg = g.to_svg

    assert_match(%r{\A<svg xmlns="http://www\.w3\.org/2000/svg" class="railroad" }, svg)
    assert_match(/ width="(\d+)" height="(\d+)" viewBox="0 0 \1 \2"/, svg)
    assert svg.end_with?("</svg>\n")
    assert_includes svg, "<title>top</title>"
    assert_includes svg, "<style>", "a standalone SVG carries its own styles"
    assert_includes svg, ">&quot;let&quot;</text>"
    refute_includes svg, "&quot;x&quot;", "other's literal is in other's diagram"
  end

  def test_to_svg_draws_a_named_rule_and_works_on_an_instance
    g = grammar do
      rule(:top)   { other }
      rule(:other) { str("x") }
    end

    assert_includes g.to_svg(:other), "<title>other</title>"
    assert_equal g.to_svg(:other), g.new.to_svg(:other)
    assert_equal g.to_svg, g.new.to_svg
  end

  def test_to_svg_raises_for_an_undefined_rule_or_no_rule_at_all
    g = grammar(nil) { rule(:top) { str("x") } }

    assert_equal "undefined rule :nope", assert_raises(ArgumentError) { g.to_svg(:nope) }.message
    assert_equal "undefined rule \"top\"", assert_raises(ArgumentError) { g.to_svg("top") }.message
    assert_equal "no rule given, and the grammar has no root", assert_raises(ArgumentError) { g.to_svg }.message
    assert_includes g.to_svg(:top), "<title>top</title>"
  end

  def test_literals_are_rounded_boxes_with_their_text_as_to_ebnf_shows_it
    lit = svg([:str, "let"])
    istr = svg([:istr, "select"])

    assert_match(/<rect class="lit" [^>]*rx="11"/, lit)
    assert_includes lit, ">&quot;let&quot;</text>"
    assert_match(/<rect class="lit" /, istr)
    assert_includes istr, ">&quot;select&quot;i</text>"
  end

  # String#inspect escapes non-ASCII when the default external encoding
  # isn't Unicode (LANG=C), which would change the text and the width.
  def test_literals_are_quoted_the_same_whatever_the_default_encoding
    utf8 = svg([:str, "école"])
    ascii = begin
      external = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      svg([:str, "école"])
    ensure
      Encoding.default_external = external
    end

    assert_includes utf8, ">&quot;école&quot;</text>"
    assert_equal utf8, ascii
    assert_includes svg([:istr, "é"]), ">&quot;é&quot;i</text>"
  end

  def test_quotes_backslashes_and_control_characters_in_literals_are_escaped
    assert_includes svg([:str, "a\"b\\c\n\t"]), %(>&quot;a\\&quot;b\\\\c\\n\\t&quot;</text>)
  end

  def test_patterns_are_rounded_boxes_of_their_own_class
    s = svg([:pat, "/\\d+/"])

    assert_match(/<rect class="pat" [^>]*rx="11"/, s)
    assert_includes s, ">/\\d+/</text>"
  end

  def test_rule_references_are_square_boxes_linking_to_the_rules_diagram
    s = svg(%i[ref expr])

    assert_match(%r{<a href="#rule-expr"><rect class="ref" [^>]*rx="0"/><text [^>]*>expr</text></a>}, s)
  end

  def test_text_is_escaped
    s = svg([:seq, nil, [[:str, "<&>"], [:pat, "/a&b/"], %i[ref a<b]]])

    assert_includes s, ">&quot;&lt;&amp;&gt;&quot;</text>"
    assert_includes s, ">/a&amp;b/</text>"
    assert_includes s, %(<a href="#rule-a&lt;b">)
  end

  def test_a_commit_point_is_a_visible_tilde_where_it_falls_in_the_sequence
    s = svg([:seq, 1, [[:str, "let"], %i[ref name]]])

    commit = s.index(%(<g class="commit">))
    assert commit, "draws the commit point"
    assert_match(%r{<g class="commit"><title>[^<]+</title><path [^>]*/><text [^>]*>~</text></g>}, s)
    assert_operator s.index("&quot;let&quot;"), :<, commit
    assert_operator commit, :<, s.index(">name<")
    refute_includes svg([:seq, nil, [[:str, "let"], %i[ref name]]]), %(class="commit")
  end

  def test_a_choice_draws_every_alternative_in_order
    s = svg([:choice, [%i[ref a], %i[ref b], %i[ref c]]])

    assert_equal %w[a b c], s.scan(/>([abc])</).flatten
  end

  def test_a_choice_with_an_empty_alternative_draws
    s = svg([:choice, [[:seq, nil, []], [:str, "z"]]])

    assert_includes s, "&quot;z&quot;"
  end

  def test_bounded_repetitions_say_how_many_times
    {
      [2, 3] => "2 to 3 times", [0, 4] => "up to 4 times", [3, 3] => "exactly 3 times",
      [2, nil] => "at least 2 times", [1, 1] => "exactly 1 time"
    }.each do |(min, max), note|
      assert_includes svg([:rep, min, max, %i[ref digit]]), %(class="note"), "#{min}..#{max}"
      assert_match(/>#{note}</, svg([:rep, min, max, %i[ref digit]]))
    end
  end

  def test_star_plus_and_optional_need_no_note
    [[0, nil], [1, nil], [0, 1]].each do |min, max|
      s = svg([:rep, min, max, %i[ref digit]])

      refute_includes s, %(class="note"), "#{min}..#{max}"
      assert_includes s, ">digit<"
    end
  end

  # A loop goes back under its item; a bypass goes over it. So a + has
  # the loop's extra depth, a ? the bypass's extra height, and a * both.
  def test_star_plus_and_optional_differ_in_shape
    sizes = [[0, nil], [1, nil], [0, 1]].to_h do |min, max|
      [[min, max], svg([:rep, min, max, %i[ref d]])[/viewBox="0 0 \d+ (\d+)"/, 1].to_i]
    end
    plain = svg(%i[ref d])[/viewBox="0 0 \d+ (\d+)"/, 1].to_i

    assert_operator sizes[[1, nil]], :>, plain
    assert_operator sizes[[0, 1]], :>, plain
    assert_operator sizes[[0, nil]], :>, sizes[[1, nil]]
    assert_operator sizes[[0, nil]], :>, sizes[[0, 1]]
  end

  def test_lookaheads_are_captioned_boxes_around_what_they_look_for
    assert_match(/class="group look".*>not followed by<.*>eof</m, svg([:not, %i[ref eof]]))
    assert_match(/class="group look".*>followed by<.*&quot;;&quot;/m, svg([:and, [:str, ";"]]))
  end

  # upto's terminator is looked for, not taken, so it's drawn as a
  # lookahead: the "*/" after it is still the one that matches.
  def test_upto_is_a_captioned_lookahead_box_around_its_terminator
    s = svg([:seq, nil, [[:str, "/*"], [:upto, [:str, "*/"]], [:str, "*/"]]])

    assert_match(%r{&quot;/\*&quot;.*class="group look".*>text up to<.*&quot;\*/&quot;.*&quot;\*/&quot;}m, s)
    assert_equal 2, s.scan("&quot;*/&quot;").size
    refute_match(/class="unknown"/, s)
  end

  def test_a_guard_is_its_lookahead_then_what_it_guards
    s = svg([:both, [:not, %i[ref reserved_word]], [:pat, "/\\w+/"]])

    assert_match(%r{>not followed by<.*>reserved_word<.*>/\\w\+/<}m, s)
    assert_match(/>followed by<.*>a<.*>b</m, svg([:both, %i[ref a], %i[ref b]]))
    refute_match(/not followed by/, svg([:both, %i[ref a], %i[ref b]]))
  end

  def test_a_check_is_a_captioned_box_naming_its_method
    s = svg([:check, :defined, %i[ref name]])

    assert_match(/class="group check".*>check :defined<.*>name</m, s)
  end

  def test_a_nested_label_is_a_captioned_box_and_a_rules_own_label_is_not_drawn
    nested = svg([:seq, nil, [%i[ref a], [:label, "operator", [:str, "+"]]]])
    own = svg([:label, "statement", %i[ref a]])

    assert_match(/class="group label".*>&quot;operator&quot;<.*&quot;\+&quot;/m, nested)
    refute_includes own, "statement"
    assert_equal svg(%i[ref a]), own
    assert_equal svg(%i[ref a]), svg([:lexeme, [:label, "statement", [:action, %i[ref a]]]]),
                 "a label under the rule's wrappers is still its own"
  end

  def test_wrappers_that_dont_change_the_language_are_not_drawn
    inner = [:seq, nil, [[:str, "a"], %i[ref b]]]
    plain = Birman::Railroad.svg(:r, [:seq, nil, [%i[ref x], inner]])

    %i[action quiet lexeme text spanned].each do |wrapper|
      assert_equal plain, Birman::Railroad.svg(:r, [:seq, nil, [%i[ref x], [wrapper, inner]]]), wrapper
    end
  end

  # Node types added after this renderer show as a box naming the type,
  # without guessing what their parts mean.
  def test_an_unknown_node_type_is_a_box_naming_it
    s = svg([:seq, nil, [[:str, "/*"], [:skim, [:str, "*/"]], %i[ref x]]])

    assert_match(%r{<rect class="unknown" [^>]*/><text [^>]*>skim</text>}, s)
    refute_includes s, "*/&quot;"
    assert_includes s, ">x<"
    assert_includes svg([:precedence]), ">precedence<"
  end

  def test_longer_text_makes_wider_boxes_and_diagrams
    width = ->(text) { svg([:str, text])[/width="(\d+)"/, 1].to_i }

    assert_operator width.call("abcdef"), :>, width.call("abc")
    assert_equal width.call("abcdef") - width.call("abc"), width.call("abcdefghi") - width.call("abcdef")
  end

  def test_output_is_deterministic_and_uses_whole_numbers
    require_relative "../examples/calc"
    first = Calc::Grammar.to_html

    assert_equal first, Calc::Grammar.to_html
    assert_equal first, Calc::Grammar.new.to_html
    refute_match(/\d\.\d/, first.scan(/ (?:d|x|y|width|height)="[^"]*"/).join)
  end

  # A checked-in page, so a change to the layout or styles shows in
  # review. After a deliberate change, regenerate it:
  #   ruby -Ilib -e 'require "./examples/calc"; File.write("test/fixtures/calc_railroad.html", Calc::Grammar.to_html)'
  def test_calcs_page_matches_its_snapshot
    require_relative "../examples/calc"

    assert_equal File.read(File.expand_path("fixtures/calc_railroad.html", __dir__)), Calc::Grammar.to_html
  end

  def test_to_svg_and_to_html_are_not_rule_names
    %i[to_svg to_html].each do |name|
      error = assert_raises(ArgumentError) { grammar { rule(name) { str("x") } } }
      assert_match(/\Arule :#{name} would replace Birman::Grammar##{name}/, error.message)
    end
  end

  def test_colors_are_custom_properties_with_a_dark_scheme
    s = svg([:str, "a"])

    assert_match(/:where\(:root\) \{[^}]*--rr-lit:/, s)
    assert_match(/@media \(prefers-color-scheme: dark\) \{\s*:where\(:root\) \{[^}]*--rr-lit:/, s)
    assert_includes s, "fill: var(--rr-lit, #"
  end

  # librsvg (ImageMagick, Inkscape's export) skips :where(:root), so
  # every color names its light value too.
  def test_every_color_has_a_fallback_for_renderers_without_custom_properties
    s = svg([:str, "a"])

    refute_match(/var\(--rr-[\w-]+\)/, s)
    assert_equal s.scan(/var\(--rr-([\w-]+), (#\h+)\)/).uniq.size, s.scan(/var\(--rr-([\w-]+),/).uniq.size
  end

  def test_to_html_is_a_page_with_every_rule_in_to_ast_order
    g = grammar do
      rule(:top)  { seq(item, item.rep) }
      rule(:item) { either(num, str("x")).label("item") }
      rule(:num)  { match(/\d+/) }
    end
    html = g.to_html

    assert html.start_with?("<!doctype html>\n<html lang=\"en\">")
    assert html.end_with?("</html>\n")
    assert_equal %w[top item num], html.scan(/<section id="rule-(\w+)">/).flatten
    assert_includes html, %(<h2><a href="#rule-item">item</a> <small>&quot;item&quot;</small></h2>)
    assert_equal 1, html.scan("<style>").size, "styles once, in the head, not in every SVG"
    assert_equal 3, html.scan("<svg ").size
    assert_equal g.new.to_html, html
  end

  def test_to_html_puts_rules_the_root_doesnt_reach_after_a_heading
    g = grammar do
      rule(:top)    { str("x") }
      rule(:orphan) { str("y") }
    end
    html = g.to_html

    assert_match(%r{id="rule-top".*<h2 class="unreachable">Not reachable from the root</h2>.*id="rule-orphan"}m, html)
    refute_includes grammar { rule(:top) { str("x") } }.to_html, "Not reachable"
  end

  def test_to_html_without_a_root_lists_every_rule_without_the_heading
    html = grammar(nil) do
      rule(:a) { str("x") }
      rule(:b) { a }
    end.to_html

    assert_equal %w[a b], html.scan(/<section id="rule-(\w+)">/).flatten
    refute_includes html, "Not reachable"
  end

  def test_to_html_titles_the_page_with_the_grammars_name_or_a_given_title
    require_relative "../examples/calc"

    assert_includes Calc::Grammar.to_html, "<title>Calc::Grammar</title>"
    assert_includes Calc::Grammar.to_html, "<h1>Calc::Grammar</h1>"
    assert_includes grammar { rule(:top) { str("x") } }.to_html, "<title>Grammar</title>"
    assert_includes Calc::Grammar.to_html(title: "Calc & co"), "<title>Calc &amp; co</title>"
  end

  def test_every_example_grammar_draws
    %w[calc leftcalc json email toml query].each { require_relative "../examples/#{_1}" }
    [Calc, LeftCalc, JSONExample, EmailExample, TOMLExample, QueryExample].each do |mod|
      html = mod::Grammar.to_html

      assert_equal mod::Grammar.to_ast.size, html.scan("<section ").size, mod
    end
  end
end
