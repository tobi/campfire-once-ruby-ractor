# frozen_string_literal: true

# Campfire::RichText against the reference vectors captured from the Rails app
# (ref-go/internal/richtext/testdata/rust.json.gz, 658 cases x 6 fields).
#
#   mise exec -- ruby -Ilib test/rich_text_test.rb
#   RICH_TEXT_VECTORS=/path/to/rust.json.gz mise exec -- ruby -Ilib test/rich_text_test.rb
#
# Infeasible cases: none -- every case passes on every field.
# Notes on how expectations are read:
#   * {"error": ...} expectations pass when the field raised
#     Campfire::RichText::Error. For presentation, Rails' MessagesHelper
#     rescues and renders nothing, so RichText.presentation returns "" (the one
#     "unrenderable" presentation vector, a missing attachable, is met that way).
#   * editable vectors with {"ok": null} (blank bodies) expect nil.
#   * mentioned_user_ids is checked twice: once with a verifier backed by the
#     vectors' "signed" table, once with the real HMAC SGID::Verifier keyed by
#     the reference SECRET_KEY_BASE.

require "minitest/autorun"
require "json"
require "zlib"
require_relative "../lib/campfire/rich_text"

class RichTextTest < Minitest::Test
  RT = Campfire::RichText
  PATH = ENV.fetch("RICH_TEXT_VECTORS", File.expand_path("../../ref-go/internal/richtext/testdata/rust.json.gz", __dir__))
  SECRET_KEY_BASE = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
  FIELDS = { "presentation" => :presentation, "plain_text" => :plain_text, "editable" => :editable,
             "filtered" => :filtered, "body_html" => :body_html, "mentioned" => :mentioned_user_ids }.freeze

  DATA = Ractor.make_shareable(JSON.parse(Zlib.gunzip(File.binread(PATH))))
  USERS = Ractor.make_shareable(DATA["users"].to_h do |u|
    [u["id"], RT::User.new(*u.values_at("id", "name", "title", "attachable_sgid", "user_path", "avatar_path"))]
  end)
  SIGNED = Ractor.make_shareable(DATA["signed"].to_h { |s| [s["sgid"], s] })
  HMAC = RT::SGID::Verifier.new(SECRET_KEY_BASE)

  # Shareable lambdas so they can cross into a Ractor.
  RESOLVER = Ractor.make_shareable(->(id) { USERS[id] })
  TABLE_VERIFIER = Ractor.make_shareable(lambda do |sgid|
    s = SIGNED[sgid]
    "gid://campfire/User/#{s["id"]}" if s && s["model"] == "User"
  end)

  def self.check(c, result)
    FIELDS.filter_map do |key, field|
      want = c[key]
      got = result[field]
      err = result.errors[field]
      ok = if want.key?("error")
        err || (field == :presentation && got == "")
      else
        !err && got == want["ok"]
      end
      [c["name"], key, want, err ? "#{err.class}: #{err.message}" : got] unless ok
    end
  end

  def run_vectors(verifier)
    pass = Hash.new(0)
    failures = DATA["cases"].flat_map do |c|
      result = RT.render(c["body"], host: c["host"], resolver: RESOLVER, verifier: verifier)
      bad = self.class.check(c, result)
      FIELDS.each_key { |k| pass[k] += 1 unless bad.any? { |b| b[1] == k } }
      bad
    end
    [pass, failures]
  end

  def report(label, pass, failures)
    total = DATA["cases"].size
    puts "\n#{label}: " + FIELDS.keys.map { |k| "#{k} #{pass[k]}/#{total}" }.join(", ")
    msg = failures.first(5).map { |n, k, w, g| "#{n} [#{k}]\n  want #{w.inspect[0, 400]}\n  got  #{g.inspect[0, 400]}" }
    assert_empty failures, "#{failures.size} field failures:\n#{msg.join("\n")}"
  end

  def test_vector_count
    assert_equal 658, DATA["cases"].size
  end

  def test_vectors_all_fields
    report("vectors (table verifier)", *run_vectors(TABLE_VERIFIER))
  end

  def test_vectors_all_fields_with_hmac_verifier
    report("vectors (HMAC verifier)", *run_vectors(HMAC))
  end

  # The single-field entry points must agree with render().
  def test_entry_points_match_render
    DATA["cases"].each do |c|
      body, host = c["body"], c["host"]
      r = RT.render(body, host: host, resolver: RESOLVER, verifier: TABLE_VERIFIER)
      assert_equal (r.errors[:presentation] ? "" : r.presentation), RT.presentation(body, host: host, resolver: RESOLVER), c["name"]
      {
        plain_text: -> { RT.plain_text(body, host: host, resolver: RESOLVER) },
        body_html: -> { RT.body_html(body, host: host, resolver: RESOLVER) },
        filtered: -> { RT.filtered(body, host: host, resolver: RESOLVER) },
        editable: -> { RT.editable(body, host: host, resolver: RESOLVER) },
        mentioned_user_ids: -> { RT.mentioned_user_ids(body, resolver: RESOLVER, verifier: TABLE_VERIFIER) }
      }.each do |field, call|
        if r.errors[field]
          assert_raises(RT::Error, "#{c["name"]} #{field}") { call.() }
        else
          assert_equal [r[field]], [call.()], "#{c["name"]} #{field}"
        end
      end
    end
  end

  def test_resolver_object
    finder = Object.new
    def finder.find_user(id) = RichTextTest::USERS[id]
    c = DATA["cases"].find { |k| k["body"].include?("vnd.campfire.mention") && k["presentation"]["ok"].to_s.include?("mention") }
    assert c, "no mention vector"
    assert_equal c["presentation"]["ok"], RT.presentation(c["body"], host: c["host"], resolver: finder)
  end

  def test_renders_inside_ractor
    names = DATA["cases"].map { |c| c["name"] }
    main = DATA["cases"].map do |c|
      r = RT.render(c["body"], host: c["host"], resolver: RESOLVER, verifier: TABLE_VERIFIER)
      [r.to_a[0, 6], r.errors.transform_values(&:message)]
    end
    inside = Ractor.new do
      RichTextTest::DATA["cases"].map do |c|
        r = Campfire::RichText.render(c["body"], host: c["host"], resolver: RichTextTest::RESOLVER, verifier: RichTextTest::TABLE_VERIFIER)
        [r.to_a[0, 6], r.errors.transform_values(&:message)]
      end
    end.value
    assert_equal main.size, inside.size
    main.zip(inside, names).each { |a, b, n| assert_equal a, b, n }
    bad = DATA["cases"].zip(inside).count { |c, (fields, _)| c["plain_text"]["ok"] && c["plain_text"]["ok"] != fields[1] }
    assert_equal 0, bad
  end

  def test_hmac_verifier_inside_ractor
    sgid = DATA["signed"].first["sgid"]
    got = Ractor.new(sgid) { |s| RichTextTest::HMAC.call(s) }.value
    assert_equal "gid://campfire/User/1?expires_in", got
  end

  def test_sgid_verifier_against_signed_table
    DATA["signed"].each do |s|
      gid = HMAC.call(s["sgid"])
      assert_equal "gid://campfire/User/#{s["id"]}?expires_in", gid, s["sgid"]
      assert_equal s["id"], RT::SGID.user_id(gid)
      assert_equal s["sgid"], HMAC.generate(gid)
      assert_equal s["exists"], USERS.key?(s["id"])
    end
    good = DATA["signed"].first["sgid"]
    assert_nil HMAC.call(good.sub(/.\z/) { |ch| ch == "0" ? "1" : "0" })
    assert_nil HMAC.call(good, purpose: "other")
    assert_nil HMAC.call("garbage")
    expiring = HMAC.generate("gid://campfire/User/1", expires_at: Time.utc(2030, 1, 1))
    assert_equal "gid://campfire/User/1", HMAC.call(expiring, now: Time.utc(2029, 1, 1))
    assert_nil HMAC.call(expiring, now: Time.utc(2031, 1, 1))
  end

  def test_all_emoji
    assert RT.all_emoji?("😀")
    assert RT.all_emoji?("👍🏽🎉")
    assert RT.all_emoji?("❤️")
    refute RT.all_emoji?("hi 😀")
    refute RT.all_emoji?("")
    refute RT.all_emoji?("123")
  end

  def test_shareable_constants
    [RT::Sanitizer, RT::DOM, RT::HTML5, RT::Autolink, RT::PlainText, RT::SGID].each do |mod|
      mod.constants.each do |name|
        value = mod.const_get(name)
        next if value.is_a?(Module)
        assert Ractor.shareable?(value), "#{mod}::#{name} is not shareable"
      end
    end
  end
end
