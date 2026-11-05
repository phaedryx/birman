# frozen_string_literal: true

module Birman
  class Trace
    # Draws a Trace as a tree, one node per line (see Trace#to_s). It
    # works out what to show first, then draws it, with explicit stacks
    # throughout: a trace of deeply nested input is as deep as the input.
    class Renderer # rubocop:disable Metrics/ClassLength
      # A line to draw: a node (mode :auto follows the filters, :all
      # expands it whatever they say, down to limit), or a line of text
      # with lines under it.
      Item = Data.define(:node, :text, :mode, :limit, :under)

      # Kinds whose children only look ahead; a memo hit whose first call
      # is under one is explained as being there.
      LOOKING = %i[not and both quiet].freeze

      # A failure nested this deep shows its outermost and innermost
      # levels, with the ones between counted.
      OUTER = 5
      INNER = 20

      def initialize(trace, at:, all:, depth:, hide:) # rubocop:disable Metrics
        @trace = trace
        @input = trace.input
        result = trace.result
        succeeded = result.nil? || result.success?
        @hide = hide == :default ? [trace.ignore, Standalone::IGNORE].compact : Array(hide)
        @all = all || (succeeded && at == :default)
        @at = at == :default ? (result.pos unless succeeded) : at
        @depth = depth || (4 if succeeded && at == :default && !all)
        @cut = !all && depth.nil? && result&.failure? && result.reason
      end

      def call
        root = @trace.root
        return "#{input_line(root)}\n" if root.kind == :input

        entries = lines(root.children.reject { hidden?(_1) }.map { Item.new(_1, nil, :auto, nil, nil) })
        entries = cut(entries) if @cut
        entries.map { |flags, text| "#{prefix(flags)}#{text}\n" }.join
      end

      # "L:C" for a character offset.
      def position(pos)
        @starts ||= [0] + @input.each_char.with_index.filter_map { |c, i| i + 1 if c == "\n" }
        line = (@starts.bsearch_index { _1 > pos } || @starts.size) - 1
        "#{line + 1}:#{pos - @starts[line] + 1}"
      end

      private

      # [flags, text] per line, in drawing order; flags says, for the
      # line and each of its ancestors, whether it was the last child.
      def lines(top)
        out = []
        # The result goes on the root rule's line: the last top-level
        # node but for an end of input after it.
        result_top = top.reject { _1.node.kind == :end_of_input }.last || top.last
        stack = top.reverse.map { [_1, []] }
        while (item, flags = stack.pop)
          out << [flags, text(item, top: item.equal?(result_top))]
          kids = children(item, flags.size)
          kids.each_with_index.reverse_each { |kid, i| stack << [kid, flags + [i == kids.size - 1]] }
        end
        out
      end

      def children(item, level) # rubocop:disable Metrics
        return item.under || [] unless item.node

        node = item.node
        return [] unless item.mode == :all || expanded?(node)

        shown = node.children.reject { hidden?(_1) }
        kids = shown.map { Item.new(_1, nil, item.mode, item.limit, nil) }
        kids << origin_item(node, level) if item.mode == :auto && node.origin && !shown?(node.origin)
        cap = item.limit || @depth
        return kids unless cap && level >= cap && !kids.empty?

        [Item.new(nil, "… (#{shown.sum { Trace.count(_1) }} nodes)", nil, nil, nil)]
      end

      # A memo hit whose first call isn't drawn gets that call under it.
      def origin_item(node, level)
        first = Item.new(node.origin, nil, :all, level + 5, nil)
        Item.new(nil, "first tried here, #{whereabouts(node.origin)}", nil, nil, [first])
      end

      def whereabouts(node)
        ancestors = ancestors(node)
        looking = ancestors.find { LOOKING.include?(_1.kind) }
        return "under #{looking.description}" if looking

        hidden = ancestors.find { hidden?(_1) }
        hidden ? "under hidden :#{hidden.rule}" : "in a collapsed node"
      end

      def expanded?(node)
        return @all if @at.nil?
        return true if @all
        return false if node.notes[:in_lookahead]
        return node.from <= @at if node.notes[:stack_ran_out] # it ran out where the deepest rule began

        reach = [node.to || node.from, node.furthest || node.from].max
        @at.between?(node.from, reach)
      end

      def hidden?(node) = node.kind == :rule && @hide.include?(node.rule)

      # Is node drawn with the filters as they are?
      def shown?(node)
        chain = ancestors(node)
        return false if hidden?(node) || chain.any? { hidden?(_1) } || (@depth && chain.size > @depth)

        chain.all? { expanded?(_1) }
      end

      # node's ancestors, nearest first, leaving out the top node.
      def ancestors(node)
        @parents ||= parents
        chain = []
        chain << node while (node = @parents[node]) && !node.equal?(@trace.root)
        chain
      end

      def parents
        map = {}.compare_by_identity
        stack = [@trace.root]
        while (node = stack.pop)
          node.children.each { map[_1] = node }
          stack.concat(node.children)
        end
        map
      end

      def text(item, top:)
        return item.text unless item.node

        node = item.node
        line = node.kind == :round ? round(node) : "#{description(node)} #{position(node.from)} #{status(node)}"
        return "#{line}#{result_note}" if top && @trace.result&.failure?

        "#{line}#{notes(node)}#{labels(node, origin: item.mode == :all && item.limit)}"
      end

      def description(node) = node.rule == Standalone::ROOT ? "parse" : node.description

      def status(node) = node.to ? "✓ → #{position(node.to)}" : "✗"

      def round(node)
        seed = node.notes[:seed_end]
        line = "round #{node.notes[:round]} (#{seed ? "seed ends at #{position(seed)}" : "seed fails"}) #{status(node)}"
        return line unless node.notes[:stopped]

        n = node.notes[:round]
        "#{line}, no further: stops#{" (keeps round #{n - 1})" if n > 1}"
      end

      # What went wrong, for a failed node.
      def notes(node) # rubocop:disable Metrics
        return "" if node.to || node.kind == :end_of_input # its description says what it expected
        return " stack ran out" if node.notes[:stack_ran_out]

        notes = node.notes
        out = +""
        if (committed = notes[:committed])
          out << " committed: expected #{list(committed[:expected])} at #{position(committed[:pos])}"
        elsif node.kind == :leaf
          out << " found #{found(node.from)}"
        elsif node.expected.any? && !notes[:seed]
          out << " expected #{list(node.expected)}"
          out << " at #{position(node.furthest)}" unless node.furthest == node.from
        end
        out << " rejected by :#{notes[:rejected_by]}" if notes[:rejected_by]
        out << " unwound by commit" if notes[:unwound_by_commit]
        out
      end

      # How a call was answered, and lookahead, whatever the outcome.
      def labels(node, origin:) # rubocop:disable Metrics
        notes = node.notes
        out = +""
        out << " (memo)" if notes[:memo]
        out << " (this round)" if notes[:this_round]
        out << (node.to ? " (seed)" : " (seed fails)") if notes[:seed]
        out << " (took the longest from :#{notes[:took_longest]}'s rounds)" if notes[:took_longest]
        out << " (caught a commit)" if notes[:caught_commit]
        out << " (lookahead)" if notes[:in_lookahead] && !origin && lookahead_top?(node)
        out
      end

      # The first node of a lookahead's attempt (its parent isn't one).
      def lookahead_top?(node)
        @parents ||= parents
        !@parents[node]&.notes&.[](:in_lookahead)
      end

      # On the last top-level line of a failure: where it failed, and why.
      def result_note
        failure = @trace.result
        head = failure.message.lines.first.chomp.sub(/\Aline \d+, column \d+: /, "")
        " #{"committed " if failure.committed}at #{position(failure.pos)}: #{head}"
      end

      def input_line(root)
        "(input) ✗ #{@trace.result&.reason || "invalid input"} at #{position(root.from)}"
      end

      def found(pos) = @input[pos]&.inspect || "end of input"

      def list(items)
        items = items.uniq
        items.size > 1 ? "#{items[0...-1].join(", ")} or #{items.last}" : items.first.to_s
      end

      def prefix(flags)
        return "" if flags.empty?

        flags[0...-1].map { _1 ? "   " : "│  " }.join + (flags.last ? "└─ " : "├─ ")
      end

      # Too deep: keeps the outermost OUTER levels and innermost INNER,
      # with a line between counting the ones left out.
      def cut(entries) # rubocop:disable Metrics
        deepest = entries.map { _1[0].size }.max
        return entries if deepest <= OUTER + INNER

        to = deepest - INNER # levels OUTER..to go, and one line stands for them
        gap = [*Array.new(OUTER - 1, false), true]
        out = []
        entries.each do |flags, text|
          if flags.size < OUTER then out << [flags, text]
          elsif flags.size > to then out << [flags[0, OUTER - 1] + [true] + flags[to..], text]
          elsif gap
            out << [flags[0, OUTER - 1] + [true], "… (#{to - OUTER + 1} levels)"]
            gap = nil
          end
        end
        out
      end
    end
  end
end
