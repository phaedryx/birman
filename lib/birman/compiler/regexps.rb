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
        raise Error, "#{re.inspect} uses #{problem}, which can't be compiled" if problem

        # With /x, a trailing comment would swallow the closing paren.
        Regexp.new("\\A(?:#{re.source}#{"\n" if extended})", re.options).inspect
      end

      # Walks a regexp's source, tracking whether something is certain to
      # have been matched (consumed) at each point. A \b or \B is allowed
      # only where it is. Conservative: what it can't follow, it refuses.
      class Check
        # One open group: whether input was consumed when it opened, in
        # every alternative finished so far, and in the current one.
        Frame = Struct.new(:start, :all, :now, :lookaround)

        OPTIONAL = /[?*]|\{,|\{0+[,}]/
        QUANTIFIER = /(?:[?*+]|\{\d*,?\d*\})[?+]?/

        def initialize(source, extended)
          @scanner = StringScanner.new(source)
          @extended = extended
          @frames = [Frame.new(false, true, false, false)]
        end

        def problem
          until @scanner.eos?
            problem = step
            return problem if problem
          end
          nil
        end

        private

        def frame = @frames.last

        def step # rubocop:disable Metrics
          s = @scanner
          if s.skip(/\\A/) then "\\A"
          elsif s.skip(/\\[bB]/) then frame.now ? nil : "\\b or \\B before anything is matched"
          elsif s.skip(/\\[zZG]/) then nil
          elsif s.skip(/\\(?:\d|k<\w+>|k'\w+')/) then quantified(false)
          elsif s.skip(/\\[pPu]\{[^}]*\}|\\./m) then atom
          elsif s.skip(/\(\?<[=!]/) then "lookbehind"
          elsif s.skip(/\(\?#[^)]*\)/) then nil
          elsif s.skip(/\(\?[=!]/) then open_group(lookaround: true)
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
          @scanner.skip(QUANTIFIER)
          frame.now ||= consumes && !optional
          nil
        end

        def open_group(lookaround:)
          @frames << Frame.new(frame.now, true, frame.now, lookaround)
          nil
        end

        def alternative
          frame.all &&= frame.now
          frame.now = frame.start
          nil
        end

        def close
          return "an unmatched )" if @frames.size == 1

          group = @frames.pop
          consumed = !group.lookaround && group.all && group.now
          optional = @scanner.match?(OPTIONAL)
          @scanner.skip(QUANTIFIER)
          frame.now ||= consumed && !optional
          nil
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
