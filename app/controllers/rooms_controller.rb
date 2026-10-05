# frozen_string_literal: true

module Campfire
  class RoomsController < ApplicationController
    ROOM_NOT_FOUND = "Room not found or inaccessible"
    SIDEBAR_SRC = "/users/me/sidebar"

    def index
      room = Room.last_for_user(@db, current_user.id)
      room ? redirect_to("/rooms/#{room.id}") : redirect_to("/")
    end

    # GET /rooms/:id and /rooms/:room_id/@:message_id
    def show
      set_room
      remember_last_room_visited
      page = find_messages
      room = @room
      @page_title = room_display_name(room)
      @body_class = "sidebar"
      @head = %(<meta name="turbo-cache-control" content="no-preview">  \n  <meta name="current-room-id" content="#{room.id}">\n)
      @nav = -> { _rooms_show_nav(room: room) }
      @footer = -> { _rooms_show_composer(room: room) }
      @sidebar = -> { sidebar_turbo_frame_open(SIDEBAR_SRC); @b << "</turbo-frame>" }
      html { layout { rooms_show(room: room, page: page) } }
    end

    def destroy
      set_room
      ensure_can_administer(@room)
      RoomOps.destroy!(@db, @room)
      broadcast_to("rooms", turbo_stream_tag("remove", "list_#{@room.dom_key}"))
      redirect_to("/")
    end

    private

    def set_room
      id = params["room_id"] || params["id"]
      @room = id && Room.find_for_user(@db, current_user.id, id.to_i)
      unless @room
        redirect_to("/", alert: ROOM_NOT_FOUND)
        throw :halt
      end
    end

    def find_messages
      mid = params["message_id"]
      if mid && !mid.empty? && (message = Message.find_in_room(@db, @room.id, mid))
        Message.page_around(@db, message)
      else
        Message.last_page(@db, @room.id)
      end
    end
  end
end
