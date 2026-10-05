# Porting guide (read before touching app/)

Ruby 4.0.7 port of Campfire (`/home/tobi/src/once/upstream` is the source of truth).
It runs Falcon in N worker Ractors with no Rails, Rack or ActiveRecord. Architecture
follows the Go port (`/home/tobi/src/once/ref-go`): plain modules over SQLite, in-process
queues and an in-process cable hub. Here the queues are Ractors joined by message passing.
Goal: **byte-identical HTML** to the Rails reference, with minimal allocations.

## Running

    cd /home/tobi/src/once/campfire-ruby
    source bin/dev-env                      # parity secrets + tmp/seed copy, PORT=3200
    mise exec -- bundle exec ruby bin/campfire

- The Rails reference runs at http://127.0.0.1:3100 with the same seed. Its cookie is in
  `/home/tobi/src/once/ref-html/cookie.txt` (`curl -b "$(cat …/cookie.txt)"`).
- Saved reference pages live in `/home/tobi/src/once/ref-html/*.html`.
- The **same cookie works on our server** (same SECRET_KEY_BASE, same DB rows). Diff with:
  `diff <(curl -s -b "$C" :3100/rooms/486777696) <(curl -s -b "$C" :3200/rooms/486777696)`.
  CSRF tokens are random per render, so normalise `authenticity_token` values and
  `csrf-token` content before diffing.
- Seed labels: `tmp/seed/labels.json`. Clock is 2026-03-02T16:00:00Z.

## Code layout and conventions

- `app/controllers/**`: `class Campfire::FooController < ApplicationController`. Upstream
  `Rooms::OpensController` becomes `Campfire::Rooms::OpensController`. Actions are public
  methods. Filters: `allow_unauthenticated_access only: %i[new]`, `allow_bot_access`,
  `skip_forgery_protection`, and `before_action` (an instance method you override; call
  `throw :halt` after rendering to stop). See `app/controllers/application_controller.rb`
  and `lib/campfire/controller.rb` for the request API: params, cookies, session, flash,
  current_user, csrf_token, html/turbo_stream/json/head/redirect_to.
- Missing controllers resolve to `MissingController` (501), so the app boots while incomplete.
- `app/models/**`: `class X < Struct.new(*COLS)` with class methods taking `db` first. Use
  frozen SQL literals (Extralite caches statements by SQL text): `db.query_splat`,
  `query_single_splat`, `query_array`. Avoid `query` (hash rows) on hot paths.
- `app/views/**.erb`: compiled by `lib/campfire/template.rb` (Erubi-compatible trimming)
  into methods on `Campfire::Views`. "rooms/show.html.erb" becomes `rooms_show`;
  "messages/_message.html.erb" becomes `_messages_message`. Declare locals on line 1:
  `<%# locals: (message:, room: nil) %>`. Templates write to `@b`. `<%= x %>` escapes and
  skips nil, `<%== x %>` is raw.
  - **Prefer literal HTML** copied from the reference output, with `<%= %>` holes. Static
    `image_tag`s become literal `<img … src="/assets/…-digest.svg" />`. Use `asset_path`
    only if you expect digests to change. Literal text costs nothing at runtime.
  - `content_for` doesn't exist. Render the layout as a method taking blocks or ivars
    (e.g. `@nav`, `@footer` lambdas or pre-rendered strings). Choose whatever gives
    identical bytes, and watch the whitespace the Rails `yield :x` produces.
  - Helpers (`app/helpers/*.rb`, `module Campfire::Helpers`) append to `@b` and return nil.
    `tag_helper.rb` has `h`, `raw`, `attrs(hash)` (Rails tag serialization), `tag`,
    `content_tag`, `image_tag`, `hidden_token_field`, `dom_id`.
- Fragment caching mirrors Rails `cache` / `cached: true`:
  `Cache.fragment(:message, id, updated_at) { render into a fresh String }`, per Ractor.
  Rails also bakes the authenticity_token into cached fragments, so we do the same.
- Background work goes through `Jobs.later(:kind, *ints_or_strings)` (a job Ractor pool).
  Register handlers with `Jobs.register(:kind, Mod)`, where Mod.perform(*args) builds its
  own `DB.connection`. Cross-worker events use `Bus.publish([:broadcast, stream, html])`.
  ActiveJob, Active Storage and ActionCable are not emulated; only their wire contracts are.
- Storage/attachments: `lib/campfire/storage.rb` (being written in parallel), with
  `Storage.blob_path`, `representation_path`, `attached`, etc.
- Rich text: `lib/campfire/rich_text.rb` (being written in parallel), with
  `RichText.presentation(body, host:, resolver:)`, plain_text, etc.
- Secrets: `Campfire.secrets` (`lib/campfire/rails_compat/secrets.rb`) provides signed ids,
  sgid, signed stream names and CSRF masking.

## Performance rules

See `/home/tobi/src/github.com/tobi/Brain/skills/ruby/resources/performance.md`.
`# frozen_string_literal: true` everywhere. Hot-path code avoids intermediate arrays,
hashes, substrings and string interpolation into throwaway strings. Append into `@b`. Use
`getbyte`/`byteslice`, and `skip` instead of `scan`. Check allocations with
`GC.stat(:total_allocated_objects)` around a render. Ractor rule: constants must be
deep-frozen (boot calls `Ractor.make_shareable` on everything under `Campfire`), so no
mutable constants or class-level memo hashes. Use `Ractor.current[:key]` / `Cache`.

### Logging

Use `Campfire::Log.info(msg)` / `Log.error(context, exception)`. Never `$stderr.puts`,
`warn` or `puts`: fd 2 belongs to the log Ractor, and `$stderr` writes from non-main Ractors
have raised ThreadError. A call appends to a Ractor-local buffer (about 100ns, 0 allocations).
A 100ms timer or a 64KB fill moves the buffer to the log Ractor with `send(move: true)`, so
nothing is copied. Don't build log strings on hot paths at all; prefer not logging.

### Allocation rules for rendering

- One output String per response: `String.new(capacity: N)`, sized from the last render of
  that page (keep the size in `Ractor[:cap_<page>]`). It is handed to the response body
  as-is; no `join`, `dup` or `to_s` copy.
- Append, never interpolate: `@b << "<a href=\"/rooms/" << id_s << "\">"`, not
  `"<a href=\"/rooms/#{id}\">"`. Interpolation allocates a throwaway String every time.
- `Integer#to_s` allocates. For ids rendered many times, take strings straight from SQL
  (`CAST(id AS TEXT)`), or render them once inside a cached fragment.
- Copy from a source string without slicing: `buf.bytesplice(buf.bytesize, 0, src, off, len)`
  appends a range of `src` with no intermediate String. Use `byteindex`/`getbyte` to find
  ranges.
- `ERB::Escape.html_escape(s)` returns `s` itself when nothing needs escaping, so 0 allocations.
- Cached fragments are frozen Strings; appending them is a memcpy.
- Avoid `Array#join`, `map`, `each_with_object`, `format`, and `Hash` arguments (`**opts`
  allocates a Hash) in helpers called per message. Write positional-arg helpers, or
  inline the literal HTML in the template.
- Measure: `GC.stat(:total_allocated_objects)` is process-wide (all Ractors), so measure in
  a quiet process. Report allocations per render in your summary.

### SQLite

- `DB.connection` is a `DB::Connection` (an Extralite subclass), one per Ractor and opened
  at worker start. Pragmas: WAL, synchronous=NORMAL, foreign_keys, 128MB mmap, 16MB cache,
  temp_store=memory, `optimize=0x10002`. GVL is held during statements
  (`gvl_release_threshold = -1`).
- An autocommit read costs about 4.5µs of read-transaction setup (WAL-index locks, fstat).
  Inside an open transaction the same point query is about 0.2µs. So `App#call` runs every
  GET/HEAD inside `connection.read { }`: one snapshot per request. The first `execute` or
  `transaction` commits it, so writes never upgrade a stale snapshot (SQLITE_BUSY_SNAPSHOT)
  and later reads see them. Writes must go through `execute`/`transaction`, not `query*`.
  Don't yield to other fibers inside a GET handler. `Jobs.call` ends the read first.
- Lock waits retry in Ruby (`Connection#busy_retry`); `busy_timeout` is 0 after open. SQLite's
  busy handler sleeps in C holding the Ractor's GVL, so that Ractor never reaches a GC safepoint.
  A writer in another Ractor stopped for GC keeps the write lock, so both sat out the full 5s
  timeout (concurrent POSTs: 2 req/s before, about 1,200 after).
- Keep transactions rare and tight. Do file copies, checksums, rendering and HTTP before
  `transaction`, never inside it. Group a request's writes into one transaction (one lock
  acquisition, one commit) rather than several autocommits. A post is one commit: the message,
  its rich text and its search index row.
- Rails' cascading callbacks are SQLite triggers (`db/triggers.sql`, recreated by
  `DB.prepare!` at every boot): boost → message → room `touch: true`, `Room#receive`'s unread
  memberships on message insert, dependent rows on message and room delete (and the search
  index row), and Search's trim to 10. They run inside the write that causes them, with no
  extra statements from Ruby. Code that inserts or updates `messages` or `boosts` must not
  touch the room or message itself. Keep the in-memory `updated_at` in step instead. Triggers
  only copy times from the row being written: SQLite's clock has milliseconds and could move
  `updated_at` backwards, so touches on delete stay in Ruby.
- One writer at a time, in arrival order (`Writer`). Racing for SQLite's lock with sleep/retry
  let some writers lose again and again (post p99 ~100ms at c=16). A writer Ractor hands out the
  write permit. `Connection#transaction`/`#execute` take it, suspending only the waiting fiber.
  The SQL still runs on the caller's own connection. `busy_retry` remains for other processes.
- WAL checkpoints run off the request path (`DB.checkpointer`, server only). SQLite's
  auto-checkpoint ran inside every ~30th post's COMMIT and fsynced the database there (10-20ms).
  Request connections set `wal_autocheckpoint = 0`. A main-Ractor thread runs PASSIVE every
  250ms, and RESTART once the WAL passes ~32MB, because a WAL under steady writes is never
  fully copied when a writer starts, so it never starts over. Posts at c=16 went from ~950 to
  ~1,850 req/s; c=1 p99 went from 17ms to 3ms.
- Extralite is vendored and patched in `vendor/gems/extralite`: `Database#close` used to
  finalize FTS5's internal statements and crash, and a failing `execute` with a cached
  statement (e.g. a UNIQUE violation) freed the statement but left it in the cache, so the
  next `execute` of the same SQL segfaulted. Neither bug is Ractor-related; both reproduce
  single-threaded. TODO: send both upstream once the port is done. After editing its C sources, rebuild with
  `cd vendor/gems/extralite/ext/extralite && ruby extconf.rb && make && cp extralite_ext.so ../../lib/ && make clean`.
- Request header values are ASCII-8BIT, and Extralite binds binary strings as BLOBs, which
  never equal TEXT. Read headers that get bound into SQL through `Controller#text_header`;
  the router retags path captures as UTF-8 for the same reason.

### Process limits

`Server.run` raises the soft `RLIMIT_NOFILE` to the hard limit, as Go's runtime does. Each cable
client holds a socket; at the usual 1024 soft limit, ~1000 clients exhausted fds, `accept()`
failed with EMFILE and the whole server stopped answering (0% CPU, every reactor in epoll_wait).
