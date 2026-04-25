#!/usr/bin/env node
// issue-comments-watcher.js — M4 A2.
// Polls Paperclip's `issue_comments` PG table every 30s. When a new comment
// matches the done/shipped/verified-live/status:done regex, append a row to
// the M4 activity_feed PG table AND to the file spillover at
// /workspace/dev-activity-feed.ndjson.
//
// This closes scenario-5 FAIL from validation.md (the dev-closes-ticket-23:30
// case): the CEO's morning digest now sees that overnight ship.
//
// Idempotency: track last-seen comment id in /paperclip/m4-watchers/cursor.txt.
// On boot: if cursor missing, start from now() (don't backfill historical).
// Errors are logged but never crash the watcher.

const fs = require("fs");
const path = require("path");

let Client;
try {
  ({ Client } = require("pg"));
} catch {
  const p = require.resolve("pg", {
    paths: ["/app/node_modules/.pnpm/pg@8.18.0/node_modules"],
  });
  ({ Client } = require(p));
}

const PG_URL =
  process.env.M4_WATCHER_PG_URL ||
  "postgres://paperclip:paperclip@127.0.0.1:54329/paperclip";
const POLL_MS = parseInt(process.env.M4_WATCHER_POLL_MS || "30000", 10);
const CURSOR_PATH =
  process.env.M4_WATCHER_CURSOR || "/paperclip/m4-watchers/cursor.txt";
const FEED_PATH =
  process.env.M4_WATCHER_FEED || "/workspace/dev-activity-feed.ndjson";

const SHIP_RE = /\b(shipped|done|verified live|status:\s*done)\b/i;

let pg;
async function ensurePg() {
  if (pg) return pg;
  pg = new Client({ connectionString: PG_URL });
  await pg.connect();
  return pg;
}

function readCursor() {
  try {
    const v = fs.readFileSync(CURSOR_PATH, "utf8").trim();
    if (v) return v;
  } catch {}
  return null;
}

function writeCursor(v) {
  try {
    fs.mkdirSync(path.dirname(CURSOR_PATH), { recursive: true });
    fs.writeFileSync(CURSOR_PATH, v);
  } catch (e) {
    console.error("[m4-watcher] cursor write failed:", e.message);
  }
}

async function ensureActivityFeedTable(c) {
  // Idempotent CREATE IF NOT EXISTS — M4 owns this table for now; M5 may
  // promote to a proper migration.
  await c.query(`
    CREATE TABLE IF NOT EXISTS activity_feed (
      id            BIGSERIAL PRIMARY KEY,
      ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
      source        TEXT NOT NULL,
      persona_slug  TEXT,
      verb          TEXT NOT NULL,
      object        TEXT NOT NULL,
      issue_ref     TEXT,
      meta          JSONB,
      digested_at   TIMESTAMPTZ
    );
    CREATE INDEX IF NOT EXISTS idx_activity_feed_ts ON activity_feed(ts DESC);
    CREATE INDEX IF NOT EXISTS idx_activity_feed_undigested ON activity_feed(digested_at) WHERE digested_at IS NULL;
  `);
}

async function pollOnce() {
  const c = await ensurePg();
  await ensureActivityFeedTable(c);

  // Find issue_comments table — the column shape may differ from M3's spec;
  // probe defensively. If table doesn't exist (or no `id` / `created_at`),
  // log + back off.
  let probe;
  try {
    probe = await c.query(
      `SELECT column_name FROM information_schema.columns WHERE table_name = 'issue_comments'`,
    );
  } catch (e) {
    console.error("[m4-watcher] probe failed:", e.message);
    return;
  }
  const cols = new Set(probe.rows.map((r) => r.column_name));
  if (!cols.has("id") || !cols.has("body") || !cols.has("created_at")) {
    console.warn(
      "[m4-watcher] issue_comments table missing or schema mismatch — skipping poll. Found cols:",
      [...cols].join(","),
    );
    return;
  }

  const cursor = readCursor();
  let q;
  let args;
  if (cursor) {
    q = `SELECT id, body, created_at,
                 ${cols.has("issue_id") ? "issue_id" : "NULL::text"} AS issue_id,
                 ${cols.has("author_agent_id") ? "author_agent_id" : "NULL::text"} AS author_agent_id
          FROM issue_comments
          WHERE id::text > $1
          ORDER BY id::text ASC
          LIMIT 200`;
    args = [cursor];
  } else {
    // First boot — no backfill, just record current latest id.
    const r = await c.query(`SELECT MAX(id::text) AS m FROM issue_comments`);
    const m = r.rows[0] && r.rows[0].m ? r.rows[0].m : "";
    writeCursor(m);
    return;
  }

  const { rows } = await c.query(q, args);
  let lastId = cursor;
  let matched = 0;
  for (const r of rows) {
    lastId = r.id;
    if (!r.body) continue;
    if (!SHIP_RE.test(r.body)) continue;
    matched++;

    // PG insert.
    try {
      await c.query(
        `INSERT INTO activity_feed (source, persona_slug, verb, object, issue_ref, meta)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [
          "paperclip-issue-comment",
          r.author_agent_id ? String(r.author_agent_id).slice(0, 64) : null,
          "shipped",
          (r.body || "").slice(0, 200),
          r.issue_id ? String(r.issue_id) : null,
          { comment_id: r.id, source_table: "issue_comments" },
        ],
      );
    } catch (e) {
      console.error("[m4-watcher] activity_feed insert failed:", e.message);
    }

    // File spillover.
    try {
      const line = JSON.stringify({
        ts: new Date(r.created_at).toISOString(),
        source: "paperclip-issue-comment",
        persona: r.author_agent_id ? String(r.author_agent_id) : null,
        verb: "shipped",
        object: (r.body || "").slice(0, 200),
        issue_ref: r.issue_id ? String(r.issue_id) : null,
      });
      fs.mkdirSync(path.dirname(FEED_PATH), { recursive: true });
      fs.appendFileSync(FEED_PATH, line + "\n");
    } catch (e) {
      console.error("[m4-watcher] spillover write failed:", e.message);
    }
  }
  if (rows.length) {
    writeCursor(String(lastId));
    console.log(`[m4-watcher] processed=${rows.length} matched=${matched} cursor=${lastId}`);
  }
}

async function main() {
  console.log(
    `[m4-watcher] starting; poll=${POLL_MS}ms cursor=${CURSOR_PATH} feed=${FEED_PATH}`,
  );
  // Loop forever; never crash.
  /* eslint-disable no-constant-condition */
  while (true) {
    try {
      await pollOnce();
    } catch (e) {
      console.error("[m4-watcher] pollOnce uncaught:", e.message);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

main().catch((e) => {
  console.error("[m4-watcher] main fatal:", e);
  process.exit(1);
});
