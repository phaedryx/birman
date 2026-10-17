# frozen_string_literal: true

module Birman
  # Turns a Failure into readable text. Anything that responds to
  # #call(failure) works in its place, for custom wording or i18n:
  #
  #   failure.message(MyFormatter.new)
  class ErrorFormatter
    def call(failure)
      <<~MSG.chomp
        line #{failure.line}, column #{failure.column}: #{problem(failure)}
          #{source_line(failure)}
          #{' ' * (failure.column - 1)}^
      MSG
    end

    private

    def problem(failure)
      failure.reason || "expected #{expected_list(failure.expected)}, found #{failure.found}"
    end

    def expected_list(items)
      case items
      in [] then "nothing"
      in [only] then only
      in [*rest, last] then "#{rest.join(', ')} or #{last}"
      end
    end

    def source_line(failure) = failure.input.lines.fetch(failure.line - 1, "").chomp
  end
end
