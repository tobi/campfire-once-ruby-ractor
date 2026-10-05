# frozen_string_literal: true

require "erb/escape"
require_relative "sanitizer"

module Campfire
  module RichText
    # rails_autolink's auto_link(html, html: { target: "_blank" }) over already
    # sanitized markup, using the gem's own regular expressions.
    module Autolink
      AUTO_LINK_RE = %r{
        (?: ((?:ed2k|ftp|http|https|irc|mailto|news|gopher|nntp|telnet|webcal|xmpp|callto|feed|svn|urn|aim|rsync|tag|ssh|sftp|rtsp|afs|file):)// | www\.\w )
        [^\s<\u00A0"]+
      }ix
      AUTO_LINK_CRE = Ractor.make_shareable([/<[^>]+$/, /^[^>]*>/, /<a\b.*?>/i, /<\/a>/i])
      AUTO_EMAIL_LOCAL_RE = /[\w.!#$%&'*\/=?^`{|}~+-]/
      AUTO_EMAIL_RE = /(?<!#{AUTO_EMAIL_LOCAL_RE})[\w.!#$%+-]\.?#{AUTO_EMAIL_LOCAL_RE}*@[\w-]+(?:\.[\w-]+)+/
      TRAILING_PUNCTUATION = %r{[^\p{Word}/\-=;]$}
      TRAILING_GT = /&gt;$/
      BRACKETS = Ractor.make_shareable({ "]" => "[", ")" => "(", "}" => "{" })
      URL_ENCODE = /[^a-zA-Z0-9_\-.~]/n

      module_function

      def call(text)
        text = urls(text) if text.include?("//") || text.match?(/www\./i)
        text = emails(text) if text.include?("@")
        text
      end

      def linked?(left, right)
        return true if left.match?(AUTO_LINK_CRE[0]) && right.match?(AUTO_LINK_CRE[1])
        left.rindex(AUTO_LINK_CRE[2]) or return false
        !$~.post_match.match?(AUTO_LINK_CRE[3])
      end

      def urls(text)
        text.gsub(AUTO_LINK_RE) do
          m = $~
          next m[0] if linked?(m.pre_match, m.post_match)
          href = m[0].dup
          punctuation = []
          while (cut = href[TRAILING_PUNCTUATION])
            href.chop!
            punctuation << cut
            opening = BRACKETS[cut]
            if opening && href.count(opening) > href.count(cut)
              href << punctuation.pop
              break
            end
          end
          trailing_gt = href.sub!(TRAILING_GT, "") ? "&gt;" : ""
          link_text = Sanitizer.sanitize_string(href)
          href = "http://#{href}" unless m[1]
          href = Sanitizer.sanitize_string(href)
          href = href.gsub('"', "&quot;") if href.include?('"')
          out = +%(<a target="_blank" href="#{href}">#{link_text}</a>)
          punctuation.reverse_each { |c| out << ERB::Escape.html_escape(c) }
          out << trailing_gt
        end
      end

      def emails(text)
        text.gsub(AUTO_EMAIL_RE) do
          m = $~
          email = m[0]
          next email if linked?(m.pre_match, m.post_match)
          sanitized = Sanitizer.sanitize_string(email)
          display = sanitized == email ? ERB::Escape.html_escape(email) : sanitized
          encoded = sanitized.b.gsub(URL_ENCODE) { |c| format("%%%02X", c.ord) }.gsub("%40", "@")
          %(<a target="_blank" href="#{ERB::Escape.html_escape("mailto:#{encoded}")}">#{display}</a>)
        end
      end
    end
  end
end
