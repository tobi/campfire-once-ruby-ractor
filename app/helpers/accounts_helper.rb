# frozen_string_literal: true

module Campfire
  # AccountsHelper, TranslationsHelper, ClipboardHelper, QrCodeHelper,
  # VersionHelper, DropTargetHelper, UsersHelper, Users::ProfilesHelper and the
  # admin-side RoomsHelper bits. Helpers other agents may also define are
  # guarded (`unless method_defined?`) so whichever file loads first wins
  # without silent redefinition warnings.
  module Helpers
    # AccountsHelper#account_logo_tag
    def account_logo_tag(style: nil)
      @b << '<figure class="account-logo avatar ' << style.to_s << '"><img alt="Account logo" src="' << fresh_account_logo_path << '" width="300" height="300" /></figure>'
      nil
    end

    unless method_defined?(:version_badge)
      def version_badge
        @b << '<span class="version-badge">'
        h(Campfire.config.app_version)
        @b << "</span>"
        nil
      end
    end

    unless method_defined?(:drop_target_actions)
      def drop_target_actions = "dragenter->drop-target#dragenter dragover->drop-target#dragover drop->drop-target#drop"
    end

    # avatar_tag(user, loading: :lazy)
    def lazy_avatar_tag(user)
      @b << '<a title="'
      user_title(user.name, user.bio)
      @b << '" class="btn avatar" data-turbo-frame="_top" href="/users/' << user.id.to_s <<
        '"><img aria-hidden="true" loading="lazy" src="' << fresh_user_avatar_path(user.id, user.updated_at) << '" width="48" height="48" /></a>'
      nil
    end

    # Opening tags of the block helpers (the block's markup is literal in the
    # templates, followed by the closing tag).
    unless method_defined?(:copy_to_clipboard_open)
      def copy_to_clipboard_open(content)
        @b << '<button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value="'
        h(content)
        @b << '">'
        nil
      end
    end

    unless method_defined?(:qr_code_link_open)
      def qr_code_link_open(url)
        path = "/qr_code/#{[url].pack("m0").tr("+/", "-_")}"
        @b << '<a class="btn" data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="' << path << '" href="' << path << '">'
        nil
      end
    end

    unless method_defined?(:web_share_open)
      def web_share_open(url, title, text)
        @b << '<button class="btn" hidden="hidden" data-controller="web-share" data-action="web-share#share" data-web-share-url-value="'
        h(url)
        @b << '" data-web-share-text-value="'
        h(text)
        @b << '" data-web-share-title-value="'
        h(title)
        @b << '">'
        nil
      end
    end

    # form_with / button_to authenticity token for `action` (path or URL).
    def form_token(action, method = "post")
      path = action.start_with?("/") ? action : action.sub(%r{\A\w+://[^/]+}, "")
      hidden_per_form_token(path, method)
    end

    # RoomsHelper
    unless method_defined?(:link_back_to_last_room_visited)
      def link_back_to_last_room_visited
        room = last_room_visited
        link_back_to(room ? "/rooms/#{room.id}" : "/")
      end
    end

    # url_for(bot.avatar) on the bot form (the blob redirect URL, absolute).
    def bot_avatar_url(blob)
      base_url + Storage.blob_path(blob)
    end

    # RoomsHelper#button_to_delete_room (button_to room_url(room), method: :delete)
    unless method_defined?(:button_to_delete_room)
      def button_to_delete_room(room)
        name = room_display_name(room)
        @b << '<form class="button_to" method="post" action="' << base_url << "/rooms/" << room.id.to_s <<
          '"><input type="hidden" name="_method" value="delete" /><button class="btn btn--negative max-width" aria-label="Delete '
        h(room.name)
        @b << '" data-turbo-confirm="Are you sure you want to delete this room and all messages in it? This can’t be undone." type="submit"><img aria-hidden="true" src="' <<
          Assets.path("trash.svg") << '" width="20" height="20" /><span class="overflow-ellipsis">'
        h(name)
        @b << "</span></button>"
        form_token("/rooms/#{room.id}", "delete")
        @b << "</form>"
        nil
      end
    end
  end
end
