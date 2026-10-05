# frozen_string_literal: true

module Campfire
  ROOT = File.expand_path("../..", __dir__).freeze

  # Process-wide settings, read once in the main Ractor and frozen.
  Config = Data.define(
    :storage_path, :database_path, :files_path, :secret_key_base, :workers, :job_workers,
    :bind, :port, :app_version, :git_revision, :vapid_public_key, :vapid_private_key,
    :background_checkpoints # the server checkpoints the WAL off the request path (DB.checkpointer)
  ) do
    def self.from_env(env = ENV)
      storage = File.expand_path(env.fetch("CAMPFIRE_STORAGE_PATH", "storage"), ROOT)
      new(
        storage_path: storage,
        database_path: env.fetch("CAMPFIRE_DATABASE_PATH") { File.join(storage, "db", "production.sqlite3") },
        files_path: env.fetch("CAMPFIRE_FILES_PATH") { File.join(storage, "files") },
        secret_key_base: env["SECRET_KEY_BASE"] || raise("SECRET_KEY_BASE is required"),
        workers: Integer(env.fetch("WEB_CONCURRENCY", "4")),
        job_workers: Integer(env.fetch("JOB_CONCURRENCY", "2")),
        bind: env.fetch("BIND", "0.0.0.0"),
        port: Integer(env.fetch("PORT") { env.fetch("HTTP_PORT", "3000") }),
        app_version: env.fetch("APP_VERSION", "0"),
        git_revision: env.fetch("GIT_REVISION", "0"),
        vapid_public_key: env["VAPID_PUBLIC_KEY"],
        vapid_private_key: env["VAPID_PRIVATE_KEY"],
        background_checkpoints: false
      )
    end
  end
end
