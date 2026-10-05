# frozen_string_literal: true

require "async/semaphore"

module Campfire
  # UnfurlLinksController: the composer asks for a pasted URL's OpenGraph
  # metadata (Opengraph::Metadata.from_url, app/models/opengraph.rb).
  #
  # Unlike Rails, which gives each connect and read 60 seconds, an unfurl has 10
  # seconds in all (then it unfurls nothing), each connect or read 5, and at most
  # 16 run at once per worker (ref-rust's limits): the endpoint is open to any
  # signed-in user and fetches pages they choose.
  class UnfurlLinksController < ApplicationController
    DEADLINE = 10
    MAX_CONCURRENT_UNFURLS = 16
    BAD_REQUEST_JSON = '{"status":400,"error":"Bad Request"}'
    ERROR_JSON_TYPE = "application/json; charset=UTF-8"

    # POST /unfurl_link
    def create
      url = params["url"]
      bad_request! if Opengraph.blank?(url) # params.require(:url)
      # A hash or array passes `require`, but URI.parse can't take it (rescued), so
      # nothing is fetched and the metadata has no title.
      return head(204) unless url.is_a?(String)
      if (body = unfurl(url))
        json(body)
      else
        head(204)
      end
    end

    private

    # -> the metadata's JSON when valid?, else nil (also when out of time)
    def unfurl(url)
      slots = (Ractor.current[:unfurl_slots] ||= Async::Semaphore.new(MAX_CONCURRENT_UNFURLS))
      Sync do |task|
        task.with_timeout(DEADLINE) do
          slots.acquire do
            opengraph = Opengraph::Metadata.from_url(url)
            opengraph.valid? ? opengraph.to_json : nil
          end
        end
      rescue Async::TimeoutError
        Opengraph.warn("Gave up unfurling #{url} after #{DEADLINE}s")
        nil
      end
    end

    # ActionController::ParameterMissing -> PublicExceptions: JSON for a JSON
    # request format, else public/400.html, which doesn't exist (an empty body).
    def bad_request!
      if head_content_type == "application/json"
        @response = Responses.build(400, [["content-type", ERROR_JSON_TYPE]], @request.method == "HEAD" ? nil : BAD_REQUEST_JSON)
      else
        text("", 400, PUBLIC_ERROR_TYPE)
      end
      throw :halt
    end
  end
end
