# frozen_string_literal: true

# Active Storage port: URL/signature parity with the reference app's HTML,
# variant digests against the seed's variant_records, byte ranges, the HTTP
# handlers, and variant generation in a job Ractor (libvips output must be
# byte-identical to the Rails seed's variants).
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/campfire"
require_relative "../lib/campfire/storage"

module StorageTestBoot
  ROOT = File.expand_path("..", __dir__)
  SEED = File.join(ROOT, "tmp/seed")
  SECRET = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
  DIR = Dir.mktmpdir("storage-test")
  FileUtils.cp_r(File.join(SEED, "db"), DIR)
  FileUtils.cp_r(File.join(SEED, "storage"), DIR)
  Minitest.after_run { FileUtils.remove_entry(DIR) }

  config = Campfire::Config.from_env(
    "SECRET_KEY_BASE" => SECRET, "CAMPFIRE_DATABASE_PATH" => File.join(DIR, "db/production.sqlite3"),
    "CAMPFIRE_FILES_PATH" => File.join(DIR, "storage")
  )
  Campfire.const_set(:CONFIG, Ractor.make_shareable(config))
  Campfire.const_set(:SECRETS, Campfire::RailsCompat::Secrets.new(SECRET))

  # Proves where a job ran.
  module WhereJob
    def self.perform = Ractor.current == Ractor.main ? "main" : Ractor.current.name
  end
  Campfire::Jobs.register(:storage_test_where, WhereJob)

  # URL helpers as a request worker Ractor would call them.
  module UrlsJob
    def self.perform(id)
      s = Campfire::Storage
      b = s.find(Campfire::DB.connection, id)
      [s.blob_path(b), s.representation_path(b, s::THUMB), s.disk_path(b)[0, 27]].freeze
    end
  end
  Campfire::Jobs.register(:storage_test_urls, UrlsJob)
  RactorCompat.share_constants!(extra_roots: [Campfire, Extralite, ERB])
  Campfire::Jobs.start(1, Campfire::CONFIG)
end

class StorageTest < Minitest::Test
  S = Campfire::Storage
  FIXTURE = File.read(File.join(__dir__, "fixtures/storage/room_654632876.html"))
  MOON_THUMB_CHECKSUM = "p7Xvr8seqToD36kDFhsGng=="

  def db = Campfire::DB.connection
  def blob(id) = S.find(db, id)

  def request(path, method: "GET", headers: [], body: nil)
    Protocol::HTTP::Request.new("http", "127.0.0.1:3100", method, path, "HTTP/1.1",
      Protocol::HTTP::Headers.new(headers), body)
  end

  def dispatch(req)
    path, query = req.path.split("?", 2)
    S.call(req, path, query)
  end

  # The header value as written on the wire (Headers#[] re-joins split values).
  def raw(response, name) = response.headers.to_a.find { |k, _| k == name }&.last

  def body_of(response) = response.body ? response.body.join.to_s.b : "".b

  # ---- URL parity ----------------------------------------------------------

  def test_urls_match_reference_html
    expected = FIXTURE.scan(%r{/rails/active_storage/(?:blobs|representations)/redirect/[^":\s)]+[^"\s)]*}).uniq.sort
    expected.map! { |u| u.gsub("&amp;", "&") }
    ours = []
    [5, 7, 9, 13, 14].each do |id|
      b = blob(id)
      ours << S.blob_path(b) << S.blob_path(b, disposition: "attachment")
    end
    ours << S.representation_path(blob(5), S::THUMB) << S.representation_path(blob(7), S::THUMB)
    ours << S.preview_path(blob(9), S::VIDEO_POSTER)
    assert_equal 13, expected.size
    assert_equal expected, ours.uniq.sort
  end

  def test_signed_id_round_trip
    sid = "eyJfcmFpbHMiOnsiZGF0YSI6NSwicHVyIjoiYmxvYl9pZCJ9fQ==--4ceb3a7460a929db324ca5fd0dffee9c8527bfad"
    assert_equal sid, S.signed_id(5)
    assert_equal sid, S.signed_id(blob(5))
    assert_equal 5, S.verify_signed_id(sid)
    assert_equal 5, S.find_signed(db, sid).id
    assert_equal 1234567, S.verify_signed_id(S.signed_id(1234567))
    assert_nil S.verify_signed_id(sid.sub("4ceb", "4cec"))
    assert_nil S.verify_signed_id(sid.sub("NSwi", "Niwi"))
    assert_nil S.verify_signed_id("garbage")
    assert_nil S.verify_signed_id(S.variation_key({ format: "jpg" })) # wrong purpose
  end

  def test_variation_key_round_trip
    v = { format: "jpg", resize_to_limit: [1200, 800] }
    key = S.variation_key(v)
    assert_equal "eyJfcmFpbHMiOnsiZGF0YSI6eyJmb3JtYXQiOiJqcGciLCJyZXNpemVfdG9fbGltaXQiOlsxMjAwLDgwMF19LCJwdXIiOiJ2YXJpYXRpb24ifX0=--28426ca1e33b0fea71b8b10b7f52a844de5886cf", key
    assert_equal v, S::Variation.decode(key)
    assert_equal({ format: "webp" }, S::Variation.decode(S::Variation.encode({ format: :webp })))
    assert_nil S::Variation.decode(S.signed_id(5))
    assert_nil S::Variation.decode(key.sub("--2", "--3"))
  end

  def test_variation_default_to
    assert_equal [:format, :resize_to_limit], S::Variation.default_to(S::THUMB, "jpg").keys
    assert_equal :webp, S::Variation.default_to(S::SQUARE, "jpg")[:format]
    assert_equal({ format: :webp, resize_to_limit: [1, 2] }, S::Variation.default_to({ resize_to_limit: [1, 2], format: :webp }, "jpg"))
    assert_equal [1200, 800], S::Variation.resize_to_limit(S::THUMB)
    assert_nil S::Variation.resize_to_limit(S::PREVIEW_WEBP)
    assert_raises(ArgumentError) { S::Variation.resize_to_limit({ rotate: 90 }) }
    assert_nil S::Variation.format({ format: "exe" })
    assert_equal "png", S::Variation.format({})
  end

  # Every active_storage_variant_records row of the seed, from the named
  # variations the app uses (Symbols in-app, blob default format applied).
  def test_variant_digests_match_seed
    seed = Extralite::Database.new(File.join(StorageTestBoot::SEED, "db/production.sqlite3"), read_only: true)
    rows = seed.query_array("SELECT blob_id, variation_digest FROM active_storage_variant_records ORDER BY id")
    seed.close
    ours = rows.map do |blob_id, _|
      b = blob(blob_id)
      case blob_id
      when 1, 3 then [blob_id, S::Variation.digest(S::Variation.default_to(S::SQUARE, b.default_variant_format))]
      when 5, 7 then [blob_id, S::Variation.digest(S::Variation.default_to(S::THUMB, b.default_variant_format))]
      end
    end
    preview = blob(10)
    ours.compact!
    ours << [10, S::Variation.digest(S::Variation.default_to(S::PREVIEW_WEBP, preview.default_variant_format))]
    ours << [10, S::Variation.digest(S::Variation.default_to(S::VIDEO_POSTER, preview.default_variant_format))]
    assert_equal 6, rows.size
    assert_equal rows.sort, ours.sort
  end

  def test_default_variant_formats
    assert_equal "jpg", blob(5).default_variant_format
    assert_equal :png, blob(14).default_variant_format
    refute blob(14).variable? # config/initializers/vips.rb removes image/bmp
    refute blob(14).representable?
    refute blob(13).representable?
    assert blob(9).previewable?
  end

  def test_existing_variants_and_attachments
    assert_equal 5, S.attached(db, "Message", 933434498, "attachment").id
    assert_nil S.attached(db, "Message", 1, "attachment")
    many = S.attached_many(db, "User", [149087659, 773523956, 1], "avatar")
    assert_equal({ 149087659 => 1, 773523956 => 3 }, many.transform_values(&:id))
    assert_equal S.path_for(blob(2).key), S.variant_path_for(db, blob(1), :square)
    assert_equal 12, S.representation(db, blob(9), S::VIDEO_POSTER).id
    assert_equal "f41i6Z376J8tfJGLMf6SEw==", S.representation(db, blob(9), S::PREVIEW_WEBP).checksum # id varies if regenerated first
    assert_equal 10, S.representation(db, blob(9), {}).id
    assert_nil S.representation(db, blob(13), S::THUMB)
  end

  def test_path_for
    assert_equal File.join(S.root, "2k/7n/2k7n5s996jb5k5xwhx14f5oetpj4"), S.path_for("2k7n5s996jb5k5xwhx14f5oetpj4")
    assert File.file?(S.path_for(blob(1).key))
    assert_raises(ArgumentError) { S.path_for("../etc/passwd") }
    assert_raises(ArgumentError) { S.path_for("a") }
  end

  def test_filename_and_disposition
    assert_equal "a-b.txt", S.sanitize_filename("a/b.txt")
    assert_equal %(inline; filename="moon.jpg"; filename*=UTF-8''moon.jpg), S.content_disposition("inline", "moon.jpg")
    assert_equal %(attachment; filename="Caf%3F.txt"; filename*=UTF-8''Caf%C3%A9.txt).sub("%3F", "e"),
      S.content_disposition("attachment", "Café.txt")
  end

  def test_disk_path_token
    now = Time.at(1_700_000_000)
    path = S.disk_path(blob(5), now: now)
    assert path.start_with?("/rails/active_storage/disk/")
    assert path.end_with?("/moon.jpg")
    token = S.unescape_segment(path.split("/")[4])
    payload = S.verifier.verified(token, purpose: "blob_key", now: now)
    assert_equal({ "key" => blob(5).key, "disposition" => %(inline; filename="moon.jpg"; filename*=UTF-8''moon.jpg),
                   "content_type" => "image/jpeg", "service_name" => "local" }, payload)
    assert_nil S.verifier.verified(token, purpose: "blob_key", now: now + 301)
    # Types outside content_types_allowed_inline are forced to attachment.
    txt = S.verifier.verified(S.unescape_segment(S.disk_path(blob(13), now: now).split("/")[4]), purpose: "blob_key", now: now)
    assert txt["disposition"].start_with?("attachment;")
    assert_equal "text/plain", txt["content_type"]
  end

  # ---- ranges ----------------------------------------------------------------

  def test_byte_ranges
    r = ->(h, size = 100) { S::Serve.byte_ranges(h, size) }
    assert_nil r.(nil)
    assert_nil r.("bytes=0-9", 0)
    assert_equal [[0, 9]], r.("bytes=0-9")
    assert_equal [[90, 99]], r.("bytes=-10")
    assert_equal [[0, 99]], r.("bytes=-500")
    assert_equal [[90, 99]], r.("bytes=90-")
    assert_equal [[95, 99]], r.("bytes=95-200")
    assert_equal [], r.("bytes=200-300")
    assert_nil r.("bytes=5-2")
    assert_nil r.("items=0-1")
    assert_nil r.("bytes=5")
    assert_equal [[0, 1], [5, 6]], r.("bytes=0-1, 5-6")
    assert_equal [], r.("bytes=0-99,0-99")
    assert_nil r.("bytes=" + (["0-0"] * 101).join(","))
    assert_equal [[1, 2]], r.("bytes=+1-0d2")
  end

  # ---- HTTP ------------------------------------------------------------------

  def test_blob_redirect
    res = dispatch(request(S.blob_path(blob(5))))
    assert_equal 302, res.status
    assert_equal "max-age=300, private", raw(res, "cache-control")
    loc = res.headers["location"].to_s
    assert_match %r{\Ahttp://127\.0\.0\.1:3100/rails/active_storage/disk/[^/]+/moon\.jpg\z}, loc
    res = dispatch(request(URI(loc).path))
    assert_equal 200, res.status
    assert_equal File.binread(S.path_for(blob(5).key)), body_of(res)
    assert_equal "image/jpeg", res.headers["content-type"].to_s
  end

  def test_blob_redirect_attachment_disposition
    loc = dispatch(request(S.blob_path(blob(5), disposition: "attachment"))).headers["location"].to_s
    token = S.unescape_segment(URI(loc).path.split("/")[4])
    assert S.verifier.verified(token, purpose: "blob_key")["disposition"].start_with?("attachment;")
  end

  def test_representation_redirect_uses_existing_variant
    res = dispatch(request(S.representation_path(blob(7), S::THUMB)))
    assert_equal 302, res.status
    token = S.unescape_segment(URI(res.headers["location"].to_s).path.split("/")[4])
    assert_equal blob(8).key, S.verifier.verified(token, purpose: "blob_key")["key"]
  end

  def test_disk_get_range
    path = S.disk_path(blob(5))
    data = File.binread(S.path_for(blob(5).key))
    res = dispatch(request(path, headers: [["range", "bytes=0-9"]]))
    assert_equal 206, res.status
    assert_equal "bytes 0-9/#{data.bytesize}", res.headers["content-range"].to_s
    assert_equal data.byteslice(0, 10), body_of(res)

    res = dispatch(request(path, headers: [["range", "bytes=0-1,-2"]]))
    assert_equal 206, res.status
    body = body_of(res)
    assert_equal res.body.length, body.bytesize if res.body.respond_to?(:length) && res.body.length
    assert_includes body, "content-range: bytes 0-1/#{data.bytesize}"
    assert_includes body, "\r\n--AaB03x--\r\n"

    res = dispatch(request(path, headers: [["range", "bytes=99999-"]]))
    assert_equal 416, res.status
    assert_equal "bytes */#{data.bytesize}", res.headers["content-range"].to_s
  end

  def test_proxy_range_and_etag
    path = S.blob_path(blob(5)).sub("/redirect/", "/proxy/")
    res = dispatch(request(path))
    assert_equal 200, res.status
    assert_equal "max-age=3155695200, public, immutable", raw(res, "cache-control")
    etag = res.headers["etag"].to_s
    assert etag.start_with?('W/"')
    body_of(res)
    assert_equal 304, dispatch(request(path, headers: [["if-none-match", etag]])).status
    res = dispatch(request(path, headers: [["range", "bytes=10-19"]]))
    assert_equal 206, res.status
    assert_equal File.binread(S.path_for(blob(5).key)).byteslice(10, 10), body_of(res)
  end

  def test_bad_tokens_are_404
    assert_equal 404, dispatch(request("/rails/active_storage/disk/bogus/moon.jpg")).status
    assert_equal 404, dispatch(request("/rails/active_storage/blobs/redirect/bogus/moon.jpg")).status
    assert_equal 404, dispatch(request("/rails/active_storage/representations/redirect/#{S.signed_id(5)}/bogus/moon.jpg")).status
    assert_equal 404, dispatch(request("/rails/active_storage/nope")).status
    expired = S.disk_path(blob(5), now: Time.now - 3600)
    assert_equal 404, dispatch(request(expired)).status
  end

  def test_uploads_require_session_and_same_site_requests
    uploads = "/rails/active_storage/direct_uploads"
    assert_equal 422, dispatch(request(uploads, method: "POST", headers: [["sec-fetch-site", "cross-site"]])).status
    assert_equal 422, dispatch(request(uploads, method: "POST", headers: [["origin", "http://evil.example"]])).status
    assert_equal 401, dispatch(request(uploads, method: "POST", headers: [["sec-fetch-site", "same-origin"]])).status
    assert_equal 401, dispatch(request(S.upload_path(blob(13)), method: "PUT")).status
  end

  def test_mime_identify
    jpeg = File.binread(S.path_for(blob(5).key), 4096)
    assert_equal "image/jpeg", S::Mime.identify(jpeg, "x.bin", "application/octet-stream")
    assert_equal "image/png", S::Mime.identify("\x89PNG\r\n\x1a\n".b + "\0" * 16, "x", nil)
    assert_equal "text/plain", S::Mime.identify("hello", "notes.txt", nil)
    assert_equal "image/webp", S::Mime.for_extension("webp")
  end

  # ---- jobs / Ractors ----------------------------------------------------------

  def test_jobs_run_in_non_main_ractor
    assert_equal "jobs-0", Campfire::Jobs.call(:storage_test_where)
  end

  def test_url_helpers_in_non_main_ractor
    b = blob(7)
    assert_equal [S.blob_path(b), S.representation_path(b, S::THUMB), "/rails/active_storage/disk/"], Campfire::Jobs.call(:storage_test_urls, 7)
  end

  # Drops the seed's thumb of blob 5 and regenerates it through Jobs.call in
  # the job Ractor; libvips output must be the seed's exact bytes.
  def test_thumbnail_generated_in_job_ractor_matches_seed
    db.execute("DELETE FROM active_storage_attachments WHERE record_type = 'ActiveStorage::VariantRecord' AND record_id = 3")
    db.execute("DELETE FROM active_storage_variant_records WHERE id = 3")
    assert_nil S.existing_variant(db, 5, "IBhrLAIapu+NCId+2Kz6EqUWRKY=")
    image = S.representation(db, blob(5), S::THUMB)
    refute_nil image
    refute_equal 6, image.id
    assert_equal "moon.jpg", image.filename
    assert_equal "image/jpeg", image.content_type
    assert_equal MOON_THUMB_CHECKSUM, image.checksum
    assert_equal MOON_THUMB_CHECKSUM, Digest::MD5.file(S.path_for(image.key)).base64digest
    assert_equal image.id, S.existing_variant(db, 5, "IBhrLAIapu+NCId+2Kz6EqUWRKY=").id
    # Second request finds it without a job.
    assert_equal image.id, S.representation(db, blob(5), S::THUMB).id
  end

  # The video preview webp (variant of the poster jpg), regenerated in the
  # job Ractor; must match the seed blob 11 bytes.
  def test_preview_webp_regenerated_in_job_ractor_matches_seed
    db.execute("DELETE FROM active_storage_attachments WHERE record_type = 'ActiveStorage::VariantRecord' AND record_id = 5")
    db.execute("DELETE FROM active_storage_variant_records WHERE id = 5")
    image = S.representation(db, blob(9), S::PREVIEW_WEBP)
    refute_equal 11, image.id
    assert_equal ["alpha-centuri.webp", "image/webp", "f41i6Z376J8tfJGLMf6SEw=="], [image.filename, image.content_type, image.checksum]
  end

  # Upload + Message#process_attachment (analyze, then thumb) in the job Ractor.
  def test_process_attachment_in_job_ractor
    data = File.binread(S.path_for(blob(1).key))
    b = S.create_blob_from_upload(db, "moon.jpg", "application/octet-stream", data)
    assert_equal "image/jpeg", b.content_type
    assert_equal "j65kKv2abaidraFRfGAQlg==", b.checksum
    assert_equal b.id, S.process_attachment(b.id)
    b = blob(b.id)
    assert_equal({ "identified" => true, "width" => 640, "height" => 640, "analyzed" => true }, JSON.parse(b.metadata))
    thumb = S.existing_variant(db, b.id, S::Variation.digest(S::Variation.default_to(S::THUMB, "jpg")))
    assert_equal MOON_THUMB_CHECKSUM, thumb.checksum
  end
end
