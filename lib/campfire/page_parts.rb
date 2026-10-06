# frozen_string_literal: true

require "zlib"
require "openssl"

module Campfire
  # gzip and ETags for pages without recompressing or rehashing them on every request (after
  # ref-rust kit/src/deflater/splice.rs). A room page is ~460KB of HTML; Zlib.gzip of it took
  # ~1.9ms of a ~2.4ms request.
  #
  # While a page renders, #record notes where each large cached fragment lands in the output
  # buffer. That splits the page into parts covering it end to end: the fragments, and the text
  # between them (the layout). Pages carry no per-request CSRF token, so the text renders the same
  # until what it shows changes, and every part can be compressed once and kept:
  #
  # - A fragment (with the few bytes of glue before it) is compressed against the fragments before
  #   it in the same run (up to deflate's 32KB window) as preset dictionary, SYNC_FLUSHed to a byte
  #   boundary, and kept with its CRC-32. Back-references can only reach the dictionary and the
  #   piece itself, so a piece is valid wherever the same predecessors (by identity, plus the glue
  #   between them) precede it.
  # - A text part is compressed against the fragment before it, and kept by its SHA-256 and that
  #   fragment's.
  #
  # #gzip splices the pieces into one raw deflate stream (within ~1% of compressing the page
  # whole) and combines their CRCs. The ETag (#digest) hashes the parts' digests instead of the
  # body. A page Rack::ETag digests whole (no recorded fragments, e.g. the sidebar) keeps its gzip
  # member by that digest (#gzip_digested).
  #
  # All tables are Ractor-local. Fragment keys are the frozen fragment Strings themselves (by
  # identity), which the fragment cache hands out unchanged until a record changes.
  module PageParts
    MIN_FRAGMENT = 1024 # smaller fragments stay in the text around them
    MAX_GLUE = 256      # at most this much text between two fragments travels with the second
    WINDOW = 32 * 1024  # deflate's window
    PIECES_PER_FRAGMENT = 4 # one per predecessor seen (room page, older page, search results)
    MAX_FRAGMENTS = 4_000   # remembered fragments per Ractor before the tables are cleared
    STORE_BUDGET = 16 << 20 # per Ractor: compressed text pieces and whole-page gzip members
    ENTRY_OVERHEAD = 128
    GZIP_HEADER = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03".b.freeze
    FINAL_BLOCK = "\x03\x00".b.freeze # an empty final fixed-Huffman block
    EMPTY = "".b.freeze
    TEXT_KEY = "t".b.freeze
    GZIP_KEY = "g".b.freeze

    # A map bounded by what its entries cost, in two generations: new entries go into the young
    # one; when it is full it becomes the old one (dropping the previous old one), and an old
    # entry that is used again moves back into the young one. Entries over 1/64 of the budget are
    # returned but not stored, so a one-off large value can't push out the rest.
    class Generations
      def initialize(budget)
        @half = budget / 2
        @max_entry = budget / 64
        @young = {}
        @old = {}
        @cost = 0
      end

      def [](key)
        if (e = @young[key])
          e[0]
        elsif (e = @old.delete(key))
          put(key, e)
          e[0]
        end
      end

      def store(key, value, cost)
        put(key, [value, cost].freeze) if cost <= @max_entry && !@young.key?(key)
        value
      end

      def size = @young.size + @old.size

      private

      def put(key, entry)
        if @cost + entry[1] > @half
          @old = @young
          @young = {}
          @cost = 0
        end
        @young[key] = entry
        @cost += entry[1]
      end
    end

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

    # Rack::ETag's digest, taken over the parts' digests instead of the whole body. `rec` comes
    # from #of.
    def digest(body, rec)
      texts = text_digests(body, rec)
      sha = (Ractor[:campfire_sha256] ||= OpenSSL::Digest.new("SHA256")).reset
      k = 0
      i = 1
      while i < rec.size
        sha.update(texts[k]) if texts[k]
        sha.update(fragment_digest(rec[i + 1]))
        k += 1
        i += 2
      end
      sha.update(texts[k]) if texts[k]
      sha.digest
    end

    # A complete gzip member for `body`; `rec` comes from #of.
    def gzip(body, rec)
      pieces = (Ractor[:page_part_pieces] ||= {}.compare_by_identity)
      pieces.clear if pieces.size > MAX_FRAGMENTS
      texts = text_digests(body, rec)
      out = String.new(GZIP_HEADER, capacity: (body.bytesize >> 4) + 64)
      crc = 0
      pos = 0
      run_start = 0 # where the current run of fragments (and glue) began
      k = 0
      i = 1
      while i < rec.size
        off = rec[i]
        frag = rec[i + 1]
        glue_len = off - pos
        if i > 1 && glue_len <= MAX_GLUE
          e = piece(pieces, body, rec, i, glue_len.zero? ? EMPTY : body.byteslice(pos, glue_len), run_start, pos)
        else
          crc = text(out, body, pos, glue_len, i > 1 ? rec[i - 1] : nil, texts[k], crc) if glue_len > 0
          glue_len = 0
          run_start = off
          e = piece(pieces, body, rec, i, EMPTY, off, off)
        end
        out << e[2]
        crc = Zlib.crc32_combine(crc, e[3], glue_len + frag.bytesize)
        pos = off + frag.bytesize
        k += 1
        i += 2
      end
      crc = text(out, body, pos, body.bytesize - pos, rec[-1], texts[k], crc) if pos < body.bytesize
      out << FINAL_BLOCK << [crc, body.bytesize & 0xffffffff].pack("VV")
    end

    # Rack::ETag digested `body` whole (it has no recorded parts): #gzip_digested may reuse a
    # stored gzip member for it. Front.deflate takes the mark back (#take_digested) on every
    # response, gzipped or not, so it never keeps a body past its response.
    def digested(body, digest)
      Ractor[:page_body_digest] = [body, digest] if body.bytesize >= MIN_FRAGMENT
      nil
    end

    def take_digested
      d = Ractor[:page_body_digest] or return
      Ractor[:page_body_digest] = nil
      d
    end

    # The gzip member of the body `mark` (from #take_digested) names, compressed once per
    # distinct body; nil for any other body.
    def gzip_digested(body, mark)
      return unless mark && mark[0].equal?(body)
      key = GZIP_KEY + mark[1]
      s = store
      s[key] || (gz = Zlib.gzip(body).freeze; s.store(key, gz, gz.bytesize + ENTRY_OVERHEAD))
    end

    def store = (Ractor[:page_part_store] ||= Generations.new(STORE_BUDGET))

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

    # The SHA-256 of each text part, once per page: [before fragment 1, before fragment 2, ...,
    # after the last], nil where there is no text.
    def text_digests(body, rec)
      memo = Ractor[:page_text_digests]
      return memo[1] if memo && memo[0].equal?(rec)
      texts = []
      pos = 0
      i = 1
      while i < rec.size
        off = rec[i]
        texts << (off > pos ? OpenSSL::Digest.digest("SHA256", body.byteslice(pos, off - pos)) : nil)
        pos = off + rec[i + 1].bytesize
        i += 2
      end
      texts << (pos < body.bytesize ? OpenSSL::Digest.digest("SHA256", body.byteslice(pos, body.bytesize - pos)) : nil)
      Ractor[:page_text_digests] = [rec, texts]
      texts
    end

    def fragment_digest(frag)
      digests = (Ractor[:page_part_digests] ||= {}.compare_by_identity)
      digests.clear if digests.size > MAX_FRAGMENTS
      digests[frag] ||= OpenSSL::Digest.digest("SHA256", frag)
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

    # The text part at pos, compressed against the fragment `pred` that ends where it starts (nil
    # at the start of the page), kept by its digest and that fragment's.
    def text(out, body, pos, len, pred, digest, crc)
      key = TEXT_KEY + digest
      key << fragment_digest(pred) if pred
      s = store
      e = s[key] || begin
        data = body.byteslice(pos, len)
        dict = pred && (pred.bytesize > WINDOW ? pred.byteslice(pred.bytesize - WINDOW, WINDOW) : pred)
        deflated = deflate(data, dict).freeze
        s.store(key, [deflated, Zlib.crc32(data)].freeze, deflated.bytesize + ENTRY_OVERHEAD)
      end
      out << e[0]
      Zlib.crc32_combine(crc, e[1], len)
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
