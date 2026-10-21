# frozen_string_literal: true

module Birman
  class Compiler
    # The generated counterpart of each node(...) class a grammar builds:
    # a plain class under BirmanRT::Node (so a rule whose value is one of
    # several node classes keeps a single type), with readers, a span,
    # == ignoring the span, and Birman::Node's s-expression inspect.
    # [class.Compiler.Nodes]
    # purpose = "Collects the grammar's node classes and writes their generated versions"
    class Nodes
      def initialize
        @classes = {}
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

      private

      def check(node, name, rule)
        if RESERVED_CONSTANTS.include?(name)
          raise Error, "rule :#{rule} builds #{node.name}, but #{name} is a name the generated parser needs"
        end

        own = node.instance_methods(false) - node.members + node.private_instance_methods(false)
        return if own.empty?

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
  end
end
