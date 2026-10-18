# frozen_string_literal: true

module Birman
  class Compiler
    # Copies the grammar methods that .action(:name) calls into the
    # generated Parser, read from their source with Prism, together with
    # the grammar methods they call and the constants they read (as
    # literals, looked up lexically from where the method was written).
    #
    # One rewrite: Kernel#Integer(x) becomes BirmanRT.to_integer(x), which
    # gives Bignums where Spinel's Integer would raise on overflow. Calls
    # with a base or keywords are copied as they are.
    # [class.Compiler.Actions]
    # purpose = "Copies .action methods, their helpers and constants, into the generated parser"
    # dependencies = ["prism (bundled from Ruby 3.3; a gem on 3.2), loaded on first use"]
    class Actions
      # Methods of the generated Parser and its runtime base class that a
      # copied method must not replace.
      RESERVED = /\A(?:rule_|ref_|lit_|init_|skip_|str_)/
      RUNTIME_METHODS = %i[
        initialize parse reset skip_ignored fail_at merge commit_failure ignored_after token_end span_end span
        failure failure_because label_end peek_end bytes_at? abandon left_recursion
      ].freeze

      def initialize(grammar)
        @grammar = grammar
        @methods = {}
        @constants = CopiedConstants.new
        @trees = {}
      end

      # Copies grammar method name (and what it needs), once.
      def copy(name, rule)
        return if @methods.key?(name)

        @methods[name] = nil # reserved first: methods can call each other
        @methods[name] = method_source(find(name, rule), rule)
      end

      def any? = !@methods.empty?

      def constants = @constants.sources

      def constant_names = @constants.names

      def methods = @methods.values

      def names = @methods.keys

      private

      def find(name, rule)
        unless @grammar.respond_to?(name, true)
          raise Error, "rule :#{rule} uses .action(:#{name}), but the grammar has no method #{name}"
        end
        if RESERVED.match?(name) || RUNTIME_METHODS.include?(name)
          raise Error, "the grammar method #{name} would clash with the generated parser's own #{name}"
        end

        method = @grammar.method(name)
        file, line = method.source_location
        raise Error, "rule :#{rule}: can't find the source of #{name}" unless file && File.exist?(file)

        MethodFinder.new(name, line).find(tree(file)) ||
          raise(Error, "rule :#{rule}: #{name} isn't written with def, so it can't be copied")
      end

      def tree(file)
        @trees[file] ||= begin
          load_prism
          Prism.parse_file(file).value
        end
      end

      def method_source(found, rule)
        node, scopes = found
        edits = []
        walk(node) { visit(_1, edits, scopes, rule) }
        MethodFinder.rewrite(node, edits)
      end

      def visit(node, edits, scopes, rule)
        case node
        when Prism::ConstantReadNode then @constants.read(node.name, scopes, rule)
        when Prism::ConstantPathNode
          raise Error, "rule :#{rule}: copied methods can't read #{node.slice}; use a constant of the grammar"
        when Prism::SuperNode, Prism::ForwardingSuperNode
          raise Error, "rule :#{rule}: copied methods can't call super"
        when Prism::CallNode then call(node, edits, rule)
        end
      end

      # A call on self (written or not) to a grammar method copies that
      # method too; Birman's own API (rules, keywords...) isn't there to call.
      def call(node, edits, rule)
        return unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        if node.receiver.nil? && integer_call?(node)
          edits << [node.message_loc, "BirmanRT.to_integer"]
        elsif birman_api?(node.name)
          raise Error, "rule :#{rule}: copied methods can't call the grammar's #{node.name}"
        elsif grammar_method?(node.name)
          copy(node.name, rule)
        end
      end

      # Integer(x): one positional argument, no base, keywords or block.
      def integer_call?(node)
        args = node.arguments&.arguments
        node.name == :Integer && node.block.nil? && args&.size == 1 &&
          !args.first.is_a?(Prism::KeywordHashNode) && !args.first.is_a?(Prism::SplatNode)
      end

      # A method of the grammar's, or of a rule module's (Rules::Strings'
      # decode_escape): not Ruby's, and not part of Birman's grammar API.
      def grammar_method?(name)
        return false unless @grammar.respond_to?(name, true)

        ![Kernel, Object, BasicObject].include?(@grammar.method(name).owner)
      end

      # Rules (which return matchers) and the methods Birman::Grammar and
      # Combinators give every grammar.
      def birman_api?(name)
        return false unless @grammar.respond_to?(name, true)
        return true if @grammar.respond_to?(:"__rule_#{name}", true)

        owner = @grammar.method(name).owner
        [Birman::Grammar, Birman::Combinators].include?(owner)
      end

      def walk(node, &)
        yield node
        node.compact_child_nodes.each { walk(_1, &) }
      end

      def load_prism
        require "prism"
      rescue LoadError
        raise Error, "copying .action methods needs the prism gem (bundled from Ruby 3.3): add it to your Gemfile"
      end
    end

    # The constants copied methods read, each written as a literal. Looked
    # up lexically from where the method was written; core classes are
    # left as they are, and anything else is refused.
    class CopiedConstants
      def initialize
        @constants = {}
      end

      def sources = @constants.map { |name, (_owner, source)| "#{name} = #{source}" }

      def names = @constants.keys.map(&:to_s)

      # Classes Ruby (or the runtime) provides, which copied code may name.
      CORE_CLASSES = %i[
        Integer Float String Symbol Array Hash Regexp Comparable Math Kernel Encoding NilClass
        StandardError ArgumentError KeyError RangeError TypeError
      ].freeze

      def read(name, scopes, rule)
        owner = scopes.find { _1.const_defined?(name) } or
          raise Error, "rule :#{rule}: copied methods read #{name}, which can't be found"
        value = owner.const_get(name)
        return core_class(name, value, rule) if value.is_a?(Module)

        check_constant(name, owner, value, rule)
        @constants[name] = [owner, Literals.source(value)]
      end

      def core_class(name, value, rule)
        return if CORE_CLASSES.include?(name) && Object.const_get(name).equal?(value)

        raise Error, "rule :#{rule}: copied methods use #{value.inspect}, which the generated parser won't have"
      end

      def check_constant(name, owner, value, rule)
        if RESERVED_CONSTANTS.include?(name.to_s)
          raise Error, "rule :#{rule}: copied methods read #{owner}::#{name}, a name the generated parser needs"
        end
        unless Literals.literal?(value)
          raise Error, "rule :#{rule}: #{name} must be a literal (strings, numbers, symbols, arrays, hashes)"
        end

        seen, = @constants[name]
        return if seen.nil? || seen == owner

        raise Error, "copied methods read both #{seen}::#{name} and #{owner}::#{name}; rename one"
      end
    end

    # The def of name at line, with the modules it was written in
    # (innermost first, then Object), for looking up its constants.
    class MethodFinder
      def initialize(name, line)
        @name = name
        @line = line
      end

      # The def's source with edits ([location, text] pairs) applied, its
      # lines indented as if written at the left margin.
      def self.rewrite(node, edits)
        "#{reindent(apply(node, edits), node.location.start_column)}\n"
      end

      def self.apply(node, edits)
        source = node.slice.dup
        base = node.location.start_offset
        edits.sort_by { -_1[0].start_offset }.each do |loc, text|
          source[(loc.start_offset - base), loc.length] = text
        end
        source
      end

      # The method's later lines are indented for where it was written.
      def self.reindent(source, column)
        first, *rest = source.lines
        [first, *rest.map { _1.sub(/\A {0,#{column}}/, "") }].join
      end

      def find(node, nesting = [])
        case node
        when Prism::DefNode
          return [node, scopes(nesting)] if node.name == @name && node.location.start_line == @line
        when Prism::ClassNode, Prism::ModuleNode
          nesting = [*nesting, node.constant_path.slice]
        end
        node.compact_child_nodes.each do |child|
          found = find(child, nesting)
          return found if found
        end
        nil
      end

      private

      def scopes(nesting)
        paths = nesting.each_index.map { nesting[0.._1].join("::") }.reverse
        [*paths.filter_map { Object.const_get(_1) if Object.const_defined?(_1) }, Object]
      end
    end
  end
end
