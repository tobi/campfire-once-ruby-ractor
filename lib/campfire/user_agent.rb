# frozen_string_literal: true

module Campfire
  # Pure Ruby, Ractor-safe port of the parts of the `useragent` gem that
  # Campfire relies on (browser / version / platform / os / bot? / mobile?),
  # plus Rails' allow_browser semantics for
  #   { safari: 17.2, chrome: 120, firefox: 121, opera: 104, ie: false }
  # and app/models/application_platform.rb.
  #
  # All state lives in shareable constants; parsing allocates only locals.
  #
  # Attribute convention inside the parser: String = value, nil = Ruby nil,
  # RAISED = the gem would have raised NoMethodError for that attribute.
  module UserAgent
    # Raised where Rails would hit a NoMethodError (e.g. `nil.match?`).
    class Error < NoMethodError; end

    RAISED = :raised

    Product = Struct.new(:name, :version, :comment)
    EMPTY_PRODUCT = Ractor.make_shareable(Product.new("", "", nil))

    # Lowercased browser name => minimum version ("" means always blocked).
    MINIMUMS = Ractor.make_shareable({
      "safari" => "17.2", "chrome" => "120", "firefox" => "121", "opera" => "104",
      "internet explorer" => ""
    })

    # Cheap pre-gate: any browser that can possibly be blocked contains one of
    # these (case-insensitively). Everything else is allowed without parsing.
    RELEVANT = /safari|chrome|firefox|opera|opr|msie|trident|webkit|crios|micromessenger|itunes|playstation|vivaldi|edge/i

    BLANK_ASCII = /\A[ \t\n\r\v\f\0]*\z/
    BLANK = /\A[[:space:]]*\z/
    STRIP_LEAD = /\A[ \t\n\r\v\f\0]+/
    STRIP_TRAIL = /[ \t\n\r\v\f\0]+\z/
    TRIDENT = /Trident.+rv:/
    IE_VERSION = /(?:MSIE[ \t\n\r\v\f]|rv:)([0-9.]+)/
    OPERA_MINI_VERSION = %r{Opera Mini/([0-9.]+)}
    WEBKIT_COMMENT = %r{\AAppleWebKit/([0-9.]+)}i
    MAC_VERSION = /(?:Intel|PPC) Mac OS X[ \t\r\n\v\f]*([0-9_.]+)?/
    IOS_VERSION = /CPU (?:iPhone |iPod )?OS ([0-9_]+) like Mac OS X/
    IOS_SAFARI = /iOS ([0-9.]+)/
    CHROME_OS = /CrOS[ \t\r\n\v\f][^ \t\r\n\v\f]+[ \t\r\n\v\f]([0-9]+(?:\.[0-9]+)*)/
    WINDOWS_OS = /Windows NT [0-9.]+|Windows Phone (?:OS )?[0-9.]+/

    WINDOWS_NAMES = Ractor.make_shareable({
      "Windows NT 10.0" => "Windows 10", "Windows NT 6.3" => "Windows 8.1",
      "Windows NT 6.2" => "Windows 8", "Windows NT 6.1" => "Windows 7",
      "Windows NT 6.0" => "Windows Vista", "Windows NT 5.2" => "Windows XP x64 Edition",
      "Windows NT 5.1" => "Windows XP", "Windows NT 5.01" => "Windows 2000, Service Pack 1 (SP1)",
      "Windows NT 5.0" => "Windows 2000", "Windows NT 4.0" => "Windows NT 4.0",
      "Windows 98" => "Windows 98", "Windows 95" => "Windows 95", "Windows CE" => "Windows CE"
    })

    WEBKIT_BUILD_VERSIONS = Ractor.make_shareable({
      "85.7" => "1.0", "85.8.5" => "1.0.3", "85.8.2" => "1.0.3", "124" => "1.2",
      "125.2" => "1.2.2", "125.4" => "1.2.3", "125.5.5" => "1.2.4", "125.5.6" => "1.2.4",
      "125.5.7" => "1.2.4", "312.1.1" => "1.3", "312.1" => "1.3", "312.5" => "1.3.1",
      "312.5.1" => "1.3.1", "312.5.2" => "1.3.1", "312.8" => "1.3.2", "312.8.1" => "1.3.2",
      "412" => "2.0", "412.6" => "2.0", "412.6.2" => "2.0", "412.7" => "2.0.1",
      "416.11" => "2.0.2", "416.12" => "2.0.2", "417.9" => "2.0.3", "418" => "2.0.3",
      "418.8" => "2.0.4", "418.9" => "2.0.4", "418.9.1" => "2.0.4", "419" => "2.0.4",
      "425.13" => "2.2", "534.52.7" => "5.1.2"
    })

    SIMPLE_BROWSERS = Ractor.make_shareable({
      edge: "Edge", ie: "Internet Explorer", opera: "Opera", wechat: "Wechat Browser",
      vivaldi: "Vivaldi", itunes: "iTunes", podcast: "Podcast Addict",
      wmp: "Windows Media Player", coremedia: "AppleCoreMedia", lavf: "libavformat"
    })

    GECKO_NAMES = Ractor.make_shareable(%w[PaleMoon Firefox Camino Iceweasel Seamonkey])
    WMP_EXCLUDED = Ractor.make_shareable(%w[4.1.0.3856 7.10.0.3059 7.0.0.1956])
    ITUNES_WINDOWS = Ractor.make_shareable(["Windows 8.1", "Windows 8", "Windows 7", "Windows Vista", "Windows XP"])
    WMP_PHONE = Ractor.make_shareable(["Windows Phone 8", "Windows Phone 8.1"])
    APP_PLATFORMS = Ractor.make_shareable([
      %w[Android Android], %w[iPad iPad], %w[iPhone iPhone],
      %w[Macintosh macOS], %w[Windows Windows], %w[CrOS ChromeOS]
    ])
    WMP_OS_11_12 = Ractor.make_shareable({
      9841 => "Windows 10", 9858 => "Windows 10", 9860 => "Windows 10", 9879 => "Windows 10",
      9651 => "Windows Phone 8.1", 9600 => "Windows 8.1", 9200 => "Windows 8",
      7600 => "Windows 7", 7601 => "Windows 7", 6000 => "Windows Vista",
      6001 => "Windows Vista", 6002 => "Windows Vista", 5721 => "Windows XP"
    })
    WMP_OS_LOW = Ractor.make_shareable({ 3564 => "Windows 98", 3925 => "Windows 98", 3857 => "Windows 9x",
                                         3936 => "Windows XP", 3938 => "Windows 2000" })
    WMP_OS_9_10 = Ractor.make_shareable({ 2980 => "Windows 98/2000", 3268 => "Windows 2000", 3367 => "Windows 2000",
                                          3270 => "Windows 2000", 3802 => "Windows XP", 4503 => "Windows XP" })

    # useragent gem's Version semantics.
    module Version
      COMPARABLE = /\A[0-9]+(?:\.|\z)/
      SEQUENCES = /[0-9]+|[A-Za-z][0-9A-Za-z-]*\z/

      module_function

      def blank?(str) = BLANK_ASCII.match?(str)

      # ["i:1", "s:beta", ...] like the gem's to_a.
      def parts(str)
        return [] if blank?(str)
        return ["s:#{str}"] unless COMPARABLE.match?(str)

        str.scan(SEQUENCES).map do |part|
          if part.getbyte(0) <= 57
            stripped = part.sub(/\A0+/, "")
            "i:#{stripped.empty? ? '0' : stripped}"
          else
            "s:#{part}"
          end
        end
      end

      # <=> of the gem (compares at most 6 segments). Returns -1/0/1.
      def compare(a, b)
        return(a == b ? 0 : -1) unless COMPARABLE.match?(a)

        ours = parts(a)
        theirs = parts(b)
        i = 0
        while i < 6
          x = ours[i] || "i:0"
          y = theirs[i] || "i:0"
          if x == y
            i += 1
            next
          end
          xs = x.getbyte(0) == 115
          ys = y.getbyte(0) == 115
          return(xs ? -1 : 1) if xs != ys
          return(x.bytesize < y.bytesize ? -1 : 1) if !xs && x.bytesize != y.bytesize

          return x.byteslice(2..) <=> y.byteslice(2..)
        end
        0
      end
    end

    class Agent
      attr_reader :browser, :version, :platform, :os, :raw

      def initialize(raw)
        @raw = raw
        @kind = :base
        @products = []
        parse_products
        classify
        @os = operating_system
        @platform = compute_platform
        @browser = compute_browser
        @version = compute_version
        @bot = compute_bot
        compute_mobile
      end

      def bot? = @bot

      def mobile?
        raise Error, "undefined method for nil" if @mobile_error

        @mobile
      end

      # ApplicationPlatform#operating_system (String, nil, or RAISED).
      def application_os
        return RAISED if @platform == RAISED

        if (pl = @platform)
          APP_PLATFORMS.each { |needle, name| return name if pl.include?(needle) }
        end
        return "Linux" if txt(@os).include?("Linux")

        @os
      end

      # true => blocked, false => allowed, RAISED => Rails would have raised.
      def blocked
        v = @version
        return RAISED if v == RAISED
        return false if v.nil? || BLANK.match?(v)

        b = @browser
        return RAISED if b.nil? || b == RAISED

        min = MINIMUMS[b.downcase]
        return false if min.nil? || @bot

        min.empty? || Version.compare(v, min).negative?
      end

      private

      def txt(v) = v.is_a?(String) ? v : ""

      def strip(s) = s.sub(STRIP_LEAD, "").sub(STRIP_TRAIL, "")

      def space?(b) = b == 32 || (b >= 9 && b <= 13)
      def good?(b) = b != 47 && !space?(b)
      def quote?(b) = b == 39 || b == 34

      def parse_products
        rest = @raw
        rest = "Mozilla/4.0 (compatible)" if BLANK_ASCII.match?(rest)
        loop do
          prod, n = product(rest)
          break if n.zero?

          @products << prod
          rest = strip(rest.byteslice(n..))
        end
      end

      def product(s)
        len = s.bytesize
        return [nil, 0] if len.zero?

        start = 0
        start += 1 while start < len && quote?(s.getbyte(start))
        if start == len || !good?(s.getbyte(start))
          return [nil, 0] unless start.positive?

          start -= 1
        end
        i = start + 1
        i += 1 while i < len && good?(s.getbyte(i))
        name = s.byteslice(start, i - start)
        i += 1 if i < len && s.getbyte(i) == 47
        b = i
        i += 1 while i < len && !space?(s.getbyte(i)) && s.getbyte(i) != 44
        ver = s.byteslice(b, i - b)
        comment = nil
        if i + 1 < len && space?(s.getbyte(i)) && s.getbyte(i + 1) == 40
          if (close = s.byteindex(")", i + 2))
            comment = s.byteslice(i + 2, close - (i + 2)).split("; ")
            i = close + 1
          end
        elsif s.byteslice(i, 10) == ",gzip(gfe)"
          i += 10
        end
        [Product.new(name, ver, comment), i]
      end

      def first = @products.first || EMPTY_PRODUCT
      def last = @products.last || EMPTY_PRODUCT

      def any?(name)
        @products.each { |p| return true if p.name == name }
        false
      end

      def detect(name)
        lname = name.downcase
        @products.each { |p| return p if p.name == name || p.name.downcase == lname }
        nil
      end

      def classify
        first = self.first
        last = self.last
        comments = first.comment
        @kind =
          if last.name == "Edge" then :edge
          elsif comments && (comments[1].to_s.include?("MSIE") || TRIDENT.match?(comments.join(" "))) then :ie
          elsif first.name == "Opera" || last.name == "OPR" then :opera
          elsif @products.any? { |p| p.name.downcase.include?("micromessenger") } then :wechat
          elsif any?("Vivaldi") then :vivaldi
          elsif any?("Chrome") || any?("CriOS") then :chrome
          elsif any?("iTunes") then :itunes
          elsif (c0 = comments && comments[0].to_s) &&
                (c0.include?("PLAYSTATION 3") || c0.include?("PlayStation Vita") || c0.include?("PlayStation 4")) then :playstation
          elsif @products.size >= 3 && @products[0].name == "Podcast" && @products[1].name == "Addict" && @products[2].name == "-" then :podcast
          elsif webkit then :webkit
          elsif first.name == "Mozilla" then :gecko
          elsif (any?("NSPlayer") || any?("Windows-Media-Player") || any?("WMFSDK")) && !WMP_EXCLUDED.include?(first.version) then :wmp
          elsif any?("AppleCoreMedia") then :coremedia
          elsif any?("Lavf") || (any?("NSPlayer") && first.version == "4.1.0.3856") then :lavf
          else :base
          end
      end

      def application
        case @kind
        when :chrome, :vivaldi, :webkit, :itunes, :coremedia
          @products.each { |p| return p if p.comment && !p.comment.empty? }
          nil
        else
          @products.first
        end
      end

      def comments = application&.comment

      def base_version = application&.version

      def webkit
        if (p = detect("AppleWebKit"))
          return p.version
        end
        @products.each do |pr|
          pr.comment&.each do |c|
            m = WEBKIT_COMMENT.match(c)
            return m[1] if m
          end
        end
        nil
      end

      def opera_mini? = (first.comment || []).join(" ").include?("Opera Mini")

      def compute_bot
        app = application
        return true if app.nil? || app.name.include?("bot") || detect("Chrome-Lighthouse")

        @products.any? { |p| p.comment&.any? { |c| c.downcase.include?("bot") } } || false
      end

      def compute_mobile
        @mobile_error = false
        case @kind
        when :opera then @mobile = opera_mini?
        when :playstation then @mobile = @platform == "PlayStation Vita"
        when :podcast then @mobile = true
        when :wmp
          @mobile_error = @os == RAISED
          @mobile = WMP_PHONE.include?(txt(@os))
        else
          m = !detect("Mobile").nil? || @products.any? { |p| p.comment&.include?("Mobile") }
          unless m
            @mobile_error = @os == RAISED
            m = txt(@os).include?("Android")
          end
          comments&.each { |c| m ||= c.start_with?("IEMobile") }
          @mobile = m
        end
      end

      def compute_browser
        case @kind
        when :base then application&.name
        when :chrome then detect("Iron") ? "Iron" : "Chrome"
        when :playstation
          c = txt(comments&.first)
          if c.include?("PLAYSTATION 3") then "PS3 Internet Browser"
          elsif last.name == "Silk" then "Silk"
          elsif c.include?("PlayStation 4") then "PS4 Internet Browser"
          end
        when :webkit
          if txt(@os).include?("Android") then "Android"
          elsif @platform == "BlackBerry" then "BlackBerry"
          else "Safari"
          end
        when :gecko
          GECKO_NAMES.each { |n| return n if detect(n) }
          first.name
        else SIMPLE_BROWSERS[@kind]
        end
      end

      def detect_version(name)
        (p = detect(name)) ? p.version : RAISED
      end

      def compute_version
        case @kind
        when :base, :wmp, :coremedia then base_version
        when :edge, :vivaldi then last.version
        when :ie
          m = IE_VERSION.match((comments || []).join(" "))
          m ? m[1] : ""
        when :opera
          if opera_mini?
            comments.each do |c|
              next unless c.include?("Opera Mini")

              m = OPERA_MINI_VERSION.match(c)
              return m ? m[1] : ""
            end
            return ""
          end
          (p = detect("Version") || detect("OPR")) ? p.version : base_version
        when :wechat then detect_version("MicroMessenger")
        when :chrome then detect("CriOS") ? detect_version("CriOS") : detect_version("Chrome")
        when :itunes then detect_version("iTunes")
        when :playstation
          return nil unless @os.is_a?(String)
          return last.version if @browser == "Silk"

          pl = @platform
          marker = pl == "PlayStation 3" ? "PLAYSTATION 3 " : "#{pl} "
          parts = @os.split(marker)
          pl && !parts.empty? ? parts.last : nil
        when :podcast then nil
        when :webkit
          if (p = detect("Version"))
            p.version
          elsif @browser == "Safari" && (m = IOS_SAFARI.match(txt(@os)))
            m[1]
          else
            WEBKIT_BUILD_VERSIONS[webkit.to_s] || ""
          end
        when :gecko
          v = detect_version(txt(@browser))
          v != RAISED && BLANK_ASCII.match?(v) ? base_version : v
        when :lavf then detect("NSPlayer") ? nil : base_version
        end
      end

      def compute_platform
        c = comments
        first = c&.first
        ft = txt(first)
        case @kind
        when :edge, :ie, :wmp then "Windows"
        when :opera, :coremedia then ft.include?("Windows") ? "Windows" : first
        when :wechat
          return "iPhone" if ft.include?("iPhone")
          return "Android" if c&.any? { |v| v.include?("Android") }

          first
        when :chrome, :vivaldi
          return "Windows" if ft.include?("Windows")

          c&.each do |v|
            return "ChromeOS" if v.include?("CrOS")
          end
          c&.each do |v|
            return "Android" if v.include?("Android")
          end
          first
        when :webkit, :itunes
          return "Windows" if ft.include?("Windows")
          return "BlackBerry" if ft == "BB10"
          return "Android" if c&.any? { |v| v.include?("Android") }

          first
        when :playstation
          o = txt(@os)
          if o.include?("PLAYSTATION 3") then "PlayStation 3"
          elsif o.include?("PlayStation 4") then "PlayStation 4"
          elsif o.include?("PlayStation Vita") then "PlayStation Vita"
          end
        when :podcast
          return RAISED unless @os.is_a?(String)

          @os.include?("Android") ? "Android" : nil
        when :gecko
          return nil if ft == "compatible" || ft == "Mobile"

          ft.start_with?("Windows ") ? "Windows" : first
        end
      end

      def norm(v) = v.is_a?(String) ? normalize_os(v) : v

      def operating_system
        c = comments
        first = c&.first
        ft = txt(first)
        case @kind
        when :edge
          @products.each do |p|
            p.comment&.each do |cm|
              m = WINDOWS_OS.match(cm)
              return normalize_os(m[0]) if m
            end
          end
          ""
        when :ie
          m = WINDOWS_OS.match((c || []).join(" "))
          normalize_os(m ? m[0] : "")
        when :opera
          ft.include?("Windows") ? norm(first) : c&.[](1)
        when :chrome, :vivaldi, :wechat, :coremedia
          return norm(first) if ft.include?("Windows NT")

          if c.nil? || c.size < 3 || txt(c[1]).include?("Android") then norm(c&.[](1))
          else norm(c[2])
          end
        when :webkit, :itunes
          if @kind == :itunes && ft.include?("Windows")
            full = txt(c[1])
            ITUNES_WINDOWS.each { |n| return n if full.include?(n) }
            return "Windows"
          end
          return norm(first) if ft.include?("Windows NT")
          return norm(c&.[](1)) if c.nil? || c.size < 3 || txt(c[1]).include?("Android")

          c.each { |v| return normalize_os(v) if IOS_VERSION.match?(v) }
          norm(c[2])
        when :playstation then c&.join(" ")
        when :podcast
          return nil if @products.size < 4

          p = @products[3]
          return nil if p.name != "Dalvik" && p.name != "Mozilla"
          return RAISED if p.comment.nil?
          return p.comment[2] if p.comment.size > 3

          p.comment.size == 3 ? "Android" : nil
        when :gecko
          return norm(c[2]) if c && c[1] == "U"
          return norm(first) if ft.start_with?("Windows ") || ft.start_with?("Android")
          return nil if first == "Mobile"

          norm(c&.[](1))
        when :wmp then windows_player_os(txt(base_version))
        end
      end

      def normalize_os(s)
        if (v = WINDOWS_NAMES[s]) then v
        elsif (m = MAC_VERSION.match(s)) then m[1].nil? || m[1].empty? ? "OS X" : "OS X #{m[1].tr('_', '.')}"
        elsif (m = IOS_VERSION.match(s)) then "iOS #{m[1].tr('_', '.')}"
        elsif (m = CHROME_OS.match(s)) then "ChromeOS #{m[1]}"
        else s
        end
      end

      def windows_player_os(version)
        parts = Version.parts(version)
        return RAISED if parts.empty? || !parts[0].start_with?("i:")

        major = int_part(parts, 0)
        build = int_part(parts, 3)
        os =
          if major >= 0 && major <= 4 then WMP_OS_LOW[build]
          elsif major == 7 then build == 3055 ? "Windows 98" : nil
          elsif major == 8 then "Windows XP"
          elsif major == 9 || major == 10 then WMP_OS_9_10[build]
          elsif major == 11 || major == 12 then WMP_OS_11_12[int_part(parts, 2)]
          end
        os.nil? || os.empty? ? "Windows" : os
      end

      def int_part(parts, i)
        s = parts[i]
        s && s.start_with?("i:") ? s.byteslice(2..).to_i : -1
      end
    end

    module_function

    def normalize(ua)
      ua = ua.to_s
      ua = ua.scrub unless ua.valid_encoding?
      ua
    end

    # Full parse: Agent with browser/version/platform/os/bot?/mobile?
    # (attributes may be nil or RAISED, see header).
    def parse(ua) = Agent.new(normalize(ua))

    # allow_browser decision. true => serve the request; false => render the
    # incompatible-browser page. If the gem would have raised (Rails 500s) this
    # fails open (true); use .blocked to distinguish.
    def allowed?(ua)
      ua = ua.to_s
      return true unless RELEVANT.match?(ua)

      Agent.new(normalize(ua)).blocked != true
    end

    # true / false / :raised
    def blocked(ua)
      ua = ua.to_s
      return false unless RELEVANT.match?(ua)

      Agent.new(normalize(ua)).blocked
    end

    # Mirror of app/models/application_platform.rb. Cheap predicates only run
    # a regexp over the raw UA; the full parse happens lazily for
    # browser/operating_system/chrome?/firefox?/safari?/edge?/windows?.
    class ApplicationPlatform
      IOS = /iPhone|iPad/
      ANDROID = /Android/
      MAC = /Macintosh/
      APPLE_FB = /facebookexternalhit/i
      APPLE_TW = /Twitterbot/i

      def initialize(ua)
        @raw = UserAgent.normalize(ua)
        @agent = nil
      end

      def agent = (@agent ||= Agent.new(@raw))
      alias_method :user_agent, :agent

      def ios? = IOS.match?(@raw)
      def android? = ANDROID.match?(@raw)
      def mac? = MAC.match?(@raw)
      def mobile? = ios? || android?
      def desktop? = !mobile?
      def apple_messages? = APPLE_FB.match?(@raw) && APPLE_TW.match?(@raw)

      def chrome? = checked_browser.include?("Chrome")
      def firefox? = (b = checked_browser).include?("Firefox") || b.include?("FxiOS")
      def safari? = checked_browser.include?("Safari")
      def edge? = checked_browser.include?("Edg")

      def browser = agent.browser
      def windows? = operating_system == "Windows"

      def operating_system
        v = agent.application_os
        raise Error, "undefined method for nil" if v == RAISED

        v
      end

      private

      def checked_browser
        b = agent.browser
        raise Error, "undefined method 'match?' for nil" unless b.is_a?(String)

        b
      end
    end
  end

  ApplicationPlatform = UserAgent::ApplicationPlatform
  Platform = UserAgent::ApplicationPlatform
end
