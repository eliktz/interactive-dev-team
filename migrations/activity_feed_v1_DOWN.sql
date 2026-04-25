-- M4 — DOWN migration for activity_feed.
DROP INDEX IF EXISTS idx_activity_feed_undigested;
DROP INDEX IF EXISTS idx_activity_feed_ts;
DROP TABLE IF EXISTS activity_feed;
