# frozen_string_literal: true

module Birman
  # Draws a grammar AST as railroad (syntax) diagrams, in SVG:
  #
  #   ("let")  rounded box   a literal ("select"i in any case)
  #   (/\d+/)  rounded box   a regexp, colored apart from literals
  #   [expr]   square box    a rule, linking to its diagram (#rule-expr)
  #   ~        orange bar    commit: a failure past here is reported
  #
  # A choice stacks its alternatives in order, the first on the main
  # line. A repeat loops back under its item, an optional one has a way
  # over it, and a bounded one notes its count ("2 to 3 times").
  # Lookaheads, upto, checks and labels inside a rule are dashed boxes
  # captioned with what they are ("not followed by", "text up to",
  # "check :name", "operator"); upto's box holds its terminator, which
  # it looks for but doesn't take. A rule's own label is its name for
  # errors, so it isn't drawn (to_html shows it beside the rule's
  # name). Actions, text,
  # spanned, lexeme and quiet don't change what's accepted, so only what
  # they wrap is drawn, as in EBNF. A node type this doesn't know is a
  # box naming it, rather than an error.
  #
  # Widths come from character counts in a monospace font, not font
  # metrics, so the output is the same on every machine, in whole
  # pixels. A wide character still counts as one.
  module Railroad
    ARC  = 10 # radius of every curve
    GAP  = 10 # track between the items of a sequence
    VGAP = 8  # space between stacked tracks
    HALF = 11 # half a box's height
    CHAR = 8  # width of a character at 13px
    SMALL_CHAR = 7 # at 11px, for captions and notes
    PAD = 20
    TURN = 2 * ARC # room for two curves, into and out of a branch

    WRAPPERS = %i[action quiet lexeme text spanned].freeze
    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;" }.freeze

    # Drawing helpers for the shapes below. Every shape knows its width,
    # how far it reaches above (up) and below (down) the track it's on,
    # and draws itself with its entry at x, y.
    module Shape
      def line(from, to, y) = from == to ? "" : path("M#{from} #{y}H#{to}")
      def path(d, css = nil) = %(<path#{%( class="#{css}") if css} d="#{d}"/>)
      def arc(sweep, dx, dy) = "a#{ARC} #{ARC} 0 0 #{sweep} #{dx} #{dy}"
      def esc(s) = Railroad.esc(s)

      # item drawn from left on the track at y, joined to it from and to.
      def on_track(item, left, y, from, to) = line(from, left, y) + item.draw(left, y) + line(left + item.width, to, y)
    end

    Skip = Data.define do
      def width = 0
      def up = 0
      def down = 0
      def draw(*) = ""
    end

    # A literal, regexp or rule; css is its class: lit, pat, ref or
    # unknown.
    Box = Data.define(:text, :css, :href) do
      include Shape

      def width = (text.size * CHAR) + 20
      def up = HALF
      def down = HALF

      def draw(x, y)
        shape = %(<rect class="#{css}" x="#{x}" y="#{y - HALF}" width="#{width}" height="#{2 * HALF}" ) +
                %(rx="#{css == "ref" ? 0 : HALF}"/><text x="#{x + (width / 2)}" y="#{y + 4}">#{esc(text)}</text>)
        href ? %(<a href="#{esc(href)}">#{shape}</a>) : shape
      end
    end

    COMMIT_TITLE = "<title>commit: a failure past here is reported, not backtracked</title>"

    Commit = Data.define do
      def width = 14
      def up = 22
      def down = 9

      def draw(x, y)
        mid = x + 7
        %(<g class="commit">#{COMMIT_TITLE}<path d="M#{mid} #{y - 9}v18"/><text x="#{mid}" y="#{y - 12}">~</text></g>)
      end
    end

    Seq = Data.define(:items) do
      include Shape

      def width = items.sum(&:width) + (GAP * (items.size - 1))
      def up = items.map(&:up).max
      def down = items.map(&:down).max

      def draw(x, y)
        items.each_with_index.map do |item, i|
          at = x
          x += item.width + GAP
          item.draw(at, y) + (i < items.size - 1 ? line(at + item.width, x, y) : "")
        end.join
      end
    end

    # The first alternative on the track, the rest below it, in order.
    Choice = Data.define(:alts) do
      include Shape

      def width = alts.map(&:width).max + (4 * ARC)
      def up = alts[0].up
      def down = tracks.last + alts.last.down

      def draw(x, y)
        first, *rest = alts
        rest.zip(tracks.drop(1)).reduce(on_track(first, x + TURN, y, x, x + width)) do |drawn, (alt, track)|
          drawn << branch(x, y, track, alt)
        end
      end

      private

      # Each alternative's track, as an offset below the first's: clear
      # of the one above it, and far enough down for two curves.
      def tracks
        alts.each_cons(2).reduce([0]) do |offsets, (above, alt)|
          offsets << [offsets.last + above.down + VGAP + alt.up, TURN].max
        end
      end

      def branch(x, y, track, alt)
        drop = track - TURN
        left = x + TURN
        path("M#{x} #{y}#{arc(1, ARC, ARC)}v#{drop}#{arc(0, ARC, ARC)}") +
          on_track(alt, left, y + track, left, x + width - TURN) +
          path("M#{x + width - TURN} #{y + track}#{arc(0, ARC, -ARC)}v#{-drop}#{arc(1, ARC, -ARC)}")
      end
    end

    # The item on the track, with a way over it.
    Optional = Data.define(:item) do
      include Shape

      def width = item.width + (4 * ARC)
      def up = [item.up + VGAP + ARC, TURN].max
      def down = item.down

      def draw(x, y) = on_track(item, x + TURN, y, x, x + width) + path("M#{x} #{y}#{over}")

      private

      # Up, across over the item, and down to the track again.
      def over
        rise = up - TURN
        "#{arc(0, ARC, -ARC)}v#{-rise}#{arc(1, ARC, -ARC)}h#{width - (2 * TURN)}" \
          "#{arc(1, ARC, ARC)}v#{rise}#{arc(0, ARC, ARC)}"
      end
    end

    # The item on the track, with a way back under it to its start; note
    # says how many times, under the loop, for a bounded repeat.
    Loop = Data.define(:item, :note) do
      include Shape

      def width = [item.width + TURN, note ? (note.size * SMALL_CHAR) + TURN : 0].max
      def up = item.up
      def down = depth + (note ? 14 : 0)

      def draw(x, y)
        left = x + ((width - item.width) / 2)
        on_track(item, left, y, x, x + width) + path("M#{left + item.width} #{y}#{back}", "loop") +
          noted(x + (width / 2), y + depth + 13)
      end

      private

      def noted(x, y) = note ? %(<text class="note" x="#{x}" y="#{y}">#{esc(note)}</text>) : ""

      def depth = [item.down + VGAP + ARC, TURN].max

      # Down, back under the item, and up to the track again.
      def back
        drop = depth - TURN
        "#{arc(1, ARC, ARC)}v#{drop}#{arc(1, -ARC, ARC)}h#{-item.width}" \
          "#{arc(1, -ARC, -ARC)}v#{-drop}#{arc(1, ARC, -ARC)}"
      end
    end

    # A dashed box around the item, captioned; css is its class: look,
    # check or label.
    Group = Data.define(:item, :caption, :css) do
      include Shape

      def width = [item.width, caption.size * SMALL_CHAR].max + 20
      def up = item.up + 26
      def down = item.down + 8

      def draw(x, y) = frame(x, y - up + 2) + on_track(item, x + ((width - item.width) / 2), y, x, x + width)

      private

      def frame(x, top)
        %(<rect class="group #{css}" x="#{x + 2}" y="#{top}" width="#{width - 4}" height="#{up + down - 4}" rx="6"/>) +
          %(<text class="caption" x="#{x + 8}" y="#{top + 13}">#{esc(caption)}</text>)
      end
    end

    module_function

    # One rule's diagram as an SVG document; with style: false, without
    # the stylesheet (STYLE), for a page that has it once (html).
    # [method."Railroad.svg"]
    # params = ["name: Symbol, the rule", "ast: as Grammar.to_ast gives it", "style: Boolean = true"]
    # returns = "String: an <svg> element, ending in a newline"
    def svg(name, ast, style: true)
      item = diagram(own(ast))
      width = item.width + (2 * PAD) + (2 * GAP)
      height = item.up + item.down + (2 * PAD)
      out = %(<svg xmlns="http://www.w3.org/2000/svg" class="railroad" width="#{width}" height="#{height}" )
      out << %(viewBox="0 0 #{width} #{height}" role="img"><title>#{esc(name)}</title>)
      out << "<style>#{STYLE}</style>" if style
      out << track(item, PAD + item.up) << "</svg>\n"
    end

    # A page of diagrams: reachable's rules, then, under a heading, the
    # rest (as Grammar's __asts splits them); without reachable rules,
    # the rest with no heading.
    # [method."Railroad.html"]
    # params = ["reachable: Hash of name => AST", "rest: Hash of name => AST", "title: String"]
    # returns = "String: an HTML document"
    def html(reachable, rest, title:)
      unreached = %(<h2 class="unreachable">Not reachable from the root</h2>\n) unless reachable.empty? || rest.empty?
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{esc(title)}</title>
        <style>#{STYLE}#{PAGE_STYLE}</style>
        </head>
        <body>
        <h1>#{esc(title)}</h1>
        #{sections(reachable)}#{unreached}#{sections(rest)}</body>
        </html>
      HTML
    end

    # A rule's own label, under any wrappers, or nil: its name in errors.
    def rule_label(ast)
      case ast
      in [:label, name, _] then name
      in [Symbol => type, inner] if WRAPPERS.include?(type) then rule_label(inner)
      else nil
      end
    end

    # One branch per AST node type, so its size grows with the matcher set.
    def diagram(node) # rubocop:disable Metrics
      case node
      in [:str, s]           then Box.new(quote(s), "lit", nil)
      in [:istr, s]          then Box.new("#{quote(s)}i", "lit", nil)
      in [:pat, source]      then Box.new(source, "pat", nil)
      in [:ref, name]        then Box.new(name.to_s, "ref", "#rule-#{name}")
      in [:label, name, inner] then Group.new(diagram(inner), quote(name), "label")
      in [:check, name, inner] then Group.new(diagram(inner), "check :#{name}", "check")
      in [:seq, commit_at, parts]
        items = parts.map { diagram(_1) }
        items.insert(commit_at, Commit.new) if commit_at
        seq(items)
      in [:choice, alts] then Choice.new(alts.map { diagram(_1) })
      in [:both, [:not, guard], right] then seq([Group.new(diagram(guard), "not followed by", "look"), diagram(right)])
      in [:both, left, right] then seq([Group.new(diagram(left), "followed by", "look"), diagram(right)])
      in [:not, inner]       then Group.new(diagram(inner), "not followed by", "look")
      in [:and, inner]       then Group.new(diagram(inner), "followed by", "look")
      in [:upto, stop]       then Group.new(diagram(stop), "text up to", "look")
      in [:rep, min, max, inner] then repeat(min, max, diagram(inner))
      in [Symbol => type, inner] if WRAPPERS.include?(type) then diagram(inner)
      in [Symbol => type, *] then Box.new(type.to_s, "unknown", nil)
      end
    end

    # What a rule's diagram draws: its AST without its own label.
    def own(ast)
      case ast
      in [:label, _, inner] then inner
      in [Symbol => type, inner] if WRAPPERS.include?(type) then own(inner)
      else ast
      end
    end

    def seq(items)
      items = items.grep_v(Skip)
      items.size > 1 ? Seq.new(items) : items.fetch(0, Skip.new)
    end

    def repeat(min, max, item)
      case [min, max]
      in [0, 1]   then Optional.new(item)
      in [0, nil] then Optional.new(Loop.new(item, nil))
      in [1, nil] then Loop.new(item, nil)
      in [n, nil] then Loop.new(item, "at least #{times(n)}")
      in [0, n]   then Optional.new(Loop.new(item, "up to #{times(n)}"))
      in [n, ^n]  then Loop.new(item, "exactly #{times(n)}")
      in [m, n]   then Loop.new(item, "#{m} to #{times(n)}")
      end
    end

    def times(n) = n == 1 ? "1 time" : "#{n} times"

    # The diagram on its track at y, between the start and end marks.
    def track(item, y)
      start = PAD + GAP
      finish = start + item.width
      %(<path class="end" d="M#{PAD - 6} #{y - 8}v16M#{PAD} #{y - 8}v16"/>) +
        %(<path d="M#{PAD} #{y}H#{start}"/>) + item.draw(start, y) + %(<path d="M#{finish} #{y}H#{finish + GAP}"/>) +
        %(<path class="end" d="M#{finish + GAP} #{y - 8}v16M#{finish + GAP + 6} #{y - 8}v16"/>)
    end

    def sections(asts)
      asts.map do |name, ast|
        label = rule_label(ast)
        id = esc("rule-#{name}")
        heading = %(<a href="##{id}">#{esc(name)}</a>#{%( <small>#{esc(quote(label))}</small>) if label})
        %(<section id="#{id}">\n<h2>#{heading}</h2>\n#{svg(name, ast, style: false)}</section>\n)
      end.join
    end

    def esc(s) = s.to_s.gsub(/[&<>"]/, ESCAPES)

    # Quoted as to_ebnf does, so the width doesn't depend on the locale.
    def quote(s) = AST.quote(s)

    # css with each var(--rr-name) given the value css first sets it to.
    def fallbacks(css)
      css.gsub(/var\(--rr-([\w-]+)\)/) do
        name = Regexp.last_match(1)
        "var(--rr-#{name}, #{css[/--rr-#{name}: (#\h+)/, 1]})"
      end
    end

    # Colors are custom properties, set with no specificity (:where), so
    # a page's own :root { --rr-lit: ... } wins wherever it comes. Each
    # use names its light value too, for renderers that skip :where
    # (librsvg).
    STYLE = <<~CSS.gsub(/\n\s*/, " ").strip.then { |css| Railroad.fallbacks(css) }
      :where(:root) { --rr-bg: #fbfaf7; --rr-text: #1d1d1f; --rr-muted: #6b7280; --rr-line: #55606e;
        --rr-lit: #fff6d8; --rr-lit-stroke: #a67c00; --rr-pat: #eaf7ee; --rr-pat-stroke: #2f7a4a;
        --rr-ref: #e6f0ff; --rr-ref-stroke: #2c5fb3; --rr-group: #8a8f98; --rr-commit: #c2410c; }
      @media (prefers-color-scheme: dark) {
        :where(:root) { --rr-bg: #16181c; --rr-text: #e6e6e6; --rr-muted: #9ca3af; --rr-line: #9aa4b2;
          --rr-lit: #3a3016; --rr-lit-stroke: #e0b84a; --rr-pat: #16301f; --rr-pat-stroke: #6cc68d;
          --rr-ref: #1b2a44; --rr-ref-stroke: #7aa7ff; --rr-group: #6b7280; --rr-commit: #fb923c; } }
      .railroad path { fill: none; stroke: var(--rr-line); stroke-width: 1.5; }
      .railroad text { font: 13px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        fill: var(--rr-text); text-anchor: middle; }
      .railroad rect { stroke-width: 1.5; }
      .railroad rect.lit { fill: var(--rr-lit); stroke: var(--rr-lit-stroke); }
      .railroad rect.pat { fill: var(--rr-pat); stroke: var(--rr-pat-stroke); }
      .railroad rect.ref { fill: var(--rr-ref); stroke: var(--rr-ref-stroke); }
      .railroad rect.unknown { fill: none; stroke: var(--rr-muted); stroke-dasharray: 2 2; }
      .railroad rect.group { fill: none; stroke: var(--rr-group); stroke-dasharray: 4 3; }
      .railroad rect.group.look { stroke-dasharray: 1 3; }
      .railroad rect.group.check { stroke: var(--rr-commit); }
      .railroad text.caption { font-size: 11px; text-anchor: start; fill: var(--rr-muted); }
      .railroad text.note { font-size: 11px; fill: var(--rr-muted); }
      .railroad .commit path { stroke: var(--rr-commit); stroke-width: 3; }
      .railroad .commit text { fill: var(--rr-commit); font-weight: 700; }
      .railroad a:hover rect { stroke-width: 2.5; }
    CSS

    PAGE_STYLE = <<~CSS.gsub(/\n\s*/, " ").strip
      body { background: var(--rr-bg); color: var(--rr-text); font: 15px/1.5 system-ui, sans-serif;
        margin: 0 auto; padding: 1rem 16px; max-width: 72rem; }
      h2 { font: 600 15px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; margin: 1.5rem 0 0; }
      h2 a { color: inherit; text-decoration: none; }
      h2 small { font-weight: 400; color: var(--rr-muted); }
      h2.unreachable { font-family: inherit; color: var(--rr-muted); margin-top: 3rem; }
      section { overflow-x: auto; }
      .railroad { display: block; }
    CSS
  end
end
