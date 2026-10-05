# frozen_string_literal: true

module Campfire
  module Storage
    PREVIEWABLE = Media::VIDEO.available?

    # Work done in job Ractors: variants, video previews, analysis, purge
    # (the Rails app's ActiveStorage jobs; Go storage/representations.go,
    # preview.go, analyze.go, purge.go). Each runs with the job Ractor's own
    # DB connection.
    module Work
      module_function

      def processing_dir
        dir = File.join(Storage.root, ".processing")
        FileUtils.mkdir_p(dir)
        dir
      end

      # The blob's file, verifying its MD5 checksum (Blob#open does).
      def checked_path(blob)
        path = Storage.path_for(blob.key)
        if blob.checksum && !blob.checksum.empty? && Digest::MD5.file(path).base64digest != blob.checksum
          raise Media::Error, "checksum mismatch for blob #{blob.id}"
        end
        path
      end

      # blob.representation(variation).processed; returns the image Blob.
      def representation(db, blob, variation)
        if blob.previewable?
          image = preview_image(db, blob)
          return image if variation.empty?
          blob = image
        end
        return nil unless blob.variable?
        variant(db, blob, Variation.default_to(variation, blob.default_variant_format))
      end

      # VariantWithRecord#processed for a variation already defaulted.
      def variant(db, blob, variation)
        dumped = Variation.dump(variation)
        digest = Variation.digest_dumped(dumped)
        if (found = Storage.existing_variant(db, blob.id, digest))
          return found
        end
        format = Variation.format(variation) or raise ArgumentError, "invalid variant format #{variation[:format].inspect}"
        dims = Variation.resize_to_limit(variation)
        input = checked_path(blob)
        ext = format.downcase
        output = File.join(processing_dir, "variant-#{SecureRandom.hex(8)}.#{ext}")
        begin
          Media.resize_to_limit(input, output, dims&.at(0), dims&.at(1))
          type = Mime.for_extension(ext) || "image/#{ext}"
          staged = File.open(output, "rb") { |f| Storage.stage_upload("#{blob.base}.#{ext}", type, f) }
        ensure
          File.unlink(output) if File.exist?(output)
        end
        won = false
        image = nil
        Storage.transaction(db) do
          db.execute("INSERT INTO active_storage_variant_records (blob_id, variation_digest) VALUES (?, ?) ON CONFLICT (blob_id, variation_digest) DO NOTHING".freeze, blob.id, digest)
          if db.changes == 1
            record_id = db.last_insert_rowid
            image = staged.insert(db)
            db.execute(SQL_INSERT_ATTACHMENT, image.id, "ActiveStorage::VariantRecord", record_id, "image", Clock.now_db)
            won = true
          end
        end
        staged.discard
        won ? image : Storage.existing_variant(db, blob.id, digest)
      ensure
        staged&.discard unless won
      end

      # Preview#process: the video's poster frame as preview_image.
      def preview_image(db, blob)
        if (image = Storage.attached(db, "ActiveStorage::Blob", blob.id, "preview_image"))
          return image
        end
        jpeg = Media.video_frame(checked_path(blob))
        raise Media::Error, "empty preview frame for blob #{blob.id}" if jpeg.empty?
        staged = Storage.stage_upload("#{blob.base}.jpg", "image/jpeg", jpeg)
        won = false
        image = nil
        Storage.transaction(db) do
          unless db.query_single_splat("SELECT 1 FROM active_storage_attachments WHERE record_type = 'ActiveStorage::Blob' AND record_id = ? AND name = 'preview_image' LIMIT 1".freeze, blob.id)
            image = staged.insert(db)
            db.execute(SQL_INSERT_ATTACHMENT, image.id, "ActiveStorage::Blob", blob.id, "preview_image", Clock.now_db)
            won = true
          end
        end
        won ? image : Storage.attached(db, "ActiveStorage::Blob", blob.id, "preview_image")
      ensure
        staged&.discard unless won
      end

      # Blob#analyze: merges analyzer metadata, sets analyzed, touches the
      # attached records (and their rooms) like Attachment#touch.
      def analyze(db, blob)
        meta = blob.metadata_hash.dup
        if blob.image?
          if (dims = Media.image_dimensions(checked_path(blob)))
            meta["width"], meta["height"] = dims
          end
        elsif blob.video? || blob.audio?
          meta.merge!(Analysis.media(Media.probe(checked_path(blob)), blob.video?))
        end
        meta["analyzed"] = true
        json = JSON.generate(meta)
        Storage.transaction(db) do
          db.execute("UPDATE active_storage_blobs SET metadata = ? WHERE id = ?".freeze, json, blob.id)
          now = Clock.now_db
          # (the messages' rooms follow, db/triggers.sql)
          db.execute("UPDATE messages SET updated_at = ? WHERE id IN (SELECT record_id FROM active_storage_attachments WHERE blob_id = ? AND record_type = 'Message')".freeze, now, blob.id)
          db.execute("UPDATE users SET updated_at = ? WHERE id IN (SELECT record_id FROM active_storage_attachments WHERE blob_id = ? AND record_type = 'User')".freeze, now, blob.id)
          db.execute("UPDATE accounts SET updated_at = ? WHERE id IN (SELECT record_id FROM active_storage_attachments WHERE blob_id = ? AND record_type = 'Account')".freeze, now, blob.id)
        end
        blob.metadata = json
        blob.instance_variable_set(:@metadata_hash, nil)
        blob
      end

      PURGE_DEPENDENTS = "(record_type = 'ActiveStorage::VariantRecord' AND record_id IN (SELECT id FROM active_storage_variant_records WHERE blob_id = ?)) OR (record_type = 'ActiveStorage::Blob' AND record_id = ? AND name = 'preview_image')"
      SQL_DEPENDENT_BLOBS = "SELECT blob_id FROM active_storage_attachments WHERE #{PURGE_DEPENDENTS}".freeze
      SQL_DELETE_DEPENDENTS = "DELETE FROM active_storage_attachments WHERE #{PURGE_DEPENDENTS}".freeze

      # Blob#purge: refuses attached blobs; removes variants and preview
      # images (recursively), the row, then the file.
      def purge(db, id)
        pending = [id]
        seen = {}
        until pending.empty?
          id = pending.shift
          next if seen[id]
          seen[id] = true
          key = nil
          dependents = nil
          Storage.transaction(db) do
            key = db.query_single_splat("SELECT key FROM active_storage_blobs WHERE id = ?".freeze, id)
            if key && db.query_single_splat("SELECT count(*) FROM active_storage_attachments WHERE blob_id = ?".freeze, id) == 0
              dependents = db.query_splat(SQL_DEPENDENT_BLOBS, id, id)
              db.execute(SQL_DELETE_DEPENDENTS, id, id)
              db.execute("DELETE FROM active_storage_variant_records WHERE blob_id = ?".freeze, id)
              db.execute("DELETE FROM active_storage_blobs WHERE id = ?".freeze, id)
            else
              key = nil
            end
          end
          next unless key
          if (path = Storage.safe_path(key))
            File.unlink(path) if File.exist?(path)
          end
          FileUtils.rm_rf(File.join(Storage.root, "variants", key)) unless key.include?("..")
          pending.concat(dependents)
        end
        nil
      end

      # Message#process_attachment: analyze, then the thumbnail (images) or
      # the webp preview (videos).
      def process_attachment(db, blob)
        blob = analyze(db, blob)
        if blob.previewable? then representation(db, blob, PREVIEW_WEBP)
        elsif blob.variable? then representation(db, blob, THUMB)
        end
        blob
      end
    end

    # Job handlers (Jobs.register). Arguments are ints/strings; results are
    # blob ids (shareable) or nil.
    module VariantJob
      # (blob_id, Variation.dump(variation)) -> representation blob id
      def self.perform(blob_id, dumped)
        db = DB.connection
        blob = Storage.find(db, blob_id) or return nil
        Work.representation(db, blob, Variation.load(dumped))&.id
      end
    end

    module PreviewJob
      def self.perform(blob_id)
        db = DB.connection
        (blob = Storage.find(db, blob_id)) && blob.previewable? ? Work.preview_image(db, blob)&.id : nil
      end
    end

    module AnalyzeJob
      def self.perform(blob_id)
        db = DB.connection
        (blob = Storage.find(db, blob_id)) ? Work.analyze(db, blob).id : nil
      end
    end

    module PurgeJob
      def self.perform(blob_id) = Work.purge(DB.connection, blob_id)
    end

    module ProcessAttachmentJob
      def self.perform(blob_id)
        db = DB.connection
        (blob = Storage.find(db, blob_id)) ? Work.process_attachment(db, blob).id : nil
      end
    end

    Jobs.register(:variant, VariantJob)
    Jobs.register(:preview, PreviewJob)
    Jobs.register(:analyze, AnalyzeJob)
    Jobs.register(:purge, PurgeJob)
    Jobs.register(:process_attachment, ProcessAttachmentJob)
  end
end
