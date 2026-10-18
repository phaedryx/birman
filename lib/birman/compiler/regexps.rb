# frozen_string_literal: true

module Birman
  class Compiler
    # Regexps for StringScanner#skip at the scan position. The interpreter
    # matches with fixed_anchor: true, so \A, ^, lookbehind, and a \b or
    # \B before anything is matched see the input before the position;
    # the generated parser's scanner starts its subject at the position,
    # where they would silently mean something else. Those are refused.
    # Everything else gets a leading \A: in Spinel an unanchored miss
    # searches the rest of the input.
    # [module.Compiler.Regexps]
    # purpose = "Checking and anchoring the grammar's regexps"
    module Regexps
      module_function

      # The regexp literal to emit for re.
      def anchored(re)
        extended = re.options.anybits?(Regexp::EXTENDED)
        problem = Check.new(re.source, extended).problem
        raise Error, "#{re.inspect} can't be compiled: it uses #{problem}" if problem

        # With /x, a trailing comment would swallow the closing paren.
        Regexp.new("\\A(?:#{re.source}#{"\n" if extended})", re.options).inspect
      end

      # Walks a regexp's source, tracking whether something is certain to
      # have been matched (consumed) at each point. A \b or \B is allowed
      # only where it is. Conservative: what it can't follow, it refuses.
      class Check
        # One open group: whether input was consumed when it opened, in
        # every alternative finished so far, and in the current one; and,
        # for spotting (?>x{m,n}), how many atoms it holds and the wide
        # interval among them.
        Frame = Struct.new(:start, :all, :now, :lookaround, :atomic, :atoms, :wide, :alternated)

        # A {m,n} that lets more than WIDE lengths be tried.
        Wide = Struct.new(:text, :safe)
        WIDE = 16

        SPINEL_BACKTRACKING = "%s with a lookaround, atomic group, backreference or lazy interval: Spinel's " \
                              "regexp engine tries every length it allows (exponential; it raises past about 18). " \
                              "Make the repeat atomic on its own, (?>x%s), if nothing after it needs a shorter " \
                              "match, or use + with a separate length check"

        OPTIONAL = /[?*]|\{,|\{0+[,}]/
        QUANTIFIER = /(?:[?*+]|\{\d*,?\d*\})[?+]?/

        def initialize(source, extended)
          @scanner = StringScanner.new(source)
          @extended = extended
          @frames = [Frame.new(false, true, false, false, false, 0)]
          @backtracks = false
          @wide = []
        end

        def problem
          until @scanner.eos?
            problem = step
            return problem if problem
          end
          spinel_problem
        end

        private

        def frame = @frames.last

        # Spinel runs a regexp on its backtracking engine if it has any of
        # these, and there a wide {m,n} goes exponential when every length
        # fails. Only a group that is (?>x{m,n}) and nothing else is safe.
        def spinel_problem
          wide = @wide.find { !_1.safe }
          format(SPINEL_BACKTRACKING, wide.text, wide.text) if @backtracks && wide
        end

        def step # rubocop:disable Metrics
          s = @scanner
          if s.skip(/\\A/) then "\\A"
          elsif s.skip(/\\[bB]/) then frame.now ? nil : "\\b or \\B before anything is matched"
          elsif s.skip(/\\[zZG]/) then nil
          elsif s.skip(/\\(?:\d|k<\w+>|k'\w+')/) then backreference
          elsif s.skip(/\\[pPu]\{[^}]*\}|\\./m) then atom
          elsif s.skip(/\(\?<[=!]/) then "lookbehind"
          elsif s.skip(/\(\?#[^)]*\)/) then nil
          elsif s.skip(/\(\?[=!]/) then open_group(lookaround: true)
          elsif s.skip(/\(\?>/) then open_group(lookaround: false, atomic: true)
          elsif s.skip(/\(\?[imx]*(?:-[imx]*)?\)/) then inline_options(s.matched)
          elsif s.skip(/\((?:\?(?:[imx]*(?:-[imx]*)?:|>|<\w+>|'\w+'))?/) then open_group(lookaround: false)
          elsif s.skip(/\|/) then alternative
          elsif s.skip(/\)/) then close
          elsif s.skip(/\^/) then "^"
          elsif s.skip(/\[/) then character_class
          elsif @extended && s.skip(/\s+|#[^\n]*/) then nil
          else
            s.getch
            atom
          end
        end

        # Something that matches at least one character, unless a
        # quantifier after it makes it optional.
        def atom = quantified(true)

        def quantified(consumes)
          optional = @scanner.match?(OPTIONAL)
          quantifier(@scanner.scan(QUANTIFIER))
          frame.now ||= consumes && !optional
          nil
        end

        def backreference
          @backtracks = true
          quantified(false)
        end

        # Counts the atom just read, and notes its quantifier if it's a
        # wide or lazy interval.
        def quantifier(text)
          frame.atoms += 1
          frame.wide = nil
          bounds = text&.match(/\A\{(\d*),(\d+)\}(\?)?/) or return
          @backtracks ||= !bounds[3].nil?
          return unless bounds[2].to_i - bounds[1].to_i > WIDE

          @wide << (frame.wide = Wide.new(text, false))
        end

        def open_group(lookaround:, atomic: false)
          @backtracks ||= lookaround || atomic
          @frames << Frame.new(frame.now, true, frame.now, lookaround, atomic, 0)
          nil
        end

        def alternative
          frame.all &&= frame.now
          frame.now = frame.start
          frame.alternated = true
          nil
        end

        def close
          return "an unmatched )" if @frames.size == 1

          group = @frames.pop
          group.wide.safe = true if atomic_interval?(group)
          consumed = !group.lookaround && group.all && group.now
          optional = @scanner.match?(OPTIONAL)
          quantifier(@scanner.scan(QUANTIFIER))
          frame.now ||= consumed && !optional
          nil
        end

        # (?>x{m,n}) and nothing else in the group.
        def atomic_interval?(group)
          group.atomic && group.wide && group.atoms == 1 && !group.alternated
        end

        # (?x) turns on extended mode for the rest (conservatively, even
        # past the end of its group).
        def inline_options(text)
          @extended ||= text[/\A\(\?([imx]*)/, 1].include?("x")
          nil
        end

        # A character class (nested ones included), after its "[".
        def character_class
          depth = 1
          @scanner.skip(/\^?\]?/)
          while depth.positive? && !@scanner.eos?
            if @scanner.skip(/\\./m) then next
            elsif @scanner.skip(/\[/) then depth += 1
            elsif @scanner.skip(/\]/) then depth -= 1
            else @scanner.getch
            end
          end
          atom
        end
      end
    end
  end
end
