# frozen_string_literal: true

# Times one large input per example: Birman's interpreter, the generated
# parser under CRuby, and the Spinel binary (parse only, via --bench).
# Run test/spinel/diff.rb first: it builds the binaries.
#
#   bundle exec ruby test/spinel/bench.rb [calc|json] [size]
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "birman"
require_relative "../support/examples"

name = ARGV.fetch(0, "calc")
size = Integer(ARGV.fetch(1, 20_000))
rng = Random.new(42)
example, source =
  case name
  when "calc" then [Examples.calc(0), Examples::CalcGen.program(rng, size)]
  when "json" then [Examples.json(0), "[#{Array.new(size) { Examples::JSONGen.document(rng) }.join(",\n")}]"]
  else abort "bench calc or json"
  end

out = File.expand_path("../../tmp/spinel", __dir__)
bin = File.join(out, "#{name}_parser")
abort "no #{bin}: run test/spinel/diff.rb #{name} first" unless File.executable?(bin)
input_path = File.join(out, "bench_input.#{name}")
File.write(input_path, source)
parser = Differential.load(example.grammar, example.namespace)

yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
puts "#{name}: #{size} items, #{source.bytesize / 1024} KB, ruby #{RUBY_VERSION} yjit=#{yjit ? true : false}"
abort "interpreter failed" unless example.grammar.parse(source).success? # warm-up
abort "generated parser failed" unless parser.new(source).parse.success?

def best(runs = 3)
  Array.new(runs) do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end.min
end

t_interp = best { example.grammar.parse(source) }
t_gen = best { parser.new(source).parse }
t_bin = best { system(bin, "--bench", in: input_path, out: File::NULL) or abort "binary failed" }
t_noop = best { system(bin, "--bench", in: File::NULL, out: File::NULL) }

def row(label, seconds, baseline = nil)
  speedup = baseline && format("  %<x>5.1fx", x: baseline / seconds)
  puts format("%<label>-25s %<ms>8.1f ms%<speedup>s", label:, ms: seconds * 1000, speedup:)
end

row "interpreter (CRuby)", t_interp
row "generated Ruby (CRuby)", t_gen, t_interp
row "Spinel binary (process)", t_bin, t_interp
row "  of which startup+empty", t_noop
