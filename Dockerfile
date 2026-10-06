# syntax = docker/dockerfile:1
#
# Production image for the Ruby (Falcon + Ractors) port. Same contract as the Rails, Go and Rust
# images: serves HTTP on $HTTP_PORT (80), keeps state in /rails/storage/{db,files}, runs as 1000.
# Media tools come from Debian trixie, the same libvips (8.16) and ffmpeg the Rails image uses.
#
#   docker build -t campfire-ruby:app .

ARG RUBY_VERSION=4.0.7

FROM docker.io/library/ruby:${RUBY_VERSION}-slim-trixie AS base
WORKDIR /rails
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8 TZ=UTC
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libsqlite3-0 libvips-tools ffmpeg libjemalloc2 curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives


FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential pkg-config libsqlite3-dev libssl-dev libvips-dev git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
COPY Gemfile Gemfile.lock ./
COPY vendor/gems vendor/gems
RUN cd vendor/gems/extralite/ext/extralite && ruby extconf.rb && make -j"$(nproc)" && \
    cp extralite_ext.so ../../lib/ && make clean && rm -f Makefile mkmf.log
RUN bundle install --jobs "$(nproc)" && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git
COPY . .
RUN cd ext/campfire_vips && ruby extconf.rb && make -j"$(nproc)" && \
    cp campfire_vips.so ../../lib/ && make clean && rm -f Makefile mkmf.log


FROM base
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /rails/storage/db /rails/storage/files /rails/tmp && \
    chown -R 1000:1000 /rails/storage /rails/tmp
USER 1000:1000

ARG APP_VERSION=0
ARG GIT_REVISION=0
ENV APP_VERSION=${APP_VERSION} GIT_REVISION=${GIT_REVISION} HTTP_PORT=80 \
    LD_PRELOAD=libjemalloc.so.2 RUBY_YJIT_ENABLE=1
EXPOSE 80
CMD ["bin/boot"]
