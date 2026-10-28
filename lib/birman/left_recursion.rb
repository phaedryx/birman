# frozen_string_literal: true

module Birman
  # Finds left recursion from a grammar's ASTs ({ rule_name => ast },
  # as Grammar#to_ast returns), without parsing anything: a rule that
  # can call itself, directly or through other rules, before consuming
  # input would loop forever on some input. Grammar#left_recursion runs
  # it on the first parse or to_ruby, and keeps it once it passes.
  # Left recursion is supported, direct (a rule that calls itself) or
  # indirect (through other rules), the way pegen does it: each cycle
  # has a leader, a rule that every way round it passes through, and
  # Context#memoize grows the leader's match from a seed. A cycle with
  # no such rule, two cycles that share none, raises in check!.
  class LeftRecursion
    FLAGS = { "i" => Regexp::IGNORECASE, "x" => Regexp::EXTENDED, "m" => Regexp::MULTILINE,
              "n" => Regexp::NOENCODING }.freeze

    # Each cycle's rules (a strongly connected component of the left-call
    # graph), in the order rules has them: first-use order, from
    # Grammar#to_ast.
    attr_reader :cycles

    # { rule => its cycle's leader } for every rule in a cycle that has
    # one. The leader is the first of its cycle's rules that every way
    # round the cycle passes through: take it out and the rest can't
    # reach each other in a loop. Only it grows; see Context#memoize.
    attr_reader :leaders

    # ignore: the grammar's ignore rule, which a lexeme calls after its
    # token; at its start, if the token was empty.
    def initialize(rules, ignore: nil)
      @rules = rules
      @ignore = ignore
      @patterns = {}
      @nullable = nullable_rules
      @calls = rules.to_h { |name, ast| [name, calls(ast).uniq] }
      @cycles = strongly_connected.select { cyclic?(_1) }
      @cycle_of = @cycles.each_with_object({}) { |cycle, h| cycle.each { h[_1] = cycle } }
      @leaders = @cycles.each_with_object({}) do |cycle, h|
        leader = cycle.find { acyclic?(cycle - [_1]) } or next
        cycle.each { h[_1] = leader }
      end.freeze
    end

    # Raises ArgumentError naming the cycles of every component with no
    # leader, or for the first cycle that could never grow (see
    # check_growth!); returns self otherwise.
    def check!
      leaderless = cycles.reject { @leaders.key?(_1.first) }
      unless leaderless.empty?
        loops = leaderless.flat_map { cycles_with_no_rule_in_common(_1) }
        names = loops.map { _1.map(&:inspect).join(" -> ") }.join("; ")
        raise ArgumentError, "left recursion through cycles with no rule in common isn't supported: #{names} " \
                             "(each rule can call the next without consuming input)"
      end
      cycles.each { check_growth!(_1) }
      self
    end

    # Can the rule match without consuming input? Undefined rules can't.
    def nullable?(name) = @nullable.key?(name)

    # The rules name can call at the position it starts at, before it
    # consumes anything, in the order its AST mentions them.
    def left_calls(name) = @calls.fetch(name, [])

    def left_recursive?(name) = @cycle_of.key?(name)
    def cycle(name) = @cycle_of[name]
    def leader(name) = @leaders[name]

    # Can node match without consuming input? Every node type gets an
    # answer; anything else (a custom matcher's own AST) is assumed to
    # consume, which can only hide left recursion, never invent it.
    def nullable_node?(node) # rubocop:disable Metrics
      case node
      in [:str | :istr, s]       then s.empty? # a literal's ignored spacing comes after the literal
      in [:pat, source]          then nullable_pattern?(source)
      in [:ref, name]            then nullable?(name)
      in [:seq, _, parts]        then parts.all? { nullable_node?(_1) }
      in [:choice, alts]         then alts.any? { nullable_node?(_1) }
      in [:rep, min, _, inner]   then min.zero? || nullable_node?(inner)
      in [:not, _] | [:and, _]   then true
      in [:both, _, right]       then nullable_node?(right) # the guard consumes nothing
      in [:action, inner]        then nullable_node?(inner)
      in [:quiet, inner]         then nullable_node?(inner)
      in [:label, _, inner]      then nullable_node?(inner)
      in [:check, _, inner]      then nullable_node?(inner) # it may reject, but it can match empty
      in [:lexeme, inner]        then nullable_node?(inner)
      in [:text | :spanned, inner] then nullable_node?(inner)
      else false
      end
    end

    private

    # Least fixpoint: start with no rule nullable and add rules until
    # nothing changes, so a rule that only calls itself stays non-nullable.
    def nullable_rules
      @nullable = {}
      loop do
        grown = @rules.reject { |name, ast| @nullable.key?(name) || !nullable_node?(ast) }
        return @nullable if grown.empty?

        grown.each_key { @nullable[_1] = true }
      end
    end

    # Rules node calls at its start position. A seq's parts run there
    # until one consumes input; lookaheads count too, since re-entering
    # a rule at the same position loops just the same.
    def calls(node) # rubocop:disable Metrics
      case node
      in [:ref, name]          then [name]
      in [:seq, _, parts]      then leading(parts).flat_map { calls(_1) }
      in [:choice, alts]       then alts.flat_map { calls(_1) }
      in [:both, left, right]  then calls(left) + calls(right)
      in [:rep, _, 0, _]       then [] # at most none: inner never runs
      in [:rep, _, _, inner]   then calls(inner)
      in [:not, inner]         then calls(inner)
      in [:and, inner]         then calls(inner)
      in [:action, inner]      then calls(inner)
      in [:quiet, inner]       then calls(inner)
      in [:label, _, inner]    then calls(inner)
      in [:check, _, inner]    then calls(inner)
      in [:lexeme, inner]      then calls(inner) + (@ignore && nullable_node?(inner) ? [@ignore] : [])
      in [:text | :spanned, inner] then calls(inner)
      else []
      end
    end

    # A cycle grows from a first match that didn't go round it (its
    # seed), so one of its rules needs an alternative that doesn't start
    # with any of them: without one it never matches. And in each of its
    # rules, an alternative like that has to come after the ones that do
    # start with one: tried first, it wins every round, so they never
    # grow. Only each rule's own choice is checked, through the wrappers
    # around it, not choices nested inside its parts.
    def check_growth!(cycle) # rubocop:disable Metrics
      raise ArgumentError, no_base_case(cycle) unless cycle.any? { seedable?(@rules[_1], cycle) }

      cycle.each do |name|
        alts = alternatives(@rules[name])
        base = alts.index { !enters?(_1, cycle) } or next
        grows = alts.drop(base).find { enters?(_1, cycle) } or next
        first, later = [alts[base], grows].map { EBNF.expr(_1, EBNF::CHOICE) }
        raise ArgumentError, "in left-recursive rule :#{name}, the alternative `#{first}` comes before `#{later}`, " \
                             "so the rule can never grow past it; " \
                             "put the alternatives that start with #{names(cycle, "or")} first"
      end
    end

    def no_base_case(cycle)
      if cycle.one?
        name = cycle.first
        "left-recursive rule :#{name} has no alternative that doesn't start with :#{name}, " \
          "so it can never match; add one that doesn't, as a base case"
      else
        "left-recursive rules #{names(cycle, "and")}, which can each reach the others without consuming " \
          "input, have no alternative that doesn't start with one of them, so they can never match; " \
          "add one that doesn't, as a base case"
      end
    end

    def enters?(node, cycle) = calls(node).intersect?(cycle)

    # ":a, :b and :c"
    def names(rules, conjunction)
      [rules[0...-1].map(&:inspect).join(", "), rules.last.inspect].reject(&:empty?).join(" #{conjunction} ")
    end

    # Can node match while its calls to the cycle's rules at its start
    # fail?
    def seedable?(node, cycle) # rubocop:disable Metrics
      case node
      in [:ref, name] then !cycle.include?(name)
      in [:choice, alts] then alts.any? { seedable?(_1, cycle) }
      in [:seq, _, parts] then leading(parts).all? { seedable?(_1, cycle) }
      in [:rep, 0, _, _] | [:rep, _, 0, _] | [:not, _] then true
      in [:rep | :label | :check, *] | [:and | :action | :quiet | :lexeme, _]
        seedable?(node.last, cycle) # a wrapper: its inner node is its last element
      in [:both, left, right] then seedable?(left, cycle) && seedable?(right, cycle)
      else true
      end
    end

    # The alternatives of node's choice, looking through wrappers; node
    # itself if it isn't one.
    def alternatives(node)
      case node
      in [:choice, alts] then alts
      in [:action | :quiet, _] | [:label | :check, _, _] then alternatives(node.last)
      else [node]
      end
    end

    # The parts up to and including the first that consumes input.
    def leading(parts) = parts.take((parts.index { !nullable_node?(_1) } || parts.size) + 1)

    # The regexp is rebuilt from its inspect form and tried on "" with
    # every assertion (see Assertions) taken to hold, since each holds
    # somewhere: /(?=a)/ matches empty before an "a", though not in "".
    # Assertions that contradict each other side by side are caught;
    # other combinations that can't hold, like /(?=a)(?=b)/, still count
    # as nullable. A pattern that can't be rebuilt is assumed to consume.
    def nullable_pattern?(source)
      @patterns.fetch(source) do
        body, flags = %r{\A/(.*)/([a-z]*)\z}m.match(source)&.captures
        @patterns[source] = body ? empty_match?(body, flags.chars.sum { FLAGS.fetch(_1, 0) }) : false
      end
    end

    # Falls back to the regexp as written when taking out its assertions
    # breaks it, or could make a backreference name another group: taking
    # out (?=(a)) renumbers the groups after it.
    def empty_match?(body, options)
      stripped = Assertions.strip(body, options.anybits?(Regexp::EXTENDED))
      stripped = body if stripped != body && body.match?(/\\(?:[1-9]|k[<'])/)
      [stripped, body].each do |source|
        return Regexp.new(source, options).match?("")
      rescue RegexpError
        next
      end
      false
    end

    def cyclic?(rules) = rules.size > 1 || left_calls(rules.first).include?(rules.first)

    # Tarjan's algorithm over the left-call graph. Each component's rules,
    # and the components, come back in rule order.
    def strongly_connected
      @index = {}
      @low = {}
      @stack = []
      @components = []
      @rules.each_key { visit(_1) unless @index.key?(_1) }
      order = @rules.keys.each_with_index.to_h
      @components.map { |c| c.sort_by { order[_1] } }.sort_by { order[_1.first] }
    end

    def visit(name)
      @index[name] = @low[name] = @index.size
      @stack.push(name)
      left_calls(name).each do |callee|
        next unless @rules.key?(callee)

        visit(callee) unless @index.key?(callee)
        @low[name] = [@low[name], @low[callee]].min if @stack.include?(callee)
      end
      @components << pop_component(name) if @low[name] == @index[name]
    end

    def pop_component(name)
      component = []
      component << @stack.pop until component.last == name
      component
    end

    # Can none of names reach itself through the others' left calls?
    def acyclic?(names)
      done = {}
      names.none? { looping?(_1, names, done, {}) }
    end

    def looping?(name, names, done, on_path)
      return true if on_path[name]
      return false if done[name]

      on_path[name] = done[name] = true
      left_calls(name).any? { names.include?(_1) && looping?(_1, names, done, on_path) }
    ensure
      on_path.delete(name)
    end

    # For a component with no leader, cycles no one rule is in all of
    # (though two of them may share one): for each rule, the first cycle
    # through the others that leaves it out.
    def cycles_with_no_rule_in_common(component)
      order = @rules.keys.each_with_index.to_h
      cycles = component.filter_map do |left_out|
        rest = component - [left_out]
        rest.lazy.filter_map { path(_1, rest) }.first
      end
      cycles.uniq(&:to_set).each_with_index.sort_by { |cycle, i| [order[cycle.first], i] }.map(&:first)
    end

    # The shortest way round from start back to it through names, through
    # another rule if there is one (a leader may also call itself); nil
    # if there's none.
    def path(start, names) # rubocop:disable Metrics/MethodLength
      from = {}
      queue = [start]
      while (name = queue.shift)
        left_calls(name).each do |callee|
          if callee == start
            next if name == start

            return [*trail(from, name), start]
          end
          next if !names.include?(callee) || from.key?(callee)

          from[callee] = name
          queue << callee
        end
      end
      [start, start] if left_calls(start).include?(start)
    end

    def trail(from, name)
      names = [name]
      names.unshift(from[names.first]) while from.key?(names.first)
      names
    end

    # A regexp's source with each assertion, which matches only where the
    # text around it allows, replaced by (?:), which matches anywhere:
    # lookarounds, anchors (\A, ^, $, \z, \Z, \G) and \b, \B. Assertions
    # side by side hold at one position, so a pair there that can't both
    # hold, (?=X) with (?!X), (?<=X) with (?<!X), or \b with \B, becomes
    # (?!), which matches nowhere. Only that shape: (?=a)(?=b) can't hold
    # either, but stays (?:)(?:). So does a negative lookaround of what
    # always matches empty, as never's (?!) or (?!a*).
    # Escapes, character classes and comments are copied as they are.
    # Only /x makes # start a comment; an inline (?x) doesn't, so a "[" or
    # "(" in such a comment can hide an assertion after it (it's then
    # taken as written, as before this rewrite).
    module Assertions
      module_function

      # kind: "=", "!", "<=" or "<!" for a lookaround (body: its source),
      # or the anchor itself ("^", "\\b"...).
      Assertion = Data.define(:kind, :body)
      OPPOSITE = { "=" => "!", "<=" => "<!", "\\b" => "\\B" }.freeze

      def strip(source, extended)
        scanner = StringScanner.new(source)
        out = +""
        run = []
        until scanner.eos?
          item = piece(scanner, extended)
          next run << item if item.is_a?(Assertion)

          flush(run, out, extended, quantified: item.match?(/\A[?*+{]/))
          out << item
        end
        flush(run, out, extended, quantified: false)
        out
      end

      # Writes out a run of assertions side by side. A quantifier after the
      # last one may skip it, so then it can't fail the rest.
      def flush(run, out, extended, quantified:)
        held = quantified ? run[0...-1] : run
        never = held.any? { |a| held.include?(Assertion.new(OPPOSITE[a.kind], a.body)) || never?(a, extended) }
        out << "(?!)" if never
        out << ("(?:)" * run.size)
        run.clear
      end

      # A negative lookaround of something with no assertions of its own
      # that matches "" never holds: that matches empty everywhere.
      def never?(assertion, extended)
        return false unless %w[! <!].include?(assertion.kind) && strip(assertion.body, extended) == assertion.body

        Regexp.new(assertion.body, extended ? Regexp::EXTENDED : 0).match?("")
      rescue RegexpError
        false
      end

      # The next piece of the source: an Assertion, or text to copy.
      def piece(s, extended) # rubocop:disable Metrics
        if s.scan(/\\[bBAzZG]|[\^$]/) then Assertion.new(s.matched, nil)
        elsif s.scan(/\(\?(<?[=!])/) then lookaround(s, s[1], extended)
        elsif s.scan(/\\./m) || s.scan(/\(\?#[^)]*\)/) then s.matched
        elsif s.skip(/\[/) then character_class(s)
        elsif extended && s.scan(/#[^\n]*/) then s.matched
        else s.getch
        end
      end

      # The rest of a lookaround, after its "(?=" (or "(?!", "(?<=", "(?<!").
      def lookaround(s, kind, extended)
        start = finish = s.pos
        depth = 1
        until depth.zero? || s.eos?
          finish = s.pos
          case piece(s, extended)
          when "(" then depth += 1
          when ")" then depth -= 1
          end
        end
        Assertion.new(kind, s.string.byteslice(start, finish - start))
      end

      # A character class (nested ones included), after its "[". A "]"
      # right after "[" or "[^" is a character, not the end.
      def character_class(s)
        start = s.pos - 1
        s.skip(/\^?\]?/)
        depth = 1
        while depth.positive? && !s.eos?
          if s.skip(/\\./m) then next
          elsif s.skip(/\[/) then depth += 1
          elsif s.skip(/\]/) then depth -= 1
          else s.getch
          end
        end
        s.string.byteslice(start, s.pos - start)
      end
    end
  end
end
