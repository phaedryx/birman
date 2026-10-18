# The runtime every parser made by Grammar.to_ruby ships with: the
# generator copies everything after the require below into the parser's
# namespace, so two generated parsers never share (or clash over) one.
# It's written in a deliberately small Ruby subset so Spinel can compile
# it: plain classes (no Data, no Struct), integer byte positions read
# with getbyte, no keyword arguments, no blocks, no metaprogramming. Inline RBS type
# comments give Spinel types it can't infer from empty literals; CRuby
# ignores them.
#
# Generated code calls this as follows:
#
#   - Every match method takes a byte position and returns the byte
#     position where its match ended, or FAIL (-1). Values go in instance
#     variables, one per rule, so each one keeps a single type.
#   - fail_at, merge and the save/restore of @furthest/@expected around a
#     rule call do what Birman::Context's do, so the parser reports the
#     same errors as the interpreter.

require "strscan"

module BirmanRT
  FAIL = -1
  IN_PROGRESS = -2
  # A memo entry abandoned by a commit failure unwinding through it (a
  # lookahead caught the commit). Written instead of deleting the key:
  # Hash#delete on Spinel's Integer-keyed Hash is O(size).
  ABSENT = -3

  # Bignum literals: see BirmanRT.to_i and based_to_i.
  TEN19 = 10_000_000_000_000_000_000
  TWO64 = 18_446_744_073_709_551_616

  # A Failure's expectations before anything has failed. It is never
  # appended to: fail_at replaces an empty list rather than adding to it.
  # Typed through Array.new: a bare [].freeze trips a Spinel pin bug.
  NONE = Array.new(0, "").freeze

  class Committed < StandardError
    attr_reader :pos, :expected

    #: (Integer, Array[String]) -> void
    def initialize(pos, expected)
      @pos = pos
      @expected = expected
      super("committed failure")
    end
  end

  # Base class of every generated node, so a rule whose value is one of
  # several node classes still has a single static type.
  class Node
    attr_reader :span

    # Overridden by every node class: inspect, plus each node's span as
    # [byte_from,byte_to], for the diff tests.
    def dump
      ""
    end
  end

  class Span
    attr_reader :input, :byte_from, :byte_to

    def initialize(input, byte_from, byte_to)
      @input = input
      @byte_from = byte_from
      @byte_to = byte_to
    end

    def text
      @input.byteslice(@byte_from, @byte_to - @byte_from)
    end

    # Character offsets, as Birman::Span's.
    def from
      BirmanRT.char_count(@input, 0, @byte_from)
    end

    def to
      BirmanRT.char_count(@input, 0, @byte_to)
    end

    def line
      n = 1
      i = 0
      while i < @byte_from
        n += 1 if @input.getbyte(i) == 10
        i += 1
      end
      n
    end

    def column
      i = @byte_from
      i -= 1 while i.positive? && @input.getbyte(i - 1) != 10
      BirmanRT.char_count(@input, i, @byte_from) + 1
    end

    def to_s
      "line #{line}, column #{column}"
    end

    def inspect
      "#<Birman::Span #{line}:#{column} #{text.inspect}>"
    end
  end

  class Success
    attr_reader :value

    def initialize(value)
      @value = value
    end

    def success?
      true
    end
  end

  # pos counts characters, as Birman::Failure's does; byte_pos is kept
  # so line, column and found don't have to convert back.
  class Failure
    attr_reader :input, :pos, :byte_pos, :expected, :committed, :reason

    #: (String, Integer, Array[String], bool, String?) -> void
    def initialize(input, byte_pos, expected, committed, reason)
      @input = input
      @byte_pos = byte_pos
      @pos = BirmanRT.char_count(input, 0, byte_pos)
      @expected = expected
      @committed = committed
      @reason = reason
    end

    def success?
      false
    end

    def line
      n = 1
      i = 0
      while i < @byte_pos
        n += 1 if @input.getbyte(i) == 10
        i += 1
      end
      n
    end

    def column
      BirmanRT.char_count(@input, line_start, @byte_pos) + 1
    end

    # The character at the failure, inspected, as Birman::Failure#found.
    def found
      return "end of input" if @byte_pos >= @input.bytesize

      width = BirmanRT.single_byte?(@input) ? 1 : BirmanRT.char_width(@input.getbyte(@byte_pos))
      @input.byteslice(@byte_pos, width).inspect
    end

    # Birman::ErrorFormatter's wording.
    def message
      problem = @reason || "expected #{expected_list}, found #{found}"
      "line #{line}, column #{column}: #{problem}\n  #{source_line}\n  #{caret_indent}^"
    end

    private

    def line_start
      i = @byte_pos
      i -= 1 while i.positive? && @input.getbyte(i - 1) != 10
      i
    end

    def source_line
      start = line_start
      stop = start
      stop += 1 while stop < @input.bytesize && @input.getbyte(stop) != 10
      stop -= 1 if stop > start && @input.getbyte(stop - 1) == 13
      @input.byteslice(start, stop - start)
    end

    # Spaces up to the caret, except tabs stay tabs.
    def caret_indent
      out = +""
      i = line_start
      while i < @byte_pos
        b = @input.getbyte(i)
        out << (b == 9 ? "\t" : " ") unless BirmanRT.continuation?(b) && !BirmanRT.single_byte?(@input)
        i += 1
      end
      out
    end

    def expected_list
      return "nothing" if @expected.empty?
      return @expected[0] if @expected.size == 1

      "#{@expected[0, @expected.size - 1].join(", ")} or #{@expected[@expected.size - 1]}"
    end
  end

  # Binary (and US-ASCII) input has a character per byte; otherwise
  # it's UTF-8 (Parser#initialize refuses anything else).
  def self.single_byte?(input)
    encoding = input.encoding
    encoding == Encoding::BINARY || encoding == Encoding::US_ASCII
  end

  def self.continuation?(b)
    b >= 0x80 && b < 0xC0
  end

  def self.char_width(b)
    return 1 if b < 0x80
    return 2 if b < 0xE0
    return 3 if b < 0xF0

    4
  end

  # Characters in input's bytes from...to: in UTF-8, every byte that
  # isn't a continuation byte starts one.
  def self.char_count(input, from, to)
    return to - from if single_byte?(input)

    n = 0
    i = from
    while i < to
      n += 1 unless continuation?(input.getbyte(i))
      i += 1
    end
    n
  end

  # A value as the diff tests compare it: like inspect, but each node
  # also shows its span as [byte_from,byte_to], and a string that isn't
  # valid UTF-8 (a lone \ud83d escape in JSON, say) shows its bytes,
  # since Spinel's String#inspect writes those differently from CRuby's.
  def self.dump(value)
    case value
    when Node then value.dump
    when Array then dump_array(value)
    when Hash then dump_hash(value)
    when String then value.valid_encoding? ? value.inspect : value.b.inspect
    else value.inspect
    end
  end

  def self.dump_array(values)
    out = +"["
    i = 0
    while i < values.size
      out << ", " if i.positive?
      out << dump(values[i])
      i += 1
    end
    out << "]"
  end

  def self.dump_hash(hash)
    out = +"{"
    keys = hash.keys
    i = 0
    while i < keys.size
      out << ", " if i.positive?
      out << dump(keys[i]) << " => " << dump(hash[keys[i]])
      i += 1
    end
    out << "}"
  end

  # String#to_i, Bignums included. Spinel has no Bignum arithmetic by
  # default (Integer overflow raises), and --int-overflow=promote would
  # box every position in the parser. Arithmetic with a Bignum literal
  # operand does promote, so longer numerals are built 18 digits at a
  # time, scaled through one.
  def self.to_i(text)
    return text.to_i if text.bytesize <= 18

    i = 0
    i += 1 while i < text.bytesize && space?(text.getbyte(i))
    negative = i < text.bytesize && text.getbyte(i) == 45
    i += 1 if i < text.bytesize && (text.getbyte(i) == 45 || text.getbyte(i) == 43)
    n = digits_to_i(integer_digits(text, i))
    negative ? -n : n
  end

  # The digits of the numeral starting at i, as to_i reads it: single
  # underscores between digits are skipped, and anything else ends it.
  def self.integer_digits(text, i)
    out = +""
    while i < text.bytesize
      b = text.getbyte(i)
      if digit?(b)
        out << text.byteslice(i, 1)
      elsif !(b == 95 && !out.empty? && i + 1 < text.bytesize && digit?(text.getbyte(i + 1)))
        break
      end
      i += 1
    end
    out
  end

  def self.digits_to_i(digits)
    n = 0
    i = 0
    while i < digits.bytesize
      k = digits.bytesize - i
      k = 18 if k > 18
      n = (n * (TEN19 / (10**(19 - k)))) + digits.byteslice(i, k).to_i
      i += k
    end
    n
  end

  # Kernel#Integer(value), for actions copied from the grammar: the
  # generator rewrites their one-argument Integer(...) calls to this.
  # Spinel's Integer raises RangeError for anything past 63 bits, so a
  # long string is read here, in Integer's syntax: whitespace around,
  # a sign, a 0x 0b 0o 0d or 0 prefix, digits with single underscores.
  def self.to_integer(value)
    return Integer(value) unless value.is_a?(String) && value.bytesize > 18

    base, digits, negative = integer_syntax(value)
    raise ArgumentError, "invalid value for Integer(): #{value.inspect}" if digits.nil?

    n = base == 10 ? digits_to_i(digits) : based_to_i(digits, base)
    negative ? -n : n
  end

  # [base, digits without underscores, negative], or nil if text isn't
  # an integer in Integer's syntax.
  def self.integer_syntax(text)
    i = 0
    i += 1 while i < text.bytesize && space?(text.getbyte(i))
    negative = i < text.bytesize && text.getbyte(i) == 45
    i += 1 if i < text.bytesize && (text.getbyte(i) == 45 || text.getbyte(i) == 43)
    base = 10
    if text.getbyte(i) == 48 && i + 1 < text.bytesize
      base = prefix_base(text.getbyte(i + 1))
      i += 2 unless base == 8 && !letter_prefix?(text.getbyte(i + 1)) # a bare 0 is an octal digit
    end
    digits = based_digits(text, i, base)
    return nil if digits.nil?

    [base, digits, negative]
  end

  # The base a "0" prefix followed by b gives: 0x 0b 0o 0d, else octal.
  def self.prefix_base(b)
    return 16 if b == 120 || b == 88
    return 2 if b == 98 || b == 66
    return 10 if b == 100 || b == 68

    8
  end

  def self.letter_prefix?(b)
    b == 111 || b == 79
  end

  # The digits from i to the end (bar trailing whitespace), in base, with
  # single underscores between digits dropped; nil if anything else.
  def self.based_digits(text, i, base)
    out = +""
    while i < text.bytesize
      b = text.getbyte(i)
      if digit_in?(b, base)
        out << text.byteslice(i, 1)
      elsif !(b == 95 && !out.empty? && i + 1 < text.bytesize && digit_in?(text.getbyte(i + 1), base))
        break
      end
      i += 1
    end
    i += 1 while i < text.bytesize && space?(text.getbyte(i))
    out.empty? || i < text.bytesize ? nil : out
  end

  def self.digit_in?(b, base)
    return b >= 48 && b < 48 + base if base <= 10

    digit?(b) || (b >= 97 && b <= 102) || (b >= 65 && b <= 70)
  end

  # digits in base 2, 8 or 16, 15 at a time, scaled through a Bignum
  # literal as digits_to_i does.
  def self.based_to_i(digits, base)
    bits = base == 16 ? 4 : (base == 8 ? 3 : 1)
    n = 0
    i = 0
    while i < digits.bytesize
      k = digits.bytesize - i
      k = 15 if k > 15
      n = (n * (TWO64 / (2**(64 - (bits * k))))) + digits.byteslice(i, k).to_i(base)
      i += k
    end
    n
  end

  # Regexp classes, ASCII-only as Ruby's are: \s \d \w.
  def self.space?(b)
    b == 32 || (b >= 9 && b <= 13)
  end

  def self.digit?(b)
    b >= 48 && b <= 57
  end

  def self.word?(b)
    digit?(b) || alpha?(b) || b == 95
  end

  def self.alpha?(b)
    (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
  end

  # The parser state shared by every generated parser, the counterpart
  # of Birman::Context.
  class Parser
    # @rbs @expected: Array[String]

    attr_reader :input

    def initialize(input)
      unless input.encoding == Encoding::UTF_8 || BirmanRT.single_byte?(input)
        raise ArgumentError, "the generated parser reads UTF-8 or binary input, not #{input.encoding}"
      end

      @input = input
      @len = input.bytesize
      @furthest = 0
      @expected = NONE
      @token_ends = {}
      @position = 0
    end

    private

    #: (Integer, String) -> Integer
    def fail_at(pos, what)
      if pos > @furthest
        @furthest = pos
        @expected = [what]
      elsif pos == @furthest
        if @expected.empty?
          @expected = [what]
        else
          @expected << what
        end
      end
      FAIL
    end

    #: (Integer, Array[String]) -> void
    def merge(pos, expected)
      i = 0
      while i < expected.size
        fail_at(pos, expected[i])
        i += 1
      end
    end

    #: (Integer, String) -> void
    def commit_failure(pos, described)
      fail_at(pos, described) if @furthest < pos || @expected.empty?
      raise Committed.new(@furthest, @expected.dup)
    end

    # Context#ignored_after / #token_end.
    #: (Integer, Integer) -> void
    def ignored_after(token_end, pos)
      @token_ends[pos] = token_end if pos > token_end
    end

    #: (Integer) -> Integer
    def token_end(pos)
      e = @token_ends[pos]
      e.nil? ? pos : e
    end

    # Where a node's span ends: the last token's end, with trailing
    # whitespace and NULs trimmed (String#rstrip).
    #: (Integer, Integer) -> Integer
    def span_end(from, to)
      to = token_end(to)
      while to > from
        b = @input.getbyte(to - 1)
        break unless b.zero? || BirmanRT.space?(b)

        to -= 1
      end
      to
    end

    #: (Integer, Integer) -> Span
    def span(from, to)
      Span.new(@input, from, span_end(from, to))
    end

    #: (Integer, Array[String], bool) -> Failure
    def failure(byte_pos, expected, committed)
      Failure.new(@input, byte_pos, expected.uniq, committed, nil)
    end

    #: (Integer, String) -> Failure
    def failure_because(byte_pos, reason)
      Failure.new(@input, byte_pos, [], false, reason)
    end

    # The end of a Label, after its isolated inner match: keep the
    # deeper error, or say "expected <name>" if it got nowhere.
    #: (Integer, Integer, Integer, Array[String], String) -> Integer
    def label_end(p, q, of, oe, name)
      f = @furthest
      ex = @expected
      @furthest = of
      @expected = oe
      if f == p && (q == FAIL || (q == p && !ex.empty?))
        fail_at(p, name)
      else
        merge(f, ex)
      end
      q
    end

    # The end of a positive lookahead (Context#peek?), after its isolated
    # inner match g: whether it matched. If not, the failure is recorded
    # at p, as what it expected there or as the lookahead itself.
    #: (Integer, Integer, Integer, Array[String], String) -> bool
    def peek_end(p, g, of, oe, described)
      f = @furthest
      ex = @expected
      @furthest = of
      @expected = oe
      return true if g != FAIL

      if f == p && !ex.empty?
        merge(p, ex)
      else
        fail_at(p, described)
      end
      false
    end

    # Exactly text's bytes at p?
    #: (Integer, String) -> bool
    def bytes_at?(p, text)
      n = text.bytesize
      return false if p + n > @len

      i = 0
      while i < n
        return false if @input.getbyte(p + i) != text.getbyte(i)

        i += 1
      end
      true
    end

    def left_recursion(name)
      raise ArgumentError, "left recursion in rule :#{name}: it can reach itself without consuming input"
    end
  end
end
