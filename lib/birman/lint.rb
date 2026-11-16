# frozen_string_literal: true

# [file]
# purpose = "Checks a grammar for mistakes before it parses anything"
# responsibility = "Undefined and unbuildable rules, unreachable rules, alternatives that can never match"
# dependencies = ["Birman::AST"]
module Birman
  # Grammar#lint: what's wrong with a grammar, found from its rules'
  # ASTs without parsing anything. It reports only what it can prove,
  # so a grammar it passes may still be wrong, but each problem it
  # reports is real.
  # [module.Lint]
  # purpose = "Grammar#lint's checks"
  # collaborators = ["Grammar (matcher_for, rules)", "AST"]
  module Lint
    # kind is :undefined_rule, :invalid_rule, :unreachable_rule or
    # :shadowed_alternative; rule is the rule it's about.
    Problem = Data.define(:kind, :rule, :message) do
      def to_s = message
    end

    # Wrappers that change a match's value or its errors, not whether
    # or how far it matches.
    TRANSPARENT = %i[action label quiet text spanned lexeme].freeze

    module_function

    # [method."Lint.call"]
    # params = ["grammar: a Grammar instance"]
    # returns = "Array of Problem: the settings', then each rule's in declaration order, then unreachable rules"
    def call(grammar)
      problems = settings(grammar)
      asts = {}
      grammar.rules.each do |name|
        asts[name] = grammar.matcher_for(name).to_ast
        problems.concat(shadowed(name, asts[name], grammar))
      rescue ArgumentError => e
        problems << Problem.new(e.cause.is_a?(NameError) ? :undefined_rule : :invalid_rule, name, e.message)
      rescue NoMethodError => e
        raise unless custom_matcher?(e)
      end
      problems.concat(unreachable(grammar, asts))
    end

    def settings(grammar)
      %i[root ignore].filter_map do |setting|
        name = grammar.class.public_send(setting)
        Problem.new(:undefined_rule, name, "#{setting} :#{name} isn't a rule") if name && !grammar.rule?(name)
      end
    end

    # The rules the grammar's own classes define (not its included
    # modules', which are libraries of rules to pick from) that the root
    # and ignore rule don't reach. Nothing when there's no root to reach
    # from, or a reached rule's references are unknown (see reached).
    def unreachable(grammar, asts)
      root = grammar.class.root
      return [] unless root && grammar.rule?(root)

      reached = reached(grammar, asts, [root, grammar.class.ignore].compact) or return []
      own = grammar.class.ancestors.grep(Class).flat_map { _1.instance_variable_get(:@__rules) || [] }
      (grammar.rules & own).reject { reached.include?(_1) }.map do |name|
        Problem.new(:unreachable_rule, name, "rule :#{name} isn't reached from root :#{root}")
      end
    end

    # The names reachable from queue, or nil if one of them is a rule
    # with no AST in asts (it couldn't be built, or is a custom matcher),
    # whose references can't be known.
    def reached(grammar, asts, queue)
      seen = []
      while (name = queue.shift)
        next if seen.include?(name)
        return if grammar.rule?(name) && !asts[name]

        seen << name
        queue.concat(AST.refs(asts[name]))
      end
      seen
    end

    # Every choice in ast whose later alternatives an earlier one hides:
    # one that never fails hides all that follow, and a literal hides
    # an alternative starting with a literal it's a prefix of.
    def shadowed(name, ast, grammar)
      choices(ast).flat_map do |alts|
        last = alts.index { never_fails?(_1, grammar) }
        [*hidden_literals(name, alts[..last], grammar), *after_never_failing(name, alts, last)]
      end
    end

    def choices(node)
      return [] unless node.is_a?(Array)

      inner = node.flat_map { choices(_1) }
      case node
      in [:choice, alts] then [alts, *inner]
      else inner
      end
    end

    def hidden_literals(name, alts, grammar)
      alts.each_with_index.filter_map do |alt, j|
        later = leading(alt, grammar) or next
        i = (0...j).find { hides?(literal(alts[_1], grammar), later) } or next
        text = [later, literal(alts[i], grammar)].map { quote(_1) }
        hint = "; put the longer one first" unless text.uniq.size == 1
        Problem.new(:shadowed_alternative, name, "rule :#{name}: #{text[0]} (alternative #{j + 1}) never matches, " \
                                                 "since #{text[1]} (alternative #{i + 1}) matches first#{hint}")
      end
    end

    def after_never_failing(name, alts, last)
      return [] unless last && last < alts.size - 1

      dead = if last + 2 == alts.size then "alternative #{alts.size} never matches"
             else "alternatives #{last + 2}-#{alts.size} never match"
             end
      [Problem.new(:shadowed_alternative, name, "rule :#{name}: #{dead}, since alternative #{last + 1} never fails")]
    end

    # node with what doesn't change how it matches peeled off, and a
    # rule reference replaced by the rule's AST (nil for one with none,
    # or a cycle).
    def peel(node, grammar, seen = [])
      case node
      in [Symbol => tag, *, inner] if TRANSPARENT.include?(tag) then peel(inner, grammar, seen)
      in [:ref, name] then peel(rule_ast(grammar, name, seen), grammar, [*seen, name])
      else node
      end
    end

    # [:str | :istr, text] when node is just a literal.
    def literal(node, grammar)
      peel(node, grammar) in [:str | :istr, String] => lit and lit
    end

    # The literal every match of node starts with, if it has one.
    def leading(node, grammar)
      case peel(node, grammar)
      in [:str | :istr, String] => lit then lit
      in [:seq, _, [first, *]] then leading(first, grammar)
      in [:rep, 1.., _, inner] then leading(inner, grammar)
      else nil
      end
    end

    def never_fails?(node, grammar, seen = [])
      case node
      in [Symbol => tag, *, inner] if TRANSPARENT.include?(tag) then never_fails?(inner, grammar, seen)
      in [:rep, 0, _, _] | [:str | :istr, ""] then true
      in [:seq, _, parts] then parts.all? { never_fails?(_1, grammar, seen) }
      in [:choice, alts] then alts.any? { never_fails?(_1, grammar, seen) }
      in [:ref, name] then never_fails?(rule_ast(grammar, name, seen), grammar, [*seen, name])
      else false
      end
    end

    # The rule's AST, or nil for a rule seen already (a cycle), an
    # undefined one, or one that can't be built or has no AST.
    def rule_ast(grammar, name, seen)
      return if seen.include?(name) || !grammar.rule?(name)

      grammar.matcher_for(name).to_ast
    rescue ArgumentError
      nil
    rescue NoMethodError => e
      raise unless custom_matcher?(e)
    end

    def custom_matcher?(error) = error.name == :to_ast && error.receiver.is_a?(Matcher)

    # Whether the literal earlier matches wherever later does, so later
    # is never tried. A word-like literal ("in") must end at a word
    # boundary, so it doesn't hide one that goes on with a word
    # character ("int").
    def hides?(earlier, later)
      s, t = comparable(earlier, later)
      return false unless s

      t.start_with?(s) && (t == s || !s.match?(/\A\w+\z/) || !t[s.size].match?(/\w/))
    end

    # The two literals' texts, to compare, or nil. Exact-case text
    # compares exactly; a case-insensitive earlier one compares
    # ASCII-insensitively, and isn't compared otherwise, nor is an
    # exact-case one against a case-insensitive later one.
    def comparable(earlier, later)
      return unless earlier

      (kind, s), (later_kind, t) = earlier, later
      return [s, t] unless kind == :istr || later_kind == :istr
      return unless kind == :istr && s.ascii_only? && t.ascii_only?

      [s.downcase, t.downcase]
    end

    def quote((kind, text)) = kind == :istr ? "#{AST.quote(text)}i" : AST.quote(text)
  end
end
