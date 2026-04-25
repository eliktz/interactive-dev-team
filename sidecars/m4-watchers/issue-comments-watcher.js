#!/usr/bin/env node
// issue-comments-watcher.js — M4 A2 (M5 fix: cursor on (created_at, id)).
// Polls Paperclip's `issue_comments` PG table every 30s. When a new comment
// matches the done/shipped/verified-live/status:done regex, append a row to
// the M4 activity_feed PG table AND to the file spillover at
// /workspace/dev-activity-feed.ndjson.
//
// This closes scenario-5 FAIL from validation.md (the dev-closes-ticket-23:30
// case): the CEO's morning digest now sees that overnight ship.
//
// Idempotency: track last-seen (created_at, id) tuple as JSON in
// /paperclip/m4-watchers/cursor.txt. M5 fix replaces the previous
// lexical-UUID ordering, which silently dropped comments with sub-cursor
// UUIDs (UUIDs are not time-sortable).
//
// On boot: if cursor missing, start from now() (don't backfill historical).
// Errors are logged but never crash the watcher.
//
// M5 also writes the spillover to /shared/activity-feed/dev-activity-feed.ndjson
// when M4_WATCHER_FEED_SHARED env is truthy AND that dir exists, so the
// war-room digest can read the same file.

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
// M5: optional shared spillover path mounted into BOTH war-room and paperclip.
const FEED_SHARED_PATH = process.env.M4_WATCHER_FEED_SHARED || "";

const SHIP_RE = /\b(shipped|done|verified live|status:\s*done)\b/i;

let pg;
async function ensurePg() {
  if (pg) return pg;
  pg = new Client({ connectionString: PG_URL });
  await pg.connect();
  return pg;
}

// M5: cursor is JSON {ts: ISO, id: string}. Falls back to legacy raw-UUID
// content for one-shot migration on first boot after upgrade.
function readCursor() {
  try {
    const v = fs.readFileSync(CURSOR_PATH, "utf8").trim();
    if (!v) return null;
    if (v.startsWith("{")) {
      const o = JSON.parse(v);
      if (o && o.ts) return { ts: String(o.ts), id: o.id ? String(o.id) : "" };
    }
    // Legacy raw-UUID cursor — we cannot map UUID → ts reliably, so treat as
    // "start from now" by returning null. The watcher's no-cursor branch will
    // re-seed against the current MAX(created_at) on next poll. Better to
    // skip a few seconds of comments than to permanently drop them.
    console.warn("[m4-watcher] legacy UUID cursor detected — re-seeding from now()");
    return null;
  } catch {}
  return null;
}

function writeCursor(ts, id) {
  try {
    fs.mkdirSync(path.dirname(CURSOR_PATH), { recursive: true });
    fs.writeFileSync(CURSOR_PATH, JSON.stringify({ ts, id: id || "" }));
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

function appendSpillover(targetPath, line) {
  try {
    fs.mkdirSync(path.dirname(targetPath), { recursive: true });
    fs.appendFileSync(targetPath, line + "\n");
  } catch (e) {
    console.error("[m4-watcher] spillover write failed (" + targetPath + "):", e.message);
  }
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
    // M5 fix: order by (created_at, id) and use a strict tuple compare so we
    // never miss a comment whose UUID happens to sort lower than a previous
    // one. The id::text tiebreaker keeps progress monotonic across rows
    // sharing the same created_at.
    q = `SELECT id, body, created_at,
                 ${cols.has("issue_id") ? "issue_id" : "NULL::text"} AS issue_id,
                 ${cols.has("author_agent_id") ? "author_agent_id" : "NULL::text"} AS author_agent_id
          FROM issue_comments
          WHERE (created_at, id::text) > ($1::timestamptz, $2)
          ORDER BY created_at ASC, id::text ASC
          LIMIT 200`;
    args = [cursor.ts, cursor.id || ""];
  } else {
    // First boot or legacy cursor — seed cursor at current max(created_at).
    const r = await c.query(
      `SELECT COALESCE(MAX(created_at), now()) AS m FROM issue_comments`,
    );
    const m = r.rows[0] && r.rows[0].m ? new Date(r.rows[0].m).toISOString() : new Date().toISOString();
    writeCursor(m, "");
    return;
  }

  const { rows } = await c.query(q, args);
  let lastTs = cursor.ts;
  let lastId = cursor.id || "";
  let matched = 0;
  for (const r of rows) {
    lastTs = new Date(r.created_at).toISOString();
    lastId = String(r.id);
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

    // File spillover (legacy path + optional M5 shared path).
    const line = JSON.stringify({
      ts: new Date(r.created_at).toISOString(),
      source: "paperclip-issue-comment",
      persona: r.author_agent_id ? String(r.author_agent_id) : null,
      verb: "shipped",
      object: (r.body || "").slice(0, 200),
      issue_ref: r.issue_id ? String(r.issue_id) : null,
    });
    appendSpillover(FEED_PATH, line);
    if (FEED_SHARED_PATH) {
      appendSpillover(FEED_SHARED_PATH, line);
    }
  }
  if (rows.length) {
    writeCursor(lastTs, lastId);
    console.log(`[m4-watcher] processed=${rows.length} matched=${matched} cursor_ts=${lastTs} cursor_id=${lastId}`);
  }
}

async function main() {
  console.log(
    `[m4-watcher] starting; poll=${POLL_MS}ms cursor=${CURSOR_PATH} feed=${FEED_PATH} feed_shared=${FEED_SHARED_PATH || "(none)"}`,
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
