# frozen_string_literal: true

require "json"
begin
  require File.expand_path("../../campfire_vips", __dir__) # ext/campfire_vips; optional
rescue LoadError
  nil
end

module Campfire
  module Storage
    # Image/video processing behind a small interface, run from job Ractors
    # only (CPU and child processes stay off request workers; Process.spawn
    # works in non-main Ractors). Images go through libvips (in-process via
    # ext/campfire_vips, else the vips CLI) with the exact operations of Rails'
    # image_processing/vips pipeline (output is byte-identical to the reference
    # app's variants); videos through ffmpeg, as upstream does. Backends are
    # modules with:
    #
    #   image_dimensions(path)                         -> [width, height] or nil
    #   resize_to_limit(input, output, width, height)  -> output (format from output's extension;
    #                                                     nil width and height = convert only)
    #   video_frame(input)                             -> JPEG bytes (Rails' VideoPreviewer frame)
    #   probe(path)                                    -> ffprobe Hash ({} when unavailable)
    module Media
      class Error < StandardError; end

      module_function

      def which(name)
        return name if name.include?("/")
        ENV.fetch("PATH", "").split(":").each do |dir|
          path = File.join(dir, name)
          return path if File.file?(path) && File.executable?(path)
        end
        nil
      end

      # Runs argv (no shell) with a kill timeout; returns stdout (binary).
      def run(argv, timeout: 60, allow_failure: false, env: EMPTY_ENV)
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = Process.spawn(env, *argv, in: File::NULL, out: out_w, err: err_w)
        out_w.close
        err_w.close
        out_r.binmode
        stdout = Thread.new { out_r.read }
        stderr = Thread.new { err_r.read }
        killer = Thread.new do
          sleep timeout
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH
          nil
        end
        _, status = Process.wait2(pid)
        killer.kill
        out = stdout.value
        err = stderr.value
        unless status.success? || (allow_failure && !out.empty?)
          detail = err.lines.reject { |l| l.include?("VIPS-WARNING") || l.strip.empty? }.join.strip[0, 500]
          raise Error, "#{File.basename(argv[0])} failed (#{status.termsig ? "signal #{status.termsig}" : status.exitstatus}): #{detail}"
        end
        out
      ensure
        out_r.close if out_r && !out_r.closed?
        err_r.close if err_r && !err_r.closed?
      end
      EMPTY_ENV = {}.freeze

      # ActiveStorage::Transformers::Vips via image_processing:
      #   load (page 0) -> autorot -> thumbnail_image(w, height: h, size: :down)
      #   -> conv(sharpen mask, precision: :integer) -> save by extension
      # (Go internal/storage/vips.go). Untrusted loaders blocked, as
      # config/initializers/vips.rb does.
      module Vips
        VIPS = (ENV["VIPS_PATH"] || "vips").freeze
        VIPSHEADER = (ENV["VIPSHEADER_PATH"] || "vipsheader").freeze
        ENV_VARS = { "VIPS_BLOCK_UNTRUSTED" => "1", "VIPS_WARNING" => "0" }.freeze
        # vipsload (.v) is itself an "untrusted" loader; the intermediates
        # are files we just wrote, so later steps run without the block.
        ENV_TRUSTED = { "VIPS_WARNING" => "0" }.freeze
        UNBOUNDED = "10000000"
        SHARPEN = "3 3 24 0\n-1 -1 -1\n-1 32 -1\n-1 -1 -1\n"
        ROTATED = /Right-top|Left-bottom|Top-right|Bottom-left/

        module_function

        def available? = !Media.which(VIPS).nil?

        def image_dimensions(path)
          out = Media.run([VIPSHEADER, "-a", path], timeout: 30, env: ENV_VARS)
          w = out[/^width: (\d+)$/, 1] or return nil
          h = out[/^height: (\d+)$/, 1] or return nil
          orientation = out[/^exif-ifd0-Orientation: (.*)$/, 1]
          orientation&.match?(ROTATED) ? [h.to_i, w.to_i] : [w.to_i, h.to_i]
        rescue Error
          nil
        end

        def resize_to_limit(input, output, width, height)
          rotated = "#{output}.r.v"
          thumb = "#{output}.t.v"
          if width.nil? && height.nil?
            vips("autorot", input, output)
          else
            vips("autorot", input, rotated)
            trusted("thumbnail_image", rotated, thumb, (width || UNBOUNDED).to_s,
              "--height", (height || UNBOUNDED).to_s, "--size", "down", "--no-rotate")
            trusted("conv", thumb, output, sharpen_mask(File.dirname(output)), "--precision", "integer")
          end
          output
        ensure
          File.unlink(rotated) if File.exist?(rotated)
          File.unlink(thumb) if File.exist?(thumb)
        end

        def vips(*args) = Media.run([VIPS, *args], env: ENV_VARS)
        def trusted(*args) = Media.run([VIPS, *args], env: ENV_TRUSTED)

        def sharpen_mask(dir)
          path = File.join(dir, "sharpen.mat")
          unless File.exist?(path)
            tmp = "#{path}.#{Process.pid}.#{rand(1 << 30)}"
            File.write(tmp, SHARPEN)
            File.rename(tmp, path)
          end
          path
        end

        def probe(path) = FFmpeg.probe(path)
        def video_frame(input) = FFmpeg.video_frame(input)
      end

      # The same pipeline in-process (ext/campfire_vips, once-campfire-rust's vips.rs): no child
      # processes and no full-size intermediate files. Each vips CLI run cost ~33 ms of startup alone,
      # and an upload took four. Runs without the GVL, so other Ractors keep going.
      module InProcess
        module_function

        def available? = defined?(::CampfireVips) ? true : false

        def image_dimensions(path)
          w, h, orientation = ::CampfireVips.header(path)
          orientation&.match?(Vips::ROTATED) ? [h, w] : [w, h]
        rescue ::CampfireVips::Error
          nil
        end

        def resize_to_limit(input, output, width, height)
          ::CampfireVips.resize_to_limit(input, output, width, height)
        rescue ::CampfireVips::Error => e
          raise Error, "libvips: #{e.message[0, 500]}"
        end
      end

      module FFmpeg
        FFMPEG = (ENV["FFMPEG_PATH"] || "ffmpeg").freeze
        FFPROBE = (ENV["FFPROBE_PATH"] || "ffprobe").freeze
        # ActiveStorage::Previewer::VideoPreviewer#draw_relevant_frame_from
        FRAME_FILTER = 'select=eq(n\,0)+eq(key\,1)+gt(scene\,0.015),loop=loop=-1:size=2,trim=start_frame=1'
        # Fallback image encoders when libvips is absent (not byte-compatible).
        CODECS = {
          "webp" => %w[-c:v libwebp -quality 75].freeze,
          "png" => %w[-c:v png].freeze,
          "jpg" => %w[-c:v mjpeg -q:v 3].freeze,
          "jpeg" => %w[-c:v mjpeg -q:v 3].freeze,
          "gif" => %w[-c:v gif].freeze,
          "tiff" => %w[-c:v tiff].freeze,
          "avif" => %w[-c:v libaom-av1 -still-picture 1 -crf 30].freeze
        }.freeze

        module_function

        def available? = !Media.which(FFMPEG).nil?

        def probe(path)
          out = Media.run([FFPROBE, "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path], timeout: 30, allow_failure: true)
          out.empty? ? {} : JSON.parse(out)
        rescue Errno::ENOENT
          {}
        rescue JSON::ParserError => e
          raise Error, "ffprobe output: #{e.message}"
        end

        def video_frame(input)
          Media.run([FFMPEG, "-nostdin", "-hide_banner", "-v", "error", "-i", input, "-y", "-vf", FRAME_FILTER,
            "-frames:v", "1", "-f", "image2", "-"])
        end

        def image_dimensions(path)
          stream = (probe(path)["streams"] || []).find { |s| s["codec_type"] == "video" } or return nil
          w = stream["width"] or return nil
          h = stream["height"] or return nil
          rotation = Analysis.rotation(stream)
          rotation && rotation.abs % 180 == 90 ? [h, w] : [w, h]
        end

        def resize_to_limit(input, output, width, height)
          format = File.extname(output).delete_prefix(".").downcase
          codec = CODECS[format] or raise Error, "unsupported variant format #{format}"
          argv = [FFMPEG, "-nostdin", "-hide_banner", "-v", "error", "-y", "-i", input, "-map", "0:v:0", "-frames:v", "1"]
          if width || height
            w = width ? "min(#{width.to_i}\\,iw)" : "iw"
            h = height ? "min(#{height.to_i}\\,ih)" : "ih"
            argv.push("-vf", "scale=w=#{w}:h=#{h}:force_original_aspect_ratio=decrease:flags=lanczos")
          end
          argv.concat(codec)
          argv.push("-update", "1") unless format == "avif"
          argv << output
          Media.run(argv)
          output
        end
      end

      IMAGE = if InProcess.available? then InProcess elsif Vips.available? then Vips else FFmpeg end
      VIDEO = FFmpeg

      def probe(path) = VIDEO.probe(path)
      def video_frame(input) = VIDEO.video_frame(input)
      def image_dimensions(path) = IMAGE.image_dimensions(path)
      def resize_to_limit(input, output, width, height) = IMAGE.resize_to_limit(input, output, width, height)
    end

    # ActiveStorage analyzers' metadata from ffprobe output (Go analyze.go).
    module Analysis
      module_function

      def stream_of(data, kind) = (data["streams"] || []).find { |s| s.is_a?(Hash) && s["codec_type"] == kind }

      def rotation(stream)
        angle = stream.dig("tags", "rotate")
        if angle.nil?
          (stream["side_data_list"] || []).each do |m|
            if m["side_data_type"] == "Display Matrix"
              angle = m["rotation"]
              break
            end
          end
        end
        angle.nil? ? nil : number(angle).to_i
      end

      def number(v)
        case v
        when Numeric then v
        when String then Float(v.strip)
        else raise ArgumentError, "invalid numeric metadata #{v.inspect}"
        end
      end

      # ActiveStorage::Analyzer::VideoAnalyzer / AudioAnalyzer
      def media(data, video)
        out = {}
        audio = stream_of(data, "audio") || {}
        unless video
          %w[duration bit_rate sample_rate].each do |key|
            next if (v = audio[key]).nil?
            out[key] = key == "duration" ? number(v).to_f : number(v).to_i
          end
          out["tags"] = audio["tags"] if audio["tags"]
          return out
        end
        v = stream_of(data, "video") || {}
        rot = rotation(v)
        width = v["width"] && number(v["width"]).to_f
        height = v["height"] && number(v["height"]).to_f
        dar = nil
        if (desc = v["display_aspect_ratio"]).is_a?(String)
          n, d = desc.split(":", 2)
          raise ArgumentError, "invalid display aspect ratio" unless d && n.match?(/\A\d+\z/) && d.match?(/\A\d+\z/)
          n = n.to_i
          d = d.to_i
          if n != 0
            dar = [n, d]
            height = width * d / n if width
          end
        end
        width, height = height, width if rot && rot.abs % 180 == 90
        duration = v["duration"] || data.dig("format", "duration")
        # VideoAnalyzer#metadata key order: width height duration angle display_aspect_ratio audio video
        out["width"] = width if width
        out["height"] = height if height
        out["duration"] = number(duration).to_f if duration
        out["angle"] = rot if rot
        out["display_aspect_ratio"] = dar if dar
        out["audio"] = !audio.empty?
        out["video"] = !v.empty?
        out
      end
    end
  end
end
