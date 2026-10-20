# frozen_string_literal: true

# The grammars generated parsers are checked against (the README's,
# examples/calc.rb, json.rb and email.rb, and Examples::Numbers), each
# with the inputs to check: fixed edge cases, random token soup, and
# valid documents built from the grammar (plus, for calc, json and
# email, one-character mutations of them).
require "json"
require_relative "differential"
require_relative "../../examples/calc"
require_relative "../../examples/json"
require_relative "../../examples/email"

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

  # Parentheses where each level looks ahead at the next (nest.present):
  # every level of nesting is an active lookahead.
  module Nest
    # (((...)))
    class Grammar
      include Birman::Grammar

      root :nest
      rule(:nest) { seq(str("("), (nest.present >> nest).maybe, str(")")) }
    end

    def self.input(depth) = "#{"(" * depth}#{")" * depth}"
  end

  # Numbers in any base, read by Grammar#large_integer: "ff", "16:ff",
  # "-0x_ff", '16:" ff\n"' (Integer's own syntax decides what's valid),
  # long enough to be Bignums.
  module Numbers
    # 16:ff, 0b101, -123
    class Grammar
      include Birman::Grammar
      include Birman::Rules::Whitespace

      root :numbers
      ignore :spacing

      rule(:numbers) { sep_by(number, ",") }
      rule(:number) { either(based, text.action(:auto)) }
      rule(:based) { seq(match(/\d\d?(?=:)/).as(:base), ":", commit, text.as(:digits)).action(:in_base) }

      # Quoted, a number can have whitespace (or anything) around and in it.
      rule(:text) { either(seq(str('"'), only(match(/[^"]*/)), str('"')), match(/[-+]?\w+/)) }

      private

      def auto(text)
        large_integer(text)
      rescue ArgumentError
        "invalid"
      end

      def in_base(parts)
        large_integer(parts[:digits], large_integer(parts[:base], 10))
      rescue ArgumentError
        "invalid"
      end
    end
  end

  # Rules in a cycle (a -> b -> a) whose values are all Strings, read by
  # .map(:to_i): their types are worked out together.
  module Cycles
    # !(5)7, !x((99))1
    class Grammar
      include Birman::Grammar

      root :start
      rule(:start) { either(str("!") >> top, a) }
      rule(:a) { either(match(/\d+/), b) }
      rule(:b) { either(str("x"), between("(", ")", a)) }
      rule(:top) { b.maybe.map(:to_i) >> a.map(:to_i) }
    end

    TOKENS = ["!", "(", ")", "x", "1", "7", "9" * 25, "0"].freeze
  end

  # Entries each checked by a grammar method (.check): dates that
  # exist, ascending ranges, even numbers after "even" (committed),
  # vowels. 2024-02-29, 1979-02-30 (rejected), 3..7, 7..3 (rejected).
  module Dates
    # on 2024-02-29, 3..7, even 12, aei
    class Grammar
      include Birman::Grammar
      include Birman::Rules::Whitespace

      DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze

      root :entries
      ignore :spacing

      rule(:entries) { sep_by(entry, ",") }
      rule(:entry) do
        either(seq("on", commit, date), date, range, seq("even", even), number,
               match(/[a-z]/).check(:vowel?, "a vowel").rep(1).label("vowels"))
      end
      rule(:even) { number.present > number.check(:even?, "an even number") }
      lexeme(:date) { match(/\d{4}-\d\d-\d\d/).check(:real_date?, "a real date") }
      rule(:range) { seq(number.as(:from), "..", number.as(:to)).check(:ascending?, "an ascending range") }
      lexeme(:number) { match(/[1-9]\d*|0/) }

      private

      def real_date?(text)
        year = digits(text, 0, 4)
        month = digits(text, 5, 2)
        day = digits(text, 8, 2)
        return false if month < 1 || month > 12 || day < 1

        leap = (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)
        day <= (month == 2 && leap ? 29 : DAYS[month - 1])
      end

      # The number written in text's count bytes from from (all digits).
      def digits(text, from, count)
        n = 0
        i = from
        while i < from + count
          n = (n * 10) + text.getbyte(i) - 48
          i += 1
        end
        n
      end

      # Compared as text, so numbers of any length work.
      def ascending?(range)
        from = range[:from]
        to = range[:to]
        from.size < to.size || (from.size == to.size && from <= to)
      end

      def even?(text) = (text.getbyte(text.bytesize - 1) % 2).zero?
      def vowel?(text) = "aeiou".include?(text)
    end

    TOKENS = ["on", "even", "2024-02-29", "1979-02-30", "2023-02-29", "1900-02-29", "2000-02-29", "2024-13-01",
              "2024-00-10", "2024-04-31", "2024-12-31", "..", ",", " ", "3", "7", "10", "0", "12",
              "9" * 25, "a", "e", "x", "-", "1"].freeze
  end

  # Grammars whose large_integer calls only ever see one type: in a
  # Spinel binary, each must compile and agree on its own.
  module OneType
    FLOAT = /[-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?/

    # Floats only: 1e30, -1.5
    class Floats
      include Birman::Grammar
      include Birman::Rules::Whitespace

      root :numbers
      ignore :spacing
      rule(:numbers) { sep_by(match(FLOAT).action(:big), ",") }

      private

      def big(text)
        large_integer(Float(text))
      rescue FloatDomainError
        "not finite"
      end
    end

    # Floats with a base, which Integer refuses.
    class FloatsWithBase
      include Birman::Grammar
      include Birman::Rules::Whitespace

      root :numbers
      ignore :spacing
      rule(:numbers) { sep_by(match(FLOAT).action(:big), ",") }

      private

      def big(text)
        large_integer(Float(text), 10)
      rescue ArgumentError
        "refused"
      end
    end

    # Integers only: each word's length, scaled.
    class Integers
      include Birman::Grammar
      include Birman::Rules::Whitespace

      root :words
      ignore :spacing
      rule(:words) { sep_by(match(/\w+/).action(:big), ",") }

      private

      def big(text) = large_integer(text.size * 1_000_000_007)
    end

    def self.floats(rng, count)
      Array.new(count) do
        Array.new(rng.rand(1..3)) do
          mantissa = format("%.#{rng.rand(0..17)}f", rng.rand * 10).sub(/\.?0+\z/, "")
          "#{["", "-", "+"].sample(random: rng)}#{mantissa.empty? ? "0" : mantissa}e#{rng.rand(-20..330)}"
        end.join(", ")
      end
    end
  end

  Example = Data.define(:name, :grammar, :namespace, :inputs)

  module_function

  def all(count)
    [let(count), calc(count), json(count), email(count), numbers(count), cycles(count), dates(count), *one_type(count)]
  end

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

  def email(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    addresses = Array.new(count / 2) { EmailGen.address(rng) }
    mutants = addresses.map { Differential.mutate(rng, _1, EmailGen::REPLACEMENTS) }
    inputs = EMAIL_FIXED + Differential.fuzz(EMAIL_TOKENS, rng, count, 10) + addresses + mutants
    Example.new("email", EmailExample::Grammar, "EmailCompiled", inputs)
  end

  def numbers(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    lists = Array.new(count) { NumbersGen.list(rng) }
    inputs = NUMBERS_FIXED + Differential.fuzz(NUMBERS_TOKENS, rng, count, 8) + lists
    Example.new("numbers", Numbers::Grammar, "NumbersCompiled", inputs)
  end

  def cycles(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    soup = Differential.fuzz(Cycles::TOKENS, rng, count, 8)
    inputs = ["!(5)7", "!x(#{"9" * 25})", "!((#{"9" * 25}))1", "!1", "(7)", "!", ""] + soup + soup.map { "!#{_1}" }
    Example.new("cycles", Cycles::Grammar, "CyclesCompiled", inputs)
  end

  def dates(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    fixed = ["on 2024-02-29", "2024-02-29, 3..7, even 12, aei", "1979-02-30", "on 1979-02-30", "7..3", "3..3",
             "#{"9" * 25}..1#{"0" * 25}", "1#{"0" * 25}..#{"9" * 25}", "even 13", "even x", "aex", "x", "", "0..10",
             "2000-02-29, 1900-02-29", "2024-04-31", "2024-06-30 , 10 .. 9"]
    entries = Array.new(count / 2) { Array.new(rng.rand(1..4)) { Dates::TOKENS.sample(random: rng) }.join(", ") }
    inputs = fixed + Differential.fuzz(Dates::TOKENS, rng, count, 8) + entries
    Example.new("dates", Dates::Grammar, "DatesCompiled", inputs)
  end

  def one_type(count)
    rng = Random.new(Integer(ENV.fetch("SEED", 1)))
    fixed = ["1.5", "-0.0", "1e30", "-1.7976931348623157e308", "9.3e18", "4611686018427387904", "1e400", "-1e400",
             "1e18, 2e19, 1.5e300", "", "1e", "12"]
    floats = fixed + OneType.floats(rng, count / 4)
    [Example.new("floats", OneType::Floats, "FloatsCompiled", floats),
     Example.new("floatbase", OneType::FloatsWithBase, "FloatBaseCompiled", fixed),
     Example.new("integers", OneType::Integers, "IntegersCompiled", ["abc", "a, bb, #{"c" * 5000}", "", "a,"])]
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
    "print -1", "print x→", "print let→", "print é", "print 1 ++ 2",
    # Deep nesting: Spinel allows 64 active begin/rescue/ensure blocks.
    "print #{"(" * 200}1#{")" * 200}", "print #{"(" * 200}1#{")" * 199}",
    "print #{"if 1 then " * 100}1#{" else 2" * 100}"
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
    '"\\u12"', '"\\uZZZZ"', "nulll", "[true false]",
    "#{"[" * 300}#{"]" * 300}", "#{"[" * 300}#{"]" * 299}", "#{'{"a":' * 200}1#{"}" * 200}",
    "\"a\xFFb\"", "[1,\n \"é\xE3\x81\"]", "\xC0\x80", "[\"\xED\xA0\x80\"]"
  ].freeze

  JSON_TOKENS = ["{", "}", "[", "]", ",", ":", " ", "\n", "\"", "\"k\"", "\"\\n\"", "\"\\u00e9\"", "\\",
                 "1", "-", "0", ".5", "e3", "true", "false", "null", "nul", "é", "\t", "12345678901234567890"].freeze

  # Arguments for BirmanRT.to_integer (Grammar#large_integer in a
  # generated parser), to compare with Kernel#Integer: values with no
  # base, then [value, base] pairs.
  INTEGER_CASES = [
    "010", "0#{"1" * 25}", "09#{"1" * 20}", "-#{"7" * 25}", "+#{"7" * 25}", "1_000_000_000_000_000_000_000",
    " 12", "12 ", " #{"3" * 22}\n", "0x1f", "", "-", "1__0", "1#{"0" * 18}", "#{"1" * 20}_", "_#{"1" * 20}",
    "1#{"_1" * 12}", "1#{"__1" * 12}", "#{"9" * 19}x", "0x#{"f" * 20}", "-0X#{"aB" * 10}", "0b#{"10" * 40}",
    "0o#{"7" * 25}", "0d#{"9" * 20}", "0_#{"7" * 20}", "0x_#{"f" * 20}", "0x#{"f" * 20}g", "0#{"8" * 20}",
    "0b#{"2" * 20}", "  -#{"5" * 30}  ", "1e#{"0" * 20}", 1.5, 42, nil
  ].freeze

  INTEGER_BASE_CASES = [
    ["ff", 16], ["0x1f", 16], ["0b1", 16], ["0x1f", 10], ["017", 8], ["0o17", 8], ["0d9", 10], ["0b1", 8],
    ["z", 36], ["Z", 36], ["0x1f", 0], ["010", 0], ["12", 3], ["10", 1], ["10", 37], [" 1f ", 16],
    ["f" * 30, 16], ["0x#{"f" * 30}", 16], ["0X#{"aB" * 12}", 16], ["0x#{"f" * 30}", 10], ["-#{"z" * 25}", 36],
    ["#{"Zz" * 15}_9", 36], ["1#{"0" * 40}", 2], ["0b#{"1" * 70}", 2], ["0b#{"1" * 70}", 8], ["0o#{"7" * 30}", 8],
    ["0#{"7" * 30}", 8], ["0d#{"9" * 30}", 10], ["  +#{"9" * 30}\n", 10], ["2" * 45, 3], ["6" * 30, 7],
    ["a" * 30, 11], ["b" * 30, 11], ["0x#{"1" * 30}", 36], ["#{"1" * 30}__1", 10], ["_#{"1" * 30}", 16],
    ["0x_#{"f" * 30}", 16], ["0x#{"f" * 30}", 0], ["0#{"7" * 30}", 0], ["1" * 30, 37], [12.5, 0], [12, 16],
    ["ahb6e38ca03a02683", 20], ["0x#{"f" * 16}", 0], ["f" * 16, 16], ["z" * 13, 36], ["1\0", 16], [nil, 10],
    ["f" * 30, 16.0], ["fff", 16.9], ["1" * 20, nil], ["1" * 20, "16"], ["1" * 20, true], ["1" * 20, :a]
  ].freeze

  # Floats for BirmanRT.to_integer (base 0): exact past 63 bits, where
  # Spinel's own Float#to_i saturates.
  FLOAT_CASES = [
    2.0**62, 2.0**63, (2.0**63) + 2048, -(2.0**63), 1e30, -1e30, Float::MAX, -Float::MAX, 2.0**1023, 4.5e15,
    -0.0, 0.5, -1.5, 4_611_686_018_427_387_903.0, 9.3e18, 2.0**61, 2.0**64, 2.0**65,
    2.0**123, 2.0**124, 2.0**125, 2.0**126, Float::NAN, Float::INFINITY, -Float::INFINITY,
    *Array.new(40) { |i| (i.even? ? 1 : -1) * Random.new(i).rand * (10**Random.new(i).rand(-3..300)).to_f }
  ].freeze

  # A Float as a Ruby expression (NaN and Infinity have no literal).
  def self.float_source(value)
    return "(0.0 / 0.0)" if value.nan?
    return value.positive? ? "(1.0 / 0.0)" : "(-1.0 / 0.0)" if value.infinite?

    value.inspect
  end

  # Bases a Spinel binary doesn't take as CRuby does: its Integer refuses
  # negative ones ("invalid radix"). Checked under CRuby only.
  NEGATIVE_BASE_CASES = [["11", -2], ["0x10", -10], ["1" * 20, -2]].freeze

  NUMBERS_FIXED = [
    *INTEGER_CASES.grep(String).grep_v(/[,:\s]|\A\z/),
    *INTEGER_BASE_CASES.filter_map { |v, b| "#{b}:#{v}" if v.is_a?(String) && !v.match?(/[,:\s]|\A\z/) },
    "16:ff, 0x10, 2:#{"1" * 80}", "36:#{"z" * 40}", "0:0x#{"f" * 30}", "16:", "1:1", "37:1", "",
    *INTEGER_BASE_CASES.filter_map { |v, b| %(#{b}:"#{v}") if v.is_a?(String) && !v.include?('"') },
    *INTEGER_CASES.grep(String).map { %("#{_1}") }, %(16:"   #{"f" * 5}"), %("  0x#{"f" * 20} \t\n"), %("1 2"), %("1\0")
  ].freeze

  NUMBERS_TOKENS = ["0x", "0b", "0o", "0d", "0", "1", "7", "9", "f", "z", "Z", "_", "-", "+", ",", " ", ":", "16:",
                    "36:", "2:", "8:", "1" * 20, "f" * 20].freeze

  # Valid and invalid numbers, in random bases, mostly past 63 bits.
  module NumbersGen
    module_function

    DIGITS = [*"0".."9", *"a".."z"].freeze
    PREFIXES = { 2 => "0b", 8 => "0o", 10 => "0d", 16 => "0x" }.freeze

    def list(rng) = Array.new(rng.rand(1..3)) { number(rng) }.join(", ")

    def number(rng)
      base = rng.rand(2..36)
      digits = Array.new(rng.rand(1..60)) { DIGITS[rng.rand(rng.rand(4).zero? ? 36 : base)] }.join
      digits = digits.chars.each_slice(rng.rand(1..9)).map(&:join).join("_") if rng.rand(4).zero?
      sign = ["", "-", "+"].sample(random: rng)
      text = quoted(rng, "#{sign}#{PREFIXES[base] if rng.rand(2).zero?}#{digits}")
      return "#{base}:#{text}" unless rng.rand(3).zero?

      quoted(rng, "#{sign}#{%w[0x 0b 0o 0d].sample(random: rng)}#{digits}")
    end

    # Sometimes in quotes, with whitespace around (or in) it.
    def quoted(rng, text)
      return text if rng.rand(2).zero?

      space = -> { [" ", "  ", "\t", "\n", " \r\n", ""].sample(random: rng) }
      text = text.dup.insert(rng.rand(text.size + 1), space.call) if rng.rand(8).zero?
      %("#{space.call}#{text}#{space.call}")
    end
  end

  EMAIL_FIXED = [
    "jo@example.com", "first.last+tag@sub.example.org", "!#$%&'*+/=?^_`{|}~-@x.io", '"jo smith"@example.com',
    '"a\\"b\\\\c"@x', "\"fold\r\n here\"@x", "jo (a (nested) comment) @ (here) example.com (end)",
    "jö@xn--bcher-kva.example", "a@#{"b" * 63}.c", "jo@[192.168.0.1]", "jo@[1.2.3.256]", "jo@[ IPv6:::1 ]",
    "jo@[1.2.3.4.5]", "jo@[01.2.3.4]", "jo@[]", "jo@[\r\n 1]", "(c)jo@x", "jo@x(c)", "jo@x (c\\)d)",
    "", "jo", "jo@", "@example.com", "jo..x@example.com", ".jo@example.com", "jo.@example.com",
    "jo@-example.com", "jo@example-.com", "jo@exa_mple.com", "jo@example..com", "\"unclosed@example.com",
    "jo(oops@example.com", "jo@[1.2.3.4", "jo@#{"b" * 64}.c", "jo@#{(["a" * 63] * 4).join(".")}",
    "jo smith@example.com", "jo@bücher.example", "jo@ ", "jo @", "jo@x\r\n", "\"\\é\"@x", "jo@x.", "jo@.x",
    "\"\"@x", "jo(((deep)))@x", "jo(\\(@x", "jo@[a]b", "\r\n jo@x", "jo\r\n\r\n @x",
    # Length bounds: Spinel's regexp engine once raised on a failing
    # label of 64+ characters (see examples/email.rb).
    "jo@#{"b" * 300}.c", "jo@#{"b" * 5000}", "jo@x.#{"b" * 64}", "jo@#{"b" * 63}-.c", "jo@#{"b" * 62}-b.c",
    "jo@#{%w[b c d].map { _1 * 63 }.join(".")}.#{"e" * 61}", "jo@#{%w[b c d].map { _1 * 63 }.join(".")}.#{"e" * 62}",
    "jo@#{Array.new(127, "a").join(".")}", "jo@#{Array.new(128, "a").join(".")}",
    "jo(#{"(" * 50}#{")" * 50})@x", "jo(#{"(" * 50}#{")" * 49}@x"
  ].freeze

  EMAIL_TOKENS = ["jo", "x", "a.b", ".", "@", "example", "com", "-", "--", "\"", "\\", "(", ")", "[", "]", " ",
                  "\t", "\r\n", "1", "192.168.0.1", "é", "_", "+", "IPv6:", ":"].freeze

  # Valid addresses, built from the grammar.
  module EmailGen
    module_function

    REPLACEMENTS = ["@", ".", "\"", "(", ")", "[", "]", " ", "\\", "-", "é", "_", "\r\n"].freeze
    ATOMS = ["jo", "first", "x", "o'neil", "a+b", "é", "{}", "1"].freeze
    LABELS = ["example", "com", "a", "b-c", "xn--bcher-kva", "x1", "9"].freeze

    def cfws(rng)
      case rng.rand(8)
      when 0, 1, 2 then ""
      when 3 then [" ", "\r\n ", "\t"].sample(random: rng)
      else [" ", ""].sample(random: rng) + comment(rng, rng.rand(1..4))
      end
    end

    # A comment nested depth levels deep, with escapes and folding.
    def comment(rng, depth)
      inner = depth > 1 ? comment(rng, depth - 1) : ""
      text = ["c", "a \\) b", "é", "x\r\n y", ""].sample(random: rng)
      "(#{text}#{" " if rng.rand(2).zero?}#{inner})"
    end

    def local(rng)
      quoted = ["jo smith", "a\\\"b", "", "é→", "tab\there", "\\\\\\(", "fold\r\n x", "\\ \\é"]
      return %("#{quoted.sample(random: rng)}") if rng.rand(4).zero?

      Array.new(rng.rand(1..3)) { ATOMS.sample(random: rng) }.join(".")
    end

    def domain(rng)
      case rng.rand(5)
      when 0 then "[#{Array.new(4) { rng.rand(256) }.join(".")}]"
      when 1 then ["[IPv6:::1]", "[ x ]", "[1.2.3.999]"].sample(random: rng)
      else Array.new(rng.rand(1..3)) { rng.rand(10).zero? ? "#{"b" * 62}c" : LABELS.sample(random: rng) }.join(".")
      end
    end

    def address(rng) = "#{cfws(rng)}#{local(rng)}#{cfws(rng)}@#{cfws(rng)}#{domain(rng)}#{cfws(rng)}"
  end

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
