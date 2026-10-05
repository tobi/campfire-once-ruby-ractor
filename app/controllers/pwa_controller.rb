# frozen_string_literal: true

module Campfire
  class PwaController < ApplicationController
    allow_unauthenticated_access
    skip_forgery_protection

    JS_TYPE = "text/javascript; charset=utf-8"
    SERVICE_WORKER = File.read(File.join(ROOT, "app/views/pwa/service_worker.js")).freeze

    def service_worker
      text(SERVICE_WORKER, 200, JS_TYPE)
    end

    def manifest
      @b = String.new(capacity: 2048, encoding: Encoding::UTF_8)
      pwa_manifest
      json(@b)
    end
  end
end
