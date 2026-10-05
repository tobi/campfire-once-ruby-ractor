# frozen_string_literal: true

require_relative "dom"

module Campfire
  module RichText
    # ActionText::PlainTextConversion (bottom-up reduction keyed on node name).
    module PlainText
      include HTML5

      BLOCKS = HTML5.set("p h1") # the reference Rails treats h2-h6 as inline
      LISTS = HTML5.set("ul ol")
      SKIP = HTML5.set("script style unsupported")
      BLANK = /\A[[:space:]]*\z/

      module_function

      # Ruby's String#chomp(""): drops every trailing "\n" / "\r\n".
      def chomp(s)
        s.end_with?("\n") ? s.chomp("") : s
      end

      def convert(root) = chomp(node(root))

      def node(n)
        return chomp(n.data) if n.type == TEXT
        return "" if n.type == COMMENT
        name = n.type == ELEMENT ? n.data : nil
        return "" if SKIP[name]
        return chomp(DOM.text_content(n)) if name == "text"
        text = +""
        n.children.each { |c| text << node(c) }
        return text unless name
        if BLOCKS[name]
          "#{chomp(text)}\n\n"
        elsif LISTS[name]
          list_depth(n).positive? ? "\n#{chomp(text)}\n\n" : "#{chomp(text)}\n\n"
        elsif name == "br" then "\n"
        elsif name == "div" then "#{chomp(text)}\n"
        elsif name == "figcaption" then "[#{chomp(text)}]"
        elsif name == "blockquote" then blockquote("#{chomp(text)}\n\n")
        elsif name == "li" then li(n, chomp(text))
        else text
        end
      end

      def blockquote(text)
        return "“”" if text.match?(BLANK)
        text.insert(text.rindex(/\S/) + 1, "”")
        text.insert(text.index(/\S/), "“")
      end

      def li(n, text)
        depth = 0
        list = nil
        p = n.parent
        while p
          if p.type == ELEMENT && LISTS[p.data]
            depth += 1
            list ||= p.data
          end
          p = p.parent
        end
        bullet = if list == "ol"
          index = 1
          n.parent.children.each do |c|
            break if c.equal?(n)
            index += 1 if c.type == ELEMENT
          end
          "#{index}."
        else
          "•"
        end
        "#{"  " * (depth - 1) if depth > 1}#{bullet} #{text}\n"
      end

      def list_depth(n)
        depth = 0
        p = n.parent
        while p
          depth += 1 if p.type == ELEMENT && LISTS[p.data]
          p = p.parent
        end
        depth
      end
    end
  end
end
