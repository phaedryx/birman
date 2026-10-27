# frozen_string_literal: true

require "test_helper"

# rules, rule? and rule(:name), and to_ast and to_ebnf covering every rule.
class IntrospectionTest < Minitest::Test
  def grammar(root = :top, &rules)
    Class.new do
      include Birman::Grammar

      self.root(root)
      class_eval(&rules)
    end
  end

  def test_rules_lists_rule_names_in_declaration_order
    g = grammar do
      rule(:top)    { item.rep }
      lexeme(:num)  { match(/\d+/) }
      rule(:item)   { num | str("x") }
      rule(:orphan) { str("z") }
    end

    assert_equal %i[top num item orphan], g.rules
    assert_equal %i[top num item orphan], g.new.rules
  end

  Shared = Module.new do
    include Birman::Grammar

    rule(:word) { match(/[a-z]+/) }
    rule(:sep)  { str(",") }
  end

  # Included modules' rules come first, in the order they were included,
  # then the class's own, then a subclass's: the order Ruby reads them
  # in. Overriding a rule keeps its place.
  def test_rules_puts_included_modules_rules_first_and_an_override_in_its_place
    g = grammar do
      include Birman::Rules::Whitespace
      include Shared

      rule(:top) { word.rep }
      rule(:sep) { str(";") }
    end
    sub = Class.new(g) { rule(:extra) { str("!") } }

    assert_equal %i[spacing word sep top], g.rules
    assert_equal %i[spacing word sep top extra], sub.rules
    assert_equal %i[word sep], Shared.rules
  end

  def test_rule_predicate_says_whether_a_rule_is_defined
    g = grammar do
      include Shared

      rule(:top) { word }
    end

    assert g.rule?(:top)
    assert g.rule?(:word), "included rules count"
    assert g.new.rule?(:top)
    refute g.rule?(:nope)
    refute g.rule?(:send), "a method isn't a rule"
    refute g.rule?("top"), "names are Symbols"
  end

  # The grammar reads its rules through these, as it parses through
  # parse, so a rule can't take their names.
  def test_the_introspection_methods_are_not_rule_names
    %i[rules rule rule?].each do |name|
      error = assert_raises(ArgumentError) { grammar { rule(name) { str("x") } } }
      assert_match(/\Arule :#{Regexp.escape(name.to_s)} would replace Birman::Grammar#/, error.message)
    end
  end

  def test_rule_without_a_block_returns_the_rules_matcher
    g = grammar do
      rule(:top)   { num.rep }
      lexeme(:num) { match(/\d+/) }
    end

    matcher = g.rule(:num)
    assert_kind_of Birman::Lexeme, matcher
    assert_equal matcher, g.new.rule(:num)
    assert_equal Birman::Success.new(value: "42", input: "42"), Birman.parse(matcher, "42")
    assert_equal %w[1 2], Birman.parse!((matcher >> ",").rep.map { _1.map(&:first) }, "1,2,")
  end

  def test_rule_without_a_block_raises_for_an_undefined_rule
    g = grammar { rule(:top) { str("a") } }
    error = assert_raises(ArgumentError) { g.rule(:nope) }
    assert_equal "undefined rule :nope", error.message
    assert_raises(ArgumentError) { g.new.rule(:nope) }
  end

  # A module of rules has no grammar to build a matcher in.
  def test_rule_without_a_block_in_a_rule_module_raises
    error = assert_raises(ArgumentError) { Shared.rule(:word) }
    assert_equal "no block given for rule :word", error.message
    error = assert_raises(ArgumentError) { Module.new { extend Birman::RuleSet }.rule(:x) }
    assert_equal "no block given for rule :x", error.message
  end

  def test_rule_raises_for_a_rule_whose_matcher_cant_be_built
    g = grammar { rule(:top) { match(/(\d+)-(\d+)/).captures } }
    error = assert_raises(ArgumentError) { g.rule(:top) }
    assert_match(/has no named groups/, error.message)
  end

  def test_to_ast_covers_every_rule_with_the_reachable_ones_first
    g = grammar do
      rule(:top)    { item.rep }
      rule(:item)   { str("x") | unused_by_top }
      rule(:unused_by_top) { str("y") }
      rule(:orphan) { str("z") }
      rule(:other)  { orphan >> str("!") }
    end

    assert_equal %i[top item unused_by_top orphan other], g.to_ast.keys
    assert_equal [:seq, nil, [%i[ref orphan], [:str, "!"]]], g.to_ast[:other]
    assert_equal %i[top item unused_by_top orphan other], g.new.to_ast.keys
  end

  # The reachable rules read as they did, aligned among themselves; the
  # rest follow after a blank line, so they're visibly not part of the
  # root's grammar, and don't widen its lines.
  def test_to_ebnf_lists_the_unreachable_rules_after_a_blank_line
    g = grammar do
      rule(:top)    { item.rep }
      rule(:item)   { str("x") }
      rule(:orphan) { str("z") }
      rule(:another_orphan) { orphan >> str("!") }
    end

    assert_equal <<~EBNF.chomp, g.to_ebnf
      top  = item* ;
      item = "x" ;

      orphan         = "z" ;
      another_orphan = orphan "!" ;
    EBNF
    assert_equal g.to_ebnf, g.new.to_ebnf
  end

  # As before: the root, the ignore rule, then what they reach as it's
  # first used, so the reachable part of the output doesn't change.
  def test_to_ast_keeps_the_root_and_ignore_rule_first
    g = grammar do
      include Birman::Rules::Whitespace

      ignore :spacing
      rule(:top)   { word.rep }
      rule(:extra) { str("!") }
      rule(:word)  { match(/[a-z]+/) }
    end

    assert_equal %i[top spacing word extra], g.to_ast.keys
  end

  def test_to_ast_without_a_root_lists_every_rule_in_declaration_order
    g = grammar(nil) do
      rule(:b) { str("b") }
      rule(:a) { b }
    end

    assert_equal %i[b a], g.to_ast.keys
    assert_equal "b = \"b\" ;\na = b ;", g.to_ebnf
  end

  def test_to_ast_raises_for_an_unreachable_rule_whose_matcher_cant_be_built
    g = grammar do
      rule(:top)    { str("a") }
      rule(:orphan) { match(/(\d+)/).captures }
    end

    assert_equal Birman::Success.new(value: "a", input: "a"), g.parse("a")
    error = assert_raises(ArgumentError) { g.to_ast }
    assert_match(/has no named groups/, error.message)
  end
end
