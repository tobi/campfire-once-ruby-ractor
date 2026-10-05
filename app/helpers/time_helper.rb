# frozen_string_literal: true

module Campfire
  module Helpers
    # local_datetime_tag(datetime, style: :time, **attributes):
    # <time [attributes] datetime="2026-02-28T18:44:00Z" data-local-time-target="time"></time>
    def local_datetime_tag(datetime, style: :time, **attributes)
      @b << "<time"
      attrs(attributes) unless attributes.empty?
      @b << ' datetime="' << Clock.iso8601(datetime) << '" data-local-time-target="' << style.to_s << '"></time>'
      nil
    end
  end
end
