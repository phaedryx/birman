# frozen_string_literal: true

module Birman
  # Finds left recursion from a grammar's ASTs ({ rule_name => ast },
  # as Grammar#to_ast returns), without parsing anything: a rule that
  # can call itself, directly or through other rules, before consuming
  # input would loop forever on some input. Grammar#parse runs it once
  # per grammar instance. Internal: the answers (which rules are
  # nullable, which rules a rule calls first, the cycles and the rule
  # each is reached through first) are also what left-recursion support
  # would need.
  class LeftRecursion
    FLAGS = { "i" => Regexp::IGNORECASE, "x" => Regexp::EXTENDED, "m" => Regexp::MULTILINE,
              "n" => Regexp::NOENCODING }.freeze

    # Each cycle's rules, in the order rules has them (first-use order,
    # from Grammar#to_ast), so the first is the rule the parse reaches
    # first: its leader.
    attr_reader :cycles

    def initialize(rules)
      @rules = rules
      @patterns = {}
      @nullable = nullable_rules
      @calls = rules.to_h { |name, ast| [name, calls(ast).uniq] }
      @cycles = strongly_connected.select { cyclic?(_1) }
      @cycle_of = @cycles.each_with_object({}) { |cycle, h| cycle.each { h[_1] = cycle } }
    end

    # Raises ArgumentError naming every cycle; returns self if there are none.
    def check!
      return self if cycles.empty?

      names = cycles.map { path(_1).map(&:inspect).join(" -> ") }.join("; ")
      raise ArgumentError, "left recursion: #{names} (each rule can call the next without consuming input)"
    end

    # Can the rule match without consuming input? Undefined rules can't.
    def nullable?(name) = @nullable.key?(name)

    # The rules name can call at the position it starts at, before it
    # consumes anything, in the order its AST mentions them.
    def left_calls(name) = @calls.fetch(name, [])

    def left_recursive?(name) = @cycle_of.key?(name)
    def cycle(name) = @cycle_of[name]
    def leader(name) = @cycle_of[name]&.first

    # Can node match without consuming input? Every node type gets an
    # answer; anything else (a custom matcher's own AST) is assumed to
    # consume, which can only hide left recursion, never invent it.
    def nullable_node?(node) # rubocop:disable Metrics
      case node
      in [:str, s]               then s.empty? # a literal's ignored spacing comes after the literal
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
      in [:rep, _, _, inner]   then calls(inner)
      in [:not, inner]         then calls(inner)
      in [:and, inner]         then calls(inner)
      in [:action, inner]      then calls(inner)
      in [:quiet, inner]       then calls(inner)
      in [:label, _, inner]    then calls(inner)
      in [:check, _, inner]    then calls(inner)
      else []
      end
    end

    # The parts up to and including the first that consumes input.
    def leading(parts) = parts.take((parts.index { !nullable_node?(_1) } || parts.size) + 1)

    # The regexp is rebuilt from its inspect form and tried on "" with
    # every assertion (see Assertions) taken to hold, since each holds
    # somewhere: /(?=a)/ matches empty before an "a", though not in "".
    # That overestimates: /(?=a)(?!a)/ counts as nullable though it never
    # matches. A pattern that can't be rebuilt is assumed to consume.
    def nullable_pattern?(source)
      @patterns.fetch(source) do
        body, flags = %r{\A/(.*)/([a-z]*)\z}m.match(source)&.captures
        @patterns[source] = body ? empty_match?(body, flags.chars.sum { FLAGS.fetch(_1, 0) }) : false
      end
    end

    # Falls back to the regexp as written when taking out its assertions
    # breaks it (a \1 naming a group inside a lookahead).
    def empty_match?(body, options)
      [Assertions.strip(body, options.anybits?(Regexp::EXTENDED)), body].each do |source|
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

    # The shortest way round a cycle, from its leader back to it.
    def path(cycle)
      leader = cycle.first
      from = {}
      queue = [leader]
      while (name = queue.shift)
        left_calls(name).each do |callee|
          return [*trail(from, name), leader] if callee == leader
          next if !cycle.include?(callee) || from.key?(callee)

          from[callee] = name
          queue << callee
        end
      end
    end

    def trail(from, name)
      names = [name]
      names.unshift(from[names.first]) while from.key?(names.first)
      names
    end

    # A regexp's source with each assertion, which matches only where the
    # text around it allows, replaced by (?:), which matches anywhere:
    # lookarounds, anchors (\A, ^, $, \z, \Z, \G) and \b, \B.
    # Escapes, character classes and comments are copied as they are.
    module Assertions
      module_function

      def strip(source, extended)
        scanner = StringScanner.new(source)
        out = +""
        out << piece(scanner, extended) until scanner.eos?
        out
      end

      # The next piece of the source, rewritten.
      def piece(s, extended) # rubocop:disable Metrics
        if s.skip(/\\[bBAzZG]|[\^$]/) then "(?:)"
        elsif s.skip(/\(\?<?[=!]/) then skip_group(s, extended)
        elsif s.scan(/\\./m) || s.scan(/\(\?#[^)]*\)/) then s.matched
        elsif s.skip(/\[/) then character_class(s)
        elsif extended && s.scan(/#[^\n]*/) then s.matched
        else s.getch
        end
      end

      # The rest of a lookaround, after its "(?=" (or "(?!", "(?<=", "(?<!").
      def skip_group(s, extended)
        depth = 1
        until depth.zero? || s.eos?
          case piece(s, extended)
          when "(" then depth += 1
          when ")" then depth -= 1
          end
        end
        "(?:)"
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
