# frozen_string_literal: true

# [file]
# purpose = "Running a matcher without writing a grammar class"
# responsibility = "Birman.parse and Birman.parse!, via a cached anonymous grammar per matcher"
# dependencies = ["Birman::Grammar", "Birman::AST"]
module Birman
  # Parses input with matcher as the whole grammar: Success or Failure,
  # exactly as Grammar.parse, and bad input never raises.
  #
  #   Birman.parse(Birman.seq("let", Birman.match(/\w+/)), "let x", ignore: /\s*/)
  #   # => #<data Birman::Success value=["let", "x"]>
  #
  # ignore is a matcher (a String, Regexp or Matcher), not a rule name:
  # there is no grammar here for a name to refer to. Literals skip it
  # after themselves, and it's skipped at the start of input.
  # [method."Birman.parse"]
  # params = ["matcher: String | Regexp | Matcher", "input: String", "ignore: String | Regexp | Matcher | nil"]
  # returns = "Birman::Success(value) when all of input parses, else Birman::Failure"
  # raises = ["ArgumentError if matcher or ignore refers to a rule (Ref): rules need a grammar class"]
  def self.parse(matcher, input, ignore: nil) = Standalone.grammar(matcher, ignore).parse(input)

  # [method."Birman.parse!"]
  # params = ["matcher, input, ignore: as Birman.parse", "formatter: #call(failure) = ErrorFormatter.new"]
  # returns = "The parsed value"
  # raises = ["Birman::ParseError", "ArgumentError, as Birman.parse"]
  def self.parse!(matcher, input, ignore: nil, **) = Standalone.grammar(matcher, ignore).parse!(input, **)

  # The anonymous grammar classes behind Birman.parse: the matcher is
  # the root rule and ignore the ignore rule. Matchers are immutable
  # values, so equal ones share a class, and with it the per-grammar
  # caches (literal matchers, rule matchers). The cache is bounded, so
  # matchers built afresh for each parse (with a new .map block, say)
  # don't pile up.
  # [module.Standalone]
  # purpose = "Builds and caches the anonymous grammar Birman.parse runs"
  module Standalone
    ROOT = :__standalone_root
    IGNORE = :__standalone_ignore
    LIMIT = 256

    @grammars = {}
    @lock = Mutex.new

    # [method."Standalone.grammar"]
    # params = ["matcher: String | Regexp | Matcher", "ignore: String | Regexp | Matcher | nil"]
    # returns = "A grammar class whose root rule is matcher (to_ebnf, to_ruby and parse work on it)"
    # raises = ["ArgumentError if matcher or ignore refers to a rule"]
    def self.grammar(matcher, ignore)
      key = [matcher, ignore].freeze
      @lock.synchronize do
        @grammars[key] ||= begin
          @grammars.shift if @grammars.size >= LIMIT
          build(matcher, ignore)
        end
      end
    end

    def self.build(matcher, ignore)
      check_no_refs!(matcher, ignore)

      Class.new do
        include Grammar

        root ROOT
        rule(ROOT) { matcher }
        next unless ignore

        rule(IGNORE) { ignore }
        self.ignore IGNORE
      end
    end

    # A Ref here would raise "undefined rule" only when the parse reached
    # it, so a mistake could hide in an untried alternative. Checked up
    # front instead.
    def self.check_no_refs!(*matchers)
      names = matchers.compact.flat_map { AST.refs(Birman.coerce(_1).to_ast) }.uniq
      return if names.empty?

      raise ArgumentError, "undefined rule #{names.map(&:inspect).join(", ")}: " \
                           "a matcher run by Birman.parse can't refer to rules; define them in a grammar class"
    end
    private_class_method :build, :check_no_refs!
  end
end
