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
  #
  # consume: false and offset: are Grammar#parse's. There is no root:
  # option, since matcher is the only rule; passing one raises
  # ArgumentError (unknown keyword).
  # [method."Birman.parse"]
  # params = [
  #   "matcher: String | Regexp | Matcher", "input: String", "ignore: String | Regexp | Matcher | nil",
  #   "consume: Boolean = true (false: a prefix of input may match)",
  #   "offset: Integer = 0 (the character offset to start at; positions still count from 0)"
  # ]
  # returns = "Birman::Success(value) when all of input parses (or a prefix, with consume: false), else Birman::Failure"
  # raises = [
  #   "ArgumentError if matcher or ignore refers to a rule, or an .action/.check method Birman lacks",
  #   "ArgumentError for an offset: that isn't an Integer, or is negative or past the end of input"
  # ]
  def self.parse(matcher, input, ignore: nil, consume: true, offset: 0)
    Standalone.grammar(matcher, ignore).parse(input, consume:, offset:)
  end

  # [method."Birman.parse!"]
  # params = [
  #   "matcher, input, ignore, consume, offset: as Birman.parse", "formatter: #call(failure) = ErrorFormatter.new"
  # ]
  # returns = "The parsed value"
  # raises = ["Birman::ParseError", "ArgumentError, as Birman.parse"]
  def self.parse!(matcher, input, ignore: nil, consume: true, offset: 0, formatter: ErrorFormatter.new) # rubocop:disable Metrics/ParameterLists
    Standalone.grammar(matcher, ignore).parse!(input, consume:, offset:, formatter:)
  end

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
    # raises = ["ArgumentError if matcher or ignore refers to a rule, or an .action/.check method Birman lacks"]
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
      grammar = Class.new do
        include Grammar

        root ROOT
        rule(ROOT) { matcher }
        next unless ignore

        rule(IGNORE) { ignore }
        self.ignore IGNORE
      end
      check!(grammar, [matcher, ignore].compact.map { Birman.coerce(_1) })
      grammar
    end

    # A rule reference, or an action or check calling a method only a
    # grammar of your own would have, raises only when the parse reaches
    # it (and the method as a NoMethodError on an anonymous class), so a
    # mistake could hide in an untried alternative. Checked up front.
    def self.check!(grammar, matchers)
      matchers.each { each_matcher(_1) { |m| check_matcher!(grammar, m) } }
    end

    def self.check_matcher!(grammar, matcher)
      case matcher
      when Ref
        raise ArgumentError, "undefined rule #{matcher.name.inspect}: " \
                             "a matcher run by Birman.parse can't refer to rules; define them in a grammar class"
      when Action, Check
        name = matcher.method_name
        return if grammar.method_defined?(name) || grammar.private_method_defined?(name)

        raise ArgumentError, "undefined method #{name.inspect} for .#{matcher.is_a?(Action) ? "action" : "check"}: " \
                             "a matcher run by Birman.parse can only use Birman's own methods there; " \
                             "define yours in a grammar class"
      end
    end

    # Every matcher inside root, root included, once each.
    def self.each_matcher(root)
      queue = [root]
      seen = {}.compare_by_identity
      while (m = queue.shift)
        next if seen[m]

        seen[m] = true
        yield m
        queue.concat(m.to_h.values.flat_map { Array(_1) }.grep(Matcher)) if m.is_a?(Data)
      end
    end
    private_class_method :build, :check!, :check_matcher!, :each_matcher
  end
end
