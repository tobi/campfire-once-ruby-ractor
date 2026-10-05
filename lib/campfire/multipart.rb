# frozen_string_literal: true

require "tmpdir"
require "securerandom"

module Campfire
  # multipart/form-data decoding into Rails-style nested params (Rack's
  # semantics): text parts become strings, file parts become UploadedFile
  # objects whose bytes were written to a tempfile, a file input left empty
  # (filename="") assigns nil, and browser-supplied directory components are
  # stripped from filenames.
  #
  # The scanner works on byte offsets over the request body: boundaries,
  # header lines and Content-Disposition parameters are located with
  # byteindex/getbyte, and the only allocations are the leaf values
  # (field names, field values, filenames) and one write per file.
  module Multipart
    # Rack's Rack::Multipart::UploadedFile surface, as used by controllers.
    class UploadedFile
      attr_reader :filename, :content_type, :path, :size

      def initialize(filename, content_type, path, size)
        @filename = filename
        @content_type = content_type
        @path = path
        @size = size
      end

      alias_method :original_filename, :filename
      def tempfile = @path
      def read = File.binread(@path)
      def open(&) = File.open(@path, "rb", &)
      def unlink = (File.unlink(@path) if File.exist?(@path))
      def inspect = "#<UploadedFile #{@filename.inspect} #{@content_type} #{@size}b>"
    end

    class ParseError < StandardError; end

    CRLF = "\r\n"
    HEADER_END = "\r\n\r\n"
    BINARY = Encoding::BINARY
    UTF8 = Encoding::UTF_8
    DEFAULT_TYPE = "application/octet-stream"
    MAX_PARTS = 4096
    MAX_FILES = 128

    # ASCII-lowercase compare of `name` (lowercase literal) at body[pos, len].
    def self.header_is?(body, pos, len, name)
      return false unless len == name.bytesize
      i = 0
      while i < len
        b = body.getbyte(pos + i)
        b |= 32 if b >= 65 && b <= 90
        return false unless b == name.getbyte(i)
        i += 1
      end
      true
    end

    module_function

    # Parses `body` (a String; treated as bytes) using the boundary in
    # `content_type`, assigning each part into `into` (a Hash). Returns `into`.
    def parse(body, content_type, into = {}, tmpdir: Dir.tmpdir)
      boundary = boundary_of(content_type) or raise ParseError, "missing boundary"
      enc = body.encoding
      body.force_encoding(BINARY) unless enc == BINARY
      begin
        scan(body, (+"--") << boundary, into, tmpdir)
      ensure
        body.force_encoding(enc) unless enc == BINARY
      end
      into
    end

    # boundary=xyz or boundary="xyz" from the Content-Type header value.
    def boundary_of(ct)
      i = ct.index("boundary=") or return nil
      i += 9
      if ct.getbyte(i) == 34 # "
        j = ct.index('"', i + 1) or return nil
        b = ct[i + 1, j - i - 1]
      else
        j = i
        len = ct.bytesize
        while j < len
          c = ct.getbyte(j)
          break if c == 59 || c == 32 || c == 9 # ; space tab
          j += 1
        end
        b = ct.byteslice(i, j - i)
      end
      b.empty? ? nil : b
    end

    def scan(body, delim, into, tmpdir)
      dlen = delim.bytesize
      len = body.bytesize
      pos = body.byteindex(delim) or raise ParseError, "no opening boundary"
      sep = (+"\r\n") << delim
      parts = 0
      files = 0
      loop do
        pos += dlen
        # "--" after the delimiter closes the body.
        break if body.getbyte(pos) == 45 && body.getbyte(pos + 1) == 45
        # Transport padding, then CRLF.
        pos += 1 while (c = body.getbyte(pos)) && (c == 32 || c == 9)
        raise ParseError, "bad boundary line" unless body.getbyte(pos) == 13 && body.getbyte(pos + 1) == 10
        pos += 2
        raise ParseError, "too many parts" if (parts += 1) > MAX_PARTS

        hend = body.byteindex(HEADER_END, pos)
        if hend.nil?
          # A part with no headers at all starts directly with CRLF.
          raise ParseError, "unterminated headers" unless body.getbyte(pos) == 13 && body.getbyte(pos + 1) == 10
          hend = pos - 2
        end
        name = filename = ctype = nil
        has_filename = false
        line = pos
        while line < hend
          eol = body.byteindex(CRLF, line)
          eol = hend if eol.nil? || eol > hend
          colon = body.byteindex(":", line)
          if colon && colon < eol
            vpos = colon + 1
            vpos += 1 while (c = body.getbyte(vpos)) == 32 || c == 9
            if Multipart.header_is?(body, line, colon - line, "content-disposition")
              name, filename, has_filename = disposition(body, vpos, eol)
            elsif Multipart.header_is?(body, line, colon - line, "content-type")
              ctype = body.byteslice(vpos, eol - vpos).force_encoding(UTF8)
            end
          end
          line = eol + 2
        end

        dstart = hend + 4
        dend = body.byteindex(sep, dstart)
        if dend.nil?
          # Tolerate a missing trailing CRLF before the final boundary.
          raise ParseError, "unterminated part" unless (dend = body.byteindex(delim, dstart))
          dnext = dend
        else
          dnext = dend + 2
        end

        if name
          if has_filename
            if filename.nil? || filename.empty?
              Params.assign(into, name, nil)
            else
              raise ParseError, "too many files" if (files += 1) > MAX_FILES
              path = File.join(tmpdir, "RackMultipart#{SecureRandom.hex(10)}")
              size = dend - dstart
              File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |f|
                f.write(body.byteslice(dstart, size)) if size > 0
              end
              Params.assign(into, name, UploadedFile.new(filename, ctype || DEFAULT_TYPE, path, size))
            end
          else
            Params.assign(into, name, body.byteslice(dstart, dend - dstart).force_encoding(UTF8))
          end
        end
        pos = dnext
        break if pos >= len
      end
      into
    end

    # form-data; name="user[avatar]"; filename="me.png"  (also filename*=UTF-8''...)
    # => [name, filename, filename_present]
    def disposition(body, pos, stop)
      name = filename = nil
      present = false
      while pos < stop
        pos += 1 while pos < stop && ((c = body.getbyte(pos)) == 59 || c == 32 || c == 9)
        break if pos >= stop
        kstart = pos
        pos += 1 while pos < stop && (c = body.getbyte(pos)) != 61 && c != 59
        klen = pos - kstart
        if pos >= stop || body.getbyte(pos) == 59
          next # bare token such as "form-data"
        end
        pos += 1 # '='
        if body.getbyte(pos) == 34
          pos += 1
          vstart = pos
          escaped = false
          while pos < stop && (c = body.getbyte(pos)) != 34
            if c == 92 && ((n = body.getbyte(pos + 1)) == 34 || n == 92) # \" or \\
              escaped = true
              pos += 1
            end
            pos += 1
          end
          value = body.byteslice(vstart, pos - vstart)
          value = value.gsub(/\\(["\\])/n, '\1') if escaped
          pos += 1
        else
          vstart = pos
          pos += 1 while pos < stop && (c = body.getbyte(pos)) != 59 && c != 32 && c != 9
          value = body.byteslice(vstart, pos - vstart)
        end
        if Multipart.header_is?(body, kstart, klen, "name")
          name = value.force_encoding(UTF8)
        elsif Multipart.header_is?(body, kstart, klen, "filename")
          present = true
          filename = basename(value.force_encoding(UTF8)) if filename.nil?
        elsif Multipart.header_is?(body, kstart, klen, "filename*")
          present = true
          filename = basename(ext_value(value))
        end
      end
      [name, filename, present]
    end

    # RFC 5987: charset'lang'percent-encoded
    def ext_value(v)
      q = v.byteindex("'") or return v.force_encoding(UTF8)
      q2 = v.byteindex("'", q + 1) or return v.force_encoding(UTF8)
      v.byteslice(q2 + 1, v.bytesize - q2 - 1).gsub(/%([0-9A-Fa-f]{2})/n) { $1.hex.chr }.force_encoding(UTF8)
    end

    # Rack strips directory components (including Windows paths).
    def basename(f)
      i = f.byterindex("/")
      j = f.byterindex("\\")
      k = i && j ? (i > j ? i : j) : (i || j)
      k ? f.byteslice(k + 1, f.bytesize - k - 1) : f
    end
  end
end
