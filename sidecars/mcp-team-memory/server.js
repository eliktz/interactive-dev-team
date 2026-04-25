#!/usr/bin/env node
// mcp-team-memory — Minimal HTTP server exposing 5 methods over the team_memory PG table.
// Listens on PAPERCLIP:7077 (Docker network only).
// Auth: Bearer token via env MCP_TEAM_MEMORY_TOKEN.
// Rate-limit: 10 req/sec per persona (tags[0] used as persona key when present, else author_agent_slug).
//
// HTTP shape (one endpoint per method, JSON in/out):
//   GET  /health
//   POST /set       { company_id, author_agent_slug, body_md, tags[], importance, superseded_by_id? }
//   POST /get       { id }
//   POST /list      { company_id, persona?, limit?, offset?, include_archived? }
//   POST /archive   { id }
//   POST /search    { company_id, query?, tags?, min_importance?, include_archived?, k? }

const http = require("http");

// pg may live in a pnpm shadow path inside paperclip container.
let Client;
try {
  ({ Client } = require("pg"));
} catch {
  const path = require.resolve("pg", {
    paths: ["/app/node_modules/.pnpm/pg@8.18.0/node_modules"],
  });
  ({ Client } = require(path));
}

const PORT = parseInt(process.env.MCP_TEAM_MEMORY_PORT || "7077", 10);
const TOKEN = process.env.MCP_TEAM_MEMORY_TOKEN || "";
const PG_URL =
  process.env.MCP_TEAM_MEMORY_PG_URL ||
  "postgres://paperclip:paperclip@127.0.0.1:54329/paperclip";

if (!TOKEN) {
  console.error("FATAL: MCP_TEAM_MEMORY_TOKEN unset");
  process.exit(1);
}

// ---------- pg pool (single Client; serialise) ------------
let pg;
async function ensurePg() {
  if (pg) return pg;
  pg = new Client({ connectionString: PG_URL });
  await pg.connect();
  return pg;
}

// ---------- token-bucket rate limit -----------------------
const buckets = new Map(); // persona -> { tokens, last }
const REFILL_PER_SEC = 10;
const BUCKET_MAX = 10;
function takeToken(persona) {
  const now = Date.now();
  let b = buckets.get(persona);
  if (!b) {
    b = { tokens: BUCKET_MAX, last: now };
    buckets.set(persona, b);
  }
  const elapsed = (now - b.last) / 1000;
  b.tokens = Math.min(BUCKET_MAX, b.tokens + elapsed * REFILL_PER_SEC);
  b.last = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

// ---------- helpers --------------------------------------
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(new Error("invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function checkAuth(req) {
  const h = req.headers["authorization"] || "";
  return h === `Bearer ${TOKEN}`;
}

// ---------- handlers --------------------------------------
async function handleSet(body) {
  const {
    company_id,
    author_agent_slug,
    body_md,
    tags = [],
    importance = 2,
    superseded_by_id = null,
  } = body;
  if (!company_id || !author_agent_slug || !body_md) {
    throw new Error("missing required field");
  }
  if (Buffer.byteLength(body_md, "utf8") > 16 * 1024) {
    throw new Error("body_md exceeds 16 KB cap");
  }
  if (!Array.isArray(tags)) throw new Error("tags must be array");
  if (importance < 1 || importance > 5) throw new Error("importance out of range");
  const c = await ensurePg();
  const { rows } = await c.query(
    `INSERT INTO team_memory (company_id, author_agent_slug, body_md, tags, importance, superseded_by)
     VALUES ($1,$2,$3,$4,$5,$6) RETURNING id, created_at`,
    [company_id, author_agent_slug, body_md, tags, importance, superseded_by_id],
  );
  return rows[0];
}

async function handleGet(body) {
  if (!body.id) throw new Error("missing id");
  const c = await ensurePg();
  const { rows } = await c.query(
    `SELECT id, company_id, author_agent_slug, body_md, tags, importance,
            created_at, updated_at, archived_at, superseded_by, source
     FROM team_memory WHERE id = $1`,
    [body.id],
  );
  if (!rows[0]) {
    const err = new Error("not found");
    err.status = 404;
    throw err;
  }
  return rows[0];
}

async function handleList(body) {
  const {
    company_id,
    persona = null,
    limit = 50,
    offset = 0,
    include_archived = false,
  } = body;
  if (!company_id) throw new Error("missing company_id");
  const lim = Math.min(200, Math.max(1, parseInt(limit, 10) || 50));
  const off = Math.max(0, parseInt(offset, 10) || 0);
  const c = await ensurePg();
  const wheres = ["company_id = $1"];
  const args = [company_id];
  if (persona) {
    wheres.push(`author_agent_slug = $${args.length + 1}`);
    args.push(persona);
  }
  if (!include_archived) wheres.push("archived_at IS NULL");
  const sql = `SELECT id, company_id, author_agent_slug, body_md, tags, importance,
                      created_at, updated_at, archived_at, superseded_by, source
               FROM team_memory WHERE ${wheres.join(" AND ")}
               ORDER BY created_at DESC LIMIT ${lim} OFFSET ${off}`;
  const cnt = await c.query(
    `SELECT count(*)::int AS total FROM team_memory WHERE ${wheres.join(" AND ")}`,
    args,
  );
  const { rows } = await c.query(sql, args);
  return { rows, total: cnt.rows[0].total };
}

async function handleArchive(body) {
  if (!body.id) throw new Error("missing id");
  const c = await ensurePg();
  const { rows } = await c.query(
    `UPDATE team_memory SET archived_at = now() WHERE id = $1 RETURNING archived_at`,
    [body.id],
  );
  if (!rows[0]) {
    const err = new Error("not found");
    err.status = 404;
    throw err;
  }
  return { ok: true, archived_at: rows[0].archived_at };
}

async function handleSearch(body) {
  const {
    company_id,
    query = null,
    tags = null,
    min_importance = 2,
    include_archived = false,
    k = 5,
  } = body;
  if (!company_id) throw new Error("missing company_id");
  const limit = Math.min(20, Math.max(1, parseInt(k, 10) || 5));
  const args = [company_id];
  const wheres = ["company_id = $1"];
  if (!include_archived) wheres.push("archived_at IS NULL");
  if (typeof min_importance === "number") {
    args.push(min_importance);
    wheres.push(`importance >= $${args.length}`);
  }
  let rankExpr = "0::float";
  if (query && query.trim()) {
    args.push(query.trim());
    rankExpr = `ts_rank(tsv, plainto_tsquery('english', $${args.length}))`;
    wheres.push(`tsv @@ plainto_tsquery('english', $${args.length})`);
  }
  if (tags && Array.isArray(tags) && tags.length) {
    args.push(tags);
    wheres.push(`tags && $${args.length}::text[]`);
  }
  const c = await ensurePg();
  const sql = `SELECT id, body_md, tags, importance, author_agent_slug, created_at,
                      ${rankExpr} AS rank
               FROM team_memory
               WHERE ${wheres.join(" AND ")}
               ORDER BY rank DESC, importance DESC, created_at DESC
               LIMIT ${limit}`;
  const { rows } = await c.query(sql, args);
  return { results: rows };
}

const ROUTES = {
  "POST /set": handleSet,
  "POST /get": handleGet,
  "POST /list": handleList,
  "POST /archive": handleArchive,
  "POST /search": handleSearch,
};

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      return send(res, 200, { ok: true, ts: new Date().toISOString() });
    }
    if (!checkAuth(req)) return send(res, 401, { error: "unauthorized" });

    const key = `${req.method} ${req.url.split("?")[0]}`;
    const handler = ROUTES[key];
    if (!handler) return send(res, 404, { error: "no route" });

    const body = await readBody(req);
    const persona = body.author_agent_slug || (Array.isArray(body.tags) ? body.tags[0] : null) || "anon";
    if (!takeToken(persona)) return send(res, 429, { error: "rate limit" });

    const out = await handler(body);
    return send(res, 200, out);
  } catch (e) {
    const code = e.status || 400;
    return send(res, code, { error: e.message || String(e) });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`mcp-team-memory listening on :${PORT}`);
});

process.on("SIGTERM", async () => {
  try { if (pg) await pg.end(); } catch {}
  server.close(() => process.exit(0));
});
