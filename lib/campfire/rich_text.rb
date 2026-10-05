# frozen_string_literal: true

require "json"
require "uri"
require "erb/escape"

module Campfire
  # Campfire's Action Text / Lexxy rendering pipeline in pure Ruby (Ractor-safe).
  #
  # Every entry point takes the stored message body plus:
  #   host:     the request host (opengraph embeds may not point back at it)
  #   resolver: user lookup; a callable ->(id) or an object with #find_user(id),
  #             returning a user (id name title attachable_sgid user_path
  #             avatar_path) or nil
  #   verifier: callable ->(sgid) returning the verified gid string or nil;
  #             only mentioned_user_ids needs it (see SGID::Verifier)
  #
  # Failures Rails would raise surface as Campfire::RichText::Error, except
  # presentation, which (like MessagesHelper#message_presentation) returns "".
  module RichText
    class Error < StandardError; end

    require_relative "rich_text/html5"
    require_relative "rich_text/dom"
    require_relative "rich_text/sanitizer"
    require_relative "rich_text/plain_text"
    require_relative "rich_text/autolink"
    require_relative "rich_text/sgid"
    require_relative "rich_text/renderer"

    User = Data.define(:id, :name, :title, :attachable_sgid, :user_path, :avatar_path)
    Result = Struct.new(:presentation, :plain_text, :filtered, :body_html, :editable, :mentioned_user_ids, :errors)

    EMOJI = /\A(\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)+\z/u

    module_function

    def presentation(body, host:, resolver: nil)
      Renderer.new(host, resolver).presentation(body)
    rescue Error
      ""
    end

    def body_html(body, host: nil, resolver: nil) = Renderer.new(host, resolver).body_html(body)
    def plain_text(body, host: nil, resolver: nil) = Renderer.new(host, resolver).plain_text(body)
    def canonical(body, host: nil, resolver: nil) = Renderer.new(host, resolver).canonical(body)
    def filtered(body, host:, resolver: nil) = Renderer.new(host, resolver).filtered(body)
    def editable(body, host: nil, resolver: nil) = Renderer.new(host, resolver).editable(body)

    def mentioned_user_ids(body, resolver:, verifier:)
      Renderer.new(nil, resolver, verifier).mentioned_user_ids(body)
    end

    # All fields at once, sharing the parsed body; per-field failures land in
    # Result#errors (field => Error) and leave the field nil.
    def render(body, host:, resolver: nil, verifier: nil)
      Renderer.new(host, resolver, verifier).render(body)
    end

    def all_emoji?(string) = EMOJI.match?(string)
  end
end
