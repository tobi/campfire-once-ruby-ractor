# frozen_string_literal: true

module Campfire
  # QrCodeController#show: the id is a urlsafe Base64 URL (qr_code_path in
  # QrCodeHelper); the SVG is public and cached for a year.
  class QrCodeController < ApplicationController
    allow_unauthenticated_access

    SVG_TYPE = "image/svg+xml; charset=utf-8"
    CACHE_CONTROL = "max-age=31556952, public"

    def show
      url = urlsafe_decode64(params["id"].to_s) or return text(Assets.file("/500.html")&.body || "", 500, PUBLIC_ERROR_TYPE)
      svg = Cache.fetch(:qr_code_svg, url) { QrCode.svg(url).freeze }
      add_header("cache-control", CACHE_CONTROL)
      text(svg, 200, SVG_TYPE)
    end

    private

    # Base64.urlsafe_decode64: pads when needed, then strict-decodes.
    def urlsafe_decode64(str)
      s = str.tr("-_", "+/")
      s = s.ljust((s.length + 3) & ~3, "=") unless s.length % 4 == 0
      s.unpack1("m0").force_encoding(Encoding::UTF_8)
    rescue ArgumentError
      nil
    end
  end
end
