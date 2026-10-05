# frozen_string_literal: true

require "json"
require "time"
require "digest"

module Campfire
  # Compiled frontend assets (see bin/import-assets). Everything under public/
  # is read once at boot into deeply frozen strings, so worker Ractors serve
  # them straight from shared memory, the way ActionDispatch::Static does
  # (Rack::Files headers: Rack::Mime type, Last-Modified, Content-Length, and
  # `config.public_file_server.headers`).
  module Assets
    # Rack::Mime::MIME_TYPES for the extensions public/ holds.
    TYPES = {
      ".avif" => "image/avif", ".css" => "text/css", ".csv" => "text/csv", ".gif" => "image/gif",
      ".gz" => "application/x-gzip", ".htm" => "text/html", ".html" => "text/html",
      ".ico" => "image/vnd.microsoft.icon", ".jpeg" => "image/jpeg", ".jpg" => "image/jpeg",
      ".js" => "text/javascript", ".mjs" => "text/javascript", ".json" => "application/json",
      ".mp3" => "audio/mpeg", ".mp4" => "video/mp4", ".otf" => "font/otf", ".pdf" => "application/pdf",
      ".png" => "image/png", ".svg" => "image/svg+xml", ".ttf" => "font/ttf", ".txt" => "text/plain",
      ".wav" => "audio/x-wav", ".webm" => "video/webm", ".webp" => "image/webp", ".woff" => "font/woff",
      ".woff2" => "font/woff2", ".xml" => "application/xml", ".zip" => "application/zip"
    }.freeze
    # production.rb: config.public_file_server.headers
    CACHE_CONTROL = "public, max-age=2592000"
    # stylesheet_link_tag's preload header stops before 1,000 bytes (send_preload_links_header).
    MAX_LINK_HEADER = 1_000

    StaticFile = Data.define(:body, :type, :last_modified, :length)

    module_function

    def load!(root = File.join(ROOT, "public"))
      manifest = JSON.parse(File.read(File.join(root, "assets", ".manifest.json")))
      paths = manifest.to_h { |logical, entry| [logical, "/assets/#{entry["digested_path"]}"] }
      files = {}
      Dir.glob("**/*", base: root).each do |rel|
        full = File.join(root, rel)
        next unless File.file?(full) && !rel.end_with?(".manifest.json")
        body = File.binread(full)
        ext = File.extname(rel).downcase
        type = TYPES.fetch(ext, "text/plain")
        file = StaticFile.new(body, type, File.mtime(full).httpdate, body.bytesize.to_s)
        files["/#{rel}"] = file
        # ActionDispatch::FileHandler also tries `path.html` and `path/index.html` for
        # extensionless paths.
        if ext == ".html"
          files["/#{rel.delete_suffix(".html")}"] ||= file
          files["/#{rel.delete_suffix("index.html").delete_suffix("/")}"] ||= file if File.basename(rel) == "index.html"
        end
      end
      head_tags = File.read(File.join(ROOT, "app/views/layouts/_assets.html")).chomp
      const_set(:PATHS, Ractor.make_shareable(paths))
      const_set(:FILES, Ractor.make_shareable(files))
      const_set(:HEAD_TAGS, Ractor.make_shareable(head_tags))
      const_set(:PRELOAD_LINK, Ractor.make_shareable(preload_link(head_tags)))
    end

    # The `Link` header stylesheet_link_tag sends (config.action_view.preload_links_header):
    # `<href>; rel=preload; as=style; nopush` per stylesheet, skipping any that would push the
    # header past MAX_LINK_HEADER.
    def preload_link(head_tags)
      header = +""
      head_tags.scan(/<link rel="stylesheet" href="([^"]+)"/) do |(href)|
        link = "<#{href}>; rel=preload; as=style; nopush"
        next if header.bytesize + link.bytesize > MAX_LINK_HEADER
        header << "," unless header.empty?
        header << link
      end
      header
    end

    def path(logical) = PATHS.fetch(logical)
    def file(path) = FILES[path]
  end
end
