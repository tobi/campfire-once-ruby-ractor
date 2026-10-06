# frozen_string_literal: true

module Campfire
  # Layout API (app/views/layouts/application.html.erb), for every page:
  #
  #   def show
  #     html { layout { my_page_template } }
  #   end
  #
  # `layout { ... }` writes the whole document into @b; the block renders the
  # main content (what Rails' bare `yield` produces) and must return nil
  # (template methods do). Before or inside the block, a page sets:
  #
  #   @page_title  String, <title> (default "Campfire")
  #   @body_class  String, prepended to the "admin"/"account-has-logo" classes
  #   @head        extra <head> content (Rails `yield :head`)
  #   @nav         <nav id="nav"> content (Rails `yield :nav`)
  #   @footer      <footer id="footer"> content (Rails `yield :footer`)
  #   @sidebar     <aside id="sidebar"> content (Rails `yield :sidebar`)
  #
  # `frame_layout { ... }` is turbo-rails' frame layout (@head and the content);
  # `frame_or_application_layout { ... }` picks it for Turbo-Frame requests,
  # as controllers without an explicit `layout` do upstream.
  #
  # Slot values are either a String (raw HTML, appended verbatim) or a Proc
  # called at that point in the document (it appends to @b; e.g.
  # `@nav = -> { _rooms_show_nav(room: @room) }`). The slot gets exactly what
  # Rails' content_for captured: the text between `<% content_for :x do %>\n`
  # and `<% end %>`, whitespace included. A convenient way to reproduce that
  # is a partial whose body is the captured block's lines (see
  # rooms/show/_nav.html.erb).
  #
  # Because main content is rendered inside the layout (after <head>), any
  # ivar the head depends on (@page_title, @head ...) must be set before
  # calling `layout`, or from a Proc slot. Pages whose head depends on view
  # logic can render the main content into a separate buffer with `capture`.
  module Helpers
    # Appends a layout slot (String or Proc). nil appends nothing.
    def slot(value)
      if value.is_a?(Proc)
        value.call
      elsif value
        @b << value
      end
      nil
    end

    # Renders a block into a fresh String instead of @b (Rails `capture`).
    def capture
      outer = @b
      @b = String.new(capacity: 4096, encoding: Encoding::UTF_8)
      yield
      @b
    ensure
      @b = outer
    end

    def layout(&)
      layouts_application(&)
    end

    # turbo-rails' layouts/turbo_rails/frame (controllers that keep turbo-rails'
    # `layout -> { "turbo_rails/frame" if turbo_frame_request? }`): the block
    # is the page's main content, wrapped in a minimal document with @head
    # (and no CSRF meta tags: forgery protection is by Sec-Fetch-Site).
    def frame_layout
      @b << "<html>\n  <head>\n    "
      slot(@head)
      @b << "\n  </head>\n  <body>\n    "
      yield
      @b << "\n  </body>\n</html>\n"
      nil
    end

    # frame_layout for Turbo-Frame requests, else the application layout.
    def frame_or_application_layout(&)
      turbo_frame ? frame_layout(&) : layout(&)
    end

    def page_title_tag
      @b << "<title>"
      h(@page_title || "Campfire")
      @b << "</title>"
      nil
    end

    def current_user_meta_tags
      if (u = current_user)
        @b << '<meta name="current-user-id" content="' << u.id.to_s << '" /><meta name="current-user-name" content="'
        h(u.name)
        @b << '" />'
      end
      nil
    end

    def vapid_meta_tag
      @b << '<meta name="vapid-public-key" content="'
      h(Campfire.config.vapid_public_key.to_s)
      @b << '">'
      nil
    end

    # fresh_account_logo_path: /account/logo?v=<account.updated_at number>
    def fresh_account_logo_path(size: nil)
      a = account
      s = +"/account/logo"
      if a&.updated_at
        s << "?v=" << Clock.number(a.updated_at)
        s << "&size=" << size.to_s if size
      elsif size
        s << "?size=" << size.to_s
      end
      s
    end

    # AccountsHelper#account_logo_tag(style:)
    def account_logo_tag(style: nil)
      @b << '<figure class="account-logo avatar '
      h(style)
      @b << '"><img alt="Account logo" src="'
      h(fresh_account_logo_path)
      @b << '" width="300" height="300" /></figure>'
      nil
    end

    # The static stylesheet/importmap block, plus the account's custom styles
    # where Rails' custom_styles_tag puts them (between the two).
    CUSTOM_STYLES_MARK = "\n    \n\n    <script type=\"importmap\""
    def head_assets
      preload_links!
      styles = account&.custom_styles
      if styles.nil?
        @b << Assets::HEAD_TAGS
      else
        tags = Assets::HEAD_TAGS
        i = tags.index(CUSTOM_STYLES_MARK)
        @b << tags.byteslice(0, i) << "\n    " << '<style data-turbo-track="reload">' << styles << "</style>"
        @b << tags.byteslice(i + 5, tags.bytesize - i - 5)
      end
      nil
    end

    def body_classes
      parts = nil
      parts = [@body_class] if @body_class
      (parts ||= []) << "admin" if current_user&.administrator?
      (parts ||= []) << "account-has-logo" if account&.logo_attached?(@db)
      parts ? parts.join(" ") : ""
    end

    # link_back / link_back_to (ApplicationHelper)
    def link_back
      back = header("referer")&.to_s
      back = "/" if back.nil? || back == url
      link_back_to(back)
    end

    def link_back_to(destination)
      @b << '<a class="btn" href="'
      h(destination)
      @b << '"><img aria-hidden="true" src="' << Assets.path("arrow-left.svg") <<
        '" width="20" height="20" /><span class="for-screen-reader">Go Back</span></a>'
      nil
    end

    # "a", "a and b", "a, b, and c" (Array#to_sentence)
    def to_sentence(words)
      case words.size
      when 0 then +""
      when 1 then words[0].to_s
      when 2 then "#{words[0]} and #{words[1]}"
      else "#{words[0...-1].join(", ")}, and #{words[-1]}"
      end
    end
  end
end
