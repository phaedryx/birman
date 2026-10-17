# frozen_string_literal: true

# A tiny language that exercises every Birman feature: nodes with source
# spans, rule modules, skip and keywords, commit points, named captures, infix
# operators, a pattern-matching interpreter, and EBNF output.
#
#   ruby examples/calc.rb

require_relative "../lib/birman"

module Calc
  class Grammar
    include Birman::Grammar
    include Birman::Rules::Comments
    include Birman::Rules::Numbers
    include Birman::Rules::Strings
    include Birman::Rules::Identifiers

    Num   = node(:value)
    Text  = node(:value)
    Var   = node(:name)
    BinOp = node(:op, :left, :right)
    If    = node(:cond, :then_branch, :else_branch)
    Let   = node(:name, :value)
    Print = node(:value)

    root :program
    skip :sp
    keywords "let", "print", "if", "then", "else"

    rule(:program)    { statement.rep }
    rule(:statement)  { either(let_stmt, print_stmt, expr).label("statement") }

    rule(:let_stmt)   { seq("let", commit, name.as(:name), "=", expr.as(:value)).to(Let) }
    rule(:print_stmt) { seq("print", commit, expr.as(:value)).to(Print) }

    rule(:expr)       { either(if_expr, sum) }
    rule(:if_expr) do
      seq("if", commit, expr.as(:cond),
          "then",    expr.as(:then_branch),
          "else",    expr.as(:else_branch)).to(If)
    end

    rule(:sum)        { infix(product, "+", "-", node: BinOp) }
    rule(:product)    { infix(atom, "*", "/", node: BinOp) }
    rule(:atom)       { either(number.to(Num), string.to(Text), name.to(Var), parens(expr)).label("expression") }
    rule(:name)       { identifier.map(&:to_sym) }
  end

  class RuntimeError < StandardError
    def initialize(message, node) = super("#{message} at #{node.span}")
  end

  class Interpreter
    def initialize(out: $stdout)
      @out = out
      @env = {}
    end

    def run(statements) = statements.map { evaluate(_1) }.last

    def evaluate(node)
      case node
      in Grammar::Num(value)        then value
      in Grammar::Text(value)       then value
      in Grammar::Var(name)         then @env.fetch(name) { raise RuntimeError.new("undefined variable `#{name}`", node) }
      in Grammar::Let(name, value)  then @env[name] = evaluate(value)
      in Grammar::Print(value)      then evaluate(value).tap { @out.puts(_1) }
      in Grammar::BinOp(op, left, right)
        lhs, rhs = evaluate(left), evaluate(right)
        raise RuntimeError.new("can't apply #{op} to #{lhs.inspect} and #{rhs.inspect}", node) unless lhs.class == rhs.class

        lhs.public_send(op, rhs)
      in Grammar::If(cond, then_branch, else_branch)
        truthy?(evaluate(cond)) ? evaluate(then_branch) : evaluate(else_branch)
      end
    end

    private

    def truthy?(value) = value != 0 && value != ""
  end
end

if __FILE__ == $PROGRAM_NAME
  source = <<~CALC
    # Area of a box
    let width = 3
    let height = (1 + 2) * 4   # twelve
    print "area: "
    print width * height
    print if width - 3 then "wide" else "narrow"
  CALC

  case Calc::Grammar.parse(source)
  in Birman::Success(statements)
    Calc::Interpreter.new.run(statements)
    puts "\n--- AST ---"
    statements.each { p _1 }
  in Birman::Failure => failure
    warn failure.message
  end

  puts "\n--- Parse errors ---"
  ["let = 4", "print (1 + 2", "print if 1 then 2", %(print "unclosed), "print 1 +"].each do |bad|
    puts Calc::Grammar.parse(bad).message, ""
  end

  puts "--- Runtime errors ---"
  ["let a = 1\nprint a + b", %(print 1 + "two")].each do |bad|
    Calc::Interpreter.new.run(Calc::Grammar.parse!(bad))
  rescue Calc::RuntimeError => e
    puts e.message
  end

  puts "\n--- Grammar ---"
  puts Calc::Grammar.to_ebnf
end
