# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/campfire/page_parts"

class PagePartsTest < Minitest::Test
  PP = Campfire::PageParts

  def setup
    %i[page_parts page_parts_valid page_part_pieces page_part_digests page_text_digests page_part_store page_body_digest].each { |k| Ractor[k] = nil }
    @frags = Array.new(12) { |i| (+"<div id=\"message_#{i}\">" << ("lorem ipsum #{i} dolor " * (60 + i * 7)) << "</div>\n").freeze }
  end

  def page(title, frags = @frags, glue = "", middle: nil)
    b = +"<html><head><title>#{title}</title></head><body>" << ("<nav>layout</nav>" * 300)
    frags.each_with_index do |f, i|
      b << glue if i > 0
      b << middle if middle && i == frags.size / 2
      PP.record(b, f)
      b << f
    end
    b << "<form><input value=\"#{title}\"></form></body></html>"
  end

  def gunzip(body) = Zlib.gunzip(PP.gzip(body, PP.of(body))).b

  def test_gzip_round_trips_and_reuses_pieces
    2.times do |n|
      body = page("title#{n}", @frags, n.zero? ? "" : "\n  ")
      assert_equal body.b, gunzip(body)
    end
    body = page("title0")
    assert_equal body.b, gunzip(body), "every part stored by the first page"
    reordered = page("title0", @frags.reverse)
    assert_equal reordered.b, gunzip(reordered), "other predecessors, other pieces"
  end

  # A text part is compressed against the fragment before it, so the same text after another
  # fragment needs its own piece.
  def test_the_same_text_after_other_fragments
    middle = "<aside>#{"between runs " * 40}</aside>"
    a = page("t", @frags, middle: middle)
    assert_equal a.b, gunzip(a)
    b = page("t", @frags.rotate(3), middle: middle)
    assert_equal b.b, gunzip(b)
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

  def test_whole_body_gzip_only_for_the_body_that_was_digested
    body = ("<li>sidebar</li>" * 200).freeze
    assert_nil PP.take_digested
    PP.digested(body, OpenSSL::Digest.digest("SHA256", body))
    mark = PP.take_digested
    assert_nil PP.take_digested, "taken once: the mark never outlives its response"
    assert_nil PP.gzip_digested(body.dup, mark), "another String with the same bytes isn't the digested body"
    assert_equal body, Zlib.gunzip(PP.gzip_digested(body, mark))
    assert_same PP.gzip_digested(body, mark), PP.gzip_digested(body, mark), "compressed once"
  end

  def test_generations_stay_within_budget_and_keep_what_is_used
    g = PP::Generations.new(64 * 1024)
    g.store("big", "x", 2048) # over 1/64 of the budget
    assert_nil g["big"]
    g.store("hot", "h", 1000)
    200.times do |i|
      g.store("k#{i}", "v", 1000)
      assert_equal "h", g["hot"], "used every time, so it moves back to the young generation" if i % 20 == 0
    end
    assert_operator g.size, :<=, 66
    assert_nil g["k0"]
    assert_equal "v", g["k199"]
  end
end
