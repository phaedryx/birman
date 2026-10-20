# frozen_string_literal: true

require "test_helper"
require_relative "support/examples"
require_relative "support/compiler_helpers"

# Grammar.to_ruby at the edges the example grammars don't reach: name
# clashes, action copying, regexps, value shapes, encodings. Each case
# either agrees with the interpreter or is refused with a Compiler::Error.
class CompilerEdgesTest < Minitest::Test
  include CompilerTestHelpers

  Pair = Birman.node(:left, :right)
  Wrap = Birman.node(:value)
  Bin = Birman.node(:op, :left, :right)
  Doubled = Birman.node(:value) { def initialize(value:) = super(value: value * 2) }

  # Shadow the runtime's names, as a grammar's own constants might.
  module Shadows
    FAIL = 0
    Success = Birman.node(:value)
    Parser = Birman.node(:value)

    # An action reading its own FAIL.
    class Grammar
      include Birman::Grammar

      root :top
      rule(:top) { seq(str("a").action(:zero), str("b")) | str("c") }

      private

      def zero(_text) = FAIL
    end
  end

  # A module that already holds node classes, used as the namespace.
  module Taken
    Thing = Birman.node(:value)
  end

  ESCAPES = { "n" => "N" }.freeze
  Helper = Class.new

  # --- Names ---

  def test_refuses_a_copied_constant_shadowing_the_runtime
    assert_refused Shadows::Grammar, /FAIL/
  end

  def test_refuses_node_classes_named_like_the_runtime
    assert_refused grammar { rule(:top) { str("a").to(Shadows::Success) } }, /Success/
    assert_refused grammar { rule(:top) { str("a").to(Shadows::Parser) } }, /Parser/
  end

  def test_refuses_a_namespace_that_already_defines_the_node_classes
    g = grammar { rule(:top) { str("a").to(Taken::Thing) } }
    error = assert_raises(Birman::Compiler::Error) { g.to_ruby(namespace: "CompilerEdgesTest::Taken") }
    assert_match(/Thing/, error.message)
  end

  def test_refuses_node_classes_with_methods_of_their_own
    assert_refused grammar { rule(:top) { match(/\d/).to(Doubled) } }, /Doubled/
  end

  def test_rule_names_that_arent_identifiers
    g = grammar(:top?) do
      rule(:top?) { seq(item!, item!) }
      rule(:item!) { match(/\w/) }
    end
    assert_same_results g, %w[ab a]
  end

  # --- Actions ---

  def test_unread_actions_still_run
    g = grammar do
      rule(:top) { seq(str("a").as(:key), match(/\d/).action(:odd)) }

      private

      def odd(text)
        large_integer(text).odd? ? text : raise(ArgumentError, "#{text} is even")
      end # rubocop:disable Lint/NestedMethodDefinition
    end
    parser = Differential.load(g, "CompilerTestParser")
    assert_equal({ key: "a" }, g.parse!("a1"))
    assert_equal({ key: "a" }, parser.new("a1").parse.value)
    want = assert_raises(ArgumentError) { g.parse("a2") }
    got = assert_raises(ArgumentError) { parser.new("a2").parse }
    assert_equal want.message, got.message
  end

  # --- Checks ---

  # The check's value is never read, but the predicate still decides.
  def test_unread_checks_still_run
    g = grammar do
      rule(:top) { seq(str("a").as(:key), match(/\d/).check(:odd?, "odd"), str("a").check(:odd?, "x").present) }

      private

      def odd?(text) = text == "a" || large_integer(text).odd? # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_same_results g, %w[a1a a2a a1 a3b]
  end

  def test_checks_over_nodes
    g = grammar do
      rule(:top) { either(node_checked, checked_node) }
      rule(:node_checked) { seq(digits.as(:left), ",", digits.as(:right)).to(Pair).check(:ordered_pair?, "in order") }
      rule(:checked_node) { seq(digit.as(:left), digit.as(:right)).check(:ordered?, "ordered digits").to(Pair) }
      rule(:digits) { match(/\d+/) }
      rule(:digit) { match(/\d/) }

      private

      # rubocop:disable Lint/NestedMethodDefinition
      def ordered?(parts) = large_integer(parts[:left]) <= large_integer(parts[:right])
      def ordered_pair?(pair) = large_integer(pair.left) <= large_integer(pair.right)
      # rubocop:enable Lint/NestedMethodDefinition
    end
    assert_same_results g, ["1,2", "2,1", "10,9", "1,", "12", "21", "1", ""]
  end

  def test_check_values_keep_their_type
    g = grammar do
      rule(:top) { match(/\d+/).check(:even?, "an even number") }

      private

      def even?(text) = large_integer(text).even? # rubocop:disable Lint/NestedMethodDefinition
    end
    types = Birman::Compiler::Types.new(g.new)
    assert_equal :str, types.of(Birman::Ref.new(:top))
    assert types.str_or_nil?(Birman::Ref.new(:top).maybe.check(:even?, "x"))
  end

  def test_refuses_checks_it_cant_copy_or_name
    g = grammar do
      rule(:top) { str("a").check(:check_end, "x") }
      define_method(:check_end) { |_text| true }
    end
    assert_refused g, /check_end/
    assert_refused grammar { rule(:top) { str("a").check(:"no way", "x") } }, /\.check\(:"no way"\).*plain method name/
    assert_refused grammar { rule(:top) { str("a").check(:gone?, "x") } }, /\.check\(:gone\?\).*no method gone\?/
  end

  def test_copies_birman_helpers_and_self_calls
    g = grammar do
      include Birman::Rules::Strings

      rule(:top) { match(/\\./).action(:unescape) }

      private

      def unescape(text)
        shout(decode_escape(text))
      end # rubocop:disable Lint/NestedMethodDefinition

      def shout(text) = "<#{text}>" # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_same_results g, ["\\n", "\\q", "x"]
  end

  def test_refuses_actions_it_cant_copy
    # rubocop:disable-next Lint/NestedMethodDefinition, Lint/UselessMethodDefinition
    refused = {
      /super/ => proc { def act(text) = super },
      /keywords/ => proc { def act(_text) = keywords.first },
      /Helper/ => proc { def act(_text) = Helper.new }
    }
    refused.each do |pattern, definition|
      g = grammar { rule(:top) { str("a").action(:act) } }
      g.class_eval(&definition)
      assert_refused g, pattern
    end
  end

  def test_refuses_two_constants_of_one_name
    g = grammar do
      include Birman::Rules::Strings

      rule(:top) { match(/\\./).action(:decode_escape) | match(/\w/).action(:mine) }

      private

      def mine(text) = ESCAPES.fetch(text, text) # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_refused g, /ESCAPES/
  end

  # --- Regexps ---

  def test_refuses_word_boundaries_that_may_come_first
    [/(?i)\bb/, /(?i:\bb)/, /(?=\b)b/, /(?!\B)a/, /x?\bb/, /x*\Bb/, / \bb/x, /(?:a|\b)b/, /(a)?\bb/].each do |re|
      assert_refused grammar { rule(:top) { match(re) } }, /rule :top/
    end
  end

  def test_accepts_word_boundaries_after_something_was_matched
    g = grammar { rule(:top) { match(/(?:let)\b/) >> match(/x+\b/) >> match(/[ab]\B/) >> match(/(?:c|d)\b/) } }
    assert_same_results g, ["letxxaxc", "letxab", "let x", "letxxbbd"]
  end

  # Spinel runs a regexp with a lookaround, atomic group, backreference
  # or lazy interval on a backtracking engine that tries every length a
  # wide {m,n} allows: exponential, and RegexpError past ~18.
  def test_refuses_wide_intervals_spinel_would_backtrack_through
    [/[a-z]{1,30}(?![a-z])/, /(?=a)[a-z]{1,30}/, /(?>b)[a-z]{1,30}c/, /(a)[a-z]{0,20}\1/, /x[a-z]{1,30}?y/,
     /(?>[a-z]{1,30}x)(?!y)/, /(?>[a-z]{1,30}|b)(?!y)/, /(?:ab){1,30}(?!x)/].each do |re|
      assert_refused grammar { rule(:top) { match(re) } }, /rule :top.*\{/
    end
  end

  def test_accepts_intervals_spinel_runs_in_linear_time
    g = grammar do
      rule(:top) { match(/(?>[a-z]{1,30})(?![a-z])/) >> match(/[0-9]{1,30}x/) >> match(/y(?!z)[a-z]{2,10}/) }
    end
    assert_same_results g, ["abc123xyab", "#{"a" * 31}1xyab", "a1xyz", "a1xyabcdefghijkl"]
  end

  def test_regexps_that_only_look_like_anchors
    g = grammar { rule(:top) { match(/\p{^L}+/) >> match(/a(?# ^ )b/) } }
    assert_same_results g, ["12ab", "ab", "1a b"]
  end

  def test_extended_regexps_with_a_trailing_comment
    g = grammar { rule(:top) { match(/a # comment/x) } }
    assert_same_results g, %w[a b]
  end

  # --- Values ---

  # str.maybe: nil (0, as nil.to_i) or a String, Bignums included.
  def test_map_to_i_on_an_optional_string
    g = grammar { rule(:top) { match(/\d+/).maybe.map(:to_i) >> match(/x?/) } }
    assert_same_results g, ["", "12", "#{"9" * 25}x", "x", "9" * 25]
    twice = grammar { rule(:top) { match(/\d+/).maybe.map(:to_i).maybe.map(:to_i) } }
    assert_refused twice, /\.map\(:to_i\) \(its value/
  end

  def test_to_over_infix_that_passes_a_hash_through
    g = grammar { rule(:top) { infix(seq(match(/\d/).as(:value)), "+", node: Bin).to(Wrap) } }
    assert_same_results g, ["1", "1+2", "1+"]
  end

  def test_to_over_refs_choices_and_actions
    g = grammar do
      rule(:top) { either(pair.to(Pair), named.to(Pair), match(/\w/).action(:hashed).to(Wrap)) }
      rule(:pair) { seq(match(/\d/).as(:left), "=", match(/\d/).as(:right)) }
      rule(:named) do
        either(seq(str("<").as(:left), str(">").as(:right)), seq(str("[").as(:left), str("]").as(:right)))
      end

      private

      def hashed(text) = text == "h" ? { value: text * 2 } : text # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_same_results g, ["1=2", "<>", "[]", "h", "x", "1="]
  end

  # --- Types of rules in cycles ---

  # a and b reach each other: a gives an Integer or b's value, b a String
  # or a's. Both are either, whichever is asked about first.
  def cycle(body)
    grammar(:start) do
      rule(:start) { either(str("!") >> top, a) }
      rule(:a) { either(match(/\d+/).map(:to_i), b) }
      rule(:b) { either(str("x"), between("(", ")", a)) }
      rule(:top, &body)
    end
  end

  def test_rule_types_in_a_cycle_dont_depend_on_which_is_asked_first
    g = cycle(proc { b })
    a = Birman::Ref.new(:a)
    b = Birman::Ref.new(:b)
    first_a = Birman::Compiler::Types.new(g.new)
    first_b = Birman::Compiler::Types.new(g.new)
    assert_equal %i[poly poly], [first_a.of(a), first_a.of(b)]
    assert_equal %i[poly poly], [first_b.of(b), first_b.of(a)]
  end

  # A rule typed while its cycle was still being worked out once passed
  # for a String (to_i read an Integer's bytesize) or an Integer (a plain
  # to_i, which Spinel clamps to 2**63 - 1).
  def test_map_to_i_on_rules_in_a_cycle_that_may_give_integers
    assert_refused cycle(proc { b.maybe.map(:to_i) }), /\.map\(:to_i\) \(its value/
    assert_refused cycle(proc { b.map(:to_i) }), /\.map\(:to_i\) \(its value/
    g = grammar(:start) do
      rule(:start) { either(str("!") >> top, b) }
      rule(:a) { either(between("#", "#", match(/\d+/)).map(:to_i), b) }
      rule(:b) { either(match(/\d+/), between("(", ")", a)) }
      rule(:top) { a.map(:to_i) }
    end
    assert_refused g, /\.map\(:to_i\) \(its value/
  end

  def test_map_to_i_on_rules_in_a_cycle_of_strings
    g = grammar(:start) do
      rule(:start) { either(str("!") >> top, a) }
      rule(:a) { either(match(/\d+/), b) }
      rule(:b) { either(str("x"), between("(", ")", a)) }
      rule(:top) { b.maybe.map(:to_i) >> a.map(:to_i) }
    end
    assert_same_results g, ["!(5)7", "!x(#{"9" * 25})", "!((#{"9" * 25}))1", "!1", "(7)", "!"]
  end

  # A rule that only recurses gives nothing; what reads it is refused
  # rather than overflowing the stack.
  def test_map_to_i_on_a_rule_that_only_recurses
    g = grammar do
      rule(:top) { a.map(:to_i) }
      rule(:a) { b.label("x") }
      rule(:b) { a }
    end
    assert_raises(ArgumentError) { g.parse("1") }
    assert_refused g, /\.map\(:to_i\)/
  end

  # --- Unread values ---

  # .map runs even when nothing reads its value, as an action does.
  def test_unread_maps_still_run
    g = grammar { rule(:top) { match(/x/).maybe.map(:upcase).present >> str(";") } }
    parser = Differential.load(g, "CompilerTestParser")
    ["", ";"].each do |input|
      assert_raises(NoMethodError) { g.parse(input) }
      assert_raises(NoMethodError) { parser.new(input).parse }
    end
    assert_same_results g, ["x;", "x"]
  end

  def test_refuses_overflowing_maps_that_nothing_reads
    assert_refused grammar { rule(:top) { match(/\h+/).map(:hex).absent >> match(/\w+/) } }, /\.map\(:hex\)/
  end

  # --- Diagnostics ---

  def test_label_that_succeeds_without_consuming
    g = grammar { rule(:top) { match(/a*/).label("as") >> str("b") } }
    assert_same_results g, %w[b ab c aac]
  end

  def test_commits_inside_positive_lookaheads
    g = grammar do
      rule(:top) do
        ((str("a") > str("b")).present >> match(/\w+/)) | ((str("c") > str("d")) & match(/\w+/))
      end
    end
    assert_same_results g, %w[ab ac cd ce x]
  end

  def test_rule_retried_after_a_commit_failure_in_a_lookahead
    g = grammar do
      rule(:r) { str("a") > str("b") }
      rule(:top) { seq(r.absent, str("zz")) | r | match(/\w+/) }
    end
    assert_same_results g, %w[ab ac zz a q]
  end

  def test_lexeme_without_an_ignore_rule_and_a_subclass_clearing_ignore
    g = grammar do
      lexeme(:tok) { match(/\w+/) }
      rule(:top) { seq(tok, "=", tok) }
    end
    assert_same_results g, ["a=b", "a = b"]

    parent = grammar(ignore: :spacing) { rule(:top) { seq("a", "b") } }
    assert_same_results Class.new(parent) { ignore nil }, ["ab", "a b", "a"]
  end

  # Like the interpreter's fresh Context per parse: nothing left over
  # from a parse that ended in a commit failure (rules left in progress,
  # failure tracking, token ends) changes the next one.
  def test_parsing_again_with_the_same_parser
    g = grammar(ignore: :spacing) do
      rule(:top) { either(seq("let", commit, match(/\w+/).as(:name), "=", match(/\d+/).as(:value)), pair) }
      rule(:pair) { seq(match(/\w+/), "=", match(/\d+/)) }
    end
    Differential.load(g, "CompilerTestParser")
    ["let x = 1", "let x =", "y = 2 ", "let", "y ="].each do |input|
      parser = CompilerTestParser::Parser.new(input)
      want = Differential.interpreted(g, input)
      3.times { assert_equal want, Differential.report(parser.parse, CompilerTestParser::BirmanRT.method(:dump)), input }
    end
  end

  # Spinel exits the process when more than 64 begin blocks are active,
  # so lookaheads nested past lookahead_depth make a Failure instead.
  def test_lookaheads_nested_too_deeply_fail_cleanly
    g = grammar(:nest) { rule(:nest) { seq(str("("), (nest.present >> nest).maybe, str(")")) } }
    Object.send(:remove_const, :CompilerTestDepth) if defined?(CompilerTestDepth)
    Object.class_eval(g.to_ruby(namespace: "CompilerTestDepth", lookahead_depth: 5))
    shallow = "#{"(" * 4}#{")" * 4}"
    assert_equal g.parse!(shallow), CompilerTestDepth::Parser.new(shallow).parse.value

    parser = CompilerTestDepth::Parser.new("#{"(" * 10}#{")" * 10}")
    failure = parser.parse
    refute failure.success?
    assert_equal "input is nested too deeply", failure.reason
    assert parser.parse.reason, "and again on the same parser"
  end

  def test_lookahead_depth_must_be_positive
    g = grammar { rule(:top) { str("a") } }
    assert_raises(ArgumentError) { g.to_ruby(namespace: "X", lookahead_depth: 0) }
  end

  # --- Encodings ---

  def test_binary_input_counts_bytes_as_characters
    g = grammar { rule(:top) { seq(str("a"), str("b")) } }
    assert_same_results g, ["\xA9c".b, "a\xA9".b, "ab".b, "a\nb\xA9".b]
  end

  # The generated parser checks UTF-8 byte by byte, so it's compared
  # with Ruby's own validity on every two-byte pair after an "a", and
  # on three- and four-byte sequences around each edge: overlongs,
  # surrogates, past U+10FFFF, truncated.
  def test_invalid_utf8_fails_at_the_same_byte
    g = grammar { rule(:top) { match(/[^\n]*\n?/).rep } }
    edges = [0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xEC, 0xED,
             0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF]
    pairs = (0..255).to_a.repeated_permutation(2).map { [0x61, *_1] }
    fours = edges.repeated_permutation(2).flat_map do |a, b|
      [[0xF0, a, b, 0x80], [0xF4, a, b, 0x80], [0xF1, 0x80, a, b]]
    end
    bytes = pairs + edges.repeated_permutation(3).to_a + fours
    inputs = bytes.map { _1.pack("C*").force_encoding("UTF-8") } + ["x\n\xFF", "é\nab\xC3"]
    assert inputs.any? { !_1.valid_encoding? } && inputs.all? { _1.encoding == Encoding::UTF_8 }
    assert_same_results g, inputs

    # A message with a reason doesn't say what was found, so compare it.
    parser = Differential.load(g, "CompilerTestParser")
    ["a\xFF", "a\xE3\x81", "a\xF0\x9F\x90\x88\xC3"].each do |input|
      assert_equal g.parse(input).found, parser.new(input).parse.found, input
    end
  end

  def test_invalid_us_ascii_fails_like_the_interpreter
    g = grammar { rule(:top) { match(/\w*/) } }
    inputs = ["ab\xFF", "ab\xC3\xA9", "ab"].map { _1.dup.force_encoding("US-ASCII") }
    assert_same_results g, inputs
  end

  def test_refuses_input_in_other_encodings
    parser = Differential.load(grammar { rule(:top) { str("a") } }, "CompilerTestParser")
    error = assert_raises(ArgumentError) { parser.new("a".encode("UTF-16LE")) }
    assert_match(/UTF-16LE/, error.message)
  end
end
