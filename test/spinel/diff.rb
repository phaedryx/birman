# frozen_string_literal: true

# Compiles the parsers generated from the README grammar, examples/calc.rb,
# json.rb and email.rb, and Examples::Numbers with Spinel, then checks each
# binary against the interpreter on the same inputs test_compiled_examples.rb
# uses.
#
#   bundle exec rake spinel                 # all of them
#   bundle exec ruby test/spinel/diff.rb json
#
# SPINEL is the spinel executable (default: spinel on PATH), INPUTS the number
# of inputs per kind (default 3000), SEED the random seed. Skips, rather
# than fails, when Spinel isn't installed: CI doesn't have it.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "birman"
require "fileutils"
require "open3"
require_relative "../support/examples"

module SpinelDiff
  module_function

  OUT = File.expand_path("../../tmp/spinel", __dir__)

  def spinel
    path = ENV.fetch("SPINEL") { ENV["PATH"].split(File::PATH_SEPARATOR).map { File.join(_1, "spinel") }.find { File.executable?(_1) } }
    path if path && File.executable?(path)
  end

  def build(example, compiler)
    FileUtils.mkdir_p(OUT)
    source = File.join(OUT, "#{example.name}_parser.rb")
    binary = File.join(OUT, "#{example.name}_parser")
    File.write(source, "#{example.grammar.to_ruby(namespace: example.namespace)}\n" \
                       "#{Differential.main_source(example.namespace)}")
    out, status = Open3.capture2e(compiler, source, "-o", binary)
    abort "spinel failed on #{source}:\n#{out}" unless status.success?
    binary
  end

  def run(binary, input)
    out, err, status = Open3.capture3(binary, stdin_data: input)
    return "crash (exit #{status.exitstatus}): #{err.lines.first&.chomp}" unless status.success?

    out.chomp
  end

  def agrees?(example, binary)
    inputs = example.inputs.uniq
    mismatches = inputs.filter_map do |input|
      want = Differential.interpreted(example.grammar, input)
      got = run(binary, input)
      [input, want, got] unless want == got
    end
    mismatches.first(5).each do |input, want, got|
      puts "  input: #{input.inspect}", "    interpreter: #{want.inspect}", "    spinel:      #{got.inspect}"
    end
    puts "#{example.name}: #{inputs.size} inputs, #{mismatches.size} mismatches"
    mismatches.empty?
  end
end

# BirmanRT.to_integer (Grammar#large_integer), compiled, against
# Kernel#Integer under CRuby, on Examples::INTEGER_CASES and
# INTEGER_BASE_CASES (test_compiler.rb checks it under CRuby).
module IntegerCheck
  module_function

  # Each string also padded past 12 bytes, so it's read by integer_syntax
  # rather than by Spinel's Integer.
  CASES = (Examples::INTEGER_CASES.grep(String).map { [_1, 0] } +
           Examples::INTEGER_BASE_CASES.select { _1[0].is_a?(String) })
          .flat_map { |value, base| [[value, base], ["#{" " * 13}#{value}", base]] } +
          Examples::FLOAT_CASES.map { [_1, 0] }

  def literal(value) = value.is_a?(Float) ? Examples.float_source(value) : value.inspect

  def expected(value, base)
    Integer(value, base).inspect
  rescue ArgumentError, TypeError, FloatDomainError => e
    e.class.name
  end

  def source
    runtime = File.read(Birman::Compiler::RUNTIME).split(/^require "strscan"\n\n/, 2).last
    probes = CASES.map do |value, base|
      "begin\n  puts IntegerProbe::BirmanRT.to_integer(#{literal(value)}, #{base.inspect}).inspect\n" \
        "rescue ArgumentError, FloatDomainError, RangeError, TypeError => e\n  puts e.class.name\nend\n"
    end
    "require \"strscan\"\nmodule IntegerProbe\n#{runtime}end\n#{probes.join}"
  end

  def agrees?(compiler)
    path = File.join(SpinelDiff::OUT, "integer_probe.rb")
    File.write(path, source)
    out, status = Open3.capture2e(compiler, path, "-o", path.delete_suffix(".rb"))
    abort "spinel failed on #{path}:\n#{out}" unless status.success?
    got = Open3.capture2(path.delete_suffix(".rb"))[0].lines(chomp: true)
    bad = CASES.zip(got).reject { |(value, base), line| line == expected(value, base) }
    bad.each do |(value, base), line|
      puts "  Integer(#{value.inspect}, #{base.inspect}): CRuby #{expected(value, base)}, Spinel #{line}"
    end
    puts "to_integer: #{CASES.size} cases, #{bad.size} mismatches"
    bad.empty?
  end
end

# Lookaheads nested past LOOKAHEAD_DEPTH are a Failure, not Spinel's exit
# when its 64 begin blocks run out; a binary built with a bigger
# SP_EXC_STACK_MAX takes a bigger lookahead_depth.
module DepthCheck
  module_function

  def build(compiler, name, depth, *flags)
    path = File.join(SpinelDiff::OUT, "#{name}.rb")
    source = Examples::Nest::Grammar.to_ruby(namespace: "NestCompiled", lookahead_depth: depth)
    File.write(path, "#{source}\n#{Differential.main_source("NestCompiled")}")
    out, status = Open3.capture2e(compiler, path, "-o", path.delete_suffix(".rb"), *flags)
    abort "spinel failed on #{path}:\n#{out}" unless status.success?
    path.delete_suffix(".rb")
  end

  def gives?(binary, depth, want)
    out, status = Open3.capture2e(binary, stdin_data: Examples::Nest.input(depth))
    return true if status.success? && out.include?(want)

    puts "  #{File.basename(binary)} at depth #{depth}: exit #{status.exitstatus}, #{out.lines.first&.chomp}"
    false
  end

  def agrees?(compiler)
    default = build(compiler, "nest_parser", Birman::Compiler::LOOKAHEAD_DEPTH)
    deep = build(compiler, "nest_parser_deep", 4000, "--cc=cc -DSP_EXC_STACK_MAX=4096")
    too_deep = "reason=\"input is nested too deeply\""
    results = [gives?(default, 50, "ok ["), gives?(default, 100, too_deep), gives?(deep, 3000, "ok ["),
               gives?(deep, 5000, too_deep)]
    puts "lookahead depth: #{results.size} cases, #{results.count(false)} mismatches"
    results.all?
  end
end

compiler = SpinelDiff.spinel
unless compiler
  puts "Spinel not found (set SPINEL=/path/to/spinel): skipping the compiled-parser tests"
  exit 0
end

wanted = ARGV.empty? ? %w[let calc json email numbers] : ARGV
examples = Examples.all(Integer(ENV.fetch("INPUTS", 3000))).select { wanted.include?(_1.name) }
FileUtils.mkdir_p(SpinelDiff::OUT)
ok = examples.map { |example| SpinelDiff.agrees?(example, SpinelDiff.build(example, compiler)) }
ok << IntegerCheck.agrees?(compiler) if ARGV.empty?
ok << DepthCheck.agrees?(compiler) if ARGV.empty?
exit(ok.all? ? 0 : 1)
