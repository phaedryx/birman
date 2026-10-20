# frozen_string_literal: true

module Birman
  class Compiler
    # Values written into the generated parser as Ruby literals: the
    # constants copied actions read, and .means values.
    # [module.Compiler.Literals]
    # purpose = "Which values can be written as literals, and how"
    module Literals
      module_function

      def literal?(value)
        case value
        when String, Symbol, Integer, true, false, nil then true
        when Float then value.finite?
        when Array then value.all? { literal?(_1) }
        when Hash then value.all? { |k, v| literal?(k) && literal?(v) }
        else false
        end
      end

      # A frozen Array or Hash stays frozen.
      def source(value)
        frozen = value.frozen? && (value.is_a?(Array) || value.is_a?(Hash))
        frozen ? "#{value.inspect}.freeze" : value.inspect
      end
    end
  end
end
