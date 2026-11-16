# frozen_string_literal: true

# Differential testing of generated parsers (Grammar.to_ruby) against
# the interpreter (Grammar.parse). Both sides are reduced to one report
# string: where the match ended and the value with every node's span,
# or the failure's position, expectations, committed flag, reason and
# message, and after recoveries (Matcher#recover) every error and the
# value built around them. options are the parse's (root:, consume:, offset:), on both sides. The generated side
# is either loaded into this process (CRuby) or a compiled binary that
# prints the same report (see Differential.main_source).
module Differential
  module_function

  # The interpreter's value, written the way the runtime's
  # BirmanRT.dump writes the generated parser's (see there for why
  # invalid UTF-8 shows its bytes).
  def dump(value)
    case value
    when Birman::Node then dump_node(value)
    when Birman::Spanned then "Spanned[#{value.span.byte_from},#{value.span.byte_to}](#{dump(value.value)})"
    when Array then "[#{value.map { dump(_1) }.join(", ")}]"
    when Hash then "{#{value.map { |k, v| "#{dump(k)} => #{dump(v)}" }.join(", ")}}"
    when String then value.valid_encoding? ? value.inspect : value.b.inspect
    else value.inspect
    end
  end

  # An ErrorNode's failure is written field by field, as
  # BirmanRT::ErrorNode#dump writes it.
  def dump_node(node)
    span = node.span
    if node.is_a?(Birman::ErrorNode)
      f = node.failure
      return "(ErrorNode[#{span.byte_from},#{span.byte_to}] Failure[#{f.pos} #{f.expected.inspect} " \
             "#{f.committed} #{f.reason.inspect}])"
    end

    fields = node.to_h.values.map { dump(_1) }
    "(#{["#{node.class.name.split("::").last}[#{span.byte_from},#{span.byte_to}]", *fields].join(" ")})"
  end

  def report(result, dumper)
    return "ok pos=#{result.pos} #{dumper.call(result.value)}" if result.success?

    "fail pos=#{result.pos} committed=#{result.committed} expected=#{result.expected.inspect} " \
      "reason=#{result.reason.inspect}\n#{result.message}#{recovered(result, dumper)}"
  end

  # A recovering parse's errors and value (a generated parser's Failure
  # has errors only if its grammar recovers).
  def recovered(failure, dumper)
    return "" unless failure.respond_to?(:errors) && !failure.errors.first.equal?(failure)

    errors = failure.errors.map { "#{_1.pos} #{_1.expected.inspect} #{_1.committed} #{_1.reason.inspect}" }
    "\nerrors=[#{errors.join(", ")}] value=#{dumper.call(failure.value)}"
  end

  def interpreted(grammar, input, **) = report(grammar.parse(input, **), method(:dump))

  def generated(parser, input, **)
    runtime = Object.const_get(parser.name.delete_suffix("::Parser"))::BirmanRT
    report(parser.new(input).parse(**), runtime.method(:dump))
  end

  # The entry point appended to a generated parser to make a binary:
  # it reads stdin and prints the report. With --bench it only parses.
  # recovers: the grammar recovers, so the report lists errors (see
  # recovered).
  def main_source(namespace, recovers: false, **options)
    call = options.empty? ? "parse" : "parse(#{options.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")})"
    <<~RUBY
      def report(result)
        return "ok pos=\#{result.pos} \#{#{namespace}::BirmanRT.dump(result.value)}" if result.success?

        "fail pos=\#{result.pos} committed=\#{result.committed} expected=\#{result.expected.inspect} " \\
          "reason=\#{result.reason.inspect}\\n\#{result.message}#{"\#{recovered(result)}" if recovers}"
      end
      #{"\n#{main_recovered(namespace)}" if recovers}
      if ARGV.size.positive? && ARGV[0] == "--bench"
        puts #{namespace}::Parser.new($stdin.read).#{call}.success? ? "ok" : "fail"
      else
        puts report(#{namespace}::Parser.new($stdin.read).#{call})
      end
    RUBY
  end

  def main_recovered(namespace)
    <<~RUBY
      def recovered(failure)
        return "" if failure.errors[0].equal?(failure)

        errors = []
        failure.errors.each { |e| errors << "\#{e.pos} \#{e.expected.inspect} \#{e.committed} \#{e.reason.inspect}" }
        "\\nerrors=[\#{errors.join(", ")}] value=\#{#{namespace}::BirmanRT.dump(failure.value)}"
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
  def load(grammar, namespace, **)
    Object.send(:remove_const, namespace) if Object.const_defined?(namespace, false)
    source = grammar.to_ruby(namespace:, **)
    Object.class_eval(source, "(#{namespace} generated)", 1)
    Object.const_get(namespace)::Parser
  end
end
