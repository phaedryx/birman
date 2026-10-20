# frozen_string_literal: true

# Email addresses: RFC 5322's addr-spec (local@domain, no display names
# or obsolete forms), with RFC 6532's UTF-8, and host names held to
# RFC 1035's shape. A grammar with no ignore rule: whitespace and
# (nested) comments are allowed only where the RFC allows them.
#
#   ruby examples/email.rb
#   ruby examples/email.rb 'jo(hi)@[192.168.0.1]'

require_relative "../lib/birman"

module EmailExample
  # local@domain, where the local part is a dot-atom or a quoted string,
  # and the domain a host name or a [literal].
  class Grammar
    include Birman::Grammar

    Address = node(:local, :domain)
    Host    = node(:labels)
    IPv4    = node(:octets)
    Literal = node(:text)

    root :address

    # Once there's an "@", it's an address: a bad domain is an error
    # where it goes wrong, not a reason to try something else.
    rule(:address) { seq(local_part.as(:local), "@", commit, domain.as(:domain)).to(Address) }

    rule(:local_part) { either(dot_atom, quoted_string).label("local part") }
    rule(:domain)     { either(host, domain_literal).label("domain") }

    # --- Local part ---

    # Runs of atext separated by single dots: a.b, not a..b or .a
    rule(:dot_atom) { between(cfws.maybe, cfws.maybe, sep_by1(atext, ".").action(:dotted)) }
    rule(:atext)    { match(%r{[A-Za-z0-9!#$%&'*+/=?^_`{|}~\-[^\x00-\x7f]]+}).label("atom") }

    rule(:quoted_string) do
      seq(cfws.maybe, str('"'), commit, only(qcontent.rep), str('"').label("closing quote"), cfws.maybe)
        .map(:join)
    end

    rule(:qcontent) do
      either(match(/[\x21\x23-\x5b\x5d-\x7e[^\x00-\x7f]]+/), quoted_pair, fws.action(:unfold)).label("quoted text")
    end

    # A backslash and the character it stands for.
    rule(:quoted_pair) { match(/\\[\x21-\x7e \t[^\x00-\x7f]]/).action(:unquote) }

    # --- Domain ---

    # Labels of letters, digits and inner hyphens, at most 63 characters
    # each and 253 in all. The length checks are atomic groups, (?>...):
    # backtracking into a counted repeat can't help, and Spinel's regexp
    # engine gives up (RegexpError) when a long name makes it try.
    rule(:host) { between(cfws.maybe, cfws.maybe, host_name) }

    rule(:host_name) do
      (match(/(?>[A-Za-z0-9.-]{1,253})(?![A-Za-z0-9.-])/).label("at most 253 characters").present &
        sep_by1(host_label, ".")).to(Host)
    end

    rule(:host_label) do
      (match(/(?>[A-Za-z0-9-]{1,63})(?![A-Za-z0-9-])/).label("a label of at most 63 characters").present &
        seq(let_dig, seq(match(/-+/).label("hyphen"), let_dig).rep).map(:flatten).map(:join)).label("label")
    end

    rule(:let_dig) { match(/[A-Za-z0-9]+/) }

    rule(:domain_literal) do
      seq(cfws.maybe, str("["), commit, only(either(ipv4, dtext)), str("]").label("closing bracket"), cfws.maybe)
    end

    # Four octets, as numbers, if that's all there is between the brackets.
    rule(:ipv4) do
      seq(octet.as(:first), seq(".", only(octet)).rep(3, 3).as(:rest), str("]").present).action(:octets).to(IPv4)
    end

    rule(:octet) { seq(only(match(/25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d/)), match(/\d/).absent).map(:to_i) }

    rule(:dtext) do
      seq((fws.maybe >> match(/[\x21-\x5a\x5e-\x7e[^\x00-\x7f]]+/)).rep, fws.maybe).action(:literal_text).to(Literal)
    end

    # --- Whitespace and comments ---

    # Folding whitespace: spaces and tabs, possibly across a line break.
    rule(:fws) { match(/(?:[ \t]*\r\n)?[ \t]+/).quiet }

    rule(:cfws) { either(seq((fws.maybe >> comment).rep(1), fws.maybe), fws) }

    # Comments nest: (a (b) c)
    rule(:comment) do
      seq(str("("), commit, (fws.maybe >> ccontent).rep, fws.maybe, str(")").label("closing parenthesis"))
        .label("comment")
    end

    rule(:ccontent) do
      either(match(/[\x21-\x27\x2a-\x5b\x5d-\x7e[^\x00-\x7f]]+/), quoted_pair, comment).label("comment text")
    end

    private

    def dotted(parts) = parts.join(".")

    def unquote(text) = text[1]

    # A line break in folding whitespace isn't part of the value.
    def unfold(text) = text.sub("\r\n", "")

    def octets(parts) = [parts[:first]] + parts[:rest]

    # The literal's text, without the whitespace in it.
    def literal_text(parts) = parts[0].map(&:last).join
  end
end

if __FILE__ == $PROGRAM_NAME
  examples = ["jo@example.com", "first.last+tag@sub.example.org", '"jo smith"@example.com',
              "jo (comment (nested)) @ example.com", "jo@[192.168.0.1]", "jö@example.com"]
  addresses = ARGV.any? ? ARGV : examples
  addresses.each do |address|
    case EmailExample::Grammar.parse(address)
    in Birman::Success(value) then puts "#{address.inspect}\n  #{value.inspect}"
    in Birman::Failure => failure then puts "#{address.inspect}\n  #{failure.message.gsub("\n", "\n  ")}"
    end
  end

  puts "\n--- Errors ---"
  ["jo@", "jo..x@example.com", "jo@-example.com", "\"unclosed@example.com", "jo@exa_mple.com",
   "jo(oops@example.com", "jo@[1.2.3]x"].each do |bad|
    puts EmailExample::Grammar.parse(bad).message, ""
  end
end
