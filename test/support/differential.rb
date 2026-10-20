# frozen_string_literal: true

# Differential testing of generated parsers (Grammar.to_ruby) against
# the interpreter (Grammar.parse). Both sides are reduced to one report
# string: the value with every node's span, or the failure's position,
# expectations, committed flag, reason and message. The generated side
# is either loaded into this process (CRuby) or a compiled binary that
# prints the same report (see Differential.main_source).
module Differential
  module_function

  # The interpreter's value, written the way the runtime's
  # BirmanRT.dump writes the generated parser's (see there for why
  # invalid UTF-8 shows its bytes).
  def dump(value)
    case value
    when Birman::Node
      span = value.span
      fields = value.to_h.values.map { dump(_1) }
      "(#{["#{value.class.name.split("::").last}[#{span.byte_from},#{span.byte_to}]", *fields].join(" ")})"
    when Array then "[#{value.map { dump(_1) }.join(", ")}]"
    when Hash then "{#{value.map { |k, v| "#{dump(k)} => #{dump(v)}" }.join(", ")}}"
    when String then value.valid_encoding? ? value.inspect : value.b.inspect
    else value.inspect
    end
  end

  def report(result, dumper)
    return "ok #{dumper.call(result.value)}" if result.success?

    "fail pos=#{result.pos} committed=#{result.committed} expected=#{result.expected.inspect} " \
      "reason=#{result.reason.inspect}\n#{result.message}"
  end

  def interpreted(grammar, input) = report(grammar.parse(input), method(:dump))

  def generated(parser, input)
    runtime = Object.const_get(parser.name.delete_suffix("::Parser"))::BirmanRT
    report(parser.new(input).parse, runtime.method(:dump))
  end

  # The entry point appended to a generated parser to make a binary:
  # it reads stdin and prints the report. With --bench it only parses.
  def main_source(namespace)
    <<~RUBY
      def report(result)
        return "ok \#{#{namespace}::BirmanRT.dump(result.value)}" if result.success?

        "fail pos=\#{result.pos} committed=\#{result.committed} expected=\#{result.expected.inspect} " \\
          "reason=\#{result.reason.inspect}\\n\#{result.message}"
      end

      if ARGV.size.positive? && ARGV[0] == "--bench"
        puts #{namespace}::Parser.new($stdin.read).parse.success? ? "ok" : "fail"
      else
        puts report(#{namespace}::Parser.new($stdin.read).parse)
      end
    RUBY
  end

  # Random token soup.
  def fuzz(tokens, rng, count, max_len)
    Array.new(count) { Array.new(rng.rand(1..max_len)) { tokens.sample(random: rng) }.join }
  end

  # One edit: delete, duplicate or replace a character.
  def mutate(rng, text, replacements)
    return text if text.empty?

    i = rng.rand(text.size)
    case rng.rand(3)
    when 0 then text[0...i] + text[(i + 1)..]
    when 1 then text[0..i] + text[i..]
    else text[0...i] + replacements.sample(random: rng) + text[(i + 1)..]
    end
  end

  # Loads a generated parser into this process, under namespace.
  def load(grammar, namespace)
    Object.send(:remove_const, namespace) if Object.const_defined?(namespace, false)
    source = grammar.to_ruby(namespace:)
    Object.class_eval(source, "(#{namespace} generated)", 1)
    Object.const_get(namespace)::Parser
  end
end
