# frozen_string_literal: true

require "digest"
require "securerandom"
require "protocol/http/body/file"
require "protocol/http/body/readable"

module Campfire
  module Storage
    # Streams stored files the way Rack::Files (DiskController#show) and
    # ActiveStorage::Streaming (proxy controllers) do, with byte ranges
    # (Go web/file_ranges.go). Bodies are Protocol::HTTP::Body::File, never
    # the whole file in memory.
    module Serve
      UNSATISFIABLE = "Byte range unsatisfiable\n"
      PROXY_LAST_MODIFIED = "Sat, 01 Jan 2011 00:00:00 GMT"
      PROXY_LAST_MODIFIED_TIME = Time.utc(2011, 1, 1).freeze
      RACK_BOUNDARY = "AaB03x"
      MAX_RANGES = 100
      INT_MAX = (2**63) - 1

      # Body for multipart/byteranges: header strings and file slices.
      class Multipart < Protocol::HTTP::Body::Readable
        BLOCK = 64 * 1024

        def initialize(file, parts, ending, length)
          @file = file
          @parts = parts # [[header, start, finish], ...]
          @ending = ending
          @length = length
          @index = 0
          @remaining = nil
        end

        attr_reader :length

        def read
          while @index < @parts.size
            header, start, finish = @parts[@index]
            if @remaining.nil?
              @file.seek(start)
              @remaining = finish - start + 1
              return header
            end
            if @remaining > 0
              chunk = @file.read(@remaining < BLOCK ? @remaining : BLOCK)
              if chunk
                @remaining -= chunk.bytesize
                return chunk
              end
            end
            @remaining = nil
            @index += 1
          end
          if @ending
            e = @ending
            @ending = nil
            return e
          end
          nil
        end

        def empty? = @index >= @parts.size && @ending.nil?
        def ready? = true

        def close(error = nil)
          @file.close unless @file.closed?
          super
        end
      end

      module_function

      # Rack::Utils.byte_ranges: nil (ignore the header), [] (unsatisfiable)
      # or [[first, last], ...].
      def byte_ranges(header, size)
        return nil if header.nil? || size == 0
        header = header.to_s
        spec = nil
        offset = 0
        while (i = header.index("bytes=", offset))
          offset = i + 6
          finish = header.index(";", offset) || header.length
          if finish > offset
            spec = header[offset...finish]
            break
          end
        end
        return nil if spec.nil? || spec.count(",") >= MAX_RANGES
        parts = spec.split(",")
        parts.each_with_index { |p, i| parts[i] = p.sub(/\A[ \t]+/, "") if i > 0 }
        ranges = []
        total = 0
        parts.each do |value|
          return nil unless value.include?("-")
          a, b = value.split("-")
          if a.nil? || a.empty?
            return nil if b.nil?
            first = [0, size - decimal_prefix(b)].max
            last = size - 1
          else
            first = decimal_prefix(a)
            last = size - 1
            if b
              l = decimal_prefix(b)
              return nil if l < first
              last = l < size - 1 ? l : size - 1
            end
          end
          next unless first <= last
          length = last - first + 1
          return [] if total > size - length
          total += length
          ranges << [first, last]
        end
        ranges
      end

      # String#to_i of a range bound (leading space, sign, 0d, underscores).
      def decimal_prefix(text)
        text = text.sub(/\A[ \t\n\r\v\f]+/, "").delete_prefix("+")
        text = text[2..] if text.start_with?("0d", "0D")
        n = 0
        i = 0
        len = text.length
        while i < len
          c = text.getbyte(i)
          if c == 95 && i > 0 && i + 1 < len && digit?(text.getbyte(i - 1)) && digit?(text.getbyte(i + 1))
            i += 1
            next
          end
          break unless digit?(c)
          n = n * 10 + (c - 48)
          return INT_MAX if n > INT_MAX
          i += 1
        end
        n
      end

      def digit?(c) = c && c >= 48 && c <= 57

      # `headers` already holds content-type/disposition/cache-control.
      # `proxy`: ActiveStorage::Streaming (blobs/representations proxy, send
      # variant); otherwise Rack::Files (disk service).
      def file(request, path, headers, content_type, proxy:)
        io = begin
          ::File.open(path, ::File::RDONLY | ::File::BINARY)
        rescue Errno::ENOENT, Errno::EISDIR, Errno::ENOTDIR
          return Storage.not_found
        end
        stat = io.stat
        size = stat.size
        range_header = request.headers["range"]&.to_s
        range_header = nil if range_header&.empty?
        headers << ["cache-control", "no-cache"] if proxy && range_header

        if !proxy
          modified = Util.httpdate(stat.mtime)
          if request.headers["if-modified-since"]&.to_s == modified
            io.close
            return response(304, headers, nil)
          end
          headers << ["last-modified", modified]
        elsif range_header.nil?
          etag = %(W/"#{Digest::SHA256.digest(request.path)[0, 16].unpack1("H*")}")
          headers << ["etag", etag] << ["last-modified", PROXY_LAST_MODIFIED]
          if fresh?(request, etag)
            io.close
            return response(304, headers.reject { |k, _| k == "content-type" }, nil)
          end
        end

        ranges = byte_ranges(range_header, size)
        if (ranges && ranges.empty?) || (proxy && range_header && ranges.nil?)
          io.close
          if proxy
            return response(416, headers.reject { |k, _| k == "content-type" || k == "content-disposition" }, nil)
          end
          headers.reject! { |k, _| k == "last-modified" }
          headers << ["content-range", "bytes */#{size}"]
          return response(416, headers, UNSATISFIABLE)
        end

        if ranges.nil?
          headers << ["accept-ranges", "bytes"] if proxy
          return response(200, headers, Protocol::HTTP::Body::File.new(io, size: size))
        end
        headers << ["accept-ranges", "bytes"] if proxy
        if ranges.size == 1
          first, last = ranges[0]
          headers << ["content-range", "bytes #{first}-#{last}/#{size}"]
          return response(206, headers, Protocol::HTTP::Body::File.new(io, first..last))
        end

        if proxy
          boundary = SecureRandom.hex(16)
          mime = content_type
          type_header = "Content-Type"
          range_name = "Content-Range"
          headers.reject! { |k, _| k == "content-type" }
          headers << ["content-type", "multipart/byteranges; boundary=#{boundary}"]
        else
          # Rack's text/plain parts; DiskController keeps the signed content type.
          boundary = RACK_BOUNDARY
          mime = "text/plain"
          type_header = "content-type"
          range_name = "content-range"
        end
        length = 0
        parts = ranges.map do |first, last|
          h = "\r\n--#{boundary}\r\n#{type_header}: #{mime}\r\n#{range_name}: bytes #{first}-#{last}/#{size}\r\n\r\n"
          length += h.bytesize + last - first + 1
          [h, first, last]
        end
        ending = "\r\n--#{boundary}--\r\n"
        length += ending.bytesize
        response(206, headers, Multipart.new(io, parts, ending, length))
      end

      def fresh?(request, etag)
        if (inm = request.headers["if-none-match"])
          Array(inm).join(",").split(",").any? { |t| t = t.strip; t == etag || t == "*" }
        elsif (ims = request.headers["if-modified-since"])
          t = (Time.httpdate(ims.to_s) rescue nil)
          t ? t >= PROXY_LAST_MODIFIED_TIME : false
        else
          false
        end
      end

      def response(status, headers, body)
        body = Protocol::HTTP::Body::Buffered.new([body], body.bytesize) if body.is_a?(String)
        Protocol::HTTP::Response[status, Protocol::HTTP::Headers.new(headers), body]
      end

      Util = RailsCompat::Util
    end
  end
end
