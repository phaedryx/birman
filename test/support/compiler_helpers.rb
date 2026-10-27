# frozen_string_literal: true

# Small grammars, generated and checked against the interpreter, for the
# compiler's tests.
module CompilerTestHelpers
  def grammar(root = :top, ignore: nil, keywords: [], &rules)
    Class.new do
      include Birman::Grammar
      include Birman::Rules::Whitespace

      self.root(root)
      self.ignore(ignore) if ignore
      self.keywords(*keywords) unless keywords.empty?
      class_eval(&rules)
    end
  end

  # Same value (with spans), error position, expectations and message
  # from the generated parser as from the interpreter, on every input,
  # from the grammar's root and from each of roots:.
  def assert_same_results(grammar, inputs, roots: [])
    parser = Differential.load(grammar, "CompilerTestParser", roots:)
    [nil, *roots].each do |root|
      options = root ? { root: } : {}
      inputs.each do |input|
        want = Differential.interpreted(grammar, input, **options)
        got = Differential.generated(parser, input, **options)
        assert_equal want, got, "input #{input.inspect}#{" from #{root.inspect}" if root}"
      end
    end
  end

  def assert_refused(grammar, pattern)
    error = assert_raises(Birman::Compiler::Error) { grammar.to_ruby(namespace: "CompilerTestRefused") }
    assert_match pattern, error.message
  end
end
