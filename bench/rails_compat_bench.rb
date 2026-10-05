# frozen_string_literal: true

# Micro-benchmark for the per-request Rails crypto paths.
#
#   mise exec -- ruby -Ilib bench/rails_compat_bench.rb          # interpreter
#   mise exec -- ruby --yjit -Ilib bench/rails_compat_bench.rb   # YJIT
#
# Prints ops/sec and allocated objects per op (GC.stat delta).

require_relative "../lib/campfire/rails_compat"

RC = Campfire::RailsCompat
SECRETS = RC::Secrets.new("5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995")
NOW = Time.now
EXP = SECRETS.permanent_expiry(NOW)

TOKEN = "e5XWBGGnEJqiHpVCZzbj6bra"
SIGNED = SECRETS.sign_cookie("session_token", TOKEN, expires: EXP)
CSRF_SESSION = RC::CSRF.generate_session_token
SESSION = { "session_id" => "6d3a2b1c0f9e8d7c6b5a493827161504", "_csrf_token" => CSRF_SESSION }
ENCRYPTED = SECRETS.encrypt_cookie("_campfire_session", SESSION, expires: EXP)
HEADER = "last_room=3; session_token=#{RC.escape_cookie(SIGNED)}; _campfire_session=#{RC.escape_cookie(ENCRYPTED)}"
MASKED = RC::CSRF.masked_token(CSRF_SESSION)
FORM = RC::CSRF.masked_token(CSRF_SESSION, action: "/rooms/1/messages", method: "post", request_path: "/rooms/1")
SIGNED_ID = SECRETS.signed_id("User", 1, purpose: "avatar")
STREAM = SECRETS.signed_stream_name(RC::GID.build("Rooms::Open", 1).to_param, "messages")
SGID = SECRETS.attachable_sgid("User", 1)

raise "setup" unless SECRETS.verify_cookie("session_token", SIGNED) == TOKEN &&
  SECRETS.decrypt_cookie("_campfire_session", ENCRYPTED) == SESSION &&
  RC::CSRF.valid_authenticity_token?(CSRF_SESSION, MASKED) &&
  RC::CSRF.valid_authenticity_token?(CSRF_SESSION, FORM, request_path: "/rooms/1/messages", request_method: "POST")

def bench(label, seconds: 0.5)
  200.times { yield } # warm up (and YJIT compile)
  n = 0
  GC.start
  allocs0 = GC.stat(:total_allocated_objects)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = t0 + seconds
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    100.times { yield }
    n += 100
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  allocs = GC.stat(:total_allocated_objects) - allocs0
  printf("  %-44s %11.0f ops/s %8.2f us/op %6.1f allocs/op\n", label, n / elapsed, elapsed / n * 1e6, allocs.to_f / n)
end

yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "YJIT" : "interpreter"
puts "RailsCompat bench (#{RUBY_DESCRIPTION}, #{yjit})"
bench("cookie_value(header, 'session_token')") { RC.cookie_value(HEADER, "session_token") }
bench("verify_cookie session_token") { SECRETS.verify_cookie("session_token", SIGNED, now: NOW) }
bench("cookie_value + verify_cookie") { SECRETS.verify_cookie("session_token", RC.cookie_value(HEADER, "session_token"), now: NOW) }
bench("sign_cookie session_token (permanent)") { SECRETS.sign_cookie("session_token", TOKEN, expires: EXP) }
bench("decrypt_cookie _campfire_session") { SECRETS.decrypt_cookie("_campfire_session", ENCRYPTED, now: NOW) }
bench("encrypt_cookie _campfire_session") { SECRETS.encrypt_cookie("_campfire_session", SESSION, expires: EXP) }
bench("csrf mask (global)") { RC::CSRF.masked_token(CSRF_SESSION) }
bench("csrf mask (per-form)") { RC::CSRF.masked_token(CSRF_SESSION, action: "/rooms/1/messages", method: "post", request_path: "/rooms/1") }
bench("csrf verify (masked global)") { RC::CSRF.valid_authenticity_token?(CSRF_SESSION, MASKED, request_path: "/rooms/1/messages", request_method: "POST") }
bench("csrf verify (per-form, worst case)") { RC::CSRF.valid_authenticity_token?(CSRF_SESSION, FORM, request_path: "/rooms/1/messages", request_method: "POST") }
bench("verify_signed_id avatar") { SECRETS.verify_signed_id(SIGNED_ID, model_name: "User", purpose: "avatar", now: NOW) }
bench("verified_stream_name") { SECRETS.verified_stream_name(STREAM) }
bench("verify_sgid attachable") { SECRETS.verify_sgid(SGID, purpose: "attachable", now: NOW) }
bench("escape_cookie(signed)") { RC.escape_cookie(SIGNED) }
