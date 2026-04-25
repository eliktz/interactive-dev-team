#!/usr/bin/env node
// m3-ui — Operator UI tabs for M3 (Memory / Activity / Approvals).
// Express HTML v1: server-rendered HTML, no React build, reuses paperclip embedded PG.
// Listens on M3_UI_PORT (default 3101).
//
// Routes:
//   GET /ui/memory     — operator inspect of team_memory rows
//   GET /ui/activity   — activity feed (file spillover NDJSON)
//   GET /ui/approvals  — approval inbox (placeholder; M4 wires it)
//   GET /ui/health     — liveness

const http = require("http");
const fs = require("fs");
const url = require("url");

let Client;
try {
  ({ Client } = require("pg"));
} catch {
  const path = require.resolve("pg", {
    paths: ["/app/node_modules/.pnpm/pg@8.18.0/node_modules"],
  });
  ({ Client } = require(path));
}

const PORT = parseInt(process.env.M3_UI_PORT || "3101", 10);
const PG_URL =
  process.env.M3_UI_PG_URL ||
  "postgres://paperclip:paperclip@127.0.0.1:54329/paperclip";
const ACTIVITY_NDJSON =
  process.env.M3_UI_ACTIVITY_NDJSON || "/workspace/dev-activity-feed.ndjson";

let pg;
async function ensurePg() {
  if (pg) return pg;
  pg = new Client({ connectionString: PG_URL });
  await pg.connect();
  return pg;
}

function esc(s) {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function layout(title, body) {
  return `<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>${esc(title)} — Paperclip</title>
<style>
 body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 0; background: #f7f8fa; color: #222; }
 nav { background: #1f2937; color: #fff; padding: 12px 20px; }
 nav a { color: #cbd5e1; margin-right: 16px; text-decoration: none; }
 nav a.active { color: #fff; font-weight: 600; }
 main { padding: 24px; max-width: 1100px; margin: 0 auto; }
 h1 { margin-top: 0; }
 table { width: 100%; border-collapse: collapse; background: #fff; border: 1px solid #e2e8f0; }
 th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #e2e8f0; vertical-align: top; }
 th { background: #f1f5f9; font-weight: 600; }
 .tag { display: inline-block; background: #e0e7ff; color: #3730a3; border-radius: 8px; padding: 2px 6px; font-size: 12px; margin-right: 4px; }
 .imp-1 { color: #94a3b8; } .imp-2 { color: #475569; } .imp-3 { color: #0369a1; } .imp-4 { color: #c2410c; } .imp-5 { color: #b91c1c; font-weight: 600; }
 .body { font-family: ui-monospace, monospace; font-size: 12px; max-width: 600px; white-space: pre-wrap; }
 .filters { background: #fff; padding: 12px; border: 1px solid #e2e8f0; margin-bottom: 16px; }
 .filters input, .filters select { padding: 6px; margin-right: 8px; }
 .archived { opacity: 0.5; }
 button { background: #ef4444; color: #fff; border: 0; padding: 4px 10px; border-radius: 4px; cursor: pointer; font-size: 11px; }
 .empty { color: #64748b; font-style: italic; padding: 24px; text-align: center; background: #fff; border: 1px dashed #cbd5e1; }
</style>
</head><body>
<nav>
  <a href="/ui/memory">Memory</a>
  <a href="/ui/activity">Activity</a>
  <a href="/ui/approvals">Approvals</a>
  <a href="/ui/hook-health">Hook Health</a>
  <a href="/ui/gate-fires">Gate Fires</a>
  <a href="/ui/canaries">Canaries</a>
  <a href="/ui/forgetting">Forgetting</a>
  <a href="/ui/cost">Cost</a>
</nav>
<main>${body}</main>
</body></html>`;
}

async function memoryPage(query) {
  const c = await ensurePg();
  const company = (query.company || "go-north").toString();
  const persona = (query.persona || "").toString();
  const tag = (query.tag || "").toString();
  const includeArchived = query.archived === "1";

  const wheres = ["company_id = $1"];
  const args = [company];
  if (persona) {
    args.push(persona);
    wheres.push(`author_agent_slug = $${args.length}`);
  }
  if (tag) {
    args.push([tag]);
    wheres.push(`tags && $${args.length}::text[]`);
  }
  if (!includeArchived) wheres.push("archived_at IS NULL");
  const sql = `SELECT id, company_id, author_agent_slug, body_md, tags, importance, created_at, archived_at
               FROM team_memory WHERE ${wheres.join(" AND ")}
               ORDER BY created_at DESC LIMIT 50`;
  const { rows } = await c.query(sql, args);

  const filters = `<form class="filters" method="get">
    <label>Company: <input name="company" value="${esc(company)}"></label>
    <label>Persona: <input name="persona" value="${esc(persona)}" placeholder="any"></label>
    <label>Tag: <input name="tag" value="${esc(tag)}" placeholder="any"></label>
    <label><input type="checkbox" name="archived" value="1" ${includeArchived ? "checked" : ""}> include archived</label>
    <button type="submit" style="background:#3b82f6">Filter</button>
  </form>`;

  let table = "";
  if (!rows.length) {
    table = `<div class="empty">No team_memory rows match. Insert via MCP or set up Codex agents to write.</div>`;
  } else {
    const trs = rows
      .map((r) => {
        const tags = (r.tags || []).map((t) => `<span class="tag">${esc(t)}</span>`).join("");
        const archived = r.archived_at ? "archived" : "";
        return `<tr class="${archived}">
          <td><span class="imp-${r.importance}">L${r.importance}</span></td>
          <td>${esc(r.author_agent_slug)}</td>
          <td>${tags}</td>
          <td class="body">${esc(r.body_md.slice(0, 280))}${r.body_md.length > 280 ? "…" : ""}</td>
          <td>${esc(new Date(r.created_at).toISOString().slice(0, 19).replace("T", " "))}</td>
          <td>${r.archived_at ? "archived" : `<form method="post" action="/ui/memory/archive" style="display:inline"><input type="hidden" name="id" value="${esc(r.id)}"><button type="submit">archive</button></form>`}</td>
        </tr>`;
      })
      .join("\n");
    table = `<table><thead><tr><th>Imp</th><th>Persona</th><th>Tags</th><th>Body</th><th>Created</th><th>Action</th></tr></thead><tbody>${trs}</tbody></table>`;
  }

  return layout(
    "Memory",
    `<h1>Team Memory — ${esc(company)}</h1>${filters}${table}<p style="color:#64748b;font-size:12px">Showing ${rows.length} rows (cap 50). M3 v1: read + archive only. Edit / promote-to-L4 land in M4.</p>`,
  );
}

async function archiveMemoryRow(id) {
  const c = await ensurePg();
  await c.query(`UPDATE team_memory SET archived_at = now() WHERE id = $1`, [id]);
}

function activityPage(query) {
  const filterPersona = (query.persona || "").toString();
  let lines = [];
  let banner = "";
  try {
    const data = fs.readFileSync(ACTIVITY_NDJSON, "utf8");
    lines = data.trim().split("\n").filter(Boolean).slice(-200).reverse();
  } catch (e) {
    banner = `<div class="empty">No activity feed file at ${esc(ACTIVITY_NDJSON)} (yet). M2 hooks write here on Stop.</div>`;
  }

  const events = [];
  for (const l of lines) {
    try {
      const o = JSON.parse(l);
      if (filterPersona && o.persona !== filterPersona) continue;
      events.push(o);
    } catch {
      // skip malformed
    }
  }

  const filters = `<form class="filters" method="get">
    <label>Persona: <input name="persona" value="${esc(filterPersona)}" placeholder="any"></label>
    <button type="submit" style="background:#3b82f6">Filter</button>
  </form>`;

  let body = banner;
  if (!banner) {
    if (!events.length) {
      body = `<div class="empty">No events match.</div>`;
    } else {
      const trs = events
        .map(
          (o) =>
            `<tr><td>${esc(o.ts || o.timestamp || "")}</td><td>${esc(o.persona || "")}</td><td>${esc(o.kind || o.event || "")}</td><td class="body">${esc(JSON.stringify(o).slice(0, 240))}</td></tr>`,
        )
        .join("\n");
      body = `<table><thead><tr><th>Timestamp</th><th>Persona</th><th>Kind</th><th>Payload</th></tr></thead><tbody>${trs}</tbody></table>`;
    }
  }

  return layout(
    "Activity",
    `<h1>Activity Feed</h1>${filters}${body}<p style="color:#64748b;font-size:12px">Reading ${esc(ACTIVITY_NDJSON)} (last 200 lines reversed). M4 wires PG-backed activity_feed table.</p>`,
  );
}

function approvalsPage() {
  return layout(
    "Approvals",
    `<h1>Approval Inbox</h1>
     <div class="empty">M3 placeholder. Approval queue lands in M4 (PR approvals + L4 promotion votes + archive sweeps).</div>
     <p style="color:#64748b;font-size:12px">Wired endpoints (M4): <code>POST /ui/approvals/&lt;id&gt;/approve</code>, <code>/reject</code>.</p>`,
  );
}

// ----------------------------------------------------------------------------
// M4 Observability tabs
// ----------------------------------------------------------------------------

const HOOK_LOG_PERSONAS = ["ceo-gonorth", "captain", "ux-gonorth"];

function readHookLog(persona, max = 200) {
  // Hook logs live in /tmp inside the WAR-ROOM container. From here (paperclip
  // container), we can't reach /tmp directly, so we tail via the bind-mounted
  // workspace if hooks were redirected there, otherwise we honour an env var
  // that an operator can mount to a shared volume.
  const candidates = [
    `/workspace/.hooks-logs/hooks-${persona}.log`,
    `${process.env.M4_HOOK_LOGS_DIR || "/workspace"}/hooks-${persona}.log`,
  ];
  for (const p of candidates) {
    try {
      const data = fs.readFileSync(p, "utf8");
      const lines = data.trim().split("\n").filter(Boolean);
      return { path: p, lines: lines.slice(-max), total: lines.length };
    } catch {}
  }
  return { path: candidates[0], lines: [], total: 0, missing: true };
}

function hookHealthPage() {
  const rows = HOOK_LOG_PERSONAS.map((p) => {
    const { path: lp, lines, total, missing } = readHookLog(p, 50);
    let counts = { SessionStart: 0, SessionEnd: 0, PreCompact: 0, Stop: 0, UserPromptSubmit: 0, PreToolUse: 0, other: 0 };
    for (const l of lines) {
      const m = l.match(/(SessionStart|SessionEnd|PreCompact|Stop|UserPromptSubmit|PreToolUse)/);
      if (m) counts[m[1]] = (counts[m[1]] || 0) + 1;
      else counts.other += 1;
    }
    const last = lines.slice(-3).join("<br>");
    const status = missing ? `<span style="color:#b91c1c">missing log</span>` : `${total} lines @ ${esc(lp)}`;
    return `<tr>
      <td><strong>${esc(p)}</strong></td>
      <td>${status}</td>
      <td>SS=${counts.SessionStart} SE=${counts.SessionEnd} PC=${counts.PreCompact} Stop=${counts.Stop} UPS=${counts.UserPromptSubmit} PTU=${counts.PreToolUse}</td>
      <td class="body">${esc(last)}</td>
    </tr>`;
  }).join("\n");
  return layout(
    "Hook Health",
    `<h1>Hook Health</h1>
     <p>Per-persona hook fire rates from <code>/tmp/hooks-&lt;persona&gt;.log</code> (last 50 lines).</p>
     <table><thead><tr><th>Persona</th><th>Log status</th><th>Counts</th><th>Last 3 lines</th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function gateFiresPage(query) {
  const filterPersona = (query.persona || "").toString();
  const candidates = ["/workspace/.hooks-logs/pre-send-gate.ndjson", "/workspace/pre-send-gate.ndjson", "/tmp/pre-send-gate.ndjson"];
  let lines = [];
  let foundPath = null;
  for (const p of candidates) {
    try {
      const data = fs.readFileSync(p, "utf8");
      lines = data.trim().split("\n").filter(Boolean).slice(-50).reverse();
      foundPath = p;
      break;
    } catch {}
  }
  let body = "";
  if (!foundPath) {
    body = `<div class="empty">No gate ndjson at ${candidates.map(esc).join(", ")}</div>`;
  } else {
    const events = [];
    for (const l of lines) {
      try {
        const o = JSON.parse(l);
        if (filterPersona && o.persona !== filterPersona) continue;
        events.push(o);
      } catch {}
    }
    if (!events.length) {
      body = `<div class="empty">No gate fires (yet) under filter.</div>`;
    } else {
      const trs = events
        .map(
          (o) =>
            `<tr><td>${esc(o.ts || "")}</td><td>${esc(o.persona || "")}</td><td>${esc(o.tool || "")}</td><td>${esc(o.audience || "")}</td><td>${esc(o.level || "")}</td><td>${esc(o.check || "")}</td><td class="body">${esc((o.detail || "").slice(0, 160))}</td></tr>`,
        )
        .join("\n");
      body = `<table><thead><tr><th>TS</th><th>Persona</th><th>Tool</th><th>Audience</th><th>Level</th><th>Check</th><th>Detail</th></tr></thead><tbody>${trs}</tbody></table>`;
    }
  }
  const filters = `<form class="filters" method="get">
    <label>Persona: <input name="persona" value="${esc(filterPersona)}" placeholder="any"></label>
    <button type="submit" style="background:#3b82f6">Filter</button>
  </form>`;
  return layout(
    "Gate Fires",
    `<h1>Gate Fires (last 50)</h1>${filters}${body}<p style="color:#64748b;font-size:12px">Source: ${foundPath ? esc(foundPath) : "(none found)"} </p>`,
  );
}

function canariesPage() {
  // M4 placeholder: read /workspace/.canaries/*.md if present.
  let listing = "";
  try {
    const dir = "/workspace/.canaries";
    const files = fs.readdirSync(dir).filter((f) => f.endsWith(".md")).slice(0, 20);
    if (files.length) {
      listing = `<ul>${files.map((f) => `<li>${esc(f)}</li>`).join("")}</ul>`;
    }
  } catch {}
  if (!listing) listing = `<div class="empty">No canary results yet. Forgetting detector + tone canary populate <code>/workspace/.canaries/</code> on weekly run.</div>`;
  return layout(
    "Canaries",
    `<h1>Canary Dashboard</h1>${listing}<p style="color:#64748b;font-size:12px">Daily tone canary, weekly forgetting canary, per-deploy invariant canary all land here when wired.</p>`,
  );
}

function forgettingPage() {
  let report = "";
  try {
    const dir = "/workspace/.forgetting";
    const files = fs.readdirSync(dir).filter((f) => f.startsWith("forgetting-")).sort().reverse().slice(0, 5);
    if (files.length) {
      const latest = fs.readFileSync(`${dir}/${files[0]}`, "utf8");
      report = `<h2>Latest: ${esc(files[0])}</h2><pre style="background:#fff;padding:12px;border:1px solid #e2e8f0;overflow:auto;max-height:400px">${esc(latest.slice(0, 3000))}</pre>`;
      report += `<h3>Recent reports</h3><ul>${files.map((f) => `<li>${esc(f)}</li>`).join("")}</ul>`;
    }
  } catch {}
  if (!report) report = `<div class="empty">No drift reports yet. Forgetting detector runs Sunday 09:00 IDT — first report after first Sunday post-M4.</div>`;
  return layout(
    "Forgetting",
    `<h1>Forgetting Detector</h1><p>Drift metrics across the 6 PM-behavior contracts. Alert threshold: 3+ metrics over budget.</p>${report}`,
  );
}

function costPage() {
  let body = "";
  try {
    const path = "/workspace/.cost/haiku-spend.ndjson";
    const data = fs.readFileSync(path, "utf8");
    const lines = data.trim().split("\n").filter(Boolean).slice(-7);
    let total = 0;
    const trs = lines
      .map((l) => {
        try {
          const o = JSON.parse(l);
          total += parseFloat(o.usd || 0);
          return `<tr><td>${esc(o.date || "")}</td><td>${esc(o.calls || "0")}</td><td>${esc(o.usd || "0")}</td></tr>`;
        } catch {
          return "";
        }
      })
      .join("\n");
    body = `<p>Total last 7d: <strong>$${total.toFixed(2)}</strong></p>
            <table><thead><tr><th>Date</th><th>Calls</th><th>USD</th></tr></thead><tbody>${trs}</tbody></table>`;
  } catch {
    body = `<div class="empty">No Haiku spend data yet (placeholder). Pre-send-gate rewrite calls populate <code>/workspace/.cost/haiku-spend.ndjson</code> when GATE_MODE=rewrite.</div>`;
  }
  return layout(
    "Cost",
    `<h1>Cost Alerts (Haiku spend)</h1><p>Weekly budget: $${process.env.M4_HAIKU_BUDGET_USD || "5.00"}. Alert at 80%, hard-stop at 100%.</p>${body}`,
  );
}

// M5: JSON activity_feed reader for war-room digest. Two query modes:
//   ?since_iso=<ts>            — return rows with ts > since_iso
//   ?undigested=1              — return rows where digested_at IS NULL
//   ?limit=N                   — cap (default 50, max 500)
// Returns: {entries: [{ts, source, persona_slug, verb, object, issue_ref, meta}, ...], count}.
async function activityFeedJson(q) {
  const limit = Math.max(1, Math.min(parseInt(q.limit || "50", 10) || 50, 500));
  const since = q.since_iso || "";
  const undigested = q.undigested === "1";
  try {
    const c = await ensurePg();
    let sql;
    let args;
    if (undigested) {
      sql = `SELECT id, ts, source, persona_slug, verb, object, issue_ref, meta
              FROM activity_feed WHERE digested_at IS NULL ORDER BY ts ASC LIMIT $1`;
      args = [limit];
    } else if (since) {
      sql = `SELECT id, ts, source, persona_slug, verb, object, issue_ref, meta
              FROM activity_feed WHERE ts > $1::timestamptz ORDER BY ts ASC LIMIT $2`;
      args = [since, limit];
    } else {
      sql = `SELECT id, ts, source, persona_slug, verb, object, issue_ref, meta
              FROM activity_feed ORDER BY ts DESC LIMIT $1`;
      args = [limit];
    }
    const { rows } = await c.query(sql, args);
    return JSON.stringify({ ok: true, count: rows.length, entries: rows });
  } catch (e) {
    return JSON.stringify({ ok: false, error: e.message, entries: [], count: 0 });
  }
}

async function markActivityDigested(q) {
  const ids = String(q.ids || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => parseInt(s, 10))
    .filter((n) => Number.isFinite(n));
  if (!ids.length) return JSON.stringify({ ok: true, updated: 0 });
  try {
    const c = await ensurePg();
    const r = await c.query(
      `UPDATE activity_feed SET digested_at = now() WHERE id = ANY($1::bigint[]) AND digested_at IS NULL`,
      [ids],
    );
    return JSON.stringify({ ok: true, updated: r.rowCount || 0 });
  } catch (e) {
    return JSON.stringify({ ok: false, error: e.message, updated: 0 });
  }
}

async function send(res, code, body, type = "text/html; charset=utf-8") {
  res.writeHead(code, {
    "content-type": type,
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  try {
    const u = url.parse(req.url, true);
    if (u.pathname === "/ui/health") {
      return send(res, 200, JSON.stringify({ ok: true }), "application/json");
    }
    if (req.method === "GET" && u.pathname === "/ui/memory") {
      return send(res, 200, await memoryPage(u.query));
    }
    if (req.method === "POST" && u.pathname === "/ui/memory/archive") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const params = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
      const id = params.get("id");
      if (id) await archiveMemoryRow(id);
      res.writeHead(303, { location: "/ui/memory" });
      return res.end();
    }
    if (req.method === "GET" && u.pathname === "/ui/activity") {
      return send(res, 200, activityPage(u.query));
    }
    if (req.method === "GET" && u.pathname === "/ui/approvals") {
      return send(res, 200, approvalsPage());
    }
    // M4 observability tabs
    if (req.method === "GET" && u.pathname === "/ui/hook-health") {
      return send(res, 200, hookHealthPage());
    }
    if (req.method === "GET" && u.pathname === "/ui/gate-fires") {
      return send(res, 200, gateFiresPage(u.query));
    }
    if (req.method === "GET" && u.pathname === "/ui/canaries") {
      return send(res, 200, canariesPage());
    }
    if (req.method === "GET" && u.pathname === "/ui/forgetting") {
      return send(res, 200, forgettingPage());
    }
    if (req.method === "GET" && u.pathname === "/ui/cost") {
      return send(res, 200, costPage());
    }
    // M5: JSON endpoint so war-room digest can read activity_feed via HTTP
    // (no psql required in war-room, no shared bind-mount required).
    if (req.method === "GET" && u.pathname === "/api/activity-feed") {
      return send(res, 200, await activityFeedJson(u.query), "application/json");
    }
    if (req.method === "POST" && u.pathname === "/api/activity-feed/mark-digested") {
      return send(res, 200, await markActivityDigested(u.query), "application/json");
    }
    return send(res, 404, layout("Not found", "<h1>404</h1>"));
  } catch (e) {
    console.error(e);
    return send(res, 500, layout("Error", `<h1>500</h1><pre>${esc(e.message)}</pre>`));
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`m3-ui listening on :${PORT}`);
});

process.on("SIGTERM", async () => {
  try { if (pg) await pg.end(); } catch {}
  server.close(() => process.exit(0));
});
