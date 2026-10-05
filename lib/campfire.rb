# frozen_string_literal: true

# Boot: load everything in the main Ractor, compile templates into methods,
# then deep-freeze every constant so worker Ractors can read them.
# io_uring fails (EEXIST on submit) when a second thread in the Ractor blocks
# on Ractor::Port#receive, which the bus and job bridges do; epoll is fine.
ENV["IO_EVENT_SELECTOR"] ||= "EPoll"

require "bundler/setup"
require "json"
require "time"
require "erb/escape"
require "securerandom"
require "fileutils"
require "extralite"
require "bcrypt"
require "async"
require "async/semaphore"

require_relative "ractor_compat"
require_relative "campfire/config"
require_relative "campfire/log"
require_relative "campfire/db"
require_relative "campfire/http"
require_relative "campfire/front"
require_relative "campfire/page_parts"
require_relative "campfire/rails_compat"
require_relative "campfire/user_agent"
require_relative "campfire/cache"
require_relative "campfire/assets"
require_relative "campfire/template"
require_relative "campfire/router"
require_relative "campfire/bus"
require_relative "campfire/jobs"
require_relative "campfire/server"

module Campfire
  module_function

  def secrets = SECRETS
  def config = CONFIG

  # Every view/partial becomes a method on Views; helpers append to @b.
  module Views; end
  module Helpers; end

  def load_app!
    Dir[File.join(ROOT, "lib/campfire/{storage,cable,multipart,rich_text,web_push}.rb")].each { |f| require f }
    Dir[File.join(ROOT, "app/helpers/**/*.rb")].sort.each { |f| require f }
    Dir[File.join(ROOT, "app/models/**/*.rb")].sort.each { |f| require f }
    require_relative "campfire/controller"
    require File.join(ROOT, "app/controllers/application_controller.rb")
    Dir[File.join(ROOT, "app/controllers/**/*.rb")].sort.each { |f| require f }
    Dir[File.join(ROOT, "app/channels/**/*.rb")].sort.each { |f| require f }
    Dir[File.join(ROOT, "app/jobs/**/*.rb")].sort.each { |f| require f }
    Template.define_all(Views, File.join(ROOT, "app/views"))
    require_relative "campfire/app"
    require File.join(ROOT, "config/routes.rb")
  end

  def boot!(config = Config.from_env)
    const_set(:CONFIG, Ractor.make_shareable(config))
    const_set(:SECRETS, RailsCompat::Secrets.new(config.secret_key_base))
    DB.prepare!(config.database_path)
    Assets.load!
    load_app!
    ROUTES.finalize!(self)
    RactorCompat.share_constants!(extra_roots: [Campfire, Extralite, BCrypt, ERB, OpenSSL])
  end
end
