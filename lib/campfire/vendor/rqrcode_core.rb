# frozen_string_literal: true

# Vendored rqrcode_core 2.1.0 (https://github.com/whomwah/rqrcode_core),
# namespaced under Campfire and with its constant tables made Ractor-shareable.
# Upstream Campfire renders QR codes with rqrcode 3.2.0 / rqrcode_core 2.1.0.
#
# The MIT License (MIT)
#
# Copyright (c) 2008 Duncan Robertson
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

module Campfire

# ---- qr_8bit_byte.rb

module RQRCodeCore
  class QR8bitByte
    def initialize(data)
      @data = data
    end

    def write(buffer)
      buffer.byte_encoding_start(@data.bytesize)

      @data.each_byte do |b|
        buffer.put(b, 8)
      end
    end
  end
end

# ---- qr_alphanumeric.rb

module RQRCodeCore
  ALPHANUMERIC = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F", "G", "H", "I",
    "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", " ", "$",
    "%", "*", "+", "-", ".", "/", ":"
  ].freeze

  class QRAlphanumeric
    def initialize(data)
      unless QRAlphanumeric.valid_data?(data)
        raise QRCodeArgumentError, "Not a alpha numeric uppercase string `#{data}`"
      end

      @data = data
    end

    def self.valid_data?(data)
      (data.chars - ALPHANUMERIC).empty?
    end

    def write(buffer)
      buffer.alphanumeric_encoding_start(@data.size)

      @data.size.times do |i|
        if i % 2 == 0
          if i == (@data.size - 1)
            value = ALPHANUMERIC.index(@data[i])
            buffer.put(value, 6)
          else
            value = (ALPHANUMERIC.index(@data[i]) * 45) + ALPHANUMERIC.index(@data[i + 1])
            buffer.put(value, 11)
          end
        end
      end
    end
  end
end

# ---- qr_bit_buffer.rb

module RQRCodeCore
  class QRBitBuffer
    attr_reader :buffer

    PAD0 = 0xEC
    PAD1 = 0x11

    def initialize(version)
      @version = version
      @buffer = []
      @length = 0
    end

    def get(index)
      buf_index = (index / 8).floor
      (QRUtil.rszf(@buffer[buf_index], 7 - index % 8) & 1) == 1
    end

    def put(num, length)
      (0...length).each do |i|
        put_bit((QRUtil.rszf(num, length - i - 1) & 1) == 1)
      end
    end

    def get_length_in_bits
      @length
    end

    def put_bit(bit)
      buf_index = (@length / 8).floor
      if @buffer.size <= buf_index
        @buffer << 0
      end

      if bit
        @buffer[buf_index] |= QRUtil.rszf(0x80, @length % 8)
      end

      @length += 1
    end

    def byte_encoding_start(length)
      put(QRMODE[:mode_8bit_byte], 4)
      put(length, QRUtil.get_length_in_bits(QRMODE[:mode_8bit_byte], @version))
    end

    def alphanumeric_encoding_start(length)
      put(QRMODE[:mode_alpha_numk], 4)
      put(length, QRUtil.get_length_in_bits(QRMODE[:mode_alpha_numk], @version))
    end

    def numeric_encoding_start(length)
      put(QRMODE[:mode_number], 4)
      put(length, QRUtil.get_length_in_bits(QRMODE[:mode_number], @version))
    end

    def pad_until(prefered_size)
      # Align on byte
      while get_length_in_bits % 8 != 0
        put_bit(false)
      end

      # Pad with padding code words
      while get_length_in_bits < prefered_size
        put(PAD0, 8)
        put(PAD1, 8) if get_length_in_bits < prefered_size
      end
    end

    def end_of_message(max_data_bits)
      put(0, 4) unless get_length_in_bits + 4 > max_data_bits
    end
  end
end

# ---- qr_code.rb

module RQRCodeCore
  QRMODE = {
    mode_number: 1 << 0,      # 1 (binary: 0001)
    mode_alpha_numk: 1 << 1,  # 2 (binary: 0010)
    mode_8bit_byte: 1 << 2   # 4 (binary: 0100)
  }.freeze

  QRMODE_NAME = {
    number: :mode_number,
    alphanumeric: :mode_alpha_numk,
    byte_8bit: :mode_8bit_byte,
    multi: :mode_multi
  }.freeze

  QRERRORCORRECTLEVEL = {
    l: 1,
    m: 0,
    q: 3,
    h: 2
  }.freeze

  QRMASKPATTERN = {
    pattern000: 0,
    pattern001: 1,
    pattern010: 2,
    pattern011: 3,
    pattern100: 4,
    pattern101: 5,
    pattern110: 6,
    pattern111: 7
  }.freeze

  QRMASKCOMPUTATIONS = [
    proc { |i, j| (i + j) % 2 == 0 },
    proc { |i, j| i % 2 == 0 },
    proc { |i, j| j % 3 == 0 },
    proc { |i, j| (i + j) % 3 == 0 },
    proc { |i, j| ((i / 2).floor + (j / 3).floor) % 2 == 0 },
    proc { |i, j| (i * j) % 2 + (i * j) % 3 == 0 },
    proc { |i, j| ((i * j) % 2 + (i * j) % 3) % 2 == 0 },
    proc { |i, j| ((i * j) % 3 + (i + j) % 2) % 2 == 0 }
  ].freeze

  QRPOSITIONPATTERNLENGTH = (7 + 1) * 2 + 1
  QRFORMATINFOLENGTH = 15

  # http://web.archive.org/web/20110710094955/http://www.denso-wave.com/qrcode/vertable1-e.html
  # http://web.archive.org/web/20110710094955/http://www.denso-wave.com/qrcode/vertable2-e.html
  # http://web.archive.org/web/20110710094955/http://www.denso-wave.com/qrcode/vertable3-e.html
  # http://web.archive.org/web/20110710094955/http://www.denso-wave.com/qrcode/vertable4-e.html
  QRMAXBITS = {
    l: [152, 272, 440, 640, 864, 1088, 1248, 1552, 1856, 2192, 2592, 2960, 3424, 3688, 4184,
      4712, 5176, 5768, 6360, 6888, 7456, 8048, 8752, 9392, 10_208, 10_960, 11_744, 12_248,
      13_048, 13_880, 14_744, 15_640, 16_568, 17_528, 18_448, 19_472, 20_528, 21_616, 22_496, 23_648],
    m: [128, 224, 352, 512, 688, 864, 992, 1232, 1456, 1728, 2032, 2320, 2672, 2920, 3320, 3624,
      4056, 4504, 5016, 5352, 5712, 6256, 6880, 7312, 8000, 8496, 9024, 9544, 10_136, 10_984,
      11_640, 12_328, 13_048, 13_800, 14_496, 15_312, 15_936, 16_816, 17_728, 18_672],
    q: [104, 176, 272, 384, 496, 608, 704, 880, 1056, 1232, 1440, 1648, 1952, 2088, 2360, 2600, 2936,
      3176, 3560, 3880, 4096, 4544, 4912, 5312, 5744, 6032, 6464, 6968, 7288, 7880, 8264, 8920, 9368,
      9848, 10288, 10832, 11408, 12016, 12656, 13328],
    h: [72, 128, 208, 288, 368, 480, 528, 688, 800, 976, 1120, 1264, 1440, 1576, 1784,
      2024, 2264, 2504, 2728, 3080, 3248, 3536, 3712, 4112, 4304, 4768, 5024, 5288, 5608, 5960,
      6344, 6760, 7208, 7688, 7888, 8432, 8768, 9136, 9776, 10_208]
  }.freeze

  # StandardErrors

  class QRCodeArgumentError < ArgumentError; end

  class QRCodeRunTimeError < RuntimeError; end

  # == Creation
  #
  # QRCode objects expect only one required constructor parameter
  # and an optional hash of any other. Here's a few examples:
  #
  #  qr = QRCode.new('hello world')
  #  qr = QRCode.new('hello world', size: 1, level: :m, mode: :alphanumeric)
  #

  class QRCode
    attr_reader :modules, :module_count, :version

    # Expects a string or array (for multi-segment encoding) to be parsed in, other args are optional
    #
    #   # data - the string, QRSegment or array of Hashes (with data:, mode: keys) you wish to encode
    #   # size - the size (Integer) of the QR Code (defaults to smallest size needed to encode the data)
    #   # max_size - the max_size (Integer) of the QR Code (default QRUtil.max_size)
    #   # level - the error correction level, can be:
    #      * Level :l 7%  of code can be restored
    #      * Level :m 15% of code can be restored
    #      * Level :q 25% of code can be restored
    #      * Level :h 30% of code can be restored (default :h)
    #   # mode - the mode of the QR Code (defaults to alphanumeric or byte_8bit, depending on the input data, only used when data is a string):
    #      * :number
    #      * :alphanumeric
    #      * :byte_8bit
    #
    #   qr = QRCode.new('hello world', size: 1, level: :m, mode: :alphanumeric)
    #   segment_qr = QRCodeCore::QRCode.new({ data: 'foo', mode: :byte_8bit })
    #   multi_qr = QRCode.new([{ data: 'foo', mode: :byte_8bit }, { data: 'bar1', mode: :alphanumeric }])

    def initialize(data, *args)
      options = extract_options!(args)

      level = (options[:level] || :h).to_sym
      max_size = options[:max_size] || QRUtil.max_size

      @data = case data
      when String
        QRSegment.new(data: data, mode: options[:mode])
      when Array
        raise QRCodeArgumentError, "Array must contain Hashes with :data and :mode keys" unless data.all? { |seg| seg.is_a?(Hash) && %i[data mode].all? { |s| seg.key? s } }
        data.map { |seg| QRSegment.new(**seg) }
      when QRSegment
        data
      else
        raise QRCodeArgumentError, "data must be a String, QRSegment, or an Array"
      end
      @error_correct_level = QRERRORCORRECTLEVEL[level]

      unless @error_correct_level
        raise QRCodeArgumentError, "Unknown error correction level `#{level.inspect}`"
      end

      size = options[:size] || minimum_version(limit: max_size)

      if size > max_size
        raise QRCodeArgumentError, "Given size greater than maximum possible size of #{QRUtil.max_size}"
      end

      @version = size
      @module_count = @version * 4 + QRPOSITIONPATTERNLENGTH
      @modules = Array.new(@module_count)
      @data_list = multi_segment? ? QRMulti.new(@data) : @data.writer
      @data_cache = nil
      make
    end

    # <tt>checked?</tt> is called with a +col+ and +row+ parameter. This will
    # return true or false based on whether that coordinate exists in the
    # matrix returned. It would normally be called while iterating through
    # <tt>modules</tt>. A simple example would be:
    #
    #  instance.checked?( 10, 10 ) => true
    #

    def checked?(row, col)
      if !row.between?(0, @module_count - 1) || !col.between?(0, @module_count - 1)
        raise QRCodeRunTimeError, "Invalid row/column pair: #{row}, #{col}"
      end
      @modules[row][col]
    end
    alias_method :dark?, :checked?
    extend Gem::Deprecate

    deprecate :dark?, :checked?, 2020, 1

    # This is a public method that returns the QR Code you have
    # generated as a string. It will not be able to be read
    # in this format by a QR Code reader, but will give you an
    # idea if the final outout. It takes two optional args
    # +:dark+ and +:light+ which are there for you to choose
    # how the output looks. Here's an example of it's use:
    #
    #  instance.to_s =>
    #  xxxxxxx x  x x   x x  xx  xxxxxxx
    #  x     x  xxx  xxxxxx xxx  x     x
    #  x xxx x  xxxxx x       xx x xxx x
    #
    #  instance.to_s( dark: 'E', light: 'Q' ) =>
    #  EEEEEEEQEQQEQEQQQEQEQQEEQQEEEEEEE
    #  EQQQQQEQQEEEQQEEEEEEQEEEQQEQQQQQE
    #  EQEEEQEQQEEEEEQEQQQQQQQEEQEQEEEQE
    #

    def to_s(*args)
      options = extract_options!(args)
      dark = options[:dark] || "x"
      light = options[:light] || " "
      quiet_zone_size = options[:quiet_zone_size] || 0

      rows = []

      @modules.each do |row|
        cols = light * quiet_zone_size
        row.each do |col|
          cols += (col ? dark : light)
        end
        rows << cols
      end

      quiet_zone_size.times do
        rows.unshift(light * (rows.first.length / light.size))
        rows << light * (rows.first.length / light.size)
      end
      rows.join("\n")
    end

    # Public overide as default inspect is very verbose
    #
    #  QRCode.new('my string to generate', size: 4, level: :h)
    #  => QRCodeCore: @data='my string to generate', @error_correct_level=2, @version=4, @module_count=33
    #

    def inspect
      "QRCodeCore: @data='#{@data}', @error_correct_level=#{@error_correct_level}, @version=#{@version}, @module_count=#{@module_count}"
    end

    # Return a symbol for current error connection level
    def error_correction_level
      QRERRORCORRECTLEVEL.invert[@error_correct_level]
    end

    # Return true if this QR Code includes multiple encoded segments
    def multi_segment?
      @data.is_a?(Array)
    end

    # Return a symbol in QRMODE.keys for current mode used
    def mode
      case @data_list
      when QRNumeric
        :mode_number
      when QRAlphanumeric
        :mode_alpha_numk
      else
        :mode_8bit_byte
      end
    end

    protected

    def make # :nodoc:
      prepare_common_patterns
      make_impl(false, get_best_mask_pattern)
    end

    private

    def prepare_common_patterns # :nodoc:
      @modules.map! { |row| Array.new(@module_count) }

      place_position_probe_pattern(0, 0)
      place_position_probe_pattern(@module_count - 7, 0)
      place_position_probe_pattern(0, @module_count - 7)
      place_position_adjust_pattern
      place_timing_pattern

      @common_patterns = @modules.map(&:clone)
    end

    def make_impl(test, mask_pattern) # :nodoc:
      @modules = @common_patterns.map(&:clone)

      place_format_info(test, mask_pattern)
      place_version_info(test) if @version >= 7

      if @data_cache.nil?
        @data_cache = QRCode.create_data(
          @version, @error_correct_level, @data_list
        )
      end

      map_data(@data_cache, mask_pattern)
    end

    def place_position_probe_pattern(row, col) # :nodoc:
      (-1..7).each do |r|
        next unless (row + r).between?(0, @module_count - 1)

        (-1..7).each do |c|
          next unless (col + c).between?(0, @module_count - 1)

          is_vert_line = r.between?(0, 6) && (c == 0 || c == 6)
          is_horiz_line = c.between?(0, 6) && (r == 0 || r == 6)
          is_square = r.between?(2, 4) && c.between?(2, 4)

          is_part_of_probe = is_vert_line || is_horiz_line || is_square
          @modules[row + r][col + c] = is_part_of_probe
        end
      end
    end

    def get_best_mask_pattern # :nodoc:
      min_lost_point = 0
      pattern = 0

      8.times do |i|
        make_impl(true, i)
        lost_point = QRUtil.get_lost_points(modules)

        if i == 0 || min_lost_point > lost_point
          min_lost_point = lost_point
          pattern = i
        end
      end
      pattern
    end

    def place_timing_pattern # :nodoc:
      (8...@module_count - 8).each do |i|
        @modules[i][6] = @modules[6][i] = i % 2 == 0
      end
    end

    def place_position_adjust_pattern # :nodoc:
      positions = QRUtil.get_pattern_positions(@version)

      positions.each do |row|
        positions.each do |col|
          next unless @modules[row][col].nil?

          (-2..2).each do |r|
            (-2..2).each do |c|
              is_part_of_pattern = r.abs == 2 || c.abs == 2 || (r == 0 && c == 0)
              @modules[row + r][col + c] = is_part_of_pattern
            end
          end
        end
      end
    end

    def place_version_info(test) # :nodoc:
      bits = QRUtil.get_bch_version(@version)

      18.times do |i|
        mod = !test && ((bits >> i) & 1) == 1
        @modules[(i / 3).floor][ i % 3 + @module_count - 8 - 3 ] = mod
        @modules[i % 3 + @module_count - 8 - 3][ (i / 3).floor ] = mod
      end
    end

    def place_format_info(test, mask_pattern) # :nodoc:
      data = (@error_correct_level << 3 | mask_pattern)
      bits = QRUtil.get_bch_format_info(data)

      QRFORMATINFOLENGTH.times do |i|
        mod = !test && ((bits >> i) & 1) == 1

        # vertical
        row = if i < 6
          i
        elsif i < 8
          i + 1
        else
          @module_count - 15 + i
        end
        @modules[row][8] = mod

        # horizontal
        col = if i < 8
          @module_count - i - 1
        elsif i < 9
          15 - i - 1 + 1
        else
          15 - i - 1
        end
        @modules[8][col] = mod
      end

      # fixed module
      @modules[@module_count - 8][8] = !test
    end

    def map_data(data, mask_pattern) # :nodoc:
      inc = -1
      row = @module_count - 1
      bit_index = 7
      byte_index = 0

      (@module_count - 1).step(1, -2) do |col|
        col -= 1 if col <= 6

        loop do
          2.times do |c|
            if @modules[row][col - c].nil?
              dark = false
              if byte_index < data.size && !data[byte_index].nil?
                dark = ((QRUtil.rszf(data[byte_index], bit_index) & 1) == 1)
              end
              mask = QRUtil.get_mask(mask_pattern, row, col - c)
              dark = !dark if mask
              @modules[row][ col - c ] = dark
              bit_index -= 1

              if bit_index == -1
                byte_index += 1
                bit_index = 7
              end
            end
          end

          row += inc

          if row < 0 || @module_count <= row
            row -= inc
            inc = -inc
            break
          end
        end
      end
    end

    def minimum_version(limit: QRUtil.max_size, version: 1)
      raise QRCodeRunTimeError, "Data length exceed maximum capacity of version #{limit}" if version > limit

      max_size_bits = QRMAXBITS[error_correction_level][version - 1]

      size_bits = multi_segment? ? @data.sum { |seg| seg.size(version) } : @data.size(version)

      return version if size_bits < max_size_bits

      minimum_version(limit: limit, version: version + 1)
    end

    def extract_options!(arr) # :nodoc:
      arr.last.is_a?(::Hash) ? arr.pop : {}
    end

    class << self
      def count_max_data_bits(rs_blocks) # :nodoc:
        max_data_bytes = rs_blocks.reduce(0) do |sum, rs_block|
          sum + rs_block.data_count
        end

        max_data_bytes * 8
      end

      def create_data(version, error_correct_level, data_list) # :nodoc:
        rs_blocks = QRRSBlock.get_rs_blocks(version, error_correct_level)
        max_data_bits = QRCode.count_max_data_bits(rs_blocks)
        buffer = QRBitBuffer.new(version)

        data_list.write(buffer)
        buffer.end_of_message(max_data_bits)

        if buffer.get_length_in_bits > max_data_bits
          raise QRCodeRunTimeError, "code length overflow. (#{buffer.get_length_in_bits}>#{max_data_bits}). (Try a larger size!)"
        end

        buffer.pad_until(max_data_bits)

        QRCode.create_bytes(buffer, rs_blocks)
      end

      def create_bytes(buffer, rs_blocks) # :nodoc:
        offset = 0
        max_dc_count = 0
        max_ec_count = 0
        dcdata = Array.new(rs_blocks.size)
        ecdata = Array.new(rs_blocks.size)

        rs_blocks.each_with_index do |rs_block, r|
          dc_count = rs_block.data_count
          ec_count = rs_block.total_count - dc_count
          max_dc_count = [max_dc_count, dc_count].max
          max_ec_count = [max_ec_count, ec_count].max

          dcdata_block = Array.new(dc_count)
          dcdata_block.size.times do |i|
            dcdata_block[i] = 0xff & buffer.buffer[i + offset]
          end
          dcdata[r] = dcdata_block

          offset += dc_count
          rs_poly = QRUtil.get_error_correct_polynomial(ec_count)
          raw_poly = QRPolynomial.new(dcdata[r], rs_poly.get_length - 1)
          mod_poly = raw_poly.mod(rs_poly)

          ecdata_block = Array.new(rs_poly.get_length - 1)
          ecdata_block.size.times do |i|
            mod_index = i + mod_poly.get_length - ecdata_block.size
            ecdata_block[i] = (mod_index >= 0) ? mod_poly.get(mod_index) : 0
          end
          ecdata[r] = ecdata_block
        end

        total_code_count = rs_blocks.reduce(0) do |sum, rs_block|
          sum + rs_block.total_count
        end

        data = Array.new(total_code_count)
        index = 0

        max_dc_count.times do |i|
          rs_blocks.size.times do |r|
            if i < dcdata[r].size
              data[index] = dcdata[r][i]
              index += 1
            end
          end
        end

        max_ec_count.times do |i|
          rs_blocks.size.times do |r|
            if i < ecdata[r].size
              data[index] = ecdata[r][i]
              index += 1
            end
          end
        end

        data
      end
    end
  end
end

# ---- qr_math.rb

module RQRCodeCore
  class QRMath
    module_eval {
      exp_table = Array.new(256)
      log_table = Array.new(256)

      8.times do |i|
        exp_table[i] = 1 << i
      end

      (8...256).each do |i|
        exp_table[i] = exp_table[i - 4] \
          ^ exp_table[i - 5] \
          ^ exp_table[i - 6] \
          ^ exp_table[i - 8]
      end

      255.times do |i|
        log_table[exp_table[i]] = i
      end

      const_set(:EXP_TABLE, exp_table).freeze
      const_set(:LOG_TABLE, log_table).freeze
    }

    class << self
      def glog(n)
        raise QRCodeRunTimeError, "glog(#{n})" if n < 1
        LOG_TABLE[n]
      end

      def gexp(n)
        while n < 0
          n += 255
        end

        while n >= 256
          n -= 255
        end

        EXP_TABLE[n]
      end
    end
  end
end

# ---- qr_multi.rb

module RQRCodeCore
  class QRMulti
    def initialize(data)
      @data = data
    end

    def write(buffer)
      @data.each { |seg| seg.writer.write(buffer) }
    end
  end
end

# ---- qr_numeric.rb

module RQRCodeCore
  NUMERIC = %w[0 1 2 3 4 5 6 7 8 9].freeze

  class QRNumeric
    def initialize(data)
      raise QRCodeArgumentError, "Not a numeric string `#{data}`" unless QRNumeric.valid_data?(data)

      @data = data
    end

    def self.valid_data?(data)
      (data.chars - NUMERIC).empty?
    end

    def write(buffer)
      buffer.numeric_encoding_start(@data.size)

      @data.size.times do |i|
        if i % 3 == 0
          chars = @data[i, 3]
          bit_length = get_bit_length(chars.length)
          buffer.put(get_code(chars), bit_length)
        end
      end
    end

    private

    NUMBER_LENGTH = {
      3 => 10,
      2 => 7,
      1 => 4
    }.freeze

    def get_bit_length(length)
      NUMBER_LENGTH[length]
    end

    def get_code(chars)
      chars.to_i
    end
  end
end

# ---- qr_polynomial.rb

module RQRCodeCore
  class QRPolynomial
    def initialize(num, shift)
      raise QRCodeRunTimeError, "#{num.size}/#{shift}" if num.empty?
      offset = 0

      while offset < num.size && num[offset] == 0
        offset += 1
      end

      @num = Array.new(num.size - offset + shift)

      (0...num.size - offset).each do |i|
        @num[i] = num[i + offset]
      end
    end

    def get(index)
      @num[index]
    end

    def get_length
      @num.size
    end

    def multiply(e)
      num = Array.new(get_length + e.get_length - 1)

      (0...get_length).each do |i|
        (0...e.get_length).each do |j|
          tmp = num[i + j].nil? ? 0 : num[i + j]
          num[i + j] = tmp ^ QRMath.gexp(QRMath.glog(get(i)) + QRMath.glog(e.get(j)))
        end
      end

      QRPolynomial.new(num, 0)
    end

    def mod(e)
      if get_length - e.get_length < 0
        return self
      end

      ratio = QRMath.glog(get(0)) - QRMath.glog(e.get(0))
      num = Array.new(get_length)

      (0...get_length).each do |i|
        num[i] = get(i)
      end

      (0...e.get_length).each do |i|
        tmp = num[i].nil? ? 0 : num[i]
        num[i] = tmp ^ QRMath.gexp(QRMath.glog(e.get(i)) + ratio)
      end

      QRPolynomial.new(num, 0).mod(e)
    end
  end
end

# ---- qr_rs_block.rb

module RQRCodeCore
  class QRRSBlock
    attr_reader :data_count, :total_count

    def initialize(total_count, data_count)
      @total_count = total_count
      @data_count = data_count
    end

    # http://www.thonky.com/qr-code-tutorial/error-correction-table/
    RS_BLOCK_TABLE = [
      # L
      # M
      # Q
      # H

      # 1
      [1, 26, 19],
      [1, 26, 16],
      [1, 26, 13],
      [1, 26, 9],

      # 2
      [1, 44, 34],
      [1, 44, 28],
      [1, 44, 22],
      [1, 44, 16],

      # 3
      [1, 70, 55],
      [1, 70, 44],
      [2, 35, 17],
      [2, 35, 13],

      # 4
      [1, 100, 80],
      [2, 50, 32],
      [2, 50, 24],
      [4, 25, 9],

      # 5
      [1, 134, 108],
      [2, 67, 43],
      [2, 33, 15, 2, 34, 16],
      [2, 33, 11, 2, 34, 12],

      # 6
      [2, 86, 68],
      [4, 43, 27],
      [4, 43, 19],
      [4, 43, 15],

      # 7
      [2, 98, 78],
      [4, 49, 31],
      [2, 32, 14, 4, 33, 15],
      [4, 39, 13, 1, 40, 14],

      # 8
      [2, 121, 97],
      [2, 60, 38, 2, 61, 39],
      [4, 40, 18, 2, 41, 19],
      [4, 40, 14, 2, 41, 15],

      # 9
      [2, 146, 116],
      [3, 58, 36, 2, 59, 37],
      [4, 36, 16, 4, 37, 17],
      [4, 36, 12, 4, 37, 13],

      # 10
      [2, 86, 68, 2, 87, 69],
      [4, 69, 43, 1, 70, 44],
      [6, 43, 19, 2, 44, 20],
      [6, 43, 15, 2, 44, 16],

      # 11
      [4, 101, 81],
      [1, 80, 50, 4, 81, 51],
      [4, 50, 22, 4, 51, 23],
      [3, 36, 12, 8, 37, 13],

      # 12
      [2, 116, 92, 2, 117, 93],
      [6, 58, 36, 2, 59, 37],
      [4, 46, 20, 6, 47, 21],
      [7, 42, 14, 4, 43, 15],

      # 13
      [4, 133, 107],
      [8, 59, 37, 1, 60, 38],
      [8, 44, 20, 4, 45, 21],
      [12, 33, 11, 4, 34, 12],

      # 14
      [3, 145, 115, 1, 146, 116],
      [4, 64, 40, 5, 65, 41],
      [11, 36, 16, 5, 37, 17],
      [11, 36, 12, 5, 37, 13],

      # 15
      [5, 109, 87, 1, 110, 88],
      [5, 65, 41, 5, 66, 42],
      [5, 54, 24, 7, 55, 25],
      [11, 36, 12, 7, 37, 13],

      # 16
      [5, 122, 98, 1, 123, 99],
      [7, 73, 45, 3, 74, 46],
      [15, 43, 19, 2, 44, 20],
      [3, 45, 15, 13, 46, 16],

      # 17
      [1, 135, 107, 5, 136, 108],
      [10, 74, 46, 1, 75, 47],
      [1, 50, 22, 15, 51, 23],
      [2, 42, 14, 17, 43, 15],

      # 18
      [5, 150, 120, 1, 151, 121],
      [9, 69, 43, 4, 70, 44],
      [17, 50, 22, 1, 51, 23],
      [2, 42, 14, 19, 43, 15],

      # 19
      [3, 141, 113, 4, 142, 114],
      [3, 70, 44, 11, 71, 45],
      [17, 47, 21, 4, 48, 22],
      [9, 39, 13, 16, 40, 14],

      # 20
      [3, 135, 107, 5, 136, 108],
      [3, 67, 41, 13, 68, 42],
      [15, 54, 24, 5, 55, 25],
      [15, 43, 15, 10, 44, 16],

      # 21
      [4, 144, 116, 4, 145, 117],
      [17, 68, 42],
      [17, 50, 22, 6, 51, 23],
      [19, 46, 16, 6, 47, 17],

      # 22
      [2, 139, 111, 7, 140, 112],
      [17, 74, 46],
      [7, 54, 24, 16, 55, 25],
      [34, 37, 13],

      # 23
      [4, 151, 121, 5, 152, 122],
      [4, 75, 47, 14, 76, 48],
      [11, 54, 24, 14, 55, 25],
      [16, 45, 15, 14, 46, 16],

      # 24
      [6, 147, 117, 4, 148, 118],
      [6, 73, 45, 14, 74, 46],
      [11, 54, 24, 16, 55, 25],
      [30, 46, 16, 2, 47, 17],

      # 25
      [8, 132, 106, 4, 133, 107],
      [8, 75, 47, 13, 76, 48],
      [7, 54, 24, 22, 55, 25],
      [22, 45, 15, 13, 46, 16],

      # 26
      [10, 142, 114, 2, 143, 115],
      [19, 74, 46, 4, 75, 47],
      [28, 50, 22, 6, 51, 23],
      [33, 46, 16, 4, 47, 17],

      # 27
      [8, 152, 122, 4, 153, 123],
      [22, 73, 45, 3, 74, 46],
      [8, 53, 23, 26, 54, 24],
      [12, 45, 15, 28, 46, 16],

      # 28
      [3, 147, 117, 10, 148, 118],
      [3, 73, 45, 23, 74, 46],
      [4, 54, 24, 31, 55, 25],
      [11, 45, 15, 31, 46, 16],

      # 29
      [7, 146, 116, 7, 147, 117],
      [21, 73, 45, 7, 74, 46],
      [1, 53, 23, 37, 54, 24],
      [19, 45, 15, 26, 46, 16],

      # 30
      [5, 145, 115, 10, 146, 116],
      [19, 75, 47, 10, 76, 48],
      [15, 54, 24, 25, 55, 25],
      [23, 45, 15, 25, 46, 16],

      # 31
      [13, 145, 115, 3, 146, 116],
      [2, 74, 46, 29, 75, 47],
      [42, 54, 24, 1, 55, 25],
      [23, 45, 15, 28, 46, 16],

      # 32
      [17, 145, 115],
      [10, 74, 46, 23, 75, 47],
      [10, 54, 24, 35, 55, 25],
      [19, 45, 15, 35, 46, 16],

      # 33
      [17, 145, 115, 1, 146, 116],
      [14, 74, 46, 21, 75, 47],
      [29, 54, 24, 19, 55, 25],
      [11, 45, 15, 46, 46, 16],

      # 34
      [13, 145, 115, 6, 146, 116],
      [14, 74, 46, 23, 75, 47],
      [44, 54, 24, 7, 55, 25],
      [59, 46, 16, 1, 47, 17],

      # 35
      [12, 151, 121, 7, 152, 122],
      [12, 75, 47, 26, 76, 48],
      [39, 54, 24, 14, 55, 25],
      [22, 45, 15, 41, 46, 16],

      # 36
      [6, 151, 121, 14, 152, 122],
      [6, 75, 47, 34, 76, 48],
      [46, 54, 24, 10, 55, 25],
      [2, 45, 15, 64, 46, 16],

      # 37
      [17, 152, 122, 4, 153, 123],
      [29, 74, 46, 14, 75, 47],
      [49, 54, 24, 10, 55, 25],
      [24, 45, 15, 46, 46, 16],

      # 38
      [4, 152, 122, 18, 153, 123],
      [13, 74, 46, 32, 75, 47],
      [48, 54, 24, 14, 55, 25],
      [42, 45, 15, 32, 46, 16],

      # 39
      [20, 147, 117, 4, 148, 118],
      [40, 75, 47, 7, 76, 48],
      [43, 54, 24, 22, 55, 25],
      [10, 45, 15, 67, 46, 16],

      # 40
      [19, 148, 118, 6, 149, 119],
      [18, 75, 47, 31, 76, 48],
      [34, 54, 24, 34, 55, 25],
      [20, 45, 15, 61, 46, 16]

    ].freeze

    def self.get_rs_blocks(version, error_correct_level)
      rs_block = QRRSBlock.get_rs_block_table(version, error_correct_level)

      if rs_block.nil?
        raise QRCodeRunTimeError,
          "bad rsblock @ version: #{version}/error_correct_level:#{error_correct_level}"
      end

      length = rs_block.size / 3
      list = []

      (0...length).each do |i|
        count = rs_block[i * 3 + 0]
        total_count = rs_block[i * 3 + 1]
        data_count = rs_block[i * 3 + 2]

        (0...count).each do |j|
          list << QRRSBlock.new(total_count, data_count)
        end
      end

      list
    end

    def self.get_rs_block_table(version, error_correct_level)
      case error_correct_level
      when QRERRORCORRECTLEVEL[:l]
        QRRSBlock::RS_BLOCK_TABLE[(version - 1) * 4 + 0]
      when QRERRORCORRECTLEVEL[:m]
        QRRSBlock::RS_BLOCK_TABLE[(version - 1) * 4 + 1]
      when QRERRORCORRECTLEVEL[:q]
        QRRSBlock::RS_BLOCK_TABLE[(version - 1) * 4 + 2]
      when QRERRORCORRECTLEVEL[:h]
        QRRSBlock::RS_BLOCK_TABLE[(version - 1) * 4 + 3]
      end
    end
  end
end

# ---- qr_segment.rb

module RQRCodeCore
  class QRSegment
    attr_reader :data, :mode

    def initialize(data:, mode: nil)
      @data = data
      @mode = QRMODE_NAME.dig(mode&.to_sym)

      # If mode is not explicitly found choose mode according to data type
      @mode ||= if QRNumeric.valid_data?(@data)
        QRMODE_NAME[:number]
      elsif QRAlphanumeric.valid_data?(@data)
        QRMODE_NAME[:alphanumeric]
      else
        QRMODE_NAME[:byte_8bit]
      end
    end

    def size(version)
      4 + header_size(version) + content_size
    end

    def header_size(version)
      QRUtil.get_length_in_bits(QRMODE[mode], version)
    end

    def content_size
      chunk_size, bit_length, extra = case mode
      when :mode_number
        [3, QRNumeric::NUMBER_LENGTH[3], QRNumeric::NUMBER_LENGTH[data_length % 3] || 0]
      when :mode_alpha_numk
        [2, 11, 6]
      when :mode_8bit_byte
        [1, 8, 0]
      end

      (data_length / chunk_size) * bit_length + (((data_length % chunk_size) == 0) ? 0 : extra)
    end

    def writer
      case mode
      when :mode_number
        QRNumeric.new(data)
      when :mode_alpha_numk
        QRAlphanumeric.new(data)
      when :mode_multi
        QRMulti.new(data)
      else
        QR8bitByte.new(data)
      end
    end

    private

    def data_length
      data.bytesize
    end
  end
end

# ---- qr_util.rb

module RQRCodeCore
  class QRUtil
    PATTERN_POSITION_TABLE = [
      [],
      [6, 18],
      [6, 22],
      [6, 26],
      [6, 30],
      [6, 34],
      [6, 22, 38],
      [6, 24, 42],
      [6, 26, 46],
      [6, 28, 50],
      [6, 30, 54],
      [6, 32, 58],
      [6, 34, 62],
      [6, 26, 46, 66],
      [6, 26, 48, 70],
      [6, 26, 50, 74],
      [6, 30, 54, 78],
      [6, 30, 56, 82],
      [6, 30, 58, 86],
      [6, 34, 62, 90],
      [6, 28, 50, 72, 94],
      [6, 26, 50, 74, 98],
      [6, 30, 54, 78, 102],
      [6, 28, 54, 80, 106],
      [6, 32, 58, 84, 110],
      [6, 30, 58, 86, 114],
      [6, 34, 62, 90, 118],
      [6, 26, 50, 74, 98, 122],
      [6, 30, 54, 78, 102, 126],
      [6, 26, 52, 78, 104, 130],
      [6, 30, 56, 82, 108, 134],
      [6, 34, 60, 86, 112, 138],
      [6, 30, 58, 86, 114, 142],
      [6, 34, 62, 90, 118, 146],
      [6, 30, 54, 78, 102, 126, 150],
      [6, 24, 50, 76, 102, 128, 154],
      [6, 28, 54, 80, 106, 132, 158],
      [6, 32, 58, 84, 110, 136, 162],
      [6, 26, 54, 82, 110, 138, 166],
      [6, 30, 58, 86, 114, 142, 170]
    ].freeze

    G15 = 1 << 10 | 1 << 8 | 1 << 5 | 1 << 4 | 1 << 2 | 1 << 1 | 1 << 0
    G18 = 1 << 12 | 1 << 11 | 1 << 10 | 1 << 9 | 1 << 8 | 1 << 5 | 1 << 2 | 1 << 0
    G15_MASK = 1 << 14 | 1 << 12 | 1 << 10 | 1 << 4 | 1 << 1

    DEMERIT_POINTS_1 = 3
    DEMERIT_POINTS_2 = 3
    DEMERIT_POINTS_3 = 40
    DEMERIT_POINTS_4 = 10

    BITS_FOR_MODE = {
      QRMODE[:mode_number] => [10, 12, 14],
      QRMODE[:mode_alpha_numk] => [9, 11, 13],
      QRMODE[:mode_8bit_byte] => [8, 16, 16]
    }.freeze

    # This value is used during the right shift zero fill step (rszf method).
    # Auto-set to 32 or 64 depending on system architecture (1.size * 8).
    #
    # PERFORMANCE IMPACT (64-bit vs 32-bit on 64-bit systems):
    # - Memory: 70-76% reduction (e.g., 37.91 MB → 9.10 MB for 100 small QR codes)
    # - Speed: 2-4% faster with 32-bit
    # - Objects: 85-87% fewer allocations
    # - All tests pass with ARCH_BITS=32
    #
    # RECOMMENDATION: Use RQRCODE_CORE_ARCH_BITS=32 even on 64-bit systems
    # for dramatic memory savings with no downsides. The QR code algorithm
    # doesn't require 64-bit integers—32-bit is sufficient for all operations.
    #
    # See test/benchmarks/ARCH_BITS_ANALYSIS.md for detailed benchmark data.
    ARCH_BITS = ENV.fetch("RQRCODE_CORE_ARCH_BITS", nil)&.to_i || 1.size * 8

    def self.max_size
      PATTERN_POSITION_TABLE.count
    end

    def self.get_bch_format_info(data)
      d = data << 10
      while QRUtil.get_bch_digit(d) - QRUtil.get_bch_digit(G15) >= 0
        d ^= (G15 << (QRUtil.get_bch_digit(d) - QRUtil.get_bch_digit(G15)))
      end
      ((data << 10) | d) ^ G15_MASK
    end

    def self.rszf(num, count)
      # right shift zero fill
      (num >> count) & ((1 << (ARCH_BITS - count)) - 1)
    end

    def self.get_bch_version(data)
      d = data << 12
      while QRUtil.get_bch_digit(d) - QRUtil.get_bch_digit(G18) >= 0
        d ^= (G18 << (QRUtil.get_bch_digit(d) - QRUtil.get_bch_digit(G18)))
      end
      (data << 12) | d
    end

    def self.get_bch_digit(data)
      digit = 0

      while data != 0
        digit += 1
        data = QRUtil.rszf(data, 1)
      end

      digit
    end

    def self.get_pattern_positions(version)
      PATTERN_POSITION_TABLE[version - 1]
    end

    def self.get_mask(mask_pattern, i, j)
      raise QRCodeRunTimeError, "bad mask_pattern: #{mask_pattern}" if mask_pattern > QRMASKCOMPUTATIONS.size

      QRMASKCOMPUTATIONS[mask_pattern].call(i, j)
    end

    def self.get_error_correct_polynomial(error_correct_length)
      a = QRPolynomial.new([1], 0)

      (0...error_correct_length).each do |i|
        a = a.multiply(QRPolynomial.new([1, QRMath.gexp(i)], 0))
      end

      a
    end

    def self.get_length_in_bits(mode, version)
      raise QRCodeRunTimeError, "Unknown mode: #{mode}" unless QRMODE.value?(mode)

      raise QRCodeRunTimeError, "Unknown version: #{version}" if version > 40

      if version.between?(1, 9)
        # 1 - 9
        macro_version = 0
      elsif version <= 26
        # 10 - 26
        macro_version = 1
      elsif version <= 40
        # 27 - 40
        macro_version = 2
      end

      BITS_FOR_MODE[mode][macro_version]
    end

    def self.get_lost_points(modules)
      demerit_points = 0

      demerit_points += QRUtil.demerit_points_1_same_color(modules)
      demerit_points += QRUtil.demerit_points_2_full_blocks(modules)
      demerit_points += QRUtil.demerit_points_3_dangerous_patterns(modules)
      demerit_points += QRUtil.demerit_points_4_dark_ratio(modules)

      demerit_points
    end

    def self.demerit_points_1_same_color(modules)
      demerit_points = 0
      module_count = modules.size
      max_index = module_count - 1

      # level1
      module_count.times do |row|
        modules_row = modules[row]

        module_count.times do |col|
          same_count = 0
          dark = modules_row[col]

          # Check 3x3 neighborhood, but skip center cell
          # Unroll loops and eliminate range objects for performance

          # Row above (row - 1)
          if row > 0
            row_above = modules[row - 1]
            same_count += 1 if col > 0 && dark == row_above[col - 1]
            same_count += 1 if dark == row_above[col]
            same_count += 1 if col < max_index && dark == row_above[col + 1]
          end

          # Same row
          same_count += 1 if col > 0 && dark == modules_row[col - 1]
          same_count += 1 if col < max_index && dark == modules_row[col + 1]

          # Row below (row + 1)
          if row < max_index
            row_below = modules[row + 1]
            same_count += 1 if col > 0 && dark == row_below[col - 1]
            same_count += 1 if dark == row_below[col]
            same_count += 1 if col < max_index && dark == row_below[col + 1]
          end

          demerit_points += (DEMERIT_POINTS_1 + same_count - 5) if same_count > 5
        end
      end

      demerit_points
    end

    def self.demerit_points_2_full_blocks(modules)
      demerit_points = 0
      module_count = modules.size
      max_row = module_count - 1

      # level 2: Check for 2x2 blocks of same color
      # Only need to check (module_count - 1) x (module_count - 1) positions
      max_row.times do |row|
        row_curr = modules[row]
        row_next = modules[row + 1]

        max_row.times do |col|
          # Check if all 4 modules in 2x2 block have same color
          # (count == 0: all false, count == 4: all true)
          val = row_curr[col]
          if val == row_next[col] && val == row_curr[col + 1] && val == row_next[col + 1]
            demerit_points += DEMERIT_POINTS_2
          end
        end
      end

      demerit_points
    end

    def self.demerit_points_3_dangerous_patterns(modules)
      demerit_points = 0
      module_count = modules.size
      pattern_len = 7
      max_start = module_count - pattern_len + 1

      # level 3: Check for dangerous pattern [dark, light, dark, dark, dark, light, dark]
      # Pattern: true, false, true, true, true, false, true (1:1:3:1:1 ratio)

      # Check rows
      modules.each do |row|
        max_start.times do |col|
          if row[col] && !row[col + 1] && row[col + 2] &&
              row[col + 3] && row[col + 4] && !row[col + 5] && row[col + 6]
            demerit_points += DEMERIT_POINTS_3
          end
        end
      end

      # Check columns
      module_count.times do |col|
        max_start.times do |row|
          if modules[row][col] && !modules[row + 1][col] && modules[row + 2][col] &&
              modules[row + 3][col] && modules[row + 4][col] && !modules[row + 5][col] && modules[row + 6][col]
            demerit_points += DEMERIT_POINTS_3
          end
        end
      end

      demerit_points
    end

    def self.demerit_points_4_dark_ratio(modules)
      # level 4
      dark_count = modules.reduce(0) do |sum, col|
        sum + col.count(true)
      end

      # Convert to float to prevent integer division
      ratio = dark_count.to_f / (modules.size * modules.size)
      ratio_delta = (100 * ratio - 50).abs / 5

      ratio_delta * DEMERIT_POINTS_4
    end
  end
end

  module RQRCodeCore
    # Deep-freeze the lookup tables (and mask procs) for worker Ractors.
    constants.each { |c| v = const_get(c); Ractor.make_shareable(v) unless v.is_a?(Module) }
    [QRUtil, QRMath, QRRSBlock, QRNumeric, QRBitBuffer].each do |mod|
      mod.constants.each { |c| v = mod.const_get(c); Ractor.make_shareable(v) unless v.is_a?(Module) }
    end
  end
end
