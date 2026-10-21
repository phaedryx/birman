# frozen_string_literal: true

module Birman
  class Compiler
    # The generated counterpart of each node(...) class a grammar builds:
    # a plain class under BirmanRT::Node (so a rule whose value is one of
    # several node classes keeps a single type), with readers, a span,
    # == ignoring the span, and Birman::Node's s-expression inspect. A
    # node's own initialize can give fields defaults (see Initializer),
    # which are written where each node is built.
    # [class.Compiler.Nodes]
    # purpose = "Collects the grammar's node classes and writes their generated versions"
    class Nodes
      def initialize
        @classes = {}
        @defaults = {}
      end

      # The generated class's name for node, registering it.
      def name_for(node, rule)
        unless node.is_a?(Class) && node.include?(Birman::Node)
          raise Error, "rule :#{rule} builds #{node.inspect}, which isn't a node(...) class"
        end

        name = node.name&.split("::")&.last or raise Error, "rule :#{rule} builds an anonymous node class"
        check(node, name, rule)
        other = @classes[name]
        raise Error, "#{other.name} and #{node.name} would both be generated as #{name}" if other && other != node

        @classes[name] = node
        name
      end

      def sources = @classes.map { |name, node| source(name, node.members) }

      def names = @classes.keys

      # The source of the default for each field node's initialize gives
      # one, by field.
      def defaults(node) = @defaults.fetch(node, {})

      private

      def check(node, name, rule)
        if RESERVED_CONSTANTS.include?(name)
          raise Error, "rule :#{rule} builds #{node.name}, but #{name} is a name the generated parser needs"
        end

        own = node.instance_methods(false) - node.members + node.private_instance_methods(false)
        return if own.empty?
        return @defaults[node] ||= Initializer.new(node, rule).defaults if own == [:initialize]

        raise Error, "rule :#{rule} builds #{node.name}, whose methods (#{own.join(", ")}) can't be compiled yet"
      end

      def source(name, fields)
        <<~RUBY
          class #{name} < BirmanRT::Node
            #{"attr_reader #{fields.map(&:inspect).join(", ")}" unless fields.empty?}

            def initialize(#{[*fields, :span].join(", ")})
          #{[*fields, :span].map { "    @#{_1} = #{_1}" }.join("\n")}
            end

            def ==(other)
              #{["other.is_a?(#{name})", *fields.map { "@#{_1} == other.#{_1}" }].join(" && ")}
            end

            def inspect
              "(#{[name, *fields.map { "\#{@#{_1}.inspect}" }].join(" ")})"
            end

            def dump
              "(#{["#{name}[\#{@span.byte_from},\#{@span.byte_to}]", *fields.map { "\#{BirmanRT.dump(@#{_1})}" }].join(" ")})"
            end
          end
        RUBY
      end
    end

    # A node's own initialize, read from its source with Prism. One that
    # takes exactly its fields as keywords, some with literal defaults,
    # and only calls super, as in
    #
    #   node(:name, :args) { def initialize(name:, args: []) = super }
    #
    # gives the defaults' sources: they're written where each node is
    # built, so a [] is a new Array every time, as in Ruby. Anything
    # more is refused.
    class Initializer
      def initialize(node, rule)
        @node = node
        @rule = rule
      end

      def defaults
        found = find
        check_parameters(found.parameters)
        refuse("does more than call super, so it can't be compiled") unless bare_super?(found.body)

        (found.parameters&.keywords || []).each_with_object({}) do |keyword, defaults|
          next unless keyword.is_a?(Prism::OptionalKeywordParameterNode)

          default = keyword.value
          unless literal?(default)
            refuse("gives #{keyword.name} a default (#{default.slice}) that isn't a literal " \
                   "(nil, true, false, numbers, strings, symbols, and arrays and hashes of them)")
          end
          defaults[keyword.name] = default.slice
        end
      end

      private

      def find
        file, line = @node.instance_method(:initialize).source_location
        found = (MethodFinder.new(:initialize, line).find(MethodFinder.parse(file)) if file && File.exist?(file))
        found&.first or refuse("isn't written with def, so it can't be compiled")
      end

      def check_parameters(parameters)
        keywords = parameters&.keywords || []
        return if others(parameters).empty? && keywords.map(&:name).sort == @node.members.sort

        refuse("must take exactly its fields (#{@node.members.join(", ")}) as keywords, and nothing else, " \
               "to be compiled")
      end

      # Every parameter but the keywords.
      def others(parameters)
        return [] unless parameters

        [*parameters.requireds, *parameters.optionals, parameters.rest, *parameters.posts,
         parameters.keyword_rest, parameters.block].compact
      end

      def bare_super?(body)
        body.is_a?(Prism::StatementsNode) && body.body.size == 1 &&
          body.body.first.is_a?(Prism::ForwardingSuperNode) && body.body.first.block.nil?
      end

      def literal?(value)
        case value
        when Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::IntegerNode, Prism::FloatNode,
             Prism::SymbolNode
          true
        when Prism::StringNode then !value.opening&.start_with?("<<") # a heredoc's slice is only its opening
        when Prism::ArrayNode then value.elements.all? { literal?(_1) }
        when Prism::HashNode
          value.elements.all? { _1.is_a?(Prism::AssocNode) && literal?(_1.key) && literal?(_1.value) }
        else false
        end
      end

      def refuse(problem) = raise(Error, "rule :#{@rule} builds #{@node.name}, whose initialize #{problem}")
    end
  end
end
