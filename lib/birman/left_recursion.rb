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

    # Approximate: the regexp is rebuilt from its inspect form and tried
    # on "". Anchors and lookaround see the text around a position, so
    # /\A/ counts as nullable though it only matches at the start, and
    # /(?<=a)b?/ and /(?=a)/ don't though they match empty next to an
    # "a". A pattern that can't be rebuilt is assumed to consume.
    def nullable_pattern?(source)
      @patterns.fetch(source) { @patterns[source] = pattern(source)&.match?("") || false }
    end

    def pattern(source)
      body, flags = %r{\A/(.*)/([a-z]*)\z}m.match(source)&.captures
      body && Regexp.new(body, flags.chars.sum { FLAGS.fetch(_1, 0) })
    rescue RegexpError
      nil
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
  end
end
