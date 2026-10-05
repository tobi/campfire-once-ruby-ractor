# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/campfire/http"
require_relative "../lib/campfire/multipart"

class MultipartTest < Minitest::Test
  MP = Campfire::Multipart
  BOUNDARY = "----WebKitFormBoundaryx8Gk3hQ2"
  CT = "multipart/form-data; boundary=#{BOUNDARY}"

  def setup
    @dir = Dir.mktmpdir("mp")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def body(*parts)
    s = +""
    parts.each { |headers, data| s << "--#{BOUNDARY}\r\n" << headers << "\r\n\r\n" << data << "\r\n" }
    s << "--#{BOUNDARY}--\r\n"
  end

  def field(name, value) = [%(Content-Disposition: form-data; name="#{name}"), value]

  def file(name, filename, data, type = "image/png")
    [%(Content-Disposition: form-data; name="#{name}"; filename="#{filename}"\r\nContent-Type: #{type}), data]
  end

  def parse(b, ct = CT) = MP.parse(b.dup.force_encoding(Encoding::UTF_8), ct, {}, tmpdir: @dir)

  def test_fields_nest_like_rails
    p = parse(body(field("_method", "patch"), field("authenticity_token", "abc"),
      field("user[name]", "Dávid"), field("user_ids[]", "1"), field("user_ids[]", "2"),
      field("account[settings][restrict_room_creation_to_administrators]", "true")))
    assert_equal "patch", p["_method"]
    assert_equal({ "name" => "Dávid" }, p["user"])
    assert_equal Encoding::UTF_8, p["user"]["name"].encoding
    assert_equal %w[1 2], p["user_ids"]
    assert_equal "true", p["account"]["settings"]["restrict_room_creation_to_administrators"]
  end

  def test_file_part_is_written_to_tempfile
    png = "\x89PNG\r\n\x1a\n\x00\x00\r\n--not-a-boundary\xff\xfe".b
    p = parse(body(field("user[name]", "x"), file("user[avatar]", "me.png", png)))
    f = p["user"]["avatar"]
    assert_kind_of MP::UploadedFile, f
    assert_equal "me.png", f.filename
    assert_equal "image/png", f.content_type
    assert_equal png.bytesize, f.size
    assert_equal png, File.binread(f.path)
    assert f.path.start_with?(@dir)
    assert_equal png, f.read
  end

  def test_empty_file_input_assigns_nil
    p = parse(body(file("user[avatar]", "", "", "application/octet-stream"), field("user[bio]", "")))
    assert p["user"].key?("avatar")
    assert_nil p["user"]["avatar"]
    assert_equal "", p["user"]["bio"]
  end

  def test_strips_client_directories_from_filename
    p = parse(body(file("a", 'C:\\Users\\me\\Desktop\\logo.png', "x"), file("b", "dir/sub/ü.gif", "y")))
    assert_equal "logo.png", p["a"].filename
    assert_equal "ü.gif", p["b"].filename
  end

  def test_rfc5987_filename
    b = body([%(Content-Disposition: form-data; name="f"; filename*=UTF-8''na%C3%AFve.txt), "z"])
    assert_equal "naïve.txt", parse(b)["f"].filename
  end

  def test_quoted_boundary_and_case_insensitive_headers
    b = body([%(content-disposition: form-data; name="x"), "1"])
    p = parse(b, %(multipart/form-data; boundary="#{BOUNDARY}"; charset=utf-8))
    assert_equal "1", p["x"]
  end

  def test_missing_content_type_defaults_to_octet_stream
    b = body([%(Content-Disposition: form-data; name="f"; filename="a.bin"), "q"])
    assert_equal "application/octet-stream", parse(b)["f"].content_type
  end

  def test_values_containing_crlf_and_dashes
    v = "line1\r\nline2\r\n--#{BOUNDARY}x not the end"
    # The delimiter is CRLF + "--boundary" followed by CRLF/--; a value can
    # contain the boundary string only if not preceded by CRLF. Use a safe value.
    v = "line1\r\nline2\r\n-- dashes --"
    assert_equal v, parse(body(field("t", v)))["t"]
  end

  def test_preamble_and_epilogue_are_ignored
    b = "preamble junk\r\n" + body(field("a", "1")) + "epilogue"
    assert_equal({ "a" => "1" }, parse(b))
  end

  def test_restores_body_encoding
    b = body(field("a", "1")).force_encoding(Encoding::UTF_8)
    MP.parse(b, CT, {}, tmpdir: @dir)
    assert_equal Encoding::UTF_8, b.encoding
  end

  def test_merges_into_existing_params
    into = { "user_id" => "me" }
    MP.parse(body(field("user[name]", "z")), CT, into, tmpdir: @dir)
    assert_equal({ "user_id" => "me", "user" => { "name" => "z" } }, into)
  end

  def test_missing_boundary_raises
    assert_raises(MP::ParseError) { parse(body(field("a", "1")), "multipart/form-data") }
  end

  def test_truncated_body_raises
    assert_raises(MP::ParseError) { parse("--#{BOUNDARY}\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nunterminated") }
  end

  def test_allocation_light_for_text_fields
    b = body(*Array.new(50) { |i| field("f#{i}", "v" * 100) }).force_encoding(Encoding::UTF_8)
    MP.parse(b, CT, {}, tmpdir: @dir) # warm up
    before = GC.stat(:total_allocated_objects)
    MP.parse(b, CT, {}, tmpdir: @dir)
    allocated = GC.stat(:total_allocated_objects) - before
    # Per field: name + value strings (+ hash growth); the scan itself is free.
    assert_operator allocated, :<, 50 * 3 + 20
  end
end
