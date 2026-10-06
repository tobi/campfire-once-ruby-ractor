# Campfire on Ruby 4 Ractors

A port of [ONCE Campfire](https://github.com/basecamp/once-campfire) to Ruby 4.0.7 without Rails:
[Falcon](https://github.com/socketry/falcon) serving from worker Ractors in a single process, plain
modules over SQLite, and in-process job and cable Ractors joined by message passing. It reads the
Rails app's SQLite database, storage layout and signed/encrypted cookies unchanged, and aims for
**byte-identical HTML** to the Rails app, apart from a few [deliberate differences](#deliberate-differences-from-rails).

This is an experiment in how fast idiomatic-but-careful Ruby can serve a real Rails app's workload
once the framework is gone. It stands on three reference repositories:

| Repository | Role here |
|---|---|
| [basecamp/once-campfire](https://github.com/basecamp/once-campfire) | **The source of truth.** Behavior, routes, views, assets, schema and cookie formats are ported from it; every page is diffed against it. `public/assets` is its compiled frontend. |
| [basecamp/once-campfire-go](https://github.com/basecamp/once-campfire-go) | **The architecture.** No framework, ORM or Redis: one module per concern over SQLite, in-process queues and an in-process Action Cable hub. Here the queues are Ractors. |
| [basecamp/once-campfire-rust](https://github.com/basecamp/once-campfire-rust) | **The harness.** Its parity suite (seeds, `parity/bin/reference`, `parity/bin/candidate compare`), its load generator and `bench/run`, its fixed test environment (`parity/.env.reference`), and its [list of deliberate differences](https://github.com/basecamp/once-campfire-rust#known-differences) from Rails. |

## Status

- **Parity:** before the deliberate differences below, passed the Rust repo's full parity suite
  against the Rails reference (HTML, DOM, accessibility trees, assets, Cable frames, screenshots):
  default seed 874/874, crowd 25/25, custom_styles 33/33, first_run 16/16, restricted 8/8. The
  suite has not been rerun since.
- **Not production-hardened.** No TLS/ACME front server (run it behind a proxy), no backup hooks,
  and no upgrade testing beyond sharing the seed databases with Rails, Go and Rust.
- Jobs (push, webhooks, unfurls, media) are in-process like the Go and Rust ports: queued jobs are
  lost on a crash.

### Deliberate differences from Rails

These follow the Rust port's [known differences](https://github.com/basecamp/once-campfire-rust#known-differences):

- **CSRF:** `Sec-Fetch-Site` replaces authenticity tokens, as Rails main's
  `protect_from_forgery using: :header_only` does. Writes accept `same-origin` and `same-site`,
  reject `cross-site` and missing headers with 422, and keep the `Origin` check. With `DISABLE_SSL`
  set (plain HTTP), a missing header is accepted over HTTP (the `SameSite=Lax` cookies protect it). Pages carry no
  csrf-token meta tag or `authenticity_token` fields, so a page renders the same until what it
  shows changes. HTTPS forms need a browser that sends the header (Safari 16.4 or newer).
  [`app/assets/overrides`](app/assets/overrides) holds the one frontend change this needs.
- **Caching:** HTML ETags hash the page's parts and repeat until the page changes, so revalidation
  gets a 304. Every part of a page (cached fragments and the layout between them) is compressed
  once and kept; a page without fragments keeps its gzip by body digest.
- **Cookies:** the session cookie is written only when the session changed, and deleted when it is
  empty. `session_token` is re-signed with the hourly activity refresh instead of on every request
  (its 20-year expiry keeps rolling); `last_room` is set only when it changes.
- **Routes:** `/rooms/directs/:id` redirects to the room instead of answering 500.

## Performance

Unmodified production images, the Rust repo's default seed and `bench/run-all` (its `bench/run`
plus Go and Ruby). Each app gets 4 pinned hardware threads (CPUs 8-11) on an AMD Ryzen Threadripper
PRO 7975WX, the load generator another 4. Medians of three interleaved reps on October 5, 2026, before
the deliberate differences above:
[Rails/Rust/Ruby report](bench/results/rails-rust-ruby-20261005/report.md),
[Go/Rust/Ruby report](bench/results/go-rust-ruby-20261005/report.md).

### HTTP throughput (16 concurrent clients)

| Route | Rails | Go | Rust | Ruby | Ruby vs Rails |
|---|---:|---:|---:|---:|---:|
| Room page | 189 req/s | 3,152 | 20,976 | 5,094 | **27×** |
| Messages page | 335 | 4,096 | 23,034 | 8,499 | **25×** |
| Sidebar | 480 | 11,927 | 20,182 | 7,235 | **15×** |
| Search | 334 | 5,412 | 19,871 | 6,959 | **21×** |
| Post a message | 199 | 1,077 | 2,713 | 1,810 | **9×** |
| `/up` | 3,436 | 79,600 | 118,724 | 61,370 | **18×** |

### Latency, real time and footprint

| Measurement | Rails | Go | Rust | Ruby |
|---|---:|---:|---:|---:|
| Room page p99, 64 clients | 503 ms | 67 ms | 5.6 ms | 26 ms |
| Post a message p99, 1 client | 28 ms | 26 ms | 6.4 ms | **3.3 ms** |
| Post a message p99, 64 clients | 2,208 ms | 409 ms | 60 ms | 201 ms |
| Cable deliveries/s, 100 clients | 72 | 665 | 1,807 | 1,094 |
| Cable deliveries/s, 1,000 clients | 11 | 140 | 431 | 117 |
| Upload until thumbnail served | 79 ms | 36 ms | 42 ms | 234 ms |
| Cold start until `/up` | 4.6 s | 0.5 s | 0.5 s | 2.9 s |
| Idle / peak container memory | 439 / 1,526 MB | 44 / 413 MB | 29 / 357 MB | 82 / 1,162 MB |

The Go numbers come from the Go/Rust/Ruby run; Rust and Ruby agreed within a few percent between
the two runs. Known weak spots: uploads (slower than Rails), cable p99 at 500+ clients (it varies
between runs from tens to hundreds of milliseconds) and peak memory.

**On Ruby master.** The same app on a build of ruby/ruby master ([`Dockerfile.head`](Dockerfile.head),
[report](bench/results/ruby-head-zjit-20261005/report.md)) is 1.2× faster on the room page and 1.5× on the messages page. It
delivers 1.6–2.2× more cable messages at 500–1,000 clients, and peaks at 723 MB instead of 1,247 MB. ZJIT
(`bench/run-all --apps ruby-zjit`) works with Ractors and runs 3–6% behind YJIT on the pages
([report](bench/results/ruby-zjit-20261005/report.md); each rep's boot log confirms `JIT: ZJIT`).

## How it works

An animated explainer, [`docs/explainer.html`](docs/explainer.html) (open it locally in a browser), walks through the architecture, the decisions and where the speed
comes from. The [porting guide](docs/PORTING.md) has the details and the rules; in short:

- **Ractors, not processes.** `WEB_CONCURRENCY` worker Ractors each run a Falcon/Async reactor on
  a shared listening socket, with their own SQLite connection and fragment cache. Jobs run in
  `JOB_CONCURRENCY` job Ractors; Action Cable broadcasts go through a Bus Ractor. There is no Redis:
  messages between Ractors are frozen arrays of integers and strings.
- **One writer.** A writer Ractor hands out SQLite's write permit in arrival order
  ([`writer.rb`](lib/campfire/writer.rb)). `Connection#transaction` takes it transparently, and
  only the waiting fiber suspends. Rails' `touch: true`, unread marking, dependent deletes and
  search trimming are SQLite triggers ([`db/triggers.sql`](db/triggers.sql)), so a post is one
  short transaction. WAL checkpoints run on a background thread instead of inside a request's COMMIT.
- **Reads in one snapshot.** Every GET runs inside one read transaction, which makes each query
  about 20× cheaper than autocommit.
- **Rendering without allocation.** ERB templates compile to methods that append into one
  pre-sized String per response. Rails-style fragment caches are per Ractor, and gzipped pages are
  spliced together from pre-compressed parts ([`page_parts.rb`](lib/campfire/page_parts.rb)).
- **Rails wire contracts, not Rails.** Signed/encrypted cookies, signed ids, Active Storage URLs,
  the Action Cable protocol and Turbo Streams are reimplemented where the browser or the database
  can see them ([`lib/campfire/rails_compat`](lib/campfire/rails_compat)), and nowhere else.
- **Patched Extralite.** [`vendor/gems/extralite`](vendor/gems/extralite) fixes two crashes
  (finalizing FTS5 statements on close, and reusing a statement freed by a failed `execute`).

## Running it

Build the image (same contract as the Rails, Go and Rust images: HTTP on `$HTTP_PORT`, state in
`/rails/storage/{db,files}`, uid 1000):

```sh
docker build -t campfire-ruby:app .
docker run -d -p 3000:80 \
  -e SECRET_KEY_BASE=... -e VAPID_PUBLIC_KEY=... -e VAPID_PRIVATE_KEY=... \
  -e WEB_CONCURRENCY=8 -e JOB_CONCURRENCY=2 \
  -v campfire:/rails/storage campfire-ruby:app
```

It serves plain HTTP only; put a TLS proxy in front. An empty database gets the Rails schema on first boot; an existing Campfire database is used as is.
As in the Rails app, `DISABLE_SSL` (unset by default) says the site is reached over plain HTTP:
only then are writes without `Sec-Fetch-Site` accepted, since browsers send that header only to
HTTPS and localhost origins.
Point it at a copy of a Rails install's `storage/` with that install's `SECRET_KEY_BASE` and existing
sessions keep working.

Locally, with Ruby 4.0.7 (via [mise](https://mise.jdx.dev)):

```sh
bundle install
source bin/dev-env                 # the Rust repo's fixed parity secrets, tmp/seed copy, PORT=3200
bundle exec ruby bin/campfire
```

## Testing against the references

Unit and integration tests, one file at a time:

```sh
mise exec -- ruby -W0 -Ilib -Itest test/messages_test.rb
```

Parity and benchmarks use a checkout of
[once-campfire-rust](https://github.com/basecamp/once-campfire-rust) (set `CAMPFIRE_REF_RUST` to
its path for `bench/run-all`) for its seeds, Rails reference image and harness:

```sh
cd ../ref-rust
parity/bin/reference build && parity/bin/seed build
PARITY_CANDIDATE_APP_IMAGE=campfire-ruby:app PARITY_CANDIDATE_IMAGE=campfire-candidate-ruby \
  parity/bin/candidate compare --seed default
cd -
bench/run-all --apps reference,go,rust,ruby --reps 3     # needs the four images built
```

For quick checks against a running Rails reference, `bin/parity /rooms/123` diffs one page with
the Rails CSRF tokens removed.

## License

MIT, like [once-campfire](https://github.com/basecamp/once-campfire). The views and frontend assets
are 37signals' and are used under its license; see [`MIT-LICENSE`](MIT-LICENSE).
