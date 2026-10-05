# frozen_string_literal: true

require_relative "html5"

module Campfire
  module RichText
    # Tree helpers shared by the pipeline: fragment parsing, post-order walks,
    # Nokogiri-compatible serialization and inner/outer HTML replacement.
    module DOM
      include HTML5
      Node = HTML5::Node

      VOID = HTML5.set("area base br col embed hr img input link meta param source track wbr")
      RAW = HTML5.set("style script xmp iframe noembed noframes plaintext noscript")
      TEXT_ESCAPE = /[&<>\u00A0]/
      ATTR_ESCAPE = /[&"\u00A0]/
      ATTR_ESCAPE_ANGLES = /[&"<>\u00A0]/
      ESCAPES = Ractor.make_shareable({ "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "\u00A0" => "&nbsp;" })
      STRIP_CHARS = "\0\t\n\v\f\r "

      module_function

      def parse(body, context = nil) = HTML5.parse_fragment(body, context)

      # Ruby's strip removes NUL and ASCII whitespace from both ends.
      def trim(s) = s.strip

      # Post-order traversal over a snapshot of each child list, so callbacks may
      # detach or replace the node they are given.
      def walk(node, &block)
        kids = node.children
        if kids && !kids.empty?
          kids.dup.each { |c| walk(c, &block) }
        end
        yield node
      end

      def each_element(node, &block)
        node.children&.each do |c|
          next unless c.type == ELEMENT
          yield c
          each_element(c, &block)
        end
      end

      def serialize(node, angles = false)
        out = String.new(capacity: 256)
        if node.type == DOCUMENT
          node.children.each { |c| write(out, c, false, angles) }
        else
          write(out, node, false, angles)
        end
        out
      end

      def write(out, node, raw, angles)
        case node.type
        when TEXT
          d = node.data
          out << (raw || !d.match?(TEXT_ESCAPE) ? d : d.gsub(TEXT_ESCAPE, ESCAPES))
          return
        when COMMENT
          out << "<!--" << node.data << "-->"
          return
        when ELEMENT
          out << "<" << node.data
          if (a = node.attrs)
            re = angles ? ATTR_ESCAPE_ANGLES : ATTR_ESCAPE
            i = 0
            while i < a.size
              out << " "
              out << a[i + 2] << ":" if a[i + 2]
              v = a[i + 1]
              out << a[i] << '="' << (v.match?(re) ? v.gsub(re, ESCAPES) : v) << '"'
              i += 3
            end
          end
          out << ">"
          html = node.ns.nil?
          return if html && VOID[node.data]
          raw = html && RAW[node.data]
          node.children.each { |c| write(out, c, raw, angles) }
          out << "</" << node.data << ">"
        else
          node.children.each { |c| write(out, c, false, angles) }
        end
      end

      # Replaces +node+ with +markup+ parsed in the context of its parent.
      def replace(node, markup)
        parent = node.parent
        root = parse(markup, parent)
        return unless parent
        kids = parent.children
        i = kids.index(node)
        root.children.each { |c| c.parent = parent }
        kids[i, 1] = root.children
        node.parent = nil
      end

      def inner(node, markup)
        root = parse(markup, node)
        node.children.each { |c| c.parent = nil }
        root.children.each { |c| c.parent = node }
        node.children = root.children
      end

      def remove(node) = node.parent&.remove(node)

      # Concatenated descendant text, as Nokogiri's Node#text.
      def text_content(node, out = +"")
        if node.type == TEXT
          out << node.data
        else
          node.children&.each { |c| text_content(c, out) }
        end
        out
      end

      def classes?(node, name)
        c = node["class"] or return false
        c.split(/[ \t\n\r\f]+/).include?(name)
      end
    end
  end
end
