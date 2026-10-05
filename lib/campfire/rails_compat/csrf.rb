# frozen_string_literal: true

require_relative "util"

module Campfire
  module RailsCompat
    # ActionController::RequestForgeryProtection, Rails 8.2 defaults as the app
    # runs them (verified against the reference vectors):
    #   per_form_csrf_tokens = true, forgery_protection_origin_check = true,
    #   session key "_csrf_token" holding SecureRandom.urlsafe_base64(32)
    #   (43 chars, url-safe, unpadded).
    #
    # Tokens: raw = urlsafe_decode64(session["_csrf_token"]) (32 bytes)
    #   global  = HMAC-SHA256(raw, "!real_csrf_token")
    #   form    = HMAC-SHA256(raw, "#{normalized_action_path}##{method.downcase}")
    #   masked  = urlsafe_encode64(pad + (pad XOR token), padding: false)  (86 chars)
    #
    # Stateless module functions; nothing here needs SECRET_KEY_BASE.
    module CSRF
      SESSION_KEY = "_csrf_token"
      PARAM = "authenticity_token"
      HEADER = "x-csrf-token"
      TOKEN_LENGTH = 32
      GLOBAL_IDENTIFIER = "!real_csrf_token"
      PER_FORM_CSRF_TOKENS = true
      ORIGIN_CHECK = true
      SCHEME_RE = /\A[A-Za-z][A-Za-z0-9+\-.]*:/
      PACK = "L8"

      module_function

      # generate_csrf_token: a new value for session["_csrf_token"].
      def generate_session_token
        Util.urlsafe_encode64_unpadded(Util.random_bytes(TOKEN_LENGTH))
      end

      # decode_csrf_token(session["_csrf_token"]) or nil.
      def raw_token(session_token)
        session_token.is_a?(String) ? Util.urlsafe_decode64(session_token) : nil
      end

      def global_token(raw)
        OpenSSL::HMAC.digest("SHA256", raw, GLOBAL_IDENTIFIER)
      end

      def per_form_token(raw, action_path, method)
        OpenSSL::HMAC.digest("SHA256", raw, "#{action_path}##{method.to_s.downcase}")
      end

      # form_authenticity_token(form_options: { action:, method: }).
      # Without action/method (csrf_meta_tags, or a form helper not passing
      # them) it's the masked global token. A relative `action` is resolved
      # against `request_path` (normalize_action_path).
      def masked_token(session_token, action: nil, method: nil, request_path: "/")
        raw = raw_token(session_token) or raise ArgumentError, "invalid session csrf token"
        token =
          if PER_FORM_CSRF_TOKENS && action && method
            per_form_token(raw, normalize_action_path(action, request_path), method)
          else
            global_token(raw)
          end
        mask(token)
      end
      alias form_authenticity_token masked_token

      def mask(token)
        pad = Util.random_bytes(TOKEN_LENGTH)
        Util.urlsafe_encode64_unpadded(pad + xor(pad, token))
      end

      def unmask(masked)
        xor(masked.byteslice(0, TOKEN_LENGTH), masked.byteslice(TOKEN_LENGTH, TOKEN_LENGTH))
      end

      def xor(a, b)
        x = a.unpack(PACK)
        y = b.unpack(PACK)
        i = 0
        while i < 8
          x[i] ^= y[i]
          i += 1
        end
        x.pack(PACK)
      end

      # valid_authenticity_token?(session, encoded_masked_token). Accepts the
      # unmasked session token, any masked session/global token, and (with
      # request_path/request_method given) the per-form token for
      # request_path.chomp("/") + method.
      def valid_authenticity_token?(session_token, encoded, request_path: nil, request_method: nil)
        return false unless encoded.is_a?(String) && !encoded.empty?
        raw = raw_token(session_token) or return false
        token = Util.urlsafe_decode64(encoded) or return false
        case token.bytesize
        when TOKEN_LENGTH
          Util.secure_compare(token, raw)
        when TOKEN_LENGTH * 2
          csrf = unmask(token)
          Util.secure_compare(csrf, global_token(raw)) ||
            Util.secure_compare(csrf, raw) ||
            (PER_FORM_CSRF_TOKENS && request_path && request_method &&
              Util.secure_compare(csrf, per_form_token(raw, request_path.chomp("/"), request_method))) ||
            false
        else
          false
        end
      end

      # any_authenticity_token_valid?: the form param or the X-CSRF-Token header.
      def any_authenticity_token_valid?(session_token, tokens, request_path: nil, request_method: nil)
        tokens.any? { |t| valid_authenticity_token?(session_token, t, request_path: request_path, request_method: request_method) }
      end

      # valid_request_origin?: blank Origin is accepted; "null" makes Rails
      # raise InvalidAuthenticityToken (same 422 outcome) -> false here.
      def valid_request_origin?(origin, base_url)
        return true unless ORIGIN_CHECK
        return true if origin.nil?
        return false if origin == "null"
        origin == base_url
      end

      # normalize_action_path(action) for a page at request_path.
      def normalize_action_path(action, request_path = "/")
        action = action.to_s
        if SCHEME_RE.match?(action)
          rest = action.sub(SCHEME_RE, "")
          path =
            if rest.start_with?("//")
              after = rest.byteslice(2, rest.bytesize)
              (i = after.index(%r{[/?#]})) ? strip_query(after[i..]) : ""
            elsif rest.start_with?("/")
              strip_query(rest)
            else
              "" # opaque URI (mailto:...): URI#path is nil
            end
          path = "" unless path.start_with?("/")
          path.chomp("/")
        elsif !action.empty? && action.start_with?("/")
          path = strip_query(action)
          if path.start_with?("//") # network-path reference: drop the authority
            after = path.byteslice(2, path.bytesize)
            path = (i = after.index("/")) ? after[i..] : ""
          end
          path.chomp("/")
        else
          path = strip_query(request_path.to_s).dup
          path << "/" << strip_query(action)
          path.gsub!("/./", "/")
          path.chomp("/")
        end
      end

      def strip_query(s)
        i = s.index(/[?#]/)
        i ? s[0, i] : s
      end
    end
  end
end
