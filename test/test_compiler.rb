# frozen_string_literal: true

require "test_helper"
require_relative "support/examples"
require_relative "support/compiler_helpers"

# Grammar.to_ruby, one matcher at a time: each test generates a parser
# for a small grammar and checks that it agrees with the interpreter,
# value, spans, error position, expectations and message, on every input.
class CompilerTest < Minitest::Test
  Pair = Birman.node(:left, :right)
  Wrap = Birman.node(:value)
  Bin = Birman.node(:op, :left, :right)

  include CompilerTestHelpers

  # --- Terminals ---

  def test_str
    g = grammar { rule(:top) { str("ab") } }
    assert_same_results g, ["ab", "a", "", "abc", "x"]
  end

  def test_pat_keeps_its_options_and_reports_the_original_source
    g = grammar { rule(:top) { match(/a.b/m) >> match(/[xyz]+/i) } }
    assert_same_results g, ["a\nbXy", "a\nb", "ab", "", "é"]
  end

  def test_pat_with_slashes_and_unicode
    g = grammar { rule(:top) { match(%r{\\/[^"\\\x00-\x1f]+}) >> match(/é+/) } }
    assert_same_results g, ["\\/abcé", "\\/é", "\\/\x01", "x"]
  end

  def test_lit_word_and_symbol_with_ignore
    g = grammar(ignore: :spacing) { rule(:top) { seq("let", "=", "if") } }
    assert_same_results g, ["let = if", "let=if  ", "letx = if", "let", "let =", "", "let = iffy"]
  end

  def test_lit_without_ignore
    g = grammar { rule(:top) { seq("let", "=") } }
    assert_same_results g, ["let=", "let =", "lets="]
  end

  # --- Sequences ---

  def test_seq_values_array_named_and_only
    g = grammar do
      rule(:top) do
        either(seq("a", "b"), seq(str("c").as(:x), str("d"), str("e").as(:y)), seq("f", only(str("g")), "h"))
      end
    end
    assert_same_results g, %w[ab cde fgh a cd fg x]
  end

  def test_seq_commit
    g = grammar(ignore: :spacing) do
      rule(:top) { either(seq("let", commit, match(/\w+/), "=", match(/\d+/).quiet), str("other")) }
    end
    assert_same_results g, ["let x = 1", "let", "let x", "let x =", "let x = y", "other", "lets"]
  end

  def test_commit_inside_lookahead_is_an_ordinary_failure
    g = grammar { rule(:top) { (str("a") > str("b")).absent >> match(/\w+/) } }
    assert_same_results g, %w[ab ac xy a]
  end

  def test_pick
    g = grammar { rule(:top) { between("(", ")", match(/\d+/)) } }
    assert_same_results g, ["(1)", "(1", "1)", "()", ""]
  end

  def test_sep_by
    g = grammar do
      rule(:top) { seq("[", sep_by(match(/\d+/), ","), "]", sep_by1(match(/[a-z]/), str(""))) }
    end
    assert_same_results g, ["[1,2,3]abc", "[]x", "[1,]a", "[,]a", "[1]", "[1,2]"]
  end

  # --- Choice and repetition ---

  def test_choice
    g = grammar { rule(:top) { str("a") | str("ab") | match(/\d/) } }
    assert_same_results g, ["a", "ab", "1", "", "x"]
  end

  def test_rep_bounds_and_empty_matches
    g = grammar do
      rule(:top) { seq(str("a").rep(2, 3), match(/b*/).rep(1), str("c").rep) }
    end
    assert_same_results g, %w[aa aaa aaaa a aabbccc aac aabcc]
  end

  def test_maybe
    g = grammar { rule(:top) { str("-").maybe >> match(/\d+/) } }
    assert_same_results g, %w[-1 1 - x]
  end

  # --- Lookahead ---

  def test_not_and_and_both
    g = grammar do
      rule(:top) { seq(str("x").absent, match(/\w/).present, match(/[a-c]/).present & match(/\w+/)) }
    end
    assert_same_results g, %w[abc x 1 d a]
  end

  def test_eof_and_never
    g = grammar { rule(:top) { either(seq("a", eof), never) } }
    assert_same_results g, %w[a ab b]
  end

  # --- Values ---

  SUFFIX = "?"

  # Actions are copied from their source, along with the constants they
  # read (resolved lexically, as Ruby does) and the methods they call.
  def test_send_action_and_const
    g = grammar do
      rule(:top) { seq(match(/\d+/).map(:to_i), match(/[a-z]+/).action(:shout), str("!").means(:bang)) }

      private

      def shout(text) = exclaim(text.upcase) # rubocop:disable Lint/NestedMethodDefinition
      def exclaim(text) = text + SUFFIX # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_same_results g, %w[12ab! 99999999999999999999999x! 1a 1!]
  end

  # Copied actions' Integer(x) calls become BirmanRT.to_integer(x).
  def test_to_integer_agrees_with_kernel_integer
    Differential.load(grammar { rule(:top) { str("x") } }, "CompilerTestParser")
    runtime = CompilerTestParser::BirmanRT
    Examples::INTEGER_CASES.each do |value|
      want = begin
        Integer(value)
      rescue ArgumentError, TypeError => e
        e.class
      end
      got = begin
        runtime.to_integer(value)
      rescue ArgumentError, TypeError => e
        e.class
      end
      assert_equal want, got, "Integer(#{value.inspect})"
    end
  end

  def test_integer_calls_with_a_base_are_copied_as_they_are
    g = grammar do
      rule(:top) { match(/\h+/).action(:hex) }

      private

      def hex(text) = Integer(text, 16) # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_includes g.to_ruby(namespace: "X"), "Integer(text, 16)"
    assert_same_results g, %w[ff 0 g]
  end

  def test_to_builds_nodes_with_spans
    g = grammar(ignore: :spacing) do
      rule(:top) { seq(match(/\d+/).as(:left), "+", match(/\d+/).as(:right)).to(Pair) }
      rule(:wrapped) { match(/\w+/).to(Wrap) }
    end
    assert_same_results g, ["1+2", "1 + 2  ", "1+", "+"]
  end

  def test_infix
    g = grammar(ignore: :spacing) do
      rule(:top) { infix(match(/\d+/).to(Wrap), "+", "-", node: Bin) }
    end
    assert_same_results g, ["1", "1 + 2 - 3", "1 +", "1 + + 2", ""]
  end

  # --- Diagnostics ---

  def test_label_and_quiet
    g = grammar do
      rule(:top) { seq(match(/\d+/).label("number"), match(/\s+/).quiet, str("x").label("ex")) }
    end
    assert_same_results g, ["1 x", "1x", "a", "1 ", "1 y"]
  end

  def test_refs_lexemes_and_memo
    g = grammar(ignore: :spacing, keywords: %w[if]) do
      include Birman::Rules::Identifiers
      include Birman::Rules::Numbers

      rule(:top) { either(seq(identifier, "=", number), seq(identifier, "(", number, ")")) }
    end
    assert_same_results g, ["x = 1", "x(1.5)", "if = 1", "x (", "x = ", "iffy=2"]
  end

  def test_left_recursion_raises_like_the_interpreter
    g = grammar { rule(:top) { (top >> "x") | str("y") } }
    parser = Differential.load(g, "CompilerTestParser")
    error = assert_raises(ArgumentError) { parser.new("yx").parse }
    assert_equal "left recursion in rule :top: it can reach itself without consuming input", error.message
  end

  # --- Shape of the generated code ---

  # Hash#delete costs O(size) in Spinel, and an unanchored scan misses
  # by searching the rest of the input.
  def test_generated_code_never_deletes_and_anchors_every_scan
    [Examples::Lang::Grammar, Calc::Grammar, JSONExample::Grammar].each do |g|
      source = g.to_ruby(namespace: "X")
      refute_match(/\.delete\b/, source, g.name)
      scans = source.scan(%r{@sc\.skip\(/(..)})
      refute_empty scans, g.name
      assert_equal [["\\A"]], scans.uniq, g.name
    end
  end

  def test_unread_values_are_not_kept
    source = Calc::Grammar.to_ruby(namespace: "X")
    refute_match(/@v_spacing\b|@mv_spacing\b|@mv_reserved_word\b|@mv_comment\b/, source)
    assert_match(/@mv_expr\b/, source)
  end

  # --- What the generator refuses ---

  def test_rejects_map_blocks_naming_the_rule
    g = grammar { rule(:top) { match(/\d+/).map { |text| text.to_i } } } # rubocop:disable Style/SymbolProc
    error = assert_raises(Birman::Compiler::Error) { g.to_ruby(namespace: "X") }
    assert_match(/rule :top/, error.message)
    assert_match(/map/, error.message)
  end

  def test_rejects_custom_matchers
    custom = Data.define(:x) { include Birman::Matcher }
    g = grammar { rule(:top) { custom.new(1) } }
    error = assert_raises(Birman::Compiler::Error) { g.to_ruby(namespace: "X") }
    assert_match(/rule :top/, error.message)
  end

  def test_rejects_regexps_that_see_before_the_scan_position
    [/\Aa/, /^a/, /(?<=a)b/, /(?<!a)b/, /\bx/].each do |re|
      g = grammar { rule(:top) { match(re) } }
      error = assert_raises(Birman::Compiler::Error, re.inspect) { g.to_ruby(namespace: "X") }
      assert_match(/rule :top/, error.message)
    end
  end
end
