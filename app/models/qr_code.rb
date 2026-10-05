# frozen_string_literal: true

require_relative "../../lib/campfire/vendor/rqrcode_core"

module Campfire
  # RQRCode::QRCode.new(url).as_svg(viewbox: true, fill: :white, color: :black)
  # from rqrcode 3.2.0 (MIT, Duncan Robertson): rect mode, module size 11,
  # no offset, standalone. Only the options QrCodeController uses.
  module QrCode
    MODULE_SIZE = 11
    SVG_OPEN = '<?xml version="1.0" standalone="yes"?><svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events" viewBox="0 0 '

    module_function

    def svg(data)
      qr = RQRCodeCore::QRCode.new(data)
      modules = qr.modules
      count = qr.module_count
      dim = (count * MODULE_SIZE).to_s
      size = MODULE_SIZE.to_s
      coords = Array.new(count) { |i| (i * MODULE_SIZE).to_s }
      out = String.new(capacity: 512 + count * count * 30, encoding: Encoding::UTF_8)
      out << SVG_OPEN << dim << " " << dim << '" shape-rendering="crispEdges"><rect width="' << dim << '" height="' << dim << '" x="0" y="0" fill="white"/>'
      c = 0
      while c < count
        row = modules[c]
        r = 0
        while r < count
          if row[r]
            out << '<rect width="' << size << '" height="' << size << '" x="' << coords[r] << '" y="' << coords[c] << '" fill="black"/>'
          end
          r += 1
        end
        c += 1
      end
      out << "</svg>"
    end
  end
end
