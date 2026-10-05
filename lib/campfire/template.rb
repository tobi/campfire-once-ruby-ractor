# frozen_string_literal: true

require "erb/escape"

module Campfire
  # Compiles ERB templates into plain Ruby methods that append to a single
  # output buffer (`@b`). Trimming follows Erubi (what Rails uses) so literal
  # whitespace matches the reference app byte for byte.
  #
  #   <%= expr %>   escaped append (nil appends nothing; helpers may write to
  #                 @b directly and return nil)
  #   <%== expr %>  raw append
  #   <% code %>    Ruby
  #   <%# ... %>    comment
  module Template
    REGEXP = /<%(={1,2}|-|\#|%)?(.*?)([-=])?%>([ \t]*\r?\n)?/m

    module_function

    # Returns Ruby source for a method body.
    def compile(src)
      out = +""
      pos = 0
      is_bol = true
      src.scan(REGEXP) do |indicator, code, tailch, rspace|
        match = Regexp.last_match
        text = src[pos, match.begin(0) - pos]
        pos = match.end(0)
        ch = indicator ? indicator[0] : ""
        lspace = nil

        unless ch == "="
          if text.empty?
            lspace = "" if is_bol
          elsif text[-1] == "\n"
            lspace = ""
          elsif (rindex = text.rindex("\n"))
            s = text[rindex + 1..]
            if s.match?(/\A[ \t]*\z/)
              lspace = s
              text = text[0, rindex + 1]
            end
          elsif is_bol && text.match?(/\A[ \t]*\z/)
            lspace = text
            text = ""
          end
        end

        is_bol = rspace
        add_text(out, text)
        case ch
        when "="
          rspace = nil if tailch && !tailch.empty?
          add_expr(out, indicator == "==" ? :raw : :escaped, code)
          add_text(out, rspace) if rspace
        when "#"
          n = code.count("\n") + (rspace ? 1 : 0)
          if lspace && rspace
            out << ("\n" * n)
          else
            add_text(out, lspace) if lspace
            out << ("\n" * n)
            add_text(out, rspace) if rspace
          end
        when "%"
          add_text(out, "#{lspace}<%#{code}#{tailch}%>#{rspace}")
        else
          if lspace && rspace
            out << code << ";" << "\n"
          else
            add_text(out, lspace) if lspace
            out << code << ";"
            add_text(out, rspace) if rspace
          end
        end
      end
      add_text(out, src[pos..] || "")
      out
    end

    def add_text(out, text)
      return if text.nil? || text.empty?
      out << "@b << " << text.dump << ";"
      out << ("\n" * text.count("\n"))
    end

    def add_expr(out, kind, code)
      if kind == :raw
        out << "@b << (" << code << ").to_s;"
      else
        out << "_v = (" << code << "); @b << ERB::Escape.html_escape(_v) unless _v.nil?;"
      end
      out << ("\n" * code.count("\n"))
    end

    # Defines one method per template on `mod`. Template "rooms/show" becomes
    # `rooms_show`; partial "messages/_message" becomes `_messages_message`.
    # Locals are declared in a magic comment on the first line:
    #   <%# locals: (message:, room: nil) %>
    def define_all(mod, dir)
      Dir.glob("**/*.erb", base: dir).sort.each do |rel|
        path = File.join(dir, rel)
        src = File.read(path)
        params = src[/\A<%#\s*locals:\s*\((.*?)\)\s*%>\n?/m, 1]
        src = src.sub(/\A<%#\s*locals:.*?%>\n?/m, "") if params
        name = method_name(rel)
        # Frozen literals: each static chunk is appended without allocating.
        mod.class_eval("# frozen_string_literal: true\ndef #{name}(#{params}); #{compile(src)}; nil; end", path, -1)
      end
    end

    def method_name(rel)
      base = rel.sub(/\.erb\z/, "").sub(/\.(html|turbo_stream|json|svg|js)\z/, "")
      dir, _, file = base.rpartition("/")
      partial = file.start_with?("_")
      file = file.delete_prefix("_")
      name = [dir, file].reject(&:empty?).join("_").tr("/.-", "___")
      partial ? "_#{name}" : name
    end
  end
end
