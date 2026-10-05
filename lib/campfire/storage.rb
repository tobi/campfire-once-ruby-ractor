# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "protocol/http/response"
require "protocol/http/headers"
require "protocol/http/body/buffered"

module Campfire
  # Active Storage's database, disk and URL contracts as a plain module (no
  # framework emulation). Byte-compatible with the Rails app:
  #
  # * tables active_storage_blobs / _attachments / _variant_records (db/schema.sql)
  # * disk layout <files_path>/<key[0,2]>/<key[2,2]>/<key>
  # * signed blob ids, variation keys, disk tokens and URL escaping, so the
  #   HTML carries the same /rails/active_storage/... URLs as the reference.
  #
  # Image variants (libvips), video previews (ffmpeg), analysis and purge run
  # in job Ractors (Jobs kinds :variant, :preview, :analyze, :purge,
  # :process_attachment); request Ractors only look up existing rows and wait
  # on Jobs.call for missing representations.
  module Storage
    PREFIX = "/rails/active_storage/"
    SERVICE = "local"
    OCTET = "application/octet-stream"
    BASE36 = [*"0".."9", *"a".."z"].freeze
    KEY_LENGTH = 28 # ActiveStorage::Blob::MINIMUM_TOKEN_LENGTH
    URL_TTL = 300 # ActiveStorage.service_urls_expire_in
    IDENTIFIED = '{"identified":true}'
    EMPTY_JSON = "{}"

    # ActiveStorage defaults (+ config/initializers/vips.rb removing bmp/ico/psd).
    VARIABLE = %w[image/png image/gif image/jpeg image/tiff image/webp image/avif image/heic image/heif].freeze
    WEB_IMAGE = %w[image/png image/jpeg image/gif image/webp].freeze
    INLINE = %w[image/webp image/avif image/png image/gif image/jpeg image/tiff image/bmp
      image/vnd.adobe.photoshop image/vnd.microsoft.icon application/pdf].freeze
    SERVE_AS_BINARY = %w[text/html image/svg+xml application/postscript application/x-shockwave-flash
      text/xml application/xml application/xhtml+xml application/mathml+xml text/cache-manifest].freeze

    # Named variants (has_one_attached ... attachable.variant) and the
    # transformations views pass explicitly. In-app variations carry Symbols.
    THUMB = { resize_to_limit: [1200, 800] }.freeze                    # Message :thumb
    SQUARE = { resize_to_limit: [512, 512], format: :webp }.freeze     # User avatar :square
    LOGO_LARGE = { resize_to_limit: [512, 512], format: :png }.freeze  # Account logo :large
    LOGO_SMALL = { resize_to_limit: [192, 192], format: :png }.freeze  # Account logo :small
    PREVIEW_WEBP = { format: :webp }.freeze                            # Message#process_attachment (video)
    VIDEO_POSTER = { format: :webp, resize_to_limit: [1200, 800] }.freeze # attachment_presentation poster
    VARIANTS = { thumb: THUMB, square: SQUARE, large: LOGO_LARGE, small: LOGO_SMALL }.freeze
    Ractor.make_shareable(VARIANTS)

    COLUMNS = "b.id, b.key, b.filename, b.content_type, b.metadata, b.service_name, b.byte_size, b.checksum, b.created_at"
    SQL_FIND = "SELECT #{COLUMNS} FROM active_storage_blobs b WHERE b.id = ?".freeze
    SQL_ATTACHED = ("SELECT #{COLUMNS} FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id = b.id " \
      "WHERE a.record_type = ? AND a.record_id = ? AND a.name = ? ORDER BY a.id LIMIT 1").freeze
    SQL_ATTACHED_MANY = ("SELECT a.record_id, #{COLUMNS} FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id = b.id " \
      "WHERE a.record_type = ? AND a.name = ? AND a.record_id IN (SELECT value FROM json_each(?)) ORDER BY a.id").freeze
    SQL_VARIANT = ("SELECT #{COLUMNS} FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id = b.id " \
      "JOIN active_storage_variant_records v ON v.id = a.record_id WHERE a.record_type = 'ActiveStorage::VariantRecord' " \
      "AND a.name = 'image' AND v.blob_id = ? AND v.variation_digest = ? LIMIT 1").freeze
    SQL_INSERT_BLOB = "INSERT INTO active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, checksum, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    SQL_INSERT_ATTACHMENT = "INSERT INTO active_storage_attachments (blob_id, record_type, record_id, name, created_at) VALUES (?, ?, ?, ?, ?)"
    SQL_ATTACHMENT_BLOBS = "SELECT blob_id FROM active_storage_attachments WHERE record_type = ? AND record_id = ? AND name = ?"
    SQL_DELETE_ATTACHMENTS = "DELETE FROM active_storage_attachments WHERE record_type = ? AND record_id = ? AND name = ?"

    class Blob < Struct.new(:id, :key, :filename, :content_type, :metadata, :service_name, :byte_size, :checksum, :created_at)
      # Parsed metadata (JSON text in the row); {} when absent or invalid.
      def metadata_hash
        @metadata_hash ||= begin
          h = metadata && !metadata.empty? ? JSON.parse(metadata) : {}
          h.is_a?(Hash) ? h : {}
        rescue JSON::ParserError
          {}
        end
      end

      def width = metadata_hash["width"]
      def height = metadata_hash["height"]
      def analyzed? = metadata_hash["analyzed"] == true

      def image? = content_type&.start_with?("image") || false
      def video? = content_type&.start_with?("video") || false
      def audio? = content_type&.start_with?("audio") || false
      def variable? = VARIABLE.include?(content_type)
      def previewable? = video? && Storage::PREVIEWABLE # VideoPreviewer.accept?
      def representable? = variable? || previewable?
      def web_image? = WEB_IMAGE.include?(content_type)

      # ActiveStorage::Filename#extension_without_delimiter / #base / #sanitized
      def extension
        e = File.extname(filename.to_s)
        e.empty? ? "" : e[1..]
      end

      def base = File.basename(filename.to_s, File.extname(filename.to_s))
      def sanitized_filename = Storage.sanitize_filename(filename)

      # Blob#default_variant_format: the extension (String) for web images,
      # else :png (Symbol; it ends up in the variant digest).
      def default_variant_format
        return :png unless web_image?
        ext = extension
        if !ext.empty? && Mime.for_extension(ext) == content_type
          ext
        else
          Mime.extension_for(content_type) || :png
        end
      end

      def path = Storage.path_for(key)
    end

    # An uploaded file on disk whose blob row is inserted later, inside the
    # record's transaction (Go storage.Staged).
    class Staged < Struct.new(:blob, :path)
      def insert(db)
        b = blob
        b.created_at ||= Clock.now_db
        db.execute(SQL_INSERT_BLOB, b.key, b.filename, b.content_type, b.metadata, b.service_name, b.byte_size, b.checksum, b.created_at)
        b.id = db.last_insert_rowid
        @kept = true
        b
      end

      def keep = (@kept = true)

      def discard
        return if @kept
        File.unlink(path) if File.exist?(path)
        @kept = true
      end
    end

    module_function

    def verifier = Campfire.secrets.app_verifier("ActiveStorage")
    def root = Campfire.config.files_path

    # ---- keys and disk ---------------------------------------------------

    def new_key = SecureRandom.alphanumeric(KEY_LENGTH, chars: BASE36)

    # DiskService#path_for. Raises ArgumentError for unsafe keys.
    def path_for(key)
      if key.nil? || key.bytesize < 4 || key.include?("/") || key.include?("\\") || key.include?("\0")
        raise ArgumentError, "invalid storage key"
      end
      File.join(root, key[0, 2], key[2, 2], key)
    end

    def safe_path(key)
      path_for(key)
    rescue ArgumentError
      nil
    end

    # ---- rows --------------------------------------------------------------

    def find(db, id)
      row = db.query_single_array(SQL_FIND, id)
      row && Blob.new(*row)
    end

    # record.<name> (has_one_attached): the Blob or nil.
    def attached(db, record_type, record_id, name)
      row = db.query_single_array(SQL_ATTACHED, record_type, record_id, name)
      row && Blob.new(*row)
    end

    def attached?(db, record_type, record_id, name) = !attached(db, record_type, record_id, name).nil?

    # Batch form for rendering lists: { record_id => Blob }.
    def attached_many(db, record_type, record_ids, name)
      out = {}
      return out if record_ids.empty?
      db.query_array(SQL_ATTACHED_MANY, record_type, name, JSON.generate(record_ids)).each do |row|
        rid = row.shift
        out[rid] ||= Blob.new(*row)
      end
      out
    end

    def existing_variant(db, blob_id, digest)
      row = db.query_single_array(SQL_VARIANT, blob_id, digest)
      row && Blob.new(*row)
    end

    def transaction(db)
      return yield if db.transaction_active?
      result = nil
      db.transaction { result = yield }
      result
    end

    # Blob.create_before_direct_upload! (no file yet).
    def create_blob(db, filename:, byte_size:, checksum:, content_type: nil, metadata: EMPTY_JSON, key: nil)
      b = Blob.new(nil, key || new_key, filename, content_type, metadata, SERVICE, byte_size, checksum, Clock.now_db)
      db.execute(SQL_INSERT_BLOB, b.key, b.filename, b.content_type, b.metadata, b.service_name, b.byte_size, b.checksum, b.created_at)
      b.id = db.last_insert_rowid
      b
    end

    # Writes an upload to disk under a fresh key and identifies its content
    # type like Marcel (magic bytes, declared type, filename). `data` is a
    # String or an IO. The row is inserted by Staged#insert(db).
    def stage_upload(filename, declared_type, data)
      key = new_key
      path = path_for(key)
      FileUtils.mkdir_p(File.dirname(path))
      md5 = Digest::MD5.new
      size = 0
      head = nil
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |f|
        if data.is_a?(String)
          f.write(data)
          md5 << data
          size = data.bytesize
          head = data.byteslice(0, Mime::PREFIX_LENGTH)
        else
          head = +"".b
          while (chunk = data.read(65_536))
            f.write(chunk)
            md5 << chunk
            size += chunk.bytesize
            head << chunk.byteslice(0, Mime::PREFIX_LENGTH - head.bytesize) if head.bytesize < Mime::PREFIX_LENGTH
          end
        end
      end
      type = Mime.identify(head, filename, declared_type)
      Staged.new(Blob.new(nil, key, filename, type, IDENTIFIED, SERVICE, size, md5.base64digest, nil), path)
    rescue
      File.unlink(path) if path && File.exist?(path) && !$!.is_a?(Errno::EEXIST)
      raise
    end

    # stage_upload + insert (ActiveStorage::Blob.create_and_upload!).
    def create_blob_from_upload(db, filename, declared_type, data)
      staged = stage_upload(filename, declared_type, data)
      staged.insert(db)
    ensure
      staged&.discard
    end

    # has_one_attached assignment: replaces the record's attachment `name`,
    # purging replaced blobs later. `analyze: true` enqueues analysis as
    # Attachment#analyze_blob_later does (messages call process_attachment).
    def attach(db, blob_id, record_type, record_id, name, analyze: true)
      old = nil
      transaction(db) do
        old = db.query_splat(SQL_ATTACHMENT_BLOBS, record_type, record_id, name)
        db.execute(SQL_DELETE_ATTACHMENTS, record_type, record_id, name)
        db.execute(SQL_INSERT_ATTACHMENT, blob_id, record_type, record_id, name, Clock.now_db)
      end
      old.each { |id| Jobs.later(:purge, id) unless id == blob_id }
      Jobs.later(:analyze, blob_id) if analyze
      blob_id
    end

    TOUCH_TABLES = { "User" => "users", "Account" => "accounts", "Message" => "messages" }.freeze

    # record.<name>.destroy / purge_later: removes the attachment, touches the
    # record (a message's touch reaches its room, db/triggers.sql), purges the blobs later.
    def detach(db, record_type, record_id, name)
      table = TOUCH_TABLES.fetch(record_type)
      blobs = nil
      transaction(db) do
        blobs = db.query_splat(SQL_ATTACHMENT_BLOBS, record_type, record_id, name)
        unless blobs.empty?
          db.execute(SQL_DELETE_ATTACHMENTS, record_type, record_id, name)
          now = Clock.now_db
          db.execute("UPDATE #{table} SET updated_at = ? WHERE id = ?", now, record_id)
        end
      end
      blobs.each { |id| Jobs.later(:purge, id) }
      !blobs.empty?
    end

    # Message#process_attachment, synchronously as Rails does (the message's
    # broadcast needs the dimensions) but with the work in a job Ractor.
    def process_attachment(blob_id) = Jobs.call(:process_attachment, blob_id)
    def analyze_later(blob_id) = Jobs.later(:analyze, blob_id)
    def purge_later(blob_id) = Jobs.later(:purge, blob_id)

    # ---- representations ---------------------------------------------------

    # blob.representation(variation).processed -> the image Blob to serve
    # (variant or preview image), generating it in a job Ractor if missing.
    # `variation`: Symbol keys; nil when the blob is not representable.
    def representation(db, blob, variation)
      if blob.previewable?
        if (image = attached(db, "ActiveStorage::Blob", blob.id, "preview_image"))
          return image if variation.empty?
          if image.variable?
            found = existing_variant(db, image.id, Variation.digest(Variation.default_to(variation, image.default_variant_format)))
            return found if found
          end
        end
      elsif blob.variable?
        found = existing_variant(db, blob.id, Variation.digest(Variation.default_to(variation, blob.default_variant_format)))
        return found if found
      else
        return nil
      end
      id = Jobs.call(:variant, blob.id, Variation.dump(variation))
      id && find(db, id)
    end

    # record.<name>.variant(name).processed for avatars and logos (nil when
    # the blob is not variable).
    def variant(db, blob, name_or_variation)
      return nil unless blob&.variable?
      variation = name_or_variation.is_a?(Hash) ? name_or_variation : VARIANTS.fetch(name_or_variation)
      representation(db, blob, variation)
    end

    # Filesystem path of the processed variant, for send_file
    # (AvatarsController: :square, LogosController: :large / :small).
    def variant_path_for(db, blob, name)
      (v = variant(db, blob, name)) ? path_for(v.key) : nil
    end

    # ---- URLs ----------------------------------------------------------------

    # ActiveStorage::Filename#sanitized
    def sanitize_filename(name)
      s = name.to_s
      s = s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\u{FFFD}") unless s.encoding == Encoding::UTF_8 && s.valid_encoding?
      s = s.strip
      s.match?(FILENAME_UNSAFE) ? s.tr(FILENAME_UNSAFE_CHARS, "-") : s
    end
    FILENAME_UNSAFE_CHARS = "\u{202E}%$|:;/<>?*\"\t\r\n\\"
    FILENAME_UNSAFE = /[\u{202E}%$|:;\/<>?*"\t\r\n\\]/

    # Journey::Router::Utils.escape_segment
    SEGMENT_UNSAFE = /[^a-zA-Z0-9\-._~!$&'()*+,;=:@]/n
    def escape_segment(s)
      b = s.b
      return s unless b.match?(SEGMENT_UNSAFE)
      b.gsub(SEGMENT_UNSAFE) { |c| PCT[c.ord] }.force_encoding(Encoding::US_ASCII)
    end
    PCT = Array.new(256) { |i| format("%%%02X", i).freeze }.freeze

    # Rails path params are unescaped without '+' -> ' '.
    def unescape_segment(s)
      return s unless s.include?("%")
      s.b.gsub(/%(\h\h)/) { $1.hex.chr }.force_encoding(Encoding::UTF_8)
    end

    # blob.signed_id (purpose "blob_id", no expiry). Deterministic, so cached.
    def signed_id(blob_or_id)
      id = blob_or_id.is_a?(Blob) ? blob_or_id.id : blob_or_id
      Cache.fetch(:as_signed_id, id) { verifier.generate(id, purpose: "blob_id").freeze }
    end

    # ActiveStorage::Blob.find_signed: the blob id or nil.
    def verify_signed_id(token)
      v = verifier.verified(token, purpose: "blob_id")
      case v
      when Integer then v
      when String then v.match?(/\A\d+\z/) ? v.to_i : nil
      end
    end

    def find_signed(db, token)
      (id = verify_signed_id(token)) ? find(db, id) : nil
    end

    def variation_key(variation)
      Cache.fetch(:as_variation_key, variation) { Variation.encode(variation).freeze }
    end

    # rails_blob_path(blob, disposition:)
    def blob_path(blob, disposition: nil)
      path = +"#{PREFIX}blobs/redirect/" << escape_segment(signed_id(blob)) << "/" << escape_segment(sanitize_filename(blob.filename))
      path << "?disposition=" << Params.escape(disposition) if disposition
      path
    end

    # url_for(blob.representation(variation)): previews for videos, variants
    # (with the blob's default format) for images; nil otherwise.
    def representation_path(blob, variation)
      if blob.previewable? then preview_path(blob, variation)
      elsif blob.variable? then variant_path(blob, variation)
      end
    end

    # url_for(blob.variant(variation))
    def variant_path(blob, variation)
      transformation_path(blob, Variation.default_to(variation, blob.default_variant_format))
    end

    # url_for(blob.preview(variation)) (no default format)
    def preview_path(blob, variation) = transformation_path(blob, variation)

    def transformation_path(blob, variation)
      +"#{PREFIX}representations/redirect/" << escape_segment(signed_id(blob)) << "/" <<
        escape_segment(variation_key(variation)) << "/" << escape_segment(sanitize_filename(blob.filename))
    end

    # ActionDispatch::Http::ContentDisposition.format
    APPROXIMATIONS = Ractor.make_shareable(JSON.parse(File.read(File.join(__dir__, "storage", "approximations.json"))))
    TRADITIONAL_UNSAFE = /[^ A-Za-z0-9!\#$+.^_`|~-]/n
    RFC5987_UNSAFE = /[^A-Za-z0-9!\#$&+.^_`|~-]/n
    def content_disposition(type, filename)
      ascii = filename.ascii_only? ? filename : filename.gsub(/[^\x00-\x7f]/u) { |c| APPROXIMATIONS[c] || "?" }
      +"#{type}; filename=\"" << percent_escape(ascii, TRADITIONAL_UNSAFE) << "\"; filename*=UTF-8''" << percent_escape(filename, RFC5987_UNSAFE)
    end

    def percent_escape(s, pattern)
      b = s.b
      b.match?(pattern) ? b.gsub(pattern) { |c| PCT[c.ord] }.force_encoding(Encoding::UTF_8) : s
    end

    def serving_type(type) = SERVE_AS_BINARY.include?(type) ? OCTET : type

    # Blob#url(disposition:) on the Disk service: the signed, expiring path
    # (prefix with the request origin for Location headers).
    def disk_path(blob, disposition: nil, now: Time.now)
      type = blob.content_type
      disposition = "attachment" unless INLINE.include?(type)
      disposition = "inline" unless disposition == "attachment"
      name = sanitize_filename(blob.filename)
      payload = { "key" => blob.key, "disposition" => content_disposition(disposition, name),
                  "content_type" => serving_type(type), "service_name" => blob.service_name }
      token = verifier.generate(payload, purpose: "blob_key", expires_at: now + URL_TTL)
      +"#{PREFIX}disk/" << escape_segment(token) << "/" << escape_segment(name)
    end

    # Blob#service_url_for_direct_upload (path only).
    def upload_path(blob, now: Time.now)
      payload = { "key" => blob.key, "content_type" => blob.content_type, "content_length" => blob.byte_size,
                  "checksum" => blob.checksum, "service_name" => blob.service_name }
      +"#{PREFIX}disk/" << escape_segment(verifier.generate(payload, purpose: "blob_token", expires_at: now + URL_TTL))
    end

    # ---- HTTP ------------------------------------------------------------------

    TEXT_HTML = "text/html; charset=utf-8"
    HEAD_HTML = "text/html"
    PUBLIC_HTML = "text/html; charset=UTF-8"
    JSON_TYPE = "application/json; charset=utf-8"
    REDIRECT_CACHE = "max-age=300, private"
    PROXY_CACHE = "max-age=3155695200, public, immutable"
    DISK_CACHE = "max-age=3600, public"

    # Every request under PREFIX (App dispatches here). `path` excludes the query.
    def call(request, path, query)
      rest = path.byteslice(PREFIX.bytesize, path.bytesize)
      verb = request.method
      get = verb == "GET" || verb == "HEAD"
      parts = rest.split("/", -1)
      case parts[0]
      when "blobs"
        return not_found unless get
        parts.shift
        proxy = parts[0] == "proxy"
        parts.shift if proxy || parts[0] == "redirect"
        return not_found if parts.size < 2 || parts[0].empty?
        serve_blob(request, unescape_segment(parts[0]), query, proxy)
      when "representations"
        return not_found unless get
        parts.shift
        proxy = parts[0] == "proxy"
        parts.shift if proxy || parts[0] == "redirect"
        return not_found if parts.size < 3 || parts[0].empty? || parts[1].empty?
        serve_representation(request, unescape_segment(parts[0]), unescape_segment(parts[1]), query, proxy)
      when "disk"
        if get && parts.size >= 3 && !parts[1].empty?
          serve_disk(request, unescape_segment(parts[1]))
        elsif verb == "PUT" && parts.size == 2 && !parts[1].empty?
          disk_upload(request, unescape_segment(parts[1]))
        else
          not_found
        end
      when "direct_uploads"
        verb == "POST" && parts.size == 1 ? direct_upload(request) : not_found
      else
        not_found
      end
    rescue => e
      Log.error("storage #{request.method} #{path}", e)
      respond(500, [["content-type", PUBLIC_HTML]], error_page("/500.html", "Internal Server Error"))
    end

    def serve_blob(request, token, query, proxy)
      db = DB.connection
      blob = find_signed(db, token) or return not_found
      disposition = query && Params.decode(query)["disposition"]
      if proxy
        disposition = "inline" unless disposition == "attachment"
        disposition = "attachment" unless INLINE.include?(blob.content_type)
        path = safe_path(blob.key) or return not_found
        type = serving_type(blob.content_type)
        headers = [["cache-control", PROXY_CACHE]]
        headers << ["content-type", type] if type && !type.empty?
        headers << ["content-disposition", content_disposition(disposition, sanitize_filename(blob.filename))]
        return Serve.file(request, path, headers, type, proxy: true)
      end
      redirect(request, disk_path(blob, disposition: disposition))
    end

    def serve_representation(request, token, key, query, proxy)
      db = DB.connection
      blob = find_signed(db, token) or return not_found
      variation = Variation.decode(key) or return not_found
      image = representation(db, blob, variation)
      unless image
        return not_found unless blob.representable?
        return respond(500, [["content-type", PUBLIC_HTML]], error_page("/500.html", "Internal Server Error"))
      end
      if proxy
        path = safe_path(image.key) or return not_found
        headers = [["cache-control", PROXY_CACHE]]
        headers << ["content-type", image.content_type] if image.content_type
        headers << ["content-disposition", content_disposition("inline", sanitize_filename(image.filename))]
        return Serve.file(request, path, headers, image.content_type, proxy: true)
      end
      disposition = query && Params.decode(query)["disposition"]
      redirect(request, disk_path(image, disposition: disposition))
    end

    # DiskController#show
    def serve_disk(request, token)
      key = verifier.verified(token, purpose: "blob_key")
      return head(404) unless key.is_a?(Hash)
      path = safe_path(key["key"]) or return head(404)
      type = key["content_type"]
      headers = [["cache-control", DISK_CACHE]]
      headers << ["content-type", type] if type.is_a?(String) && !type.empty?
      headers << ["content-disposition", key["disposition"].to_s]
      Serve.file(request, path, headers, type, proxy: false)
    end

    # DiskController#update (session required, no CSRF check).
    def disk_upload(request, token)
      db = DB.connection
      return head(401) unless authenticated?(request, db)
      t = verifier.verified(token, purpose: "blob_token")
      return head(404) unless t.is_a?(Hash)
      path = safe_path(t["key"]) or return head(422)
      declared = request.headers["content-type"]&.to_s&.split(";", 2)&.first&.strip&.downcase
      length = request.headers["content-length"]&.to_s
      length = length && length.match?(/\A\d+\z/) ? length.to_i : nil
      return head(422) unless declared == t["content_type"]&.downcase && length == t["content_length"]
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{File.dirname(path)}/.upload-#{SecureRandom.hex(8)}"
      md5 = Digest::MD5.new
      size = 0
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |f|
        if (body = request.body)
          while (chunk = body.read)
            size += chunk.bytesize
            break if size > length
            f.write(chunk)
            md5 << chunk
          end
        end
      end
      return head(422) unless size == length && md5.base64digest == t["checksum"]
      File.rename(tmp, path)
      head(204)
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end

    # DirectUploadsController#create (CSRF + session required).
    def direct_upload(request)
      db = DB.connection
      return head(422) unless csrf_ok?(request)
      return head(401) unless authenticated?(request, db)
      body = request.body&.join || +""
      type = request.headers["content-type"]&.to_s || ""
      params = if type.start_with?("application/json")
        (JSON.parse(body) rescue nil)
      else
        Params.decode(body.force_encoding(Encoding::UTF_8))
      end
      attrs = params.is_a?(Hash) && params["blob"]
      return respond(400, [["content-type", TEXT_HTML]], nil) unless attrs.is_a?(Hash)
      filename = scalar(attrs["filename"])
      checksum = scalar(attrs["checksum"])
      size = scalar(attrs["byte_size"])
      size = size && size[/\A\s*[+-]?\d+/]&.to_i
      return head(422) if filename.nil? || filename.empty? || checksum.nil? || checksum.empty? || size.nil?
      metadata = attrs["metadata"].is_a?(Hash) ? attrs["metadata"].except("analyzed", "identified", "composed") : {}
      blob = create_blob(db, filename: filename, byte_size: size, checksum: checksum,
        content_type: scalar(attrs["content_type"]), metadata: JSON.generate(metadata))
      json = {
        "id" => blob.id, "byte_size" => blob.byte_size, "checksum" => blob.checksum, "content_type" => blob.content_type,
        "created_at" => "#{Clock.iso8601(blob.created_at).chomp("Z")}.#{blob.created_at[20, 3]}Z",
        "filename" => blob.filename, "key" => blob.key, "metadata" => metadata, "service_name" => blob.service_name,
        "signed_id" => signed_id(blob),
        "direct_upload" => { "url" => origin(request) + upload_path(blob), "headers" => { "Content-Type" => blob.content_type } }
      }
      respond(200, [["content-type", JSON_TYPE]], RailsCompat::Util.as_json_encode(json))
    end

    def scalar(v)
      case v
      when String then v
      when Integer, Float then v.to_s
      end
    end

    def authenticated?(request, db)
      raw = RailsCompat.cookie_value(request.headers["cookie"]&.to_s, "session_token") or return false
      token = Cache.session_token(raw) or return false
      !db.query_single_splat("SELECT 1 FROM sessions WHERE token = ? LIMIT 1".freeze, token).nil?
    end

    def csrf_ok?(request)
      return false unless RailsCompat::CSRF.valid_request_origin?(request.headers["origin"]&.to_s, origin(request))
      raw = RailsCompat.cookie_value(request.headers["cookie"]&.to_s, "_campfire_session") or return false
      session = Cache.session(raw)
      token = request.headers["x-csrf-token"]&.to_s
      Campfire.secrets.valid_csrf_token?(session["_csrf_token"], token, request_path: request.path.split("?", 2)[0], request_method: "POST")
    end

    def origin(request)
      scheme = request.headers["x-forwarded-proto"]&.to_s || request.scheme || "http"
      host = request.authority || request.headers["host"]&.to_s || "localhost"
      "#{scheme}://#{host}"
    end

    def redirect(request, path)
      respond(302, [["cache-control", REDIRECT_CACHE], ["content-type", TEXT_HTML], ["location", origin(request) + path]], nil)
    end

    # `head status` (Content-Type text/html unless the status has no content).
    def head(status) = respond(status, status == 204 || status == 304 ? [] : [["content-type", HEAD_HTML]], nil)

    # ActionDispatch::PublicExceptions (RecordNotFound, routing errors).
    def not_found = respond(404, [["content-type", PUBLIC_HTML]], error_page("/404.html", "Not Found"))

    def error_page(path, fallback)
      (defined?(Assets) && Assets.const_defined?(:FILES) && Assets.file(path)&.body) || fallback
    end

    def respond(status, headers, body)
      body = body.nil? || body.empty? ? nil : Protocol::HTTP::Body::Buffered.new([body], body.bytesize)
      Protocol::HTTP::Response[status, Protocol::HTTP::Headers.new(headers), body]
    end
  end
end

require_relative "storage/mime"
require_relative "storage/variation"
require_relative "storage/media"
require_relative "storage/serve"
require_relative "storage/work"
