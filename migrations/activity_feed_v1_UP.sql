-- M4 — activity_feed table for cross-source ship/done events.
-- Auto-applied by sidecars/m4-watchers/issue-comments-watcher.js on boot
-- (CREATE TABLE IF NOT EXISTS) — this file is the canonical source-of-truth
-- so it can be re-applied on a clean DB or audited.

CREATE TABLE IF NOT EXISTS activity_feed (
  id            BIGSERIAL PRIMARY KEY,
  ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
  source        TEXT NOT NULL,                 -- 'paperclip-issue-comment' | 'telegram-out' | ...
  persona_slug  TEXT,
  verb          TEXT NOT NULL,                 -- 'shipped' | 'replied' | 'routed' | ...
  object        TEXT NOT NULL,                 -- short noun phrase, body excerpt, etc.
  issue_ref     TEXT,
  meta          JSONB,
  digested_at   TIMESTAMPTZ                    -- NULL = pending; set by A3 morning-digest
);

CREATE INDEX IF NOT EXISTS idx_activity_feed_ts ON activity_feed(ts DESC);
CREATE INDEX IF NOT EXISTS idx_activity_feed_undigested
  ON activity_feed(digested_at)
  WHERE digested_at IS NULL;
