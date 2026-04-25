# mcp-team-memory

Minimal HTTP server backing the L4 `team_memory` shared memory layer.

## Run

```
MCP_TEAM_MEMORY_TOKEN=... \
  MCP_TEAM_MEMORY_PG_URL=postgres://paperclip:paperclip@127.0.0.1:54329/paperclip \
  node server.js
```

Inside the paperclip container, the resolver will fall back to the pnpm-shadow path for `pg`.

## Endpoints

All POST endpoints require `Authorization: Bearer <token>`. JSON in / JSON out.

- `GET  /health`
- `POST /set`     create a new row
- `POST /get`     fetch by id
- `POST /list`    paginated, filterable
- `POST /archive` soft-delete (sets archived_at)
- `POST /search`  FTS + tag filter, ranked

## Rate limit

Token bucket per persona (`author_agent_slug` or `tags[0]`): 10 req/sec, burst 10.
