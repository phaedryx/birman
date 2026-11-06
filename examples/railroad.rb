# frozen_string_literal: true

# Railroad diagrams of every example grammar: one HTML page each, every
# rule drawn, its references linked to their diagrams, plus calc's sum
# rule as a standalone SVG.
#
#   ruby examples/railroad.rb             # writes tmp/railroad/
#   ruby examples/railroad.rb some/dir    # writes some/dir/

require "fileutils"
%w[calc leftcalc json email toml query].each { require_relative _1 }

GRAMMARS = {
  "calc" => Calc::Grammar, "leftcalc" => LeftCalc::Grammar, "json" => JSONExample::Grammar,
  "email" => EmailExample::Grammar, "toml" => TOMLExample::Grammar, "query" => QueryExample::Grammar
}.freeze

dir = ARGV.fetch(0, File.expand_path("../tmp/railroad", __dir__))
FileUtils.mkdir_p(dir)

GRAMMARS.each do |name, grammar|
  path = File.join(dir, "#{name}.html")
  File.write(path, grammar.to_html(title: "#{name} grammar"))
  puts "#{path}  (#{grammar.rules.size} rules)"
end

path = File.join(dir, "calc-sum.svg")
File.write(path, Calc::Grammar.to_svg(:sum))
puts path
