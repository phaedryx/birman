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
  Moment = Birman.node(:date, :time, :offset)
  Empty = Birman.node
  Call = Birman.node(:name, :args) { def initialize(name:, args: []) = super }
  Defaults = Birman.node(:text, :none, :int, :float, :str, :sym, :truthy, :falsy, :list, :table) do
    def initialize( # rubocop:disable Metrics/ParameterLists
      text:, none: nil, int: -1, float: 2.5e-3, str: "s\n", sym: :"a b", truthy: true, falsy: false,
      list: [1, "a", [:b, nil]], table: { k: [1], "s" => {} }
    )
      super
    end
  end

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

  # Unnamed groups don't count (Ruby stops capturing them once a group
  # is named), so the generated parser can read groups by number.
  def test_captures
    moment = /(?<date>\d{4}-\d\d-\d\d)(T(?<time>\d\d:\d\d))?(?<offset>Z|[-+]\d\d:\d\d)?/ # rubocop:disable Lint/MixedRegexpCaptureTypes
    g = grammar do
      rule(:top) { sep_by(either(match(moment).captures.to(Moment), word), str(",")) }
      rule(:word) { seq(match(/(?<word> [a-zé]+ ) (?<bang>!)? # x/x).captures.as(:parts), str(";").maybe) }
    end
    assert_same_results g, ["1979-05-27T07:32Z,ab!;,cd", "1979-05-27-07:00", "1979-05-27T", "é!", "!", "1979", ""]
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

  def test_sep_by_with_a_trailing_separator
    g = grammar do
      rule(:top) do
        seq("[", sep_by(match(/\d+/).label("value"), ",", trailing: true), "]",
            sep_by1(seq(str("a"), commit, str("b")), str(";"), trailing: true))
      end
    end
    assert_same_results g, ["[1,2,]ab;", "[1,2]ab;ab", "[1,]ab", "[,]ab", "[]ab;;", "[1,2,x", "[1,,]", "[]ab;a",
                            "[]", "[1]"]
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
  KIND = :oct

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

  # Ruby's own spelling of a Float that has no literal; other constant
  # paths are refused (see test_compiler_edges.rb).
  def test_float_infinity_and_nan_in_actions
    g = grammar do
      rule(:top) { sep_by(match(/-?inf|nan|\d/).action(:special), str(",")) }

      private

      # rubocop:disable-next Lint/NestedMethodDefinition
      def special(text)
        case text
        when "inf" then Float::INFINITY
        when "-inf" then -Float::INFINITY
        when "nan" then Float::NAN
        else Float(text)
        end
      end
    end
    assert_same_results g, ["inf,-inf,nan,1", "nan", "x"]
  end

  # BirmanRT.to_integer is Grammar#large_integer in a generated parser.
  def test_to_integer_agrees_with_large_integer
    g = grammar { rule(:top) { str("x") } }
    Differential.load(g, "CompilerTestParser")
    runtime = CompilerTestParser::BirmanRT
    cases = Examples::INTEGER_CASES.map { [_1, 0] } + Examples::INTEGER_BASE_CASES + Examples::NEGATIVE_BASE_CASES +
            Examples::FLOAT_CASES.map { [_1, 0] }
    cases.each do |value, base|
      assert_equal outcome { g.new.send(:large_integer, value, base) }, outcome { runtime.to_integer(value, base) },
                   "large_integer(#{value.inspect}, #{base.inspect})"
    end
  end

  # Ruby 3.2's Integer ignores a base that isn't a number; 3.3 and later raise.
  def test_large_integer_refuses_a_base_that_isnt_a_number_on_every_ruby
    g = grammar { rule(:top) { str("x") } }
    { nil => "from nil to integer", true => "of true into Integer", false => "of false into Integer",
      "16" => "of String into Integer", :a => "of Symbol into Integer" }.each do |base, message|
      error = assert_raises(TypeError) { g.new.send(:large_integer, "12", base) }
      assert_equal "no implicit conversion #{message}", error.message
    end
  end

  # Strings of 12 bytes or fewer go to Integer itself; padded with
  # leading whitespace, the same ones are read by integer_syntax.
  def test_to_integer_reads_short_strings_as_integer_does
    Differential.load(grammar { rule(:top) { str("x") } }, "CompilerTestParser")
    runtime = CompilerTestParser::BirmanRT
    cases = Examples::INTEGER_CASES.grep(String).map { [_1, 0] } +
            Examples::INTEGER_BASE_CASES.select { |v, b| v.is_a?(String) && b.is_a?(Integer) }
    cases.each do |value, base|
      padded = "#{" " * 13}#{value}"
      assert_equal outcome { Integer(padded, base) }, outcome { runtime.to_integer(padded, base) },
                   "Integer(#{padded.inspect}, #{base})"
    end
  end

  def outcome
    yield
  rescue ArgumentError, TypeError, FloatDomainError => e
    [e.class, e.message]
  end

  def test_large_integer_in_actions
    g = grammar(ignore: :spacing) do
      rule(:top) { sep_by(either(hex, word, match(/[-+]?\d+/).action(:large_integer)), ",") }
      rule(:hex) { match(/0x\h+/).action(:auto) }
      rule(:word) { match(/[a-z]\w*/).action(:base36) }

      private

      def auto(text) = large_integer(text) # rubocop:disable Lint/NestedMethodDefinition
      def base36(text) = self.large_integer(text, 36) # rubocop:disable Lint/NestedMethodDefinition,Style/RedundantSelf
    end
    assert_includes g.to_ruby(namespace: "X"), "def auto(text) = large_integer(text)\n", "copied as written"
    assert_same_results g, ["#{"9" * 25}, -#{"1" * 30}", "0x#{"f" * 30}, z#{"z" * 25}", "1, 0xff, abc", "1,"]
  end

  # Integer, String#to_i, #hex and #oct raise past 63 bits in a Spinel binary.
  # One definition per line: an action's source is found by its line.
  def test_refuses_integer_and_to_i_in_actions
    # rubocop:disable-next Lint/NestedMethodDefinition
    [proc { def act(text) = Integer(text) },
     proc { def act(text) = Integer(text, 16) },
     proc { def act(text) = text.to_i },
     proc { def act(text) = text.to_i(16) },
     proc { def act(text) = Kernel.Integer(text) },
     proc { def act(text) = [text].map(&:to_i) },
     proc { def act(text) = helper(text) + 1 }].each do |definition|
      g = grammar { rule(:top) { match(/\d+/).action(:act) } }
      g.class_eval { def helper(text) = text.to_i }
      g.class_eval(&definition)
      assert_refused g, %r{rule :top: Integer\(\)/to_i overflow .*large_integer}
    end
  end

  def test_refuses_hex_and_oct_in_actions
    hex = /hex overflows .*large_integer\(text, 16\)/
    oct = /oct overflows .*large_integer\(text, 8\)/
    # rubocop:disable-next Lint/NestedMethodDefinition
    cases = [[hex, proc { def act(text) = text.hex }],
             [hex, proc { def act(text) = [text].map(&:hex) }],
             [oct, proc { def act(text) = text.oct }],
             [oct, proc { def act(text) = text.send(:oct) }]]
    cases.each do |pattern, definition|
      g = grammar { rule(:top) { match(/\h+/).action(:act) } }
      g.class_eval(&definition)
      assert_refused g, pattern
    end
  end

  # send and method with a name that isn't a literal symbol can't be
  # checked, so they're refused.
  def test_refuses_computed_names_and_overflowing_dispatch
    integer = %r{Integer\(\)/to_i overflow}
    computed = /can't (?:public_)?send a computed name/
    # rubocop:disable-next Lint/NestedMethodDefinition, Style/SendWithLiteralMethodName, Lint/SymbolConversion
    cases = [[computed, proc { def act(text) = text.send("to_i") }],
             [computed, proc { def act(text) = text.public_send("to_i") }],
             [computed, proc { def act(text) = text.send("to_i".to_sym) }],
             [computed, proc { def act(text) = text.send(:"to_#{text}") }],
             [computed, proc { def act(text) = send("Integer", text) }],
             [integer, proc { def act(text) = text.send(:to_i) }],
             [integer, proc { def act(text) = send(:Integer, text) }],
             [/hex overflows/, proc { def act(text) = text.method(:hex).call }]]
    cases.each do |pattern, definition|
      g = grammar { rule(:top) { match(/\d+/).action(:act) } }
      g.class_eval(&definition)
      assert_refused g, pattern
    end
  end

  # Only a symbol that names a method being called is checked, and a
  # grammar's own method isn't Ruby's.
  def test_overflow_names_that_arent_calls_of_rubys_methods
    g = grammar do
      rule(:top) { match(/#\h+/).action(:color) | match(/\w+/).action(:tagged) }

      private

      # rubocop:disable Lint/NestedMethodDefinition
      def color(text) = hex(text[1..])
      def hex(text) = large_integer(text, 16)
      def tagged(text) = [[:hex, text], { to_i: text }, [:Integer, text], text.respond_to?(:to_i), KIND]
      # rubocop:enable Lint/NestedMethodDefinition
    end
    assert_same_results g, ["##{"f" * 30}", "#ff", "abc"]
  end

  def test_refuses_map_hex_oct_and_to_i_on_values_that_may_not_be_strings
    { /\.map\(:hex\): hex overflows/ => proc { match(/\h+/).map(:hex) },
      /\.map\(:oct\): oct overflows/ => proc { match(/\d+/).map(:oct) },
      /\.map\(:to_i\) \(its value isn't always/ => proc { either(match(/\d+/), str("x").means(1.5)).map(:to_i) },
      /\.map\(:to_i\) \(its value/ => proc { match(/\d+/).action(:large_integer).map(:to_i) } }.each do |pattern, body|
      assert_refused grammar { rule(:top, &body) }, pattern
    end
    assert_same_results grammar { rule(:top) { match(/\d+/).map(:to_i).map(:to_i) } }, ["9" * 25, "1", "x"]
  end

  def test_to_i_on_an_integer_literal_and_map_to_i_are_allowed
    g = grammar do
      rule(:top) { match(/\d+/).map(:to_i) >> match(/x/).action(:one) }

      private

      def one(_text) = 1.to_i # rubocop:disable Lint/NestedMethodDefinition, Lint/RedundantTypeConversion
    end
    assert_same_results g, ["#{"9" * 25}x", "1x", "x"]
  end

  def test_refuses_a_large_integer_of_the_grammars_own
    g = grammar do
      rule(:top) { match(/\d+/).action(:large_integer) }

      private

      def large_integer(text) = text # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_refused g, /large_integer/
  end

  def test_to_builds_nodes_with_spans
    g = grammar(ignore: :spacing) do
      rule(:top) { seq(match(/\d+/).as(:left), "+", match(/\d+/).as(:right)).to(Pair) }
      rule(:wrapped) { match(/\w+/).to(Wrap) }
    end
    assert_same_results g, ["1+2", "1 + 2  ", "1+", "+"]
  end

  # A node with no fields drops its value, whatever it is.
  def test_to_builds_nodes_with_no_fields
    g = grammar(ignore: :spacing) do
      rule(:top) { either(seq("(", ")").to(Empty), str("{}").means({}).to(Empty), match(/\w+/).to(Empty)) }
    end
    assert_same_results g, ["()", "( ) ", "{}", "ab", "(", ""]
  end

  def test_infix
    g = grammar(ignore: :spacing) do
      rule(:top) { infix(match(/\d+/).to(Wrap), "+", "-", node: Bin) }
    end
    assert_same_results g, ["1", "1 + 2 - 3", "1 +", "1 + + 2", ""]
  end

  # A node whose initialize gives fields defaults, and only calls super,
  # gets the default for each field its value leaves out: a seq of fewer
  # named parts, captures of fewer groups, a value that isn't a Hash, or
  # a Hash whose keys are only known at parse time.
  def test_to_fills_in_fields_initialize_gives_defaults
    g = grammar(ignore: :spacing) do
      rule(:top) { sep_by(either(with_args, captured, bare, upper, shaped), ",") }
      rule(:with_args) { seq(name.as(:name), "(", sep_by(name, ",").as(:args), ")").to(Call) }
      rule(:captured) { match(/(?<name>[a-z]+)!/).captures.to(Call) }
      rule(:bare) { seq(name.as(:name)).to(Call) }
      rule(:upper) { match(/[A-Z]+/).to(Call) }
      rule(:shaped) { seq("~", only(one_of_shapes)).to(Call) }
      rule(:one_of_shapes) do
        either(seq(name.as(:name), "&", sep_by1(name, "&").as(:args)), seq(name.as(:name), "?"), match(/\d+/))
      end
      rule(:name) { match(/[a-z]+/) }
    end
    assert_same_results g, ["f(a, b), g!, h, AB, ~x&y&z, ~x?, ~42", "f()", "f(a,", "~", "~x", "g !", ""]
  end

  # Nodes with no fields and nodes with defaults are built alike.
  def test_nodes_with_no_fields_beside_nodes_with_defaults
    g = grammar(ignore: :spacing) do
      rule(:top) { sep_by(either(str("()").to(Empty), str("{}").means({}).to(Empty), match(/[a-z]+/).to(Call)), ",") }
    end
    assert_same_results g, ["(), ab, {}", "ab", "()", "{}, x,", ""]
  end

  def test_defaults_of_every_literal_kind
    g = grammar { rule(:top) { match(/\w/).to(Defaults) } }
    assert_same_results g, %w[a 1 -]
  end

  # As in the interpreter, where a default is evaluated on each call,
  # a [] default is a new Array for every node.
  def test_mutable_defaults_arent_shared_between_nodes
    g = grammar { rule(:top) { sep_by(match(/[a-z]/).to(Call), str(",")) } }
    parser = Differential.load(g, "CompilerTestParser")
    pairs = [g.parse!("a,b"), parser.new("a,b").parse.value, [g.parse!("c"), g.parse!("c")].map(&:first),
             [parser.new("c").parse.value, parser.new("c").parse.value].map(&:first)]
    pairs.each do |first, second|
      first.args << "x"
      assert_empty second.args
    end
  end

  # --- Diagnostics ---

  def test_label_and_quiet
    g = grammar do
      rule(:top) { seq(match(/\d+/).label("number"), match(/\s+/).quiet, str("x").label("ex")) }
    end
    assert_same_results g, ["1 x", "1x", "a", "1 ", "1 y"]
  end

  # Every check behavior the interpreter's tests cover: rejection, a
  # later alternative getting further, commit, lookaheads, labels, rep,
  # and a checked rule reached twice at one position.
  def test_check
    g = grammar do
      rule(:top) { sep_by(entry, str(";")) }
      rule(:entry) do
        either(str("n=") > even, (str("m") > even).absent >> str("m") >> match(/\d+/),
               even.label("count") >> str("!"), even >> str("?"), str("41") >> str("."),
               match(/\d+/).present > even >> str("#"), str("a").rep.check(:few, "at most two") >> str("b"),
               seq(match(/\d/).check(:even?, "an even digit").rep, str("~")))
      end
      rule(:even) { match(/\d+/).check(:even?, "an even number") }

      private

      def even?(text) = large_integer(text).even? # rubocop:disable Lint/NestedMethodDefinition
      # Truthy rather than true.
      def few(items) = items.size <= 2 ? items : nil # rubocop:disable Lint/NestedMethodDefinition
    end
    assert_same_results g, ["n=42", "n=41", "m41", "m42", "42!", "41!", "42?", "41?", "41.", "42#", "43#", "aab",
                            "aaab", "aac", "24~", "245~", "~", "42!;n=4;41.", "42!;n=3", "", "x"]
  end

  def test_refs_lexemes_and_memo
    g = grammar(ignore: :spacing, keywords: %w[if]) do
      include Birman::Rules::Identifiers
      include Birman::Rules::Numbers

      rule(:top) { either(seq(identifier, "=", number), seq(identifier, "(", number, ")")) }
    end
    assert_same_results g, ["x = 1", "x(1.5)", "if = 1", "x (", "x = ", "iffy=2"]
  end

  # See BirmanTest#test_memo_hits_do_not_repeat_expectations.
  def test_memo_hits_do_not_repeat_expectations
    g = grammar(:l12) do
      rule(:l0) { str("x") }
      (1..12).each do |i|
        below = :"l#{i - 1}"
        rule(:"l#{i}") { either(seq(send(below), "!"), seq(send(below), "?"), send(below)) }
      end
    end
    parser = Differential.load(g, "CompilerTestParser").new("x.")
    parser.parse
    expected = parser.instance_variable_get(:@expected)
    assert_equal 3, expected.size
    assert_equal ['"!"', '"?"', "end of input"], expected
    assert_same_results g, ["x", "x.", "x!?", ""]
  end

  def test_left_recursion_is_rejected_before_generating
    g = grammar { rule(:top) { (top >> "x") | str("y") } }
    error = assert_raises(ArgumentError) { g.to_ruby(namespace: "X") }
    assert_equal "left recursion: :top -> :top (each rule can call the next without consuming input)", error.message
  end

  # /(?=y)/ matches empty only before a "y", so the static check, which
  # tries patterns on "", takes it to consume input.
  def test_left_recursion_the_static_check_misses_raises_like_the_interpreter
    g = grammar { rule(:top) { (match(/(?=y)/) >> top >> "x") | str("y") } }
    parser = Differential.load(g, "CompilerTestParser")
    error = assert_raises(ArgumentError) { parser.new("yx").parse }
    assert_equal "left recursion in rule :top: it can reach itself without consuming input", error.message
  end

  # --- Shape of the generated code ---

  # Hash#delete costs O(size) in Spinel, and an unanchored scan misses
  # by searching the rest of the input.
  # A copied constant or node class named like one of these would shadow it.
  def test_every_runtime_constant_is_reserved
    runtime = File.read(Birman::Compiler::RUNTIME)
    names = runtime.scan(/^\s*([A-Z][A-Z0-9_]*) = /).flatten + runtime.scan(/^\s*class ([A-Z]\w*)/).flatten +
            runtime.scan(/\b(?:raise|rescue) ([A-Z]\w*)/).flatten
    assert_empty names.uniq - Birman::Compiler::RESERVED_CONSTANTS
  end

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
    refute_match(/@v_ref_spacing\b|@mv_spacing\b|@mv_reserved_word\b|@mv_comment\b/, source)
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
