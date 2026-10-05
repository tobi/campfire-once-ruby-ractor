# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/campfire/user_agent"

class UserAgentTest < Minitest::Test
  VECTORS = ENV.fetch("UA_VECTORS", "/home/tobi/src/once/ref-rust/vectors/campfire_user_agents.json")
  DATA = JSON.parse(File.read(VECTORS))
  UA = Campfire::UserAgent
  RAISED = UA::RAISED

  # Expected value from JSON -> comparable with ours (error hash => :error).
  def want(v) = v.is_a?(Hash) && v.key?("error") ? :error : v
  def got(v) = v == RAISED ? :error : v

  def attempt
    yield
  rescue UA::Error
    :error
  end

  def test_agent_vectors
    failures = []
    DATA["user_agents"].each do |c|
      a = UA.parse(c["ua"])
      p = Campfire::ApplicationPlatform.new(c["ua"])
      ap = c["application_platform"]
      actual = {
        "browser" => got(a.browser), "version" => got(a.version), "platform" => got(a.platform),
        "os" => got(a.os), "bot" => a.bot?, "mobile" => attempt { a.mobile? },
        "blocked" => got(a.blocked)
      }
      expected = c.slice("browser", "version", "platform", "os", "bot", "mobile", "blocked").transform_values { want(_1) }
      actual["blocked"] = :error if actual["blocked"] == :error
      expected.each { |k, v| failures << [c["ua"], k, v, actual[k]] unless v == actual[k] }

      pf = {
        "ios" => p.ios?, "android" => p.android?, "mac" => p.mac?, "mobile" => p.mobile?,
        "desktop" => p.desktop?, "apple_messages" => p.apple_messages?,
        "chrome" => attempt { p.chrome? }, "firefox" => attempt { p.firefox? },
        "safari" => attempt { p.safari? }, "edge" => attempt { p.edge? },
        "windows" => attempt { p.windows? }, "operating_system" => attempt { p.operating_system },
        "browser" => got(p.browser)
      }
      ap.each { |k, v| failures << [c["ua"], "ap.#{k}", want(v), pf[k]] unless want(v) == pf[k] }

      # allowed? is the public hot-path API; raised => fail open
      blocked = c["blocked"]
      allowed = blocked.is_a?(Hash) ? true : !blocked
      failures << [c["ua"], "allowed?", allowed, UA.allowed?(c["ua"])] unless UA.allowed?(c["ua"]) == allowed
    end
    assert_empty failures.first(15), "#{failures.size} failures of #{DATA['user_agents'].size} vectors"
  end

  def test_versions
    DATA["versions"].each do |v|
      assert_equal v["to_a"], UA::Version.parts(v["string"]), v["string"].inspect
      assert_equal v["nil"], UA::Version.blank?(v["string"]), v["string"].inspect
    end
  end

  def test_comparisons
    DATA["comparisons"].each do |v|
      cmp = UA::Version.compare(v["a"], v["b"])
      assert_equal v["cmp"], cmp, v.inspect
      assert_equal v["lt"], cmp.negative?, v.inspect
      assert_equal v["eq"], v["a"] == v["b"], v.inspect
    end
  end

  def test_constants_shareable
    UA.constants.each do |n|
      c = UA.const_get(n)
      next if c.is_a?(Module)

      assert Ractor.shareable?(c), n.to_s
    end
  end

  CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  OLD = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.0.0 Safari/537.36"
  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

  def test_ractor
    r = Ractor.new(CHROME, OLD, IPHONE) do |chrome, old, iphone|
      p = Campfire::Platform.new(iphone)
      [Campfire::UserAgent.allowed?(chrome), Campfire::UserAgent.allowed?(old),
       Campfire::UserAgent.allowed?(nil), p.ios?, p.mobile?, p.safari?, p.operating_system,
       Campfire::Platform.new(chrome).mac?, Campfire::Platform.new(chrome).chrome?]
    end
    assert_equal [true, false, true, true, true, true, "iPhone", true, true], r.value
  end
end
