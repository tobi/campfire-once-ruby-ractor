# frozen_string_literal: true

module Campfire
  # Routes are grouped by their first path segment; within a group each route
  # is one anchored regex. Patterns use Rails syntax (`/rooms/:room_id/messages`)
  # and accept an optional `.format` suffix like Rails' `(.:format)`.
  class Router
    Route = Data.define(:verb, :regex, :names, :controller, :action, :defaults)

    def initialize(&block)
      @groups = Hash.new { |h, k| h[k] = [] }
      instance_eval(&block)
    end

    %w[GET POST PATCH PUT DELETE].each do |verb|
      define_method(verb.downcase) do |pattern, to:, defaults: nil, format: true|
        add(verb, pattern, to, defaults, format)
      end
    end

    def add(verb, pattern, to, defaults, format)
      controller, action = to.split("#")
      names = []
      src = pattern.gsub(%r{:(\w+)|\*(\w+)|\.|@}) do
        if $1
          names << $1
          "([^/.]+)"
        elsif $2
          names << $2
          "(.+)"
        else
          Regexp.escape($&)
        end
      end
      src << "(?:\\.([a-z0-9]+))?" if format
      first = pattern.split("/")[1] || ""
      first = "" if first.start_with?(":")
      @groups[first] << Route.new(verb, Regexp.new("\\A#{src}\\z"), names.freeze,
        controller, action.to_sym, defaults&.freeze)
    end

    # Resolve controller names to classes and freeze for sharing across Ractors.
    def finalize!(namespace)
      @groups = @groups.transform_values do |routes|
        routes.map { |r| r.with(controller: resolve(namespace, r)) }.freeze
      end.freeze
      @fallback = @groups[""] || [].freeze
      freeze
      Ractor.make_shareable(self)
    end

    # => [route, params_hash, format] or nil. HEAD matches GET routes.
    def recognize(verb, path)
      verb = "GET" if verb == "HEAD"
      slash = path.index("/", 1)
      first = slash ? path[1, slash - 1] : path[1..]
      dot = first.index(".")
      first = first[0, dot] if dot
      route_in(@groups[first], verb, path) || route_in(@fallback, verb, path)
    end

    private

    def route_in(routes, verb, path)
      return nil unless routes
      routes.each do |r|
        next unless r.verb == verb
        m = r.regex.match(path) or next
        params = r.defaults ? r.defaults.dup : {}
        # Captures are fresh slices of the ASCII-8BIT path; retag them (no copy) so they bind
        # to SQLite as TEXT, not BLOB.
        r.names.each_with_index { |n, i| params[n] = m[i + 1]&.force_encoding(Encoding::UTF_8) }
        return [r, params, m[r.names.size + 1]]
      end
      nil
    end
  end
end

module Campfire
  class Router
    # Controllers not ported yet answer 501 so the app boots while incomplete.
    def resolve(namespace, route)
      namespace.const_get(route.controller)
    rescue NameError
      Log.info "router: #{route.controller} missing" if $VERBOSE
      MissingController
    end
  end
end
