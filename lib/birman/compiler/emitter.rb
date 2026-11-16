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
    #
    # A grammar that recovers (Matcher#recover) gets the error log
    # Birman::Context keeps: a matcher that can record errors takes a
    # mark (@log_mark) where Birman's takes one, and rolls back or skips
    # user code where it does; a rule that can carries its errors in its
    # memo (@mr_). Nothing else changes, so a grammar that doesn't
    # recover generates what it did before recover existed.
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
      # analysis: the grammar's LeftRecursion for the roots. roots: the
      # rules parse may start at besides the grammar's root.
      def initialize(grammar, valued, analysis, roots) # rubocop:disable Metrics/MethodLength
        @grammar = grammar
        @valued = valued
        @analysis = analysis
        @roots = roots
        @read_rules = [grammar.class.root, *roots]
        @types = Types.new(grammar, roots)
        @nodes = Nodes.new
        @actions = Actions.new(grammar)
        @methods = []
        @compiled = {}
        @taken = {}
        @values = {}
        @rules = {}
        @ignores = []
        @recovers = @types.any_recovers?
      end

      # Does any rule the parser reaches recover?
      def recovers? = @recovers

      def compile
        root = @grammar.class.root or raise Error, "#{@grammar.class} has no root rule"
        queue = [root, ignore_rule, *@roots].compact
        while (name = queue.shift)
          next if @rules.key?(name)

          @rules[name] = compile_rule(name)
          queue.concat(@pending)
        end
        refuse_clashes
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

      def refuse_clashes
        met = @rules.keys.group_by { ident(_1) }.values.find { _1.size > 1 }
        raise Error, "rules #{met.map(&:inspect).join(" and ")} would have one name in the generated parser" if met

        clash = @actions.names.find { @taken.key?(_1.to_s) || @rules.key?(_1) }
        raise Error, "the grammar method #{clash} would clash with a generated method" if clash

        shared = (@actions.constant_names & @nodes.names).first
        raise Error, "#{shared} is both a node class and a constant copied actions read" if shared
      end

      # Can matcher change the error log (see Types#recovers?)? Only then
      # does it take a mark and roll back to it.
      def logs?(matcher) = @recovers && @types.recovers?(matcher)

      # Does rule name's memo entry carry errors (@mr_, and in a cycle
      # led by another rule @rx_ and @bx_ too)?
      def carries?(name) = logs?(Ref.new(name))

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
        @values["@v_ref_#{ident(name)}"] = @types.initial(Ref.new(name)) if want
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
        when Captures then captures(matcher, want, name)
        when Lit then lit(matcher, want)
        when Nocase then nocase(matcher, want)
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
        when Check then check(matcher, want, name)
        when Named then compile_matcher(matcher.inner, want, name)
        when To then to(matcher, want, name)
        when Text then text(matcher, want, name)
        when Upto then upto(matcher, want, name)
        when SpannedMatcher then spanned(matcher, want, name)
        when Operators then operators(matcher, want, name)
        when Lexeme then lexeme(matcher, want, name)
        when Quiet then quiet(matcher, want, name)
        when Recover then recover(matcher, want, name)
        when Ref then ref(matcher, want)
        when Map
          raise Error, "rule :#{@rule} uses .map with a block, which can't be compiled; " \
                       "use .map(:method_name) or .action(:method_name)"
        else raise Error, "rule :#{@rule} uses #{matcher.class}, which the compiler doesn't know"
        end
      end

      # --- Methods ---

      # Defines a method for matcher, its body from the block (given the
      # value variable, or nil if no value is kept, and the method's name),
      # and returns its Call. The slot is taken first, so a method comes
      # before those it calls. extra names a second, Integer, parameter.
      def define(kind, matcher, keep, name = nil, value: nil, extra: nil) # rubocop:disable Metrics/ParameterLists
        name = claim(name || "#{@prefix}_#{kind}")
        ivar = "@v_#{name}" if keep
        @values[ivar] = @types.initial(matcher) if ivar
        slot = @methods.size
        @methods << nil
        body = yield(ivar, name).gsub(/^[ \t]+$/, "").gsub(/\n{3,}/, "\n\n")
        signature = extra ? "#: (Integer, Integer) -> Integer\ndef #{name}(p, #{extra})" : "#{POSITION}def #{name}(p)"
        @methods[slot] = "# #{describe(matcher)}\n#{signature}\n#{indent(body.chomp)}\nend\n"
        Call.new(name, value || ivar)
      end

      # name, or name with a number added if it's taken. ref_ and skip_
      # names (and @v_ref_ values) are the rules' own (see ref_method and
      # skip_method), so a part of rule :ref is rule_ref_seq, not ref_seq.
      def claim(name)
        name = "rule_#{name}" if name.start_with?("ref_", "skip_")
        candidate = name
        n = 1
        candidate = "#{name}#{n += 1}" while @taken.key?(candidate)
        @taken[candidate] = true
        candidate
      end

      def describe(matcher)
        kind = matcher.class.name.split("::").last
        kind = "#{kind} #{matcher.name.inspect}" if matcher.is_a?(Label) || matcher.is_a?(Check)
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

      # Groups by number: Spinel's scanner can't look them up by name.
      # Named groups are numbered in order, and once a group is named the
      # unnamed ones don't capture (see Captures).
      def captures(matcher, want, name)
        regexp = anchored(matcher.pat.re)
        define(:captures, matcher, want, name) do |v|
          pairs = matcher.pat.re.names.each_with_index.map { |group, i| "#{hash_key(group.to_sym)} @sc[#{i + 1}]" }
          found = if v
                    "unless len.nil?\n  #{v} = { #{pairs.join(", ")} }\n  return p + len\nend\n"
                  else
                    "return p + len unless len.nil?\n\n"
                  end
          "@sc.pos = p\nlen = @sc.skip(#{regexp})\n#{found}fail_at(p, #{matcher.pat.source.inspect})"
        end
      end

      # Everything up to the terminator, as the interpreter's Upto.
      def upto(matcher, want, name)
        define(:upto, matcher, want, name) do |v|
          "#{find(matcher.terminator)}\n#{"#{v} = @input.byteslice(p, q - p)\n" if v}q"
        end
      end

      # Sets q to where stop first matches at or after p, or returns FAIL
      # having recorded what it expected at the end. Exact text or a
      # regexp is one byteindex, which would have found a match at the
      # end, so a miss is recorded as the terminator's own would be. Else
      # a negative lookahead at each character, and at the end a positive
      # one, which records what the terminator expected there.
      def find(stop)
        case stop
        when Str then "q = @input.byteindex(#{stop.str.inspect}, p)\n#{missing(stop.str.inspect)}"
        when Pat then "q = @input.byteindex(#{searched(stop.re)}, p)\n#{missing(stop.source)}"
        else
          miss = compile_matcher(Not.new(stop), false)
          at_end = compile_matcher(And.new(stop), false)
          <<~RUBY
            bytes = BirmanRT.single_byte?(@input)
            q = p
            while q < @len && #{miss.name}(q) != FAIL
              q += bytes ? 1 : BirmanRT.char_width(@input.getbyte(q))
            end
            q = #{at_end.name}(q) if q == @len
            return FAIL if q == FAIL
          RUBY
        end
      end

      def missing(expected) = "return fail_at(@len, #{expected.inspect}) if q.nil?\n"

      def anchored(re)
        Regexps.anchored(re)
      rescue Error => e
        raise Error, "rule :#{@rule}: #{e.message}"
      end

      def searched(re)
        Regexps.searched(re)
      rescue Error => e
        raise Error, "rule :#{@rule}: #{e.message}"
      end

      # A literal is whatever the grammar says it stands for (keyword or
      # exact string, then the ignore rule), resolved now.
      def lit(matcher, want)
        outer = @prefix
        @prefix = "lit_#{slug(matcher.str)}"
        compile_matcher(@grammar.literal_matcher(matcher.str), want, @prefix)
      ensure
        @prefix = outer
      end

      # A case-insensitive literal, likewise (see Combinators#nocase_matcher).
      def nocase(matcher, want)
        outer = @prefix
        @prefix = "nocase_#{slug(matcher.str)}"
        compile_matcher(@grammar.nocase_matcher(matcher.str), want, @prefix)
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
          lines, locals = steps(matcher.parts, matcher.commit_at, wanted, logs?(matcher))
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
      # commit_at fails the sequence, dropping the errors recorded since
      # it began (logs); one at or after it ends the parse.
      # Returns the lines and {index => local} for the wanted values.
      def steps(parts, commit_at, wanted, logs) # rubocop:disable Metrics
        locals = {}
        failed = logs ? "rollback_to(m)" : "FAIL"
        lines = parts.each_with_index.flat_map do |part, i|
          keep = wanted.include?(i)
          locals[i] = "v#{i}" if keep
          step(compile_matcher(part, keep), part, i.zero? ? "p" : "q", commit_at && i >= commit_at, keep && "v#{i}",
               failed)
        end
        lines.unshift("q = p") if parts.empty?
        lines.unshift("m = @log_mark") if logs
        [lines, locals]
      end

      def step(call, part, at, committed, local, failed) # rubocop:disable Metrics/ParameterLists
        keep = local ? ["#{local} = #{call.value}"] : []
        return ["q = #{call.name}(#{at})", "return #{failed} if q == FAIL\n", *keep] unless committed

        ["r = #{call.name}(#{at})", "commit_failure(#{at}, #{expected(part)}) if r == FAIL", *keep, "q = r"]
      end

      def pick(matcher, want, name)
        wanted = want ? [matcher.index] : []
        define(:pick, matcher, want, name) do |v|
          lines, locals = steps(matcher.parts, nil, wanted, logs?(matcher))
          lines << "#{v} = #{locals.fetch(matcher.index)}" if v
          [*lines, "q"].join("\n")
        end
      end

      # A separator and item dropped (logs) take their errors with them.
      def sep_by(matcher, want, name)
        logs = logs?(matcher)
        define(:sep_by, matcher, want, name) do |v|
          item = compile_matcher(matcher.item, want)
          sep = compile_matcher(matcher.sep, false)
          <<~RUBY
            q = #{item.name}(p)
            #{sep_by_none(matcher, v)}
            #{"values = [#{item.value}]" if v}
            while true
              #{"k = @log_mark\n  " if logs}s = #{sep.name}(q)
              break if s == FAIL

              r = #{item.name}(s)
              #{"q = s if r == FAIL # a trailing separator\n  " if matcher.trailing}#{sep_by_stop(matcher, logs)}

              #{"values << #{item.value}" if v}
              q = r
            end
            #{"#{v} = values" if v}
            q
          RUBY
        end
      end

      def sep_by_stop(matcher, logs)
        return "break if r == FAIL || r == q" unless logs

        "#{"break if r == FAIL\n  " if matcher.trailing}if r == FAIL || r == q\n    rollback_to(k)\n    break\n  end"
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

      # Too few matches, or an empty one after real ones, drop their
      # errors (logs).
      def rep(matcher, want, name) # rubocop:disable Metrics
        logs = logs?(matcher)
        define(:rep, matcher, want, name) do |v|
          inner = compile_matcher(matcher.inner, want)
          <<~RUBY
            #{"m = @log_mark\n" if logs}n = 0
            #{"values = []" if v}
            while #{matcher.max ? "n < #{matcher.max}" : "true"}
              #{"k = @log_mark\n  " if logs}r = #{inner.name}(p)
              break if r == FAIL

              # Matching nothing ends the loop, but counts as the first match.
              if r == p
                if n.zero?
                  #{"values << #{inner.value}" if v}
                  n = 1
                #{"else\n      rollback_to(k)\n    " if logs}end
                break
              end
              #{"values << #{inner.value}" if v}
              n += 1
              p = r
            end
            #{"return #{logs ? "rollback_to(m)" : "FAIL"} if n < #{matcher.min}" if matcher.min.positive?}
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
          "#{SAVE}#{lookahead(inner, logs?(matcher))}@furthest = of\n@expected = oe\nq == FAIL ? p : FAIL"
        end
      end

      # A commit failure inside a lookahead is just a failure. The rules it
      # unwound through are left in progress, so they're abandoned. Each
      # active lookahead holds one of Spinel's 64 begin blocks, so they're
      # counted (see Compiler::LOOKAHEAD_DEPTH). Errors recovered from
      # inside it are dropped (logs).
      def lookahead(inner, logs)
        <<~RUBY
          raise TooDeep, "lookaheads nested too deeply" if @lookaheads >= LOOKAHEAD_DEPTH

          @lookaheads += 1
          depth = @in_progress_at.size
          #{"m = @log_mark\n" if logs}begin
            q = #{inner.name}(p)
          rescue Committed
            abandon(depth)
            q = FAIL
          end
          @lookaheads -= 1#{"\nrollback_to(m)" if logs}
        RUBY
      end

      def positive(matcher, want, name)
        define(:and, matcher, false, name, value: want ? "nil" : nil) do
          inner = compile_matcher(matcher.inner, false)
          "#{SAVE}#{lookahead(inner, logs?(matcher))}peek_end(p, q, of, oe, #{expected(matcher.inner)}) ? p : FAIL"
        end
      end

      def both(matcher, want, name)
        define(:both, matcher, want, name) do |v|
          left = compile_matcher(matcher.left, false)
          right = compile_matcher(matcher.right, want)
          "#{SAVE}#{lookahead(left, logs?(matcher.left))}" \
            "return FAIL unless peek_end(p, q, of, oe, #{expected(matcher.left)})\n\n" \
            "q = #{right.name}(p)\n#{"#{v} = #{right.value} if q != FAIL\n" if v}q"
        end
      end

      # --- Values ---

      def const(matcher, want)
        return recovering_const(matcher) if want && logs?(matcher.inner)

        inner = compile_matcher(matcher.inner, false)
        return inner unless want

        Call.new(inner.name, constant(matcher))
      end

      def constant(matcher)
        return matcher.constant.inspect if Literals.literal?(matcher.constant)

        raise Error, "rule :#{@rule} uses .means(#{matcher.constant.inspect}), which isn't a literal"
      end

      # .means over a match that may recover: its value is the constant,
      # or the inner value if errors were recorded in it.
      def recovering_const(matcher)
        define(:means, matcher, true) do |v|
          inner = compile_matcher(matcher.inner, true)
          "m = @log_mark\nq = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n" \
            "#{v} = @log_mark > m ? #{inner.value} : #{constant(matcher)}\nq"
        end
      end

      # Send and Action. Both run even when nothing reads their value, as
      # the interpreter's do: either may raise (an action checking its
      # value, nil.upcase). Not over errors (logs): the value is left alone.
      def transform(matcher, want, name)
        check_send(matcher) if matcher.is_a?(Send)

        kind = matcher.is_a?(Send) ? :send : :action
        define(kind, matcher, want, name) do |v|
          inner = compile_matcher(matcher.inner, true)
          call = apply(matcher, inner.value)
          next "q = #{inner.name}(p)\n#{"#{v} = " if v}#{call} if q != FAIL\nq" unless logs?(matcher.inner)
          next "m = @log_mark\nq = #{inner.name}(p)\n#{call} if q != FAIL && @log_mark == m\nq" unless v

          "m = @log_mark\nq = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n" \
            "#{v} = @log_mark > m ? #{inner.value} : #{call}\nq"
        end
      end

      def apply(matcher, value)
        name = plain_name(matcher)
        # String#to_i, Bignums included (Spinel's overflows past 63 bits).
        if name == :to_i && matcher.is_a?(Send)
          return "BirmanRT.to_i(#{value})" if @types.of(matcher.inner) == :str
          return "(#{value}.nil? ? 0 : BirmanRT.to_i(#{value}))" if @types.str_or_nil?(matcher.inner)
        end
        return "#{value}.#{name}" if matcher.is_a?(Send)

        @actions.copy(name, @rule, "action")
        "#{name}(#{value})"
      end

      # The method name of a .map, .action or .check, which the generated
      # code calls as written.
      def plain_name(matcher)
        name = matcher.method_name
        return name if name.match?(/\A[a-z_]\w*[?!]?\z/)

        form = { Send => "map", Action => "action", Check => "check" }.fetch(matcher.class)
        raise Error, "rule :#{@rule} uses .#{form}(#{name.inspect}), which isn't a plain method name"
      end

      # .map(:hex) and .map(:oct) raise past 63 bits in a Spinel binary, as
      # does .map(:to_i) unless the value is a String (BirmanRT.to_i reads
      # those, and nil, as from str.maybe, is 0) or an Integer.
      def check_send(matcher)
        name = matcher.method_name
        return unless %i[hex oct].include?(name) || (name == :to_i && !to_i_safe?(matcher.inner))

        unknown = " (its value isn't always a String or an Integer)" if name == :to_i
        raise Error, "rule :#{@rule} uses .map(:#{name})#{unknown}: #{Overflows::MESSAGES.fetch(name)}"
      end

      def to_i_safe?(inner) = %i[str int].include?(@types.of(inner)) || @types.str_or_nil?(inner)

      # --- Nodes ---

      def to(matcher, want, name) # rubocop:disable Metrics/AbcSize
        return compile_matcher(matcher.inner, false) unless want

        node = @nodes.name_for(matcher.node, @rule)
        keys = hash_keys(matcher.inner)
        return seq_node(matcher, node, name) if keys.is_a?(Array) && direct_seq?(matcher.inner)
        return recovering_to(matcher, node, keys, name) if logs?(matcher.inner)

        define(:to, matcher, true, name) do |v|
          inner = compile_matcher(matcher.inner, true)
          args = node_args(matcher.node, keys, inner.value)
          value = "x = #{inner.value}\n" if keys == :unknown && !matcher.node.members.empty?
          "q = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n#{value}#{v} = #{node_call(node, args, "span(p, q)")}\nq"
        end
      end

      # .to over a match that may recover, as To: without errors the node
      # is built as ever (keys are the Hash's then); with them, from
      # whatever the value turned out to be, if its fields fit the node,
      # else the value is passed on. (A direct seq of named parts always
      # fits: seq_node builds it either way.)
      def recovering_to(matcher, node, keys, name)
        define(:to, matcher, true, name) do |v|
          inner = compile_matcher(matcher.inner, true)
          built = node_call(node, node_args(matcher.node, keys, "x"), "span(p, q)")
          rebuilt = node_call(node, recovered_fields(matcher.node), "span(p, q)")
          "m = @log_mark\nq = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\nx = #{inner.value}\n" \
            "if @log_mark == m\n  #{v} = #{built}\nelsif #{fits(matcher.node)}\n  #{v} = #{rebuilt}\n" \
            "else\n  #{v} = x\nend\nq"
        end
      end

      # Whether node can be built from x (see To#fits?): a Hash with no
      # field node lacks and every one without a default; anything else
      # fills the first field, so the rest need defaults.
      def fits(node)
        members = node.members
        optional = @nodes.defaults(node).keys
        checks = ["known_keys?(x, #{members.inspect})", *(members - optional).map { "x.key?(#{_1.inspect})" }]
        hash = members.empty? ? "x.empty?" : checks.join(" && ")
        "(x.is_a?(Hash) ? #{hash} : #{(members.drop(1) - optional).empty?})"
      end

      # Node fields from x, a Hash or not, as Birman.build fills them;
      # fits has made sure no field without a default is left out.
      def recovered_fields(node)
        defaults = @nodes.defaults(node)
        node.members.each_with_index.map do |member, i|
          default = defaults.fetch(member, "nil")
          "x.is_a?(Hash) ? (x.key?(#{member.inspect}) ? x[#{member.inspect}] : #{default}) : #{i.zero? ? "x" : default}"
        end
      end

      # The source text from p to where a node's span would end. Unread,
      # it's just the inner match, whose actions still run.
      def text(matcher, want, name)
        return compile_matcher(matcher.inner, false, name) unless want

        define(:text, matcher, true, name) do |v|
          inner = compile_matcher(matcher.inner, false)
          "q = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n#{v} = @input.byteslice(p, span_end(p, q) - p)\nq"
        end
      end

      # The inner value with the span a node would get.
      def spanned(matcher, want, name)
        return compile_matcher(matcher.inner, false, name) unless want

        define(:spanned, matcher, true, name) do |v|
          inner = compile_matcher(matcher.inner, true)
          "q = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n#{v} = Spanned.new(#{inner.value}, span(p, q))\nq"
        end
      end

      # A seq of named parts builds the node from its locals, no Hash.
      def seq_node(matcher, node, name)
        fields = hash_keys(matcher.inner).to_h { [_1, nil] }
        node_fields(matcher.node, fields) # checked before compiling the seq
        build = ->(locals) { node_new(matcher.inner, node, matcher.node, locals) }
        seq(matcher.inner, true, name, build:).tap { @compiled[[matcher, true]] = _1 }
      end

      def node_new(seq, node, node_class, locals)
        by_key = {}
        seq.parts.each_with_index { |part, i| by_key[part.capture_key] = locals[i] if part.capture_key }
        node_call(node, node_fields(node_class, by_key), "span(p, q)")
      end

      # node.new(fields..., span), with no stray comma when there are no fields.
      def node_call(node, args, span) = "#{node}.new(#{[*args, span].join(", ")})"

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
        when Label, Check, Quiet, Named, Lexeme, Recover then hash_keys(matcher.inner, seen) # see recovering_to
        when Both then hash_keys(matcher.right, seen)
        when Captures then matcher.pat.re.names.map(&:to_sym)
        when Lit, Nocase, Str, Pat, Rep, SepBy, Not, And, To, Text, SpannedMatcher, Upto then nil
        when Operators then hash_keys(matcher.operand, seen) && :unknown # with no operator, the operand's value
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

      # Like Birman.build: a Hash value fills the fields by name, and any
      # other value is the first field. Fields left out get their defaults.
      def node_args(node, keys, value)
        return node_fields(node, keys.to_h { [_1, "#{value}[#{_1.inspect}]"] }) if keys.is_a?(Array)
        return [] if node.members.empty? # As in To#match: a node with no fields drops the value.

        first, *rest = node.members
        defaults = @nodes.defaults(node)
        unless (rest - defaults.keys).empty?
          raise Error, "rule :#{@rule} builds a node with #{node.members.size} fields from one value"
        end
        return node_fields(node, first => value) if keys.nil?

        node.members.map { unknown_field(_1, _1 == first, defaults[_1]) }
      end

      # A field from x, which may or may not be a Hash, and may be one
      # that leaves the field out.
      def unknown_field(member, first, default)
        key = member.inspect
        from_hash = default ? "(x.key?(#{key}) ? x[#{key}] : #{default})" : "x.fetch(#{key})"
        "x.is_a?(Hash) ? #{from_hash} : #{first ? "x" : default}"
      end

      # node.new's field arguments: each field from given (sources by field),
      # or its default, written out so that each node gets its own.
      def node_fields(node, given)
        defaults = @nodes.defaults(node)
        unless (given.keys - node.members).empty? && (node.members - given.keys - defaults.keys).empty?
          raise Error, "rule :#{@rule} builds a node with fields #{node.members.inspect} " \
                       "from named parts #{given.keys.inspect}"
        end

        node.members.map { |member| given.fetch(member) { defaults.fetch(member) } }
      end

      # A precedence table: name(p) climbs from the loosest rank, and
      # name_climb(p, min) is Operators#climb, recursing for prefix
      # operands and right sides. Each entry is numbered from 1 in its
      # choice, and k is the one that matched (0: none). Sub-matchers'
      # values are copied to locals before any recursion overwrites them.
      def operators(matcher, want, name)
        climb = nil
        call = define(:operators, matcher, false, name) do |_, own|
          climb = @compiled[[matcher, :climb]] ||=
            define(:climb, matcher, true, "#{own}_climb", extra: "min") { |v, me| climb_body(matcher, v, me) }
          "#{climb.name}(p, 1)"
        end
        Call.new(call.name, want ? climb.value : nil)
      end

      # An operator dropped (logs) takes the errors recorded since it
      # began with it, as Operators' operand_at, prefix_at and
      # suffix_step do: m marks where the prefix, or this trip round the
      # operator loop, began.
      def climb_body(matcher, value, climb)
        logs = logs?(matcher)
        operand = compile_matcher(matcher.operand, true)
        bare = "q = #{operand.name}(p)\nreturn FAIL if q == FAIL\n\nleft = #{operand.value}\n"
        slot = if matcher.prefixes.empty? then bare
               else "#{prefix_slot(matcher.prefixes, climb, "@v_#{climb}", logs)}if q == FAIL\n#{indent(bare)}end\n"
               end
        "#{slot}#{suffix_loop(matcher.suffixes, climb, "@v_#{climb}", logs)}#{value} = left\nq"
      end

      # break if cond, dropping the operator's errors (see climb_body).
      def drop_if(cond, logs)
        logs ? "if #{cond}\n  rollback_to(m)\n  break\nend\n" : "break if #{cond}\n"
      end

      # The first entry matching at at sets k and op, as Operators'
      # prefix_at and suffix_at do: later ones aren't tried.
      def entry_choice(entries, at)
        entries.each_with_index.map do |entry, i|
          op = compile_matcher(entry.matcher, true)
          try = "o = #{op.name}(#{at})\nif o != FAIL\n  k = #{i + 1}\n  op = #{op.value}\nend\n"
          i.zero? ? try : "if k == 0\n#{indent(try)}end\n"
        end.join
      end

      # The operand slot's prefixed form: the quiet prefix choice (one that
      # consumes nothing is no match), then the operand at its rank. q is
      # FAIL if there's none, for the bare operand to try.
      def prefix_slot(entries, climb, right, logs)
        dropped = "  else\n    rollback_to(m)\n" if logs
        branches = entries.each_with_index.map do |entry, i|
          node = @nodes.name_for(entry.node, @rule)
          args = operator_fields(entry, "op" => "op", "operand" => right)
          "#{i.zero? ? "if" : "elsif"} k == #{i + 1}\n  r = #{climb}(o, #{entry.rank})\n  " \
            "if r != FAIL\n    left = #{node}.new(#{args}, span(p, r))\n    q = r\n#{dropped}  end\n"
        end
        empty = logs ? "if k != 0 && o == p\n  k = 0\n  rollback_to(m)\nend\n" : "k = 0 if k != 0 && o == p\n"
        "#{"m = @log_mark\n" if logs}k = 0\n#{SAVE}#{entry_choice(entries, "p")}@furthest = of\n@expected = oe\n" \
          "#{empty}q = FAIL\n#{branches.join}end\n"
      end

      # The operator loop: the suffix choice under the "operator" label,
      # then the winner's rank and fixity, as Operators#suffix_step.
      def suffix_loop(entries, climb, right, logs)
        return "" if entries.empty?

        branches = entries.each_with_index.map { |entry, i| suffix_branch(entry, i, climb, right, logs) }
        save = "#{"m = @log_mark\n" if logs}of = @furthest\noe = @expected\n@furthest = q\n@expected = NONE\nk = 0\n"
        body = "#{save}#{entry_choice(entries, "q")}label_end(q, k == 0 ? FAIL : o, of, oe, \"operator\")\n" \
               "break if k == 0\n\ns = q\n#{branches.join}end\nq = s\n"
        "while true\n#{indent(body)}end\n"
      end

      def suffix_branch(entry, index, climb, right, logs)
        node = @nodes.name_for(entry.node, @rule)
        head = "#{index.zero? ? "if" : "elsif"} k == #{index + 1}\n#{indent(drop_if("min > #{entry.rank}", logs))}"
        if entry.fixity == :postfix
          args = operator_fields(entry, "op" => "op", "operand" => "left")
          return "#{head}#{indent(drop_if("o == q", logs))}\n  left = #{node}.new(#{args}, span(p, o))\n  s = o\n"
        end

        rank = entry.fixity == :left ? entry.rank + 1 : entry.rank
        head += indent(drop_if("o == p", logs)) if entry.fixity == :right
        args = operator_fields(entry, "op" => "op", "left" => "left", "right" => "right")
        "#{head}  r = #{climb}(o, #{rank})\n#{indent(drop_if("r == FAIL || r == q", logs))}\n  right = #{right}\n  " \
          "left = #{node}.new(#{args}, span(p, r))\n  s = r\n"
      end

      # The node's field arguments in its members' order.
      def operator_fields(entry, sources) = entry.node.members.map { sources.fetch(_1.to_s) }.join(", ")

      # --- Diagnostics, tokens, rules ---

      def label(matcher, want, name)
        inner = nil
        call = define(:label, matcher, false, name) do
          inner = compile_matcher(matcher.inner, want)
          "#{SAVE}q = #{inner.name}(p)\nlabel_end(p, q, of, oe, #{matcher.name.inspect})"
        end
        Call.new(call.name, inner.value) # label_end leaves values alone
      end

      # The predicate runs whether or not anything reads the value (so the
      # inner value is always kept), as an action does, but only after a
      # match: after a failure the value variable is stale. Over errors
      # (logs) it passes without running.
      # `? true : false` keeps ok a bool for Spinel.
      def check(matcher, want, name)
        inner = nil
        call = define(:check, matcher, false, name) do
          inner = compile_matcher(matcher.inner, true)
          predicate = plain_name(matcher)
          @actions.copy(predicate, @rule, "check")
          skip = "@log_mark > m || " if logs?(matcher.inner) # passes over errors
          "#{"m = @log_mark\n" if skip}#{SAVE}q = #{inner.name}(p)\n" \
            "ok = q == FAIL || #{skip}(#{predicate}(#{inner.value}) ? true : false)\n" \
            "check_end(p, q, ok, of, oe, #{matcher.name.inspect})"
        end
        Call.new(call.name, want ? inner.value : nil) # check_end leaves values alone
      end

      def quiet(matcher, want, name)
        inner = nil
        call = define(:quiet, matcher, false, name) do
          inner = compile_matcher(matcher.inner, want)
          "#{SAVE}q = #{inner.name}(p)\n@furthest = of\n@expected = oe\nq"
        end
        Call.new(call.name, inner.value)
      end

      # Matcher#recover: inner, isolated, with a commit failure in it
      # caught, as a lookahead catches one (so it holds a begin block, and
      # counts against LOOKAHEAD_DEPTH). A failure that committed or got
      # past p is recorded as an ErrorNode spanning p to where the sync
      # point is found from it (or the end), and the match ends there;
      # what inner expected isn't merged outward then. Else it's inner's.
      def recover(matcher, want, name)
        define(:recover, matcher, want, name) do |v| # rubocop:disable Metrics/BlockLength
          inner = compile_matcher(matcher.inner, want)
          search = compile_matcher(Upto.new(matcher.sync), false)
          <<~RUBY
            raise TooDeep, "lookaheads nested too deeply" if @lookaheads >= LOOKAHEAD_DEPTH

            #{SAVE.chomp}
            @lookaheads += 1
            depth = @in_progress_at.size
            committed = false
            begin
              q = #{inner.name}(p)
            rescue Committed => e
              abandon(depth)
              committed = true
              @furthest = e.pos
              @expected = e.expected
              q = FAIL
            end
            @lookaheads -= 1
            f = @furthest
            ex = @expected
            @furthest = of
            @expected = oe
            if q != FAIL || (!committed && f <= p)
              merge(f, ex)
              #{"#{v} = #{inner.value} if q != FAIL\n  " if v}return q
            end

            @furthest = f
            @expected = NONE
            s = #{search.name}(f)
            @furthest = of
            @expected = oe
            s = @len if s == FAIL
            node = ErrorNode.new(failure(f, ex, committed), span(p, s))
            record_error(node)
            #{"#{v} = node\n" if v}s
          RUBY
        end
      end

      def lexeme(matcher, want, name)
        return compile_matcher(matcher.inner, want, name) unless ignore_rule

        @ignores |= [ignore_rule]
        define(:lexeme, matcher, want, name) do |v|
          inner = compile_matcher(matcher.inner, want)
          keep = "#{v} = #{inner.value}\n" if v
          "q = #{inner.name}(p)\nreturn FAIL if q == FAIL\n\n#{keep}skip_#{ident(ignore_rule)}(q)"
        end
      end

      def ref(matcher, want)
        @pending << matcher.name
        @read_rules |= [matcher.name] if want
        Call.new("ref_#{ident(matcher.name)}", want ? "@v_ref_#{ident(matcher.name)}" : nil)
      end

      # --- The rest of the Parser ---

      def initializer
        <<~RUBY
          def initialize(input)
            super
            @sc = StringScanner.new(@input)
            init_values
          end
        RUBY
      end

      # Grammar#parse, root:, consume: and offset: included. root: is the
      # grammar's root or one of to_ruby's roots:, each a branch of its
      # own, so each Success.new sees one rule's value.
      def parse_method
        start = ignore_rule ? "start = ref_#{ident(ignore_rule)}(from)\nstart = from if start == FAIL" : "start = from"
        roots = [@grammar.class.root, *@roots].uniq
        # After recoveries, a Failure listing the errors (see parse_result).
        failed = @recovers ? ->(failure) { "parse_failure(#{failure})" } : ->(failure) { failure }
        <<~RUBY
          # Grammar#parse: Success(value) if all of the input parses (or,
          # with consume: false, a prefix of it), else Failure. root: is
          # #{roots.map(&:inspect).join(", ")} (nil: #{roots.first.inspect}).
          # offset: is the character offset to start at.
          def parse(root: nil, consume: true, offset: 0)
            entry = 0
          #{indent(entry_checks(roots))}
            bad = BirmanRT.invalid_byte(@input)
            return invalid_input(bad) if bad != FAIL

            from = BirmanRT.byte_offset(@input, offset)
            reset(from)
            init_memos
          #{indent(start)}
            q = FAIL
          #{indent(entry_matches(roots))}
            fail_at(q, "end of input") if q != FAIL
            #{failed.call("failure(@furthest, @expected, false)")}
          rescue Committed => e
            #{failed.call("failure(e.pos, e.expected, true)")}
          rescue SystemStackError, TooDeep
            #{failed.call("failure_because(@position, \"input is nested too deeply\")")}
          end
        RUBY
      end

      # Sets entry to root's index in roots, or raises.
      def entry_checks(roots)
        branches = roots.each_with_index.map do |name, i|
          test = i.zero? ? "root.nil? || root == #{name.inspect}" : "root == #{name.inspect}"
          "#{i.zero? ? "if" : "elsif"} #{test}\n  entry = #{i}\n"
        end
        message = "\#{root.inspect} isn't a root of this parser (#{roots.map(&:inspect).join(", ")}); " \
                  "Grammar.to_ruby's roots: adds others"
        "#{branches.join}else\n  raise ArgumentError, \"#{message}\"\nend\n"
      end

      # Matches the entry's rule, returning a Success where it stopped (if
      # consume: false) or at the end of input.
      def entry_matches(roots)
        branches = roots.each_with_index.map do |name, i|
          id = ident(name)
          value = "@v_ref_#{id}"
          result = @recovers ? "parse_result(#{value}, token_end(q))" : "Success.new(#{value}, @input, token_end(q))"
          "#{i.zero? ? "if" : "elsif"} entry == #{i}\n  q = ref_#{id}(start)\n  " \
            "return #{result} if q != FAIL && (q == @len || !consume)\n"
        end
        "#{branches.join}end\n"
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
          tables = @valued.include?(name) ? %w[mp mv mf me] : %w[mp mf me]
          (carries?(name) ? [*tables, "mr"] : tables).map { "@#{_1}_#{ident(name)} = {}\n" }
        end
        lines += @rules.keys.flat_map { round_memos(_1) }
        "def init_memos\n#{indent(lines.join)}end\n"
      end

      # A cycle's leader numbers its rounds in @gp_; the cycle's other
      # rules keep a memo for the round (see in_round) and their longest
      # match over the growth's rounds in @bp_, @bv_, @bf_ and @be_ (see
      # growing_ref_method).
      def round_memos(name) # rubocop:disable Metrics/PerceivedComplexity
        leader = @analysis.leader(name)
        tables = if leader.nil? then []
                 elsif leader == name then leads_others?(name) ? %w[gp] : []
                 else @valued.include?(name) ? %w[rr rp rv rf re bp bv bf be] : %w[rr rp rf re bp bf be]
                 end
        tables += %w[rx bx] if leader && leader != name && carries?(name)
        tables.map { "@#{_1}_#{ident(name)} = {}\n" }
      end

      # Ref: the rule's memo entry at p, computed the first time with
      # fresh failure tracking, which is then merged into the caller's.
      # No begin/ensure: Spinel allows only 64 of them active at once, and
      # each level of nesting in the input would use one. Instead, entries
      # being computed are kept on a stack, and a lookahead that catches a
      # commit failure marks the ones it unwound through ABSENT (never
      # deleted: Hash#delete is O(size) in Spinel), so the rule can be
      # tried again there. A rule in a cycle led by another rule is
      # matched in the leader's round while it grows at p (in_round), and
      # entered from outside, takes its longest match from the leader's
      # rounds if its own match grew the leader there (adopt).
      def ref_method(name, call) # rubocop:disable Metrics
        leader = @analysis.leader(name)
        return growing_ref_method(name, call) if leader == name

        valued = @valued.include?(name)
        id = ident(name)
        hit = leader ? "unless q.nil? || q == ABSENT || q == IN_PROGRESS" : "unless q.nil? || q == ABSENT"
        carries = carries?(name)
        <<~RUBY
          #{POSITION.chomp}
          def ref_#{id}(p)
            q = @mp_#{id}[p]
            #{hit}
              left_recursion(#{name.to_s.inspect}) if q == IN_PROGRESS
          #{"    @v_ref_#{id} = @mv_#{id}[p] if q != FAIL" if valued}
              merge(@mf_#{id}[p], @me_#{id}[p])#{replay("@mr_#{id}", 2) if carries}
              return q
            end#{"\n#{indent(in_round(name, leader, call)).chomp}" if leader}
            @mp_#{id}[p] = IN_PROGRESS
            @position = p
            of = @furthest
            oe = @expected
            @furthest = p
            @expected = NONE
            @in_progress << @mp_#{id}
            @in_progress_at << p
            #{"mark = @log_mark\n  " if carries}q = #{call.name}(p)
            @in_progress.pop
            @in_progress_at.pop#{"\n  x = @log_mark > mark ? take_errors(mark) : nil" if carries}
            f = @furthest
            ex = @expected
            @furthest = of
            @expected = oe
            @mp_#{id}[p] = q
          #{indent("if q != FAIL\n  @v_ref_#{id} = #{call.value || "nil"}\n  @mv_#{id}[p] = @v_ref_#{id}\nend").chomp if valued}
            @mf_#{id}[p] = f
            @me_#{id}[p] = ex#{"\n  @mr_#{id}[p] = x" if carries}#{"\n#{indent(adopt(name, leader)).chomp}" if leader}
            merge(f, ex)#{"\n  replay_errors(x) unless x.nil?" if carries}
            q
          end
        RUBY
      end

      # Records again the errors a memo entry in table carries (see
      # Birman::Context#replay), at depth (in twos of spaces).
      def replay(table, depth)
        pad = "  " * depth
        "\n#{pad}e = #{table}[p]\n#{pad}replay_errors(e) unless e.nil?"
      end

      # The middle of Ref for a rule in a cycle led by another rule, as
      # Birman::Context#in_round, after a final memo hit: while the leader
      # grows at p (its @gp_ entry is the round's number, above 0), the
      # rule is memoized there for the round only, in its @rr_ (the round
      # each entry is for), @rp_, @rv_, @rf_ and @re_ tables, with fresh
      # failure tracking merged into the caller's. A match that gets
      # further than the rule's longest so far in this growth (ABSENT
      # since the leader began it: even a failure beats that) replaces it.
      def in_round(name, leader, call) # rubocop:disable Metrics
        valued = @valued.include?(name)
        id = ident(name)
        carries = carries?(name)
        <<~RUBY
          g = @gp_#{ident(leader)}[p]
          unless g.nil? || g <= 0
            r = @rr_#{id}[p]
            unless r.nil? || r != g
              q = @rp_#{id}[p]
          #{"    @v_ref_#{id} = @rv_#{id}[p] if q != FAIL" if valued}
              merge(@rf_#{id}[p], @re_#{id}[p])#{replay("@rx_#{id}", 2) if carries}
              return q
            end
            @position = p
            of = @furthest
            oe = @expected
            @furthest = p
            @expected = NONE
            #{"mark = @log_mark\n  " if carries}q = #{call.name}(p)#{"\n  x = @log_mark > mark ? take_errors(mark) : nil" if carries}
          #{indent("if q != FAIL\n  @v_ref_#{id} = #{call.value || "nil"}\n  @rv_#{id}[p] = @v_ref_#{id}\nend").chomp if valued}
            f = @furthest
            ex = @expected
            @furthest = of
            @expected = oe
            @rr_#{id}[p] = g
            @rp_#{id}[p] = q
            @rf_#{id}[p] = f
            @re_#{id}[p] = ex#{"\n  @rx_#{id}[p] = x" if carries}
            b = @bp_#{id}[p]
            if b == ABSENT
              @bp_#{id}[p] = q#{"\n    @bx_#{id}[p] = x" if carries}
          #{"    @bv_#{id}[p] = @v_ref_#{id} if q != FAIL" if valued}
              @bf_#{id}[p] = f
              @be_#{id}[p] = ex
            else
              if q > b
                @bp_#{id}[p] = q#{"\n      @bx_#{id}[p] = x" if carries}
          #{"      @bv_#{id}[p] = @v_ref_#{id} if q != FAIL" if valued}
              end
              bf = @bf_#{id}[p]
              if f > bf
                @bf_#{id}[p] = f
                @be_#{id}[p] = ex
              elsif f == bf && !ex.empty?
                @be_#{id}[p] = fold_expected(@be_#{id}[p], ex)
              end
            end
            merge(f, ex)#{"\n  replay_errors(x) unless x.nil?" if carries}
            return q
          end
        RUBY
      end

      # The end of Ref for a rule in a cycle led by another rule, as
      # Birman::Context#outside: entered from outside the cycle at p (no
      # round of the leader's was on), the rule has just been matched
      # as any rule is. If that grew the leader at p (its memo entry
      # there is final now) and the leader's rounds reached the rule, the
      # rule's longest match from them, with their diagnostics, replaces
      # what it matched with the leader's final one, unless that got
      # further (ties go to the kept one).
      def adopt(name, leader)
        valued = @valued.include?(name)
        id = ident(name)
        <<~RUBY
          l = @mp_#{ident(leader)}[p]
          unless l.nil? || l == ABSENT
            b = @bp_#{id}[p]
            if b != ABSENT && b >= q
              q = b
              @mp_#{id}[p] = b
          #{indent("if b != FAIL\n  @v_ref_#{id} = @bv_#{id}[p]\n  @mv_#{id}[p] = @v_ref_#{id}\nend").chomp if valued}
              f = @bf_#{id}[p]
              ex = @be_#{id}[p]
              @mf_#{id}[p] = f
              @me_#{id}[p] = ex#{"\n    x = @bx_#{id}[p]\n    @mr_#{id}[p] = x" if carries?(name)}
            end
          end
        RUBY
      end

      # For a leader's growth at p: the lines that forget each other
      # rule's longest match (its start), and the ones that publish them
      # (its end), each starting with a newline so that a rule that
      # leads only itself gets none.
      def longest_lines(name)
        others = leads_others?(name) ? @analysis.cycle(name) - [name] : []
        [others.map { "\n  @bp_#{ident(_1)}[p] = ABSENT" }.join, others.map { "\n#{indent(publish(_1)).chomp}" }.join]
      end

      # The end of a leader's growth at p, with the growth's diagnostics
      # in f and ex, for each other rule of its cycle its rounds reached:
      # the growth's diagnostics are folded into the rule's longest
      # match's (as Birman::Context#further does, the leader's first),
      # and it becomes the rule's memo entry at p, unless it has one.
      def publish(name)
        valued = @valued.include?(name)
        id = ident(name)
        <<~RUBY
          b = @bp_#{id}[p]
          if b != ABSENT
            bf = @bf_#{id}[p]
            if bf < f || (bf == f && @be_#{id}[p].empty?)
              @bf_#{id}[p] = f
              @be_#{id}[p] = ex
            elsif bf == f
              @be_#{id}[p] = fold_expected(ex, @be_#{id}[p])
            end
            m = @mp_#{id}[p]
            if m.nil? || m == ABSENT
              @mp_#{id}[p] = b
          #{"    @mv_#{id}[p] = @bv_#{id}[p] if b != FAIL" if valued}
              @mf_#{id}[p] = @bf_#{id}[p]
              @me_#{id}[p] = @be_#{id}[p]#{"\n    @mr_#{id}[p] = @bx_#{id}[p]" if carries?(name)}
            end
          end
        RUBY
      end

      # Does name lead a cycle through other rules too?
      def leads_others?(name)
        @analysis.leader(name) == name && !@analysis.cycle(name).one?
      end

      # Ref for a cycle's leader: seed-growing, as Birman::Context#grow.
      # The memo entry starts as a failing seed, so the rule's own call is
      # an ordinary memo hit, and each match that gets further replaces
      # it. Each attempt starts with fresh failure tracking, so a commit
      # failure reports only its own attempt's, and is then merged into
      # the rule's, so every attempt's expectations are kept. A leader of
      # other rules numbers each round (@round counts them across the
      # parse) in its @gp_ table at p, and sets it to 0 when done; it
      # starts the growth with each other rule's longest match at p
      # ABSENT, and ends it by folding the growth's diagnostics into each
      # one its rounds reached and publishing it as that rule's memo
      # entry at p (see Birman::Context#publish). A lookahead that
      # catches a commit failure mid-growth abandons the entry (ABSENT),
      # seed, round number and all.
      def growing_ref_method(name, call) # rubocop:disable Metrics
        valued = @valued.include?(name)
        id = ident(name)
        marks = leads_others?(name)
        forget, publish = longest_lines(name)
        carries = carries?(name)
        <<~RUBY
          #{POSITION.chomp}
          def ref_#{id}(p)
            q = @mp_#{id}[p]
            unless q.nil? || q == ABSENT
          #{"    @v_ref_#{id} = @mv_#{id}[p] if q != FAIL" if valued}
              merge(@mf_#{id}[p], @me_#{id}[p])#{replay("@mr_#{id}", 2) if carries}
              return q
            end
            @mp_#{id}[p] = FAIL
            @mf_#{id}[p] = p
            @me_#{id}[p] = NONE#{"\n  @mr_#{id}[p] = nil" if carries}
            @position = p
            of = @furthest
            oe = @expected
            @furthest = p
            @expected = NONE
            @in_progress << @mp_#{id}
            @in_progress_at << p#{"\n  @in_progress << @gp_#{id}\n  @in_progress_at << p" if marks}#{forget}
            #{"mark = @log_mark\n  " if carries}while true#{"\n    @round += 1\n    @gp_#{id}[p] = @round" if marks}
              af = @furthest
              ae = @expected
              @furthest = p
              @expected = NONE
              q = #{call.name}(p)
              f = @furthest
              ex = @expected
              @furthest = af
              @expected = ae
              merge(f, ex)
              #{grown(id, carries)}
              @mp_#{id}[p] = q#{"\n    @mr_#{id}[p] = @log_mark > mark ? take_errors(mark) : nil" if carries}
          #{"    @mv_#{id}[p] = #{call.value || "nil"}" if valued}
            end
            @in_progress.pop
            @in_progress_at.pop#{"\n  @gp_#{id}[p] = 0\n  @in_progress.pop\n  @in_progress_at.pop" if marks}
            q = @mp_#{id}[p]
          #{"  @v_ref_#{id} = @mv_#{id}[p] if q != FAIL" if valued}
            f = @furthest
            ex = @expected#{publish}
            @furthest = of
            @expected = oe
            @mf_#{id}[p] = f
            @me_#{id}[p] = ex
            merge(f, ex)#{replay("@mr_#{id}", 1) if carries}
            q
          end
        RUBY
      end

      # The end of a growth round that got no further, dropping its
      # errors if the leader carries some (see Birman::Context#grow); a
      # round that did get further takes its errors out of the log, for
      # the next round's call to itself to replay as the seed's.
      def grown(id, carries)
        return "break if q <= @mp_#{id}[p]\n" unless carries

        "if q <= @mp_#{id}[p]\n      rollback_to(mark)\n      break\n    end\n"
      end
    end
  end
end
