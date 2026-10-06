# frozen_string_literal: true

module Campfire
  # Rails' ApplicationController filter chain, in the reference order:
  # allow_browser, require_authentication, deny_bots, verify_authenticity_token,
  # reject_banned_ip, set_version_headers. Subclasses opt out per action.
  class ApplicationController < Controller
    include Helpers
    include Views

    # Set at load time: worker Ractors may read but not assign class ivars.
    @filters = {}

    class << self
      def filters = (@filters ||= {})

      def skip(filter, only: nil, except: nil)
        filters[filter] = only ? [:only, only.map(&:to_sym)] : except ? [:except, except.map(&:to_sym)] : [:all]
      end

      def allow_unauthenticated_access(**opts) = skip(:authentication, **opts)
      def allow_bot_access(**opts) = skip(:deny_bots, **opts)
      def skip_forgery_protection(**opts) = skip(:csrf, **opts)
      def skip_allow_browser(**opts) = skip(:allow_browser, **opts)

      def require_unauthenticated_access(**opts)
        skip(:authentication, **opts)
        skip(:require_unauthenticated, except: []) unless opts.any?
        filters[:unauthenticated_only] = opts.empty? ? [:all] : [:only, (opts[:only] || []).map(&:to_sym)]
      end

      def skipped?(filter, action)
        own = filters[filter]
        rule = own || (superclass.respond_to?(:skipped?) ? (return superclass.skipped?(filter, action)) : nil)
        return false unless rule
        case rule[0]
        when :all then true
        when :only then rule[1].include?(action)
        when :except then !rule[1].include?(action)
        end
      end

      def inherited(sub)
        super
        sub.instance_variable_set(:@filters, {})
      end
    end

    def dispatch(action)
      @action = action
      klass = self.class
      catch(:halt) do
        # Rails callback order: `include AllowBrowser, Authentication, ...,
        # BlockBannedRequests, ...` includes right to left, so reject_banned_ip,
        # require_authentication, deny_bots and verify_authenticity_token run
        # before allow_browser, and require_unauthenticated_access's filters
        # (added by subclasses) run last.
        filter_head(429) if !get? && Ban.banned?(@db, remote_ip)
        unless klass.skipped?(:authentication, action)
          throw :halt unless require_authentication
        end
        filter_head(403) if authenticated_by_bot? && !klass.skipped?(:deny_bots, action)
        unless authenticated_by_bot? || klass.skipped?(:csrf, action) || verified_request?
          # ActionController::InvalidAuthenticityToken -> public/422.html
          text(Assets.file("/422.html")&.body || "", 422, PUBLIC_ERROR_TYPE)
          throw :halt
        end
        unless klass.skipped?(:allow_browser, action) || UserAgentCache.allowed?(user_agent)
          html { sessions_incompatible_browser }
          throw :halt
        end
        if klass.skipped?(:unauthenticated_only, action) == false && klass.filters_for_unauth?(action)
          restore_authentication
          if signed_in?
            redirect_to("/")
            throw :halt
          end
        end
        before_action
        public_send(action) unless @response
      end
      @response || head(204)
    end

    # Hook for per-controller before_actions; call `throw :halt` after rendering to stop.
    def before_action; end

    def self.filters_for_unauth?(action)
      rule = filters[:unauthenticated_only] || (superclass.respond_to?(:filters_for_unauth?) ? nil : nil)
      return false unless rule
      rule[0] == :all || rule[1].include?(action)
    end

    # ---- shared lookups -------------------------------------------------

    def platform = (@platform ||= UserAgentCache.platform(user_agent))

    def last_room_visited
      @last_room_visited ||= begin
        id = cookies["last_room"]
        (id && Room.find_for_user(@db, current_user.id, id.to_i)) || Room.original_for_user(@db, current_user.id)
      end
    end

    # Only when it changes: Rails sets it on every room page.
    def remember_last_room_visited
      id = @room.id.to_s
      set_cookie("last_room", id, expires: Campfire.secrets.permanent_expiry, same_site: "lax") unless cookies["last_room"] == id
    end

    def ensure_can_administer(record = nil)
      filter_head(403) unless current_user.can_administer?(record)
    end

    # ActionDispatch::PublicExceptions content type.
    PUBLIC_ERROR_TYPE = "text/html; charset=UTF-8"

    # ActiveRecord::RecordNotFound -> public/404.html
    def not_found!
      text(Assets.file("/404.html")&.body || "Not Found", 404, PUBLIC_ERROR_TYPE)
      throw :halt
    end
  end

  # allow_browser and ApplicationPlatform parse the UA string; workers memoize
  # per distinct UA since browsers send the same string on every request.
  module UserAgentCache
    module_function

    def allowed?(ua) = Cache.fetch(:ua_allowed, ua) { UserAgent.allowed?(ua) }
    def platform(ua) = Cache.fetch(:ua_platform, ua) { ApplicationPlatform.new(ua) }
  end

  module Ban
    module_function

    def banned?(db, ip)
      !db.query_single_splat("SELECT 1 FROM bans WHERE ip_address = ? LIMIT 1".freeze, ip).nil?
    end
  end
end
