# frozen_string_literal: true

module Campfire
  module RailsCompat
    # Forgery protection by the Sec-Fetch-Site header instead of authenticity tokens, as Rails
    # main's `protect_from_forgery using: :header_only` (and once-campfire-rust) does. A deliberate
    # divergence from the Rails app: pages carry no csrf-token meta tag and no authenticity_token
    # fields, so a page renders the same until what it shows changes (stable ETags, cacheable parts).
    #
    # A write passes when its Origin (if any) is the app's own and its Sec-Fetch-Site says
    # same-origin or same-site. Browsers send the header on every request to a secure origin;
    # without it (an old browser, or plain HTTP) a write is only allowed when `ssl` is false:
    # neither the app (force_ssl, i.e. no DISABLE_SSL) nor the request uses SSL. There the
    # SameSite=Lax session cookie and the Origin check are the protection.
    module CSRF
      ORIGIN_CHECK = true # forgery_protection_origin_check

      module_function

      def valid_request?(origin, base_url, fetch_site, ssl)
        valid_request_origin?(origin, base_url) && same_site_request?(fetch_site, ssl)
      end

      # valid_request_origin?: blank Origin is accepted; "null" makes Rails
      # raise InvalidAuthenticityToken (same 422 outcome) -> false here.
      def valid_request_origin?(origin, base_url)
        return true unless ORIGIN_CHECK
        return true if origin.nil?
        return false if origin == "null"
        origin == base_url
      end

      def same_site_request?(fetch_site, ssl)
        case fetch_site
        when "same-origin", "same-site" then true
        when nil then !ssl
        else false
        end
      end
    end
  end
end
