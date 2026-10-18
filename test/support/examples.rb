# frozen_string_literal: true

# The three grammars generated parsers are checked against (the README's,
# examples/calc.rb and examples/json.rb), each with the inputs to check:
# fixed edge cases, random token soup, and for calc and json, valid
# documents built from the grammar plus one-character mutations of them.
require "json"
require_relative "differential"
require_relative "../../examples/calc"
require_relative "../../examples/json"

module Examples
  # The README's grammar.
  module Lang
    # let x = 42
    class Grammar
      include Birman::Grammar
      include Birman::Rules::Whitespace
      include Birman::Rules::Numbers
      include Birman::Rules::Identifiers

      Let = node(:name, :value)
      Num = node(:value)

      root :let_statement
      ignore :spacing
      keywords "let"

      rule(:let_statement) do
        seq("let", commit, identifier.as(:name), "=", number.to(Num).as(:value)).to(Let)
      end
    end
  end

  Example = Data.define(:name, :grammar, :namespace, :inputs)

  module_function

  def all(count) = [let(count), calc(count), json(count)]

  def let(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    Example.new("let", Lang::Grammar, "LangCompiled", LET_FIXED + Differential.fuzz(LET_TOKENS, rng, count, 7))
  end

  def calc(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    programs = Array.new(count / 2) { CalcGen.program(rng, rng.rand(1..4)) }
    mutants = programs.map { Differential.mutate(rng, _1, CalcGen::REPLACEMENTS) }
    inputs = CALC_FIXED + Differential.fuzz(CALC_TOKENS, rng, count, 12) + programs + mutants
    Example.new("calc", Calc::Grammar, "CalcCompiled", inputs)
  end

  def json(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    docs = Array.new(count / 2) { JSONGen.document(rng) }
    mutants = docs.map { Differential.mutate(rng, _1, JSONGen::REPLACEMENTS) }
    inputs = JSON_FIXED + Differential.fuzz(JSON_TOKENS, rng, count, 10) + docs + mutants
    Example.new("json", JSONExample::Grammar, "JSONCompiled", inputs)
  end

  LET_FIXED = [
    "let x = 42", "let x = 4.5 ", "  let\tx=1", "let x = 1\n", "let\nx\n=\n7\n",
    "", " ", "let", "let ", "letx = 1", "let = 1", "let let = 1", "let lets = 1",
    "let x", "let x =", "let x = ", "let x = y", "let x = 1 2", "let x = 1.",
    "let x = .5", "let x = 1.5.5", "let 9 = 1", "let _a9 = 007",
    "let letä = 1", "let lét = 1", "let x→ = 1", "let let→ = 1", "let\tx = \t", "lét x = 1",
    "let x = 1 # c", "let x\r\n= 1",
    "let x = 9223372036854775807", "let x = 9223372036854775808", "let x = 00000000000000000000001",
    "let x = 99999999999999999999", "let x = 000000000000000000000000000000000000042"
  ].freeze

  LET_TOKENS = ["let", "lets", "x", "_y1", "=", "1", "42", "4.5", "1.", ".", " ", "  ", "\t", "\n",
                "ä", "é", "→", "9", "#", "letä", "", "9223372036854775807"].freeze

  CALC_FIXED = [
    "", "let x = 1", "print 1 + 2 * 3", "print (1 + 2) * 3", "let a = 1 let b = a - 2 print a / b",
    "print if 1 then 2 else 3", "print if x then if y then 1 else 2 else 3 + 4",
    %(print "hi\\n" + "a\\tb" + "\\q" + "é→"), %(print "unclosed), %(print "line\nbreak"),
    "let = 4", "print (1 + 2", "print if 1 then 2", "print 1 +", "print 1 + + 2", "1 + 2 3",
    "# only a comment", "let x = 1 # trailing\nprint x # again", "print\t1\n*\n2",
    "let letter = 1", "let lets = print", "print printer", "print if", "if 1 then 2 else 3",
    "print 1.5 * 2.25", "print 1.", "print .5", "print 007", "print 9223372036854775808",
    "print 123456789012345678901234567890123456789 + 1",
    "print ((((((((((1))))))))))", "print \"\\", "print \"a\\\"b\"", ")", "let x = 1 )",
    "print -1", "print x→", "print let→", "print é", "print 1 ++ 2"
  ].freeze

  CALC_TOKENS = ["let", "print", "if", "then", "else", "x", "y1", "_z", "letter", "=", "+", "-", "*", "/",
                 "(", ")", "1", "42", "2.5", "1.", " ", " ", " ", "\n", "\t", "# c\n", "\"", "\"s\"",
                 "\"a\\n\"", "\\", "é", "→", "ä"].freeze

  JSON_FIXED = [
    "0", "-0", "42", "-17", "3.25", "1e3", "1E-2", "-2.5e+10", "12345678901234567890",
    "-98765432109876543210123", "1e400", "1.5e-400",
    '""', '"plain"', '"tab\\tnewline\\nquote\\"slash\\/back\\\\"', '"\\u00e9\\u4e2d"',
    '"\\ud83d\\udc08"', "\"café \u{1F408}\"", '"\\b\\f\\r"', '"\\ud83d"', '"\\udc08\\ud83d"',
    "true", "false", "null",
    "[]", "{}", "[1, [2, [3, []]]]", '{"a": {"b": {"c": {}}}}', '{"a": 1, "a": 2}',
    ' { "a" : [ 1 , true , null ] , "b" : "x" } ',
    "\t\n\r [1,\n2]\n",
    "", "[1, 2,]", '{"a": 1,}', '{"a" 1}', "{a: 1}", "['x']", '"unterminated',
    "[1, 2", "01", "1.", ".5", "+1", "tru", "nul", "truex", '"\\x"', "\"a\u0001b\"",
    "[1] [2]", "// comment\n1", "{", "[", '{"a"', '{"a":', "\u00a0[]", "[1\u00a0]", "-", "1e", "1e+",
    '"\\u12"', '"\\uZZZZ"', "nulll", "[true false]"
  ].freeze

  JSON_TOKENS = ["{", "}", "[", "]", ",", ":", " ", "\n", "\"", "\"k\"", "\"\\n\"", "\"\\u00e9\"", "\\",
                 "1", "-", "0", ".5", "e3", "true", "false", "null", "nul", "é", "\t", "12345678901234567890"].freeze

  # Arguments for BirmanRT.to_integer, which copied actions' Integer(x)
  # calls become, to compare with Kernel#Integer.
  INTEGER_CASES = [
    "010", "0#{"1" * 25}", "09#{"1" * 20}", "-#{"7" * 25}", "+#{"7" * 25}", "1_000_000_000_000_000_000_000",
    " 12", "12 ", " #{"3" * 22}\n", "0x1f", "", "-", "1__0", "1#{"0" * 18}", "#{"1" * 20}_", "_#{"1" * 20}",
    "1#{"_1" * 12}", "1#{"__1" * 12}", "#{"9" * 19}x", "0x#{"f" * 20}", "-0X#{"aB" * 10}", "0b#{"10" * 40}",
    "0o#{"7" * 25}", "0d#{"9" * 20}", "0_#{"7" * 20}", "0x_#{"f" * 20}", "0x#{"f" * 20}g", "0#{"8" * 20}",
    "0b#{"2" * 20}", "  -#{"5" * 30}  ", "1e#{"0" * 20}", 1.5, 42, nil
  ].freeze

  # Valid calc programs, built from the grammar.
  module CalcGen
    module_function

    SPACES = [" ", " ", "  ", "\n", "\t", " # note\n"].freeze
    REPLACEMENTS = %w[( ) " = + let if then 1 x é].freeze

    def sp(rng) = SPACES.sample(random: rng)
    def name(rng) = %w[x y total _t1 letter iffy].sample(random: rng)

    def atom(rng, depth)
      case rng.rand(depth > 3 ? 3 : 5)
      when 0 then [rng.rand(1000).to_s, "#{rng.rand(100)}.#{rng.rand(100)}"].sample(random: rng)
      when 1 then name(rng)
      when 2 then %("#{["hi", "a\\nb", "\\\"q\\\"", "é→", ""].sample(random: rng)}")
      else "(#{sp(rng)}#{expr(rng, depth + 1)}#{sp(rng)})"
      end
    end

    def expr(rng, depth = 0)
      if depth < 3 && rng.rand(6).zero?
        return "if #{expr(rng, depth + 1)} then #{expr(rng, depth + 1)} else #{expr(rng, depth + 1)}"
      end

      parts = Array.new(rng.rand(1..4)) { atom(rng, depth) }
      parts.each_with_index.map do |a, i|
        i.zero? ? a : "#{sp(rng)}#{%w[+ - * /].sample(random: rng)}#{sp(rng)}#{a}"
      end.join
    end

    def statement(rng)
      case rng.rand(3)
      when 0 then "let #{name(rng)}#{sp(rng)}=#{sp(rng)}#{expr(rng)}"
      when 1 then "print #{expr(rng)}"
      else expr(rng)
      end
    end

    def program(rng, statements) = Array.new(statements) { statement(rng) }.join(sp(rng))
  end

  # Valid JSON documents, with JSON's whitespace sprinkled between tokens.
  module JSONGen
    module_function

    SPACES = ["", "", " ", "\n", "\t", "\r\n  "].freeze
    REPLACEMENTS = ["{", "}", "[", "]", ",", ":", "\"", "\\", "1", "e", "-", ".", "n", "é", " "].freeze
    STRINGS = ["", "a", "key", "é→", "tab\\t", "q\\\"", "\\u00e9", "\\ud83d\\udc08", "\\/\\\\", "\\b\\f\\n\\r"].freeze
    NUMBERS = ["0", "-1", "42", "3.25", "-0.5", "1e3", "2E-2", "6.02e+23", "12345678901234567890"].freeze

    def sp(rng) = SPACES.sample(random: rng)
    def string(rng) = %("#{STRINGS.sample(random: rng)}")

    def value(rng, depth)
      case rng.rand(depth > 3 ? 4 : 6)
      when 0 then string(rng)
      when 1 then NUMBERS.sample(random: rng)
      when 2 then %w[true false null].sample(random: rng)
      when 3 then string(rng)
      when 4 then "[#{sp(rng)}#{Array.new(rng.rand(0..3)) do
        value(rng, depth + 1)
      end.join("#{sp(rng)},#{sp(rng)}")}#{sp(rng)}]"
      else
        members = Array.new(rng.rand(0..3)) { "#{string(rng)}#{sp(rng)}:#{sp(rng)}#{value(rng, depth + 1)}" }
        "{#{sp(rng)}#{members.join("#{sp(rng)},#{sp(rng)}")}#{sp(rng)}}"
      end
    end

    def document(rng) = "#{sp(rng)}#{value(rng, 0)}#{sp(rng)}"
  end
end
