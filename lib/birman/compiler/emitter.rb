# frozen_string_literal: true

module Birman
  class Compiler
    # Writes the Parser's methods: one per matcher (shared by equal
    # matchers), plus a packrat memo wrapper (ref_<rule>) per rule.
    #
    # Each matcher becomes a fixed template, following Birman's matchers
    # line by line. A method takes a byte position p and returns where
    # its match ended, or FAIL. A matcher whose value something reads
    # leaves it in its own instance variable, which the caller copies
    # straight away: the next match may overwrite it.
    # [class.Compiler.Emitter]
    # purpose = "Turns each matcher into a method of the generated Parser"
    class Emitter
      # How to call a compiled matcher: the name of the method to call with a
      # position, and the expression for its value just after a
      # successful call (nil when nothing reads it).
      Call = Struct.new(:name, :value)

      PUNCTUATION = {
        "=" => "eq", "+" => "plus", "-" => "minus", "*" => "star", "/" => "slash", "(" => "lparen",
        ")" => "rparen", "{" => "lbrace", "}" => "rbrace", "[" => "lbracket", "]" => "rbracket",
        "," => "comma", ":" => "colon", ";" => "semicolon", "." => "dot", "<" => "lt", ">" => "gt",
        "!" => "bang", "?" => "question", "&" => "amp", "|" => "bar", "%" => "percent", "^" => "caret"
      }.freeze

      # An inline RBS signature for every position-taking method: one
      # position Spinel can't type would widen them all to boxed values.
      POSITION = "#: (Integer) -> Integer\n"

      SAVE = <<~RUBY
        of = @furthest
        oe = @expected
        @furthest = p
        @expected = NONE
      RUBY

      # Rules whose values something reads (Refs met wanting a value).
      attr_reader :read_rules

      # valued: the rules to keep values for. If read_rules turns out
      # bigger, compile again with those (see Compiler#to_ruby).
      def initialize(grammar, valued)
        @grammar = grammar
        @valued = valued
        @read_rules = [grammar.class.root]
        @types = Types.new(grammar)
        @nodes = Nodes.new
        @actions = Actions.new(grammar)
        @methods = []
        @compiled = {}
        @taken = {}
        @values = {}
        @rules = {}
        @ignores = []
      end

      def compile
        root = @grammar.class.root or raise Error, "#{@grammar.class} has no root rule"
        queue = [root, ignore_rule].compact
        while (name = queue.shift)
          next if @rules.key?(name)

          @rules[name] = compile_rule(name)
          queue.concat(@pending)
        end
        clash = @actions.names.find { @taken.key?(_1.to_s) || @rules.key?(_1) }
        raise Error, "the grammar method #{clash} would clash with a generated method" if clash

        shared = (@actions.constant_names & @nodes.names).first
        raise Error, "#{shared} is both a node class and a constant copied actions read" if shared
      end

      def node_classes = @nodes.sources

      def node_names = @nodes.names

      def parser_body
        [*@actions.constants.map { "#{_1}\n" }, initializer, parse_method, "private\n",
         *@actions.methods, *@methods, *@ignores.map { skip_method(_1) }, init_values, init_memos,
         *@rules.map { |name, call| ref_method(name, call) }].join("\n")
      end

      private

      def ignore_rule = @grammar.class.ignore

      # A rule's name as part of a Ruby identifier: rule(:valid?) is ref_valid_3f.
      def ident(name) = name.to_s.gsub(/[^A-Za-z0-9_]/) { format("_%02x", _1.ord) }

      def compile_rule(name)
        @pending = []
        @rule = name
        @prefix = ident(name)
        matcher = begin
          @grammar.matcher_for(name)
        rescue ArgumentError => e
          raise Error, e.message
        end
        want = @valued.include?(name)
        call = compile_matcher(matcher, want, "rule_#{ident(name)}")
        @values["@v_#{ident(name)}"] = @types.initial(Ref.new(name)) if want
        call
      end

      # --- Dispatch ---

      def compile_matcher(matcher, want, name = nil)
        key = [matcher, want]
        return @compiled[key] if @compiled.key?(key)

        @compiled[key] = translate(matcher, want, name)
      end

      def translate(matcher, want, name) # rubocop:disable Metrics
        case matcher
        when Str then str(matcher, want)
        when Pat then pat(matcher, want, name)
        when Lit then lit(matcher, want)
        when Seq then seq(matcher, want, name)
        when Pick then pick(matcher, want, name)
        when SepBy then sep_by(matcher, want, name)
        when Choice then choice(matcher, want, name)
        when Rep then rep(matcher, want, name)
        when Maybe then maybe(matcher, want, name)
        when Not then negative(matcher, want, name)
        when And then positive(matcher, want, name)
        when Both then both(matcher, want, name)
        when Const then const(matcher, want)
        when Send, Action then transform(matcher, want, name)
        when Label then label(matcher, want, name)
        when Named then compile_matcher(matcher.inner, want, name)
        when To then to(matcher, want, name)
        when Infix then infix(matcher, want, name)
        when Lexeme then lexeme(matcher, want, name)
        when Quiet then quiet(matcher, want, name)
        when Ref then ref(matcher, want)
        when Map
          raise Error, "rule :#{@rule} uses .map with a block, which can't be compiled; " \
                       "use .map(:method_name) or .action(:method_name)"
        else raise Error, "rule :#{@rule} uses #{matcher.class}, which the compiler doesn't know"
        end
      end

      # --- Methods ---

      # Defines a method for matcher, its body from the block (given the
      # value variable, or nil if no value is kept), and returns its Call.
      # The slot is taken first, so a method comes before those it calls.
      def define(kind, matcher, keep, name = nil, value: nil)
        name = claim(name || "#{@prefix}_#{kind}")
        ivar = "@v_#{name}" if keep
        @values[ivar] = @types.initial(matcher) if ivar
        slot = @methods.size
        @methods << nil
        body = yield(ivar).gsub(/^[ \t]+$/, "").gsub(/\n{3,}/, "\n\n")
        @methods[slot] = "# #{describe(matcher)}\n#{POSITION}def #{name}(p)\n#{indent(body.chomp)}\nend\n"
        Call.new(name, value || ivar)
      end

      # name, or name with a number added if it's taken.
      def claim(name)
        candidate = name
        n = 1
        candidate = "#{name}#{n += 1}" while @taken.key?(candidate)
        @taken[candidate] = true
        candidate
      end

      def describe(matcher)
        kind = matcher.class.name.split("::").last
        kind = "#{kind} #{matcher.name.inspect}" if matcher.is_a?(Label)
        "#{kind}: #{EBNF.expr(matcher.to_ast, EBNF::CHOICE)}"
      end

      # How an EBNF expression appears in a generated string literal.
      def expected(matcher) = EBNF.expr(matcher.to_ast, EBNF::CHOICE).inspect

      def indent(text) = text.lines.map { _1.strip.empty? ? "\n" : "  #{_1}" }.join

      # --- Terminals ---

      def str(matcher, want)
        text = matcher.str
        call = @compiled[[matcher, false]] ||= define(:str, matcher, false, "str_#{slug(text)}") do
          next "p" if text.empty?

          test = if text.bytesize == 1
                   "p < @len && @input.getbyte(p) == #{text.getbyte(0)}"
                 else
                   "bytes_at?(p, #{text.inspect})"
                 end
          "return fail_at(p, #{text.inspect.inspect}) unless #{test}\n\np + #{text.bytesize}"
        end
        Call.new(call.name, want ? text.inspect : nil)
      end

      def pat(matcher, want, name)
        regexp = anchored(matcher.re)
        define(:pat, matcher, want, name) do |v|
          found = if v
                    "unless len.nil?\n  #{v} = @input.byteslice(p, len)\n  return p + len\nend\n"
                  else
                    "return p + len unless len.nil?\n\n"
                  end
          "@sc.pos = p\nlen = @sc.skip(#{regexp})\n#{found}fail_at(p, #{matcher.source.inspect})"
        end
      end

      def anchored(re)
        Regexps.anchored(re)
      rescue Error => e
        raise Error, "rule :#{@rule}: #{e.message}"
      end

      # A literal is whatever the grammar says it stands for (keyword or
      # exact string, then the ignore rule), resolved now.
      def lit(matcher, want)
        outer = @prefix
        @prefix = "lit_#{slug(matcher.text)}"
        compile_matcher(@grammar.literal_matcher(matcher.text), want, @prefix)
      ensure
        @prefix = outer
      end

      def slug(text)
        return text if text.match?(/\A\w+\z/)

        text.each_char.map { |c| PUNCTUATION[c] || c.bytes.map { format("x%02x", _1) }.join }.join("_")
      end

      # --- Sequences ---

      def seq(matcher, want, name, build: nil)
        wanted = seq_wanted(matcher, want || build)
        define(:seq, matcher, want, name) do |v|
          lines, locals = steps(matcher.parts, matcher.commit_at, wanted)
          lines << "#{v} = #{build ? build.call(locals) : seq_value(matcher, locals)}" if v
          [*lines, "q"].join("\n")
        end
      end

      def seq_wanted(matcher, want)
        return [] unless want
        return [matcher.only_at] if matcher.only_at

        named = matcher.parts.each_index.select { matcher.parts[_1].capture_key }
        named.empty? ? matcher.parts.each_index.to_a : named
      end

      def seq_value(matcher, locals)
        return locals.fetch(matcher.only_at) if matcher.only_at

        keys = matcher.parts.map(&:capture_key)
        return "[#{locals.values.join(", ")}]" if keys.none?

        pairs = {}
        keys.each_with_index { |key, i| pairs[key] = locals[i] if key }
        "{ #{pairs.map { |key, local| "#{hash_key(key)} #{local}" }.join(", ")} }"
      end

      def hash_key(key) = key.is_a?(Symbol) && key.match?(/\A[a-z_]\w*\z/) ? "#{key}:" : "#{key.inspect} =>"

      # The parts in order from p, ending at q. A part that fails before
      # commit_at fails the sequence; one at or after it ends the parse.
      # Returns the lines and {index => local} for the wanted values.
      def steps(parts, commit_at, wanted)
        locals = {}
        lines = parts.each_with_index.flat_map do |part, i|
          keep = wanted.include?(i)
          locals[i] = "v#{i}" if keep
          step(compile_matcher(part, keep), part, i.zero? ? "p" : "q", commit_at && i >= commit_at, keep && "v#{i}")
        end
        lines.unshift("q = p") if parts.empty?
        [lines, locals]
      end

      def step(call, part, at, committed, local)
        keep = local ? ["#{local} = #{call.value}"] : []
        return ["q = #{call.name}(#{at})", "return FAIL if q == FAIL\n", *keep] unless committed

        ["r = #{call.name}(#{at})", "commit_failure(#{at}, #{expected(part)}) if r == FAIL", *keep, "q = r"]
      end

      def pick(matcher, want, name)
        wanted = want ? [matcher.index] : []
        define(:pick, matcher, want, name) do |v|
          lines, locals = steps(matcher.parts, nil, wanted)
          lines << "#{v} = #{locals.fetch(matcher.index)}" if v
          [*lines, "q"].join("\n")
        end
      end

      def sep_by(matcher, want, name)
        define(:sep_by, matcher, want, name) do |v|
          item = compile_matcher(matcher.item, want)
          sep = compile_matcher(matcher.sep, false)
          <<~RUBY
            q = #{item.name}(p)
            #{sep_by_none(matcher, v)}
            #{"values = [#{item.value}]" if v}
            while true
              s = #{sep.name}(q)
              break if s == FAIL

              r = #{item.name}(s)
              break if r == FAIL || r == q

              #{"values << #{item.value}" if v}
              q = r
            end
            #{"#{v} = values" if v}
            q
          RUBY
        end
      end

      def sep_by_none(matcher, value)
        return "return FAIL if q == FAIL\n" unless matcher.min.zero?
        return "return p if q == FAIL\n" unless value

        "if q == FAIL\n  #{value} = []\n  return p\nend\n"
      end

      # --- Choice and repetition ---

      def choice(matcher, want, name)
        define(:choice, matcher, want, name) do |v|
          *alts, last = matcher.alts.map { compile_matcher(_1, want) }
          tries = alts.map do |alt|
            taken = v ? "if q != FAIL\n  #{v} = #{alt.value}\n  return q\nend\n" : "return q if q != FAIL\n"
            "q = #{alt.name}(p)\n#{taken}"
          end
          [*tries, "q = #{last.name}(p)", ("#{v} = #{last.value} if q != FAIL" if v), "q"].compact.join("\n")
        end
      end

      def rep(matcher, want, name)
        define(:rep, matcher, want, name) do |v|
          inner = compile_matcher(matcher.inner, want)
          <<~RUBY
            n = 0
            #{"values = []" if v}
            while #{matcher.max ? "n < #{matcher.max}" : "true"}
              r = #{inner.name}(p)
              break if r == FAIL

              # Matching nothing ends the loop, but counts as the first match.
              if r == p
                if n.zero?
                  #{"values << #{inner.value}" if v}
                  n = 1
                end
                break
              end
              #{"values << #{inner.value}" if v}
              n += 1
              p = r
            end
            #{"return FAIL if n < #{matcher.min}" if matcher.min.positive?}
            #{"#{v} = values" if v}
            p
          RUBY
        end
      end

      def maybe(matcher, want, name)
        define(:maybe, matcher, want, name) do |v|
          inner = compile_matcher(matcher.inner, want)
          next "q = #{inner.name}(p)\nq == FAIL ? p : q" unless v

          "q = #{inner.name}(p)\nif q == FAIL\n  #{v} = nil\n  return p\nend\n#{v} = #{inner.value}\nq"
        end
      end

      # --- Lookahead ---

      # Not: isolated, a commit failure inside is just a failure, and its
      # diagnostics are dropped either way.
      def negative(matcher, want, name)
        define(:not, matcher, false, name, value: want ? "nil" : nil) do
          inner = compile_matcher(matcher.inner, false)
          "#{SAVE}#{lookahead(inner)}@furthest = of\n@expected = oe\nq == FAIL ? p : FAIL"
        end
      end

      def lookahead(inner) = "begin\n  q = #{inner.name}(p)\nrescue Committed\n  q = FAIL\nend\n"

      def positive(matcher, want, name)
        define(:and, matcher, false, name, value: want ? "nil" : nil) do
          inner = compile_matcher(matcher.inner, false)
          "#{SAVE}#{lookahead(inner)}peek_end(p, q, of, oe, #{expected(matcher.inner)}) ? p : FAIL"
        end
      end

      def both(matcher, want, name)
        define(:both, matcher, want, name) do |v|
          left = compile_matcher(matcher.left, false)
          right = compile_matcher(matcher.right, want)
          "#{SAVE}#{lookahead(left)}return FAIL unless peek_end(p, q, of, oe, #{expected(matcher.left)})\n\n" \
            "q = #{right.name}(p)\n#{"#{v} = #{right.value} if q != FAIL\n" if v}q"
        end
      end

      # --- Values ---

      def const(matcher, want)
        inner = compile_matcher(matcher.inner, false)
        return inner unless want

        unless Literals.literal?(matcher.constant)
          raise Error, "rule :#{@rule} uses .means(#{matcher.constant.inspect}), which isn't a literal"
        end

        Call.new(inner.name, matcher.constant.inspect)
      end

      # Send and Action. A value nothing reads is never computed.
      # Send and Action. A Send value nothing reads is skipped (it's a
      # plain method call on the value); an action always runs, since it
      # may check the value and raise, as the interpreter's would.
      def transform(matcher, want, name)
        return compile_matcher(matcher.inner, false) if !want && matcher.is_a?(Send)

        kind = matcher.is_a?(Send) ? :send : :action
        define(kind, matcher, want, name) do |v|
          inner = compile_matcher(matcher.inner, true)
          call = apply(matcher, inner.value)
          "q = #{inner.name}(p)\n#{"#{v} = " if v}#{call} if q != FAIL\nq"
        end
      end

      def apply(matcher, value)
        name = matcher.method_name
        unless name.match?(/\A[a-z_]\w*[?!]?\z/)
          raise Error, "rule :#{@rule} uses .#{matcher.is_a?(Send) ? "map" : "action"}(#{name.inspect}), " \
                       "which isn't a plain method name"
        end
        # String#to_i, Bignums included (Spinel's overflows past 63 bits).
        return "BirmanRT.to_i(#{value})" if name == :to_i && matcher.is_a?(Send) && @types.of(matcher.inner) == :str
        return "#{value}.#{name}" if matcher.is_a?(Send)

        @actions.copy(name, @rule)
        "#{name}(#{value})"
      end

      # --- Nodes ---

      def to(matcher, want, name)
        return compile_matcher(matcher.inner, false) unless want

        node = @nodes.name_for(matcher.node, @rule)
        members = matcher.node.members
        keys = hash_keys(matcher.inner)
        return seq_node(matcher, node, members, name) if keys.is_a?(Array) && direct_seq?(matcher.inner)

        define(:to, matcher, true, name) do |v|
          inner = compile_matcher(matcher.inner, true)
          args = node_args(members, keys, inner.value)
          value = "x = #{inner.value}\n" if keys == :unknown
          "q = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n#{value}#{v} = #{node}.new(#{args}, span(p, q))\nq"
        end
      end

      # A seq of named parts builds the node from its locals, no Hash.
      def seq_node(matcher, node, members, name)
        check_keys(members, hash_keys(matcher.inner))
        build = ->(locals) { node_new(matcher.inner, node, members, locals) }
        seq(matcher.inner, true, name, build:).tap { @compiled[[matcher, true]] = _1 }
      end

      def node_new(seq, node, members, locals)
        by_key = {}
        seq.parts.each_with_index { |part, i| by_key[part.capture_key] = locals[i] if part.capture_key }
        "#{node}.new(#{members.map { by_key.fetch(_1) }.join(", ")}, span(p, q))"
      end

      def direct_seq?(matcher) = matcher.is_a?(Seq) && matcher.only_at.nil?

      # The keys of the Hash that matcher's value is: nil if it's never a
      # Hash, :unknown if that's only known at parse time.
      def hash_keys(matcher, seen = []) # rubocop:disable Metrics
        case matcher
        when Seq
          return hash_keys(matcher.parts[matcher.only_at], seen) if matcher.only_at

          keys = matcher.parts.filter_map(&:capture_key)
          keys.empty? ? nil : keys.uniq
        when Pick then hash_keys(matcher.parts[matcher.index], seen)
        when Label, Quiet, Named, Lexeme then hash_keys(matcher.inner, seen)
        when Both then hash_keys(matcher.right, seen)
        when Lit, Str, Pat, Rep, SepBy, Not, And, To then nil
        when Infix then hash_keys(matcher.operand, seen) && :unknown # with no operator, the operand's value
        when Send then Types::SENDS.key?(matcher.method_name) && matcher.method_name != :to_h ? nil : :unknown
        when Const then matcher.constant.is_a?(Hash) ? matcher.constant.keys : nil
        when Choice
          keys = matcher.alts.map { hash_keys(_1, seen) }.uniq
          keys.size == 1 ? keys.first : :unknown
        when Ref
          seen.include?(matcher.name) ? :unknown : hash_keys(@grammar.matcher_for(matcher.name), [*seen, matcher.name])
        else :unknown
        end
      end

      def node_args(members, keys, value)
        if keys.is_a?(Array)
          check_keys(members, keys)
          return members.map { |member| "#{value}[#{member.inspect}]" }.join(", ")
        end
        raise Error, "rule :#{@rule} builds a node with #{members.size} fields from one value" if members.size != 1
        # Like Birman.build: a Hash value fills the fields by name.
        return "x.is_a?(Hash) ? x.fetch(#{members.first.inspect}) : x" if keys == :unknown

        value
      end

      def check_keys(members, keys)
        return if members.sort == keys.sort

        raise Error, "rule :#{@rule} builds a node with fields #{members.inspect} from named parts #{keys.inspect}"
      end

      def infix(matcher, want, name)
        node = @nodes.name_for(matcher.node, @rule)
        members = matcher.node.members
        unless members.sort == %i[left op right]
          raise Error, "rule :#{@rule}: infix needs a node with fields op, left and right"
        end

        define(:infix, matcher, want, name) do |v|
          infix_body(matcher, node, members, v)
        end
      end

      def infix_body(matcher, node, members, value)
        operand = compile_matcher(matcher.operand, true)
        op = compile_matcher(matcher.op, true)
        fields = { op: "op", left: "left", right: operand.value }
        <<~RUBY
          r = #{operand.name}(p)
          return FAIL if r == FAIL

          left = #{operand.value}
          q = r
          while true
            o = #{op.name}(q)
            break if o == FAIL

            op = #{op.value}
            r = #{operand.name}(o)
            break if r == FAIL

            left = #{node}.new(#{members.map { fields.fetch(_1) }.join(", ")}, span(p, r))
            q = r
          end
          #{"#{value} = left" if value}
          q
        RUBY
      end

      # --- Diagnostics, tokens, rules ---

      def label(matcher, want, name)
        inner = nil
        call = define(:label, matcher, false, name) do
          inner = compile_matcher(matcher.inner, want)
          "#{SAVE}q = #{inner.name}(p)\nlabel_end(p, q, of, oe, #{matcher.name.inspect})"
        end
        Call.new(call.name, inner.value) # label_end leaves values alone
      end

      def quiet(matcher, want, name)
        inner = nil
        call = define(:quiet, matcher, false, name) do
          inner = compile_matcher(matcher.inner, want)
          "#{SAVE}q = #{inner.name}(p)\n@furthest = of\n@expected = oe\nq"
        end
        Call.new(call.name, inner.value)
      end

      def lexeme(matcher, want, name)
        return compile_matcher(matcher.inner, want, name) unless matcher.ignore

        @ignores |= [matcher.ignore]
        define(:lexeme, matcher, want, name) do |v|
          inner = compile_matcher(matcher.inner, want)
          keep = "#{v} = #{inner.value}\n" if v
          "q = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n#{keep}skip_#{ident(matcher.ignore)}(q)"
        end
      end

      def ref(matcher, want)
        @pending << matcher.name
        @read_rules |= [matcher.name] if want
        Call.new("ref_#{ident(matcher.name)}", want ? "@v_#{ident(matcher.name)}" : nil)
      end

      # --- The rest of the Parser ---

      def initializer
        <<~RUBY
          def initialize(input)
            super
            @sc = StringScanner.new(input)
            init_values
            init_memos
          end
        RUBY
      end

      def parse_method
        start = ignore_rule ? "start = ref_#{ident(ignore_rule)}(0)\nstart = 0 if start == FAIL" : "start = 0"
        root = @grammar.class.root
        <<~RUBY
          # Grammar#parse: Success(value) if all of the input parses, else Failure.
          def parse
          #{indent(start)}
            q = ref_#{ident(root)}(start)
            return Success.new(@v_#{ident(root)}) if q == @len

            fail_at(q, "end of input") if q != FAIL
            failure(@furthest, @expected, false)
          rescue Committed => e
            failure(e.pos, e.expected, true)
          rescue SystemStackError
            failure_because(@position, "input is nested too deeply")
          end
        RUBY
      end

      # Lexeme's tail: the ignore rule, recorded so spans leave it out.
      def skip_method(rule)
        <<~RUBY
          #{POSITION.chomp}
          def skip_#{ident(rule)}(q)
            s = ref_#{ident(rule)}(q)
            return q if s == FAIL

            ignored_after(q, s)
            s
          end
        RUBY
      end

      def init_values
        "def init_values\n#{indent(@values.map { |ivar, initial| "#{ivar} = #{initial}\n" }.join)}end\n"
      end

      def init_memos
        lines = @rules.keys.flat_map do |name|
          (@valued.include?(name) ? %w[mp mv mf me] : %w[mp mf me]).map { "@#{_1}_#{ident(name)} = {}\n" }
        end
        "def init_memos\n#{indent(lines.join)}end\n"
      end

      # Ref: the rule's memo entry at p, computed the first time with
      # fresh failure tracking, which is then merged into the caller's.
      # An entry abandoned by a commit failure (caught by a lookahead) is
      # overwritten with ABSENT, never deleted: Hash#delete is O(size) in
      # Spinel.
      def ref_method(name, call)
        valued = @valued.include?(name)
        id = ident(name)
        <<~RUBY
          #{POSITION.chomp}
          def ref_#{id}(p)
            q = @mp_#{id}[p]
            unless q.nil? || q == ABSENT
              left_recursion(#{name.to_s.inspect}) if q == IN_PROGRESS
          #{"    @v_#{id} = @mv_#{id}[p] if q != FAIL" if valued}
              merge(@mf_#{id}[p], @me_#{id}[p])
              return q
            end
            @mp_#{id}[p] = IN_PROGRESS
            @position = p
            of = @furthest
            oe = @expected
            @furthest = p
            @expected = NONE
            begin
              q = #{call.name}(p)
            ensure
              f = @furthest
              ex = @expected
              @furthest = of
              @expected = oe
              @mp_#{id}[p] = ABSENT if @mp_#{id}[p] == IN_PROGRESS
            end
            @mp_#{id}[p] = q
          #{indent("if q != FAIL\n  @v_#{id} = #{call.value || "nil"}\n  @mv_#{id}[p] = @v_#{id}\nend").chomp if valued}
            @mf_#{id}[p] = f
            @me_#{id}[p] = ex
            merge(f, ex)
            q
          end
        RUBY
      end
    end
  end
end
