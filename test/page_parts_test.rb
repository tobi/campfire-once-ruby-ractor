# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/campfire/page_parts"

class PagePartsTest < Minitest::Test
  PP = Campfire::PageParts

  def setup
    %i[page_parts page_parts_valid page_part_pieces page_part_digests].each { |k| Ractor[k] = nil }
    @frags = Array.new(12) { |i| (+"<div id=\"message_#{i}\">" << ("lorem ipsum #{i} dolor " * (60 + i * 7)) << "</div>\n").freeze }
  end

  def page(csrf, frags = @frags, glue = "")
    b = +"<html><head><meta name=\"csrf-token\" content=\"#{csrf}\"></head><body>" << ("<nav>layout</nav>" * 300)
    frags.each_with_index { |f, i| b << glue if i > 0; PP.record(b, f); b << f }
    b << "<form><input value=\"#{csrf}\"></form></body></html>"
  end

  def test_gzip_round_trips_and_reuses_pieces
    2.times do |n|
      body = page("token#{n}", @frags, n.zero? ? "" : "\n  ")
      rec = PP.of(body)
      refute_nil rec
      gz = PP.gzip(body, rec)
      assert_equal body.b, Zlib.gunzip(gz).b
    end
    body = page("token2")
    assert_equal body.b, Zlib.gunzip(PP.gzip(body, PP.of(body))).b, "pieces cached by the first page"
    reordered = page("token3", @frags.reverse)
    assert_equal reordered.b, Zlib.gunzip(PP.gzip(reordered, PP.of(reordered))).b, "other predecessors, other pieces"
  end

  def test_digest_follows_the_content
    a = page("same")
    da = PP.digest(a, PP.of(a))
    b = page("same")
    assert_equal da, PP.digest(b, PP.of(b))
    c = page("same", @frags[0..-2] + ["#{@frags[-1]}x".freeze])
    refute_equal da, PP.digest(c, PP.of(c))
    d = page("other")
    refute_equal da, PP.digest(d, PP.of(d))
  end

  def test_parts_that_no_longer_match_the_body_are_ignored
    body = page("t")
    body[0, 0] = "x" # shifts every recorded offset
    assert_nil PP.of(body)
    assert_nil PP.of(+"unrelated")
  end
end
