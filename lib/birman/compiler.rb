# frozen_string_literal: true

# [file]
# purpose = "Turns a grammar into a standalone Ruby parser (Grammar.to_ruby)"
# responsibility = "Walking the rules' matchers and assembling the generated source"
# dependencies = ["Birman::Compiler::Emitter", "Birman::Compiler::Actions", "compiler/runtime.rb"]
# pattern = "Code generation from the immutable matcher tree"
module Birman
  # Generates Ruby source for a parser that gives exactly the results
  # Grammar.parse gives, values, spans, errors and all, without Birman.
  # The output is written in the Ruby subset Spinel compiles to a native
  # binary: the runtime (compiler/runtime.rb), a class per node, and a
  # Parser with one method per matcher.
  #
  #   source = Calc::Grammar.to_ruby(namespace: "CalcParser")
  #   CalcParser::Parser.new(input).parse   # => Success or Failure
  #
  # Every matcher method takes a byte position and returns where its
  # match ended, or FAIL; its value, if anything reads it, goes in an
  # instance variable. Grammars using .map with a block, or a custom
  # matcher class, can't be compiled: Error names the rule.
  # [class.Compiler]
  # purpose = "Generates a standalone parser from a grammar class"
  # collaborators = ["Emitter (matcher templates)", "Actions (copies .action methods)", "Nodes"]
  class Compiler
    # Raised for a grammar the compiler can't translate faithfully.
    class Error < StandardError; end

    RUNTIME = File.join(__dir__, "compiler", "runtime.rb")

    # Constants the generated code and its runtime refer to. A node class
    # or copied constant with one of these names would sit in the same
    # lexical scope and shadow it, so it's refused.
    RESERVED_CONSTANTS = %w[
      BirmanRT Parser Node Span Spanned Success Failure Committed TooDeep FAIL IN_PROGRESS ABSENT NONE TEN19 TWO64
      CHUNK_LIMIT FLOAT_CHUNK LOOKAHEAD_DEPTH
      StringScanner Hash Array String Integer Float Symbol Regexp Kernel Encoding
      StandardError ArgumentError RangeError TypeError FloatDomainError SystemStackError
    ].freeze

    # Spinel allows 64 begin blocks active at once and exits the process
    # past that. Each lookahead (absent, present, &) holds one while its
    # inner matcher runs, so nesting deeper than this is a Failure ("input
    # is nested too deeply") instead. A binary built with a bigger
    # -DSP_EXC_STACK_MAX can take a bigger depth.
    LOOKAHEAD_DEPTH = 56

    # roots: rules the generated parser may start at (parse(root:)),
    # besides the grammar's root.
    def initialize(grammar_class, namespace:, roots: [], lookahead_depth: LOOKAHEAD_DEPTH)
      unless namespace.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)
        raise ArgumentError, "namespace must be a constant path, like \"CalcParser\""
      end
      unless lookahead_depth.is_a?(Integer) && lookahead_depth.positive?
        raise ArgumentError, "lookahead_depth must be a positive Integer"
      end

      @lookahead_depth = lookahead_depth
      @roots = roots.uniq.freeze

      @grammar_class = grammar_class
      @grammar = grammar_class.new
      @namespace = namespace
    end

    # The Parser's parse(root: nil, consume: true, offset: 0) is
    # Grammar#parse's; root: is the grammar's root or one of roots:, and
    # anything else raises ArgumentError.
    # [method."Compiler#to_ruby"]
    # returns = "String: Ruby source defining <namespace>::Parser, its node classes and BirmanRT"
    # raises = [
    #   "ArgumentError naming a root that isn't a rule",
    #   "ArgumentError for left-recursive cycles with no rule in common, or a cycle that can't grow, as Grammar#parse",
    #   "Compiler::Error for what can't be compiled (named by rule)"
    # ]
    def to_ruby
      @analysis = @grammar.left_recursion(@roots.empty? ? nil : @roots)
      emitter = emit
      check_namespace(emitter.node_names)
      body = [*emitter.node_classes, parser_class(emitter)].join("\n")
      wrap_in_namespace("#{runtime}\n#{body}")
    end

    private

    # Values nobody reads (spacing, keywords) are never kept. Which those
    # are is found by compiling: start with only the roots' values, and
    # compile again with every rule found to be read, until none is new.
    def emit
      valued = [@grammar_class.root, *@roots]
      loop do
        emitter = Emitter.new(@grammar, valued, @analysis, @roots)
        emitter.compile
        return emitter if (emitter.read_rules - valued).empty?

        valued |= emitter.read_rules
      end
    end

    # Generating into a module that already holds other classes of the
    # same names (the grammar's own nodes, say) would reopen them with a
    # different superclass.
    def check_namespace(node_names)
      return unless Object.const_defined?(@namespace)

      existing = Object.const_get(@namespace)
      node_names.each do |name|
        next unless existing.is_a?(Module) && existing.const_defined?(name, false)

        found = existing.const_get(name, false)
        next if found.is_a?(Class) && found.superclass.name == "#{@namespace}::BirmanRT::Node"

        raise Error, "#{@namespace} already defines #{name}; generate the parser into another namespace"
      end
    end

    def header
      <<~RUBY
        # Generated by Birman #{VERSION} from #{@grammar_class.name || "an anonymous grammar"}
        # (Grammar.to_ruby). Regenerate it rather than editing it.
        # Parse with #{@namespace}::Parser.new(input).parse, which returns
        # a Success (value, pos) or a Failure (pos, expected, message).
        require "strscan"
      RUBY
    end

    # The runtime file, after its require.
    def runtime = File.read(RUNTIME).split(/^require "strscan"\n\n/, 2).last

    def parser_class(emitter)
      <<~RUBY
        class Parser < BirmanRT::Parser
          include BirmanRT

          # How deeply lookaheads may nest (Grammar.to_ruby's lookahead_depth).
          LOOKAHEAD_DEPTH = #{@lookahead_depth}

        #{indent(emitter.parser_body, 1)}
        end
      RUBY
    end

    def wrap_in_namespace(body)
      modules = @namespace.split("::")
      opening = modules.each_with_index.map { |name, depth| indent("module #{name}", depth) }
      closing = modules.each_index.reverse_each.map { |depth| indent("end", depth) }
      [header, *opening, indent(body.chomp, modules.size), *closing].join("\n") << "\n"
    end

    def indent(text, depth)
      pad = "  " * depth
      text.lines.map { |line| line.strip.empty? ? "\n" : "#{pad}#{line}" }.join.chomp
    end
  end
end

require_relative "compiler/literals"
require_relative "compiler/regexps"
require_relative "compiler/types"
require_relative "compiler/actions"
require_relative "compiler/nodes"
require_relative "compiler/emitter"
