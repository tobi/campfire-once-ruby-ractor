-- Rails does these in Ruby, one UPDATE per callback. Here SQLite runs them inside the write
-- that causes them, in the same transaction. They mirror:
--   Boost   belongs_to :message, touch: true
--   Message belongs_to :room, touch: true
--   Room#receive -> unread_memberships (every message the app creates is received)
--   Message has_many :boosts, has_rich_text :body, has_one_attached (dependent rows; the
--     blobs are purged later from Ruby), and its search index row
--   Room has_many :memberships, :messages (dependent)
--   Search after_create :trim_recent_searches (a user's 10 most recent)
-- Parents delete their children BEFORE their own delete, so foreign keys hold throughout.
-- Times come from the row being written (Ruby's clock, microseconds). SQLite's own clock only
-- has milliseconds and could move updated_at backwards, so the touches on delete (boost ->
-- message, message -> room) stay in Ruby.
-- Recreated at every boot (DB.prepare!), so edits here reach existing databases.
BEGIN;
DROP TRIGGER IF EXISTS campfire_message_created;
DROP TRIGGER IF EXISTS campfire_message_updated;
DROP TRIGGER IF EXISTS campfire_message_deleted;
DROP TRIGGER IF EXISTS campfire_boost_created;
DROP TRIGGER IF EXISTS campfire_boost_deleted;
DROP TRIGGER IF EXISTS campfire_message_deleting;
DROP TRIGGER IF EXISTS campfire_room_deleting;
DROP TRIGGER IF EXISTS campfire_search_created;
CREATE TRIGGER campfire_message_created AFTER INSERT ON messages BEGIN
  UPDATE rooms SET updated_at = NEW.updated_at WHERE id = NEW.room_id;
  UPDATE memberships SET unread_at = NEW.created_at, updated_at = NEW.created_at
    WHERE room_id = NEW.room_id AND involvement != 'invisible' AND user_id != NEW.creator_id
      AND (connected_at IS NULL OR connected_at < strftime('%Y-%m-%d %H:%M:%f000', NEW.created_at, '-60 seconds'));
END;
CREATE TRIGGER campfire_message_updated AFTER UPDATE ON messages BEGIN
  UPDATE rooms SET updated_at = NEW.updated_at WHERE id = NEW.room_id;
END;
CREATE TRIGGER campfire_message_deleting BEFORE DELETE ON messages BEGIN
  DELETE FROM boosts WHERE message_id = OLD.id;
  DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = OLD.id;
  DELETE FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = OLD.id;
END;
CREATE TRIGGER campfire_message_deleted AFTER DELETE ON messages BEGIN
  DELETE FROM message_search_index WHERE rowid = OLD.id;
END;
CREATE TRIGGER campfire_room_deleting BEFORE DELETE ON rooms BEGIN
  DELETE FROM memberships WHERE room_id = OLD.id;
  DELETE FROM messages WHERE room_id = OLD.id;
END;
CREATE TRIGGER campfire_search_created AFTER INSERT ON searches BEGIN
  DELETE FROM searches WHERE user_id = NEW.user_id AND id NOT IN
    (SELECT id FROM searches WHERE user_id = NEW.user_id ORDER BY updated_at DESC LIMIT 10);
END;
CREATE TRIGGER campfire_boost_created AFTER INSERT ON boosts BEGIN
  UPDATE messages SET updated_at = NEW.updated_at WHERE id = NEW.message_id;
END;
COMMIT;
