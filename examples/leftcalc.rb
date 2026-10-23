# frozen_string_literal: true

# examples/calc.rb with its arithmetic written as left recursion instead
# of infix: each rule calls itself first, `expr op term | term`, and
# Birman grows the match from a seed. The trees, and the interpreter
# that runs them, are calc's own.
#
#   ruby examples/leftcalc.rb

require_relative "calc"

module LeftCalc
  # Calc's language, with sum and product left-recursive.
  class Grammar < Calc::Grammar
    # sum = sum ("+" | "-") product | product, so 1 - 2 - 3 is (1 - 2) - 3.
    # The alternative that starts with the rule itself comes first, and
    # the one that doesn't, the base case, last.
    rule(:sum)     { either(seq(sum.as(:left), either("+", "-").as(:op), product.as(:right)).to(BinOp), product) }
    rule(:product) { either(seq(product.as(:left), either("*", "/").as(:op), atom.as(:right)).to(BinOp), atom) }
  end
end

if __FILE__ == $PROGRAM_NAME
  source = <<~CALC
    let x = 10 - 4 - 3      # (10 - 4) - 3
    print x
    print 2 * 3 + 4 * 5     # (2 * 3) + (4 * 5)
    print 100 / 10 / 5
  CALC

  statements = LeftCalc::Grammar.parse!(source)
  Calc::Interpreter.new.run(statements)

  puts "\n--- AST ---"
  statements.each { p _1 }

  puts "\n--- Same trees as calc's infix ---"
  p(statements == Calc::Grammar.parse!(source))

  puts "\n--- Spans: each level covers its subexpression ---"
  outer = LeftCalc::Grammar.parse!("print 1 - 2 - 3").first.value
  [outer, outer.left, outer.left.left].each { puts _1.span.text.inspect }

  puts "\n--- Parse errors ---"
  ["print 1 -", "print 2 * (3 +"].each { puts LeftCalc::Grammar.parse(_1).message, "" }

  puts "--- Grammar ---"
  puts LeftCalc::Grammar.to_ebnf
end
