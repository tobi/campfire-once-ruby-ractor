# frozen_string_literal: true

require "zlib"
require "openssl"

module Campfire
  # gzip and ETags for pages made mostly of cached fragments (a room's messages), without
  # recompressing or rehashing the whole page on every request (after ref-rust
  # kit/src/deflater/splice.rs). A room page is ~460KB of HTML; Zlib.gzip of it took ~1.9ms of a
  # ~2.4ms request.
  #
  # While a page renders, #record notes where each large cached fragment lands in the output
  # buffer. #gzip then emits one raw deflate stream from pieces: each fragment (with the few bytes
  # of glue before it) is compressed once against the fragments before it in the same run (up to
  # deflate's 32KB window) as preset dictionary, SYNC_FLUSHed to a byte boundary, and kept with
  # its CRC-32. Back-references can only reach the dictionary and the piece itself, so a piece is
  # valid wherever the same predecessors (by identity, plus the glue between them) precede it. Only the text between runs of fragments (the layout, with its per-request CSRF tokens) is
  # compressed per request, against the real bytes before it. The result is within ~1% of
  # compressing the page whole.
  #
  # All tables are Ractor-local; keys are the frozen fragment Strings themselves (by identity),
  # which the fragment cache hands out unchanged until a record changes.
  module PageParts
    MIN_FRAGMENT = 1024 # smaller fragments stay in the text around them
    MAX_GLUE = 256      # at most this much text between two fragments travels with the second
    WINDOW = 32 * 1024  # deflate's window
    PIECES_PER_FRAGMENT = 4 # one per predecessor seen (room page, older page, search results)
    MAX_FRAGMENTS = 4_000   # remembered fragments per Ractor before the tables are cleared
    GZIP_HEADER = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03".b.freeze
    FINAL_BLOCK = "\x03\x00".b.freeze # an empty final fixed-Huffman block
    EMPTY = "".b.freeze

    module_function

    # Called while rendering, just before `fragment` is appended to `buf`.
    def record(buf, fragment)
      return if fragment.bytesize < MIN_FRAGMENT
      rec = Ractor[:page_parts]
      rec = Ractor[:page_parts] = [buf] if rec.nil? || !rec[0].equal?(buf)
      rec << buf.bytesize << fragment
      nil
    end

    # The recorded parts of `body`: [body, offset, fragment, offset, fragment, ...], or nil
    # when none were recorded or they don't match the body (checked once per page).
    def of(body)
      rec = Ractor[:page_parts]
      return unless rec && rec[0].equal?(body)
      return rec if Ractor[:page_parts_valid].equal?(rec)
      return Ractor[:page_parts] = nil unless valid?(body, rec)
      Ractor[:page_parts_valid] = rec
    end

    # Rack::ETag's digest, taken over the text parts and the fragments' remembered digests
    # instead of the whole body. `rec` comes from #of.
    def digest(body, rec)
      sha = (Ractor[:campfire_sha256] ||= OpenSSL::Digest.new("SHA256")).reset
      digests = (Ractor[:page_part_digests] ||= {}.compare_by_identity)
      digests.clear if digests.size > MAX_FRAGMENTS
      pos = 0
      i = 1
      while i < rec.size
        off = rec[i]
        frag = rec[i + 1]
        sha.update(body.byteslice(pos, off - pos)) if off > pos
        sha.update(digests[frag] ||= OpenSSL::Digest.digest("SHA256", frag))
        pos = off + frag.bytesize
        i += 2
      end
      sha.update(body.byteslice(pos, body.bytesize - pos)) if pos < body.bytesize
      sha.digest
    end

    # A complete gzip member for `body`; `rec` comes from #of.
    def gzip(body, rec)
      pieces = (Ractor[:page_part_pieces] ||= {}.compare_by_identity)
      pieces.clear if pieces.size > MAX_FRAGMENTS
      out = String.new(GZIP_HEADER, capacity: (body.bytesize >> 4) + 64)
      crc = 0
      pos = 0
      run_start = 0 # where the current run of fragments (and glue) began
      i = 1
      while i < rec.size
        off = rec[i]
        frag = rec[i + 1]
        glue_len = off - pos
        if i > 1 && glue_len <= MAX_GLUE
          e = piece(pieces, body, rec, i, glue_len.zero? ? EMPTY : body.byteslice(pos, glue_len), run_start, pos)
        else
          crc = text(out, body, pos, glue_len, crc) if glue_len > 0
          glue_len = 0
          run_start = off
          e = piece(pieces, body, rec, i, EMPTY, off, off)
        end
        out << e[2]
        crc = Zlib.crc32_combine(crc, e[3], glue_len + frag.bytesize)
        pos = off + frag.bytesize
        i += 2
      end
      crc = text(out, body, pos, body.bytesize - pos, crc) if pos < body.bytesize
      out << FINAL_BLOCK << [crc, body.bytesize & 0xffffffff].pack("VV")
    end

    # Each fragment sits at its offset, in order (a later prepend would shift them).
    def valid?(body, rec)
      pos = 0
      i = 1
      while i < rec.size
        off = rec[i]
        frag = rec[i + 1]
        return false if off < pos || body.byteslice(off, frag.bytesize) != frag
        pos = off + frag.bytesize
        i += 2
      end
      true
    end

    # [chain, glue, deflated, crc32] for glue + the fragment at rec[i], whose glue starts at
    # `at`. The dictionary is the run's bytes before `at` (at most WINDOW); `chain` names them:
    # the earlier fragments it reaches back over, each with the glue that preceded it.
    def piece(pieces, body, rec, i, glue, run_start, at)
      frag = rec[i + 1]
      dict_start = at - WINDOW > run_start ? at - WINDOW : run_start
      list = (pieces[frag] ||= [])
      list.each { |e| return e if e[1] == glue && same_chain?(e[0], body, rec, i, dict_start) }
      data = glue.empty? ? frag : glue + frag
      dict = at > dict_start ? body.byteslice(dict_start, at - dict_start) : nil
      e = [chain(body, rec, i, dict_start), glue.empty? ? EMPTY : glue.b.freeze, deflate(data, dict).freeze, Zlib.crc32(data)].freeze
      list.shift if list.size >= PIECES_PER_FRAGMENT
      list << e
      e
    end

    # [fragment, glue before it, fragment, glue, ...] going back from rec[i] while the
    # fragments end after dict_start.
    def chain(body, rec, i, dict_start)
      c = []
      j = i - 2
      while j >= 1 && rec[j] + rec[j + 1].bytesize > dict_start
        prev_end = j > 1 ? rec[j - 2] + rec[j - 1].bytesize : rec[j]
        c << rec[j + 1] << (rec[j] > prev_end && rec[j] > dict_start ? body.byteslice(prev_end, rec[j] - prev_end).b.freeze : EMPTY)
        j -= 2
      end
      c.freeze
    end

    def same_chain?(c, body, rec, i, dict_start)
      k = 0
      j = i - 2
      while j >= 1 && rec[j] + rec[j + 1].bytesize > dict_start
        return false if k >= c.size || !c[k].equal?(rec[j + 1])
        prev_end = j > 1 ? rec[j - 2] + rec[j - 1].bytesize : rec[j]
        glue_len = rec[j] > prev_end && rec[j] > dict_start ? rec[j] - prev_end : 0
        g = c[k + 1]
        return false if g.bytesize != glue_len || (glue_len > 0 && body.byteslice(prev_end, glue_len) != g)
        k += 2
        j -= 2
      end
      k == c.size
    end

    # Text changes with every request (masked CSRF tokens), so it gets the fastest level:
    # ~3x faster than the default on this HTML for ~14% more bytes of text.
    def text(out, body, pos, len, crc)
      data = body.byteslice(pos, len)
      start = pos > WINDOW ? pos - WINDOW : 0
      out << deflate(data, pos.zero? ? nil : body.byteslice(start, pos - start), Zlib::BEST_SPEED)
      Zlib.crc32_combine(crc, Zlib.crc32(data), len)
    end

    # Raw deflate (no zlib/gzip framing), ending byte-aligned on a non-final block.
    def deflate(data, dict, level = Zlib::DEFAULT_COMPRESSION)
      z = Zlib::Deflate.new(level, -Zlib::MAX_WBITS)
      z.set_dictionary(dict) if dict
      s = z.deflate(data, Zlib::SYNC_FLUSH)
      z.close
      s
    end
  end
end
