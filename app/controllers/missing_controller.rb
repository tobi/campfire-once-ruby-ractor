# frozen_string_literal: true

module Campfire
  class MissingController < ApplicationController
    allow_unauthenticated_access
    def method_missing(*) = text("Not implemented", 501)
    def respond_to_missing?(*) = true
  end
end
