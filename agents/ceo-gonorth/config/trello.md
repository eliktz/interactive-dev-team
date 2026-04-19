# Trello Mirror Configuration

This doc covers the env vars, discovery commands, and conventions required by
`scripts/ceo-trello-sync.sh`. The sync script runs as a step inside the CEO's
5-minute Paperclip polling cron — NOT a separate cron.

## Required environment variables

| Var | Purpose |
|---|---|
| `TRELLO_KEY` | Trello API key (personal or app) |
| `TRELLO_TOKEN` | Trello OAuth token authorizing writes on the board |
| `TRELLO_BOARD_ID` | The Go-North board's 24-char hex ID |
| `TRELLO_LIST_IDS` | Minified JSON mapping Paperclip status → Trello list ID. Example: `{"todo":"<id>","in_progress":"<id>","in_review":"<id>","done":"<id>","blocked":"<id>"}` |
| `PAPERCLIP_API_KEY` | Admin/agent bearer token for Paperclip reads. Will be replaced by `PAPERCLIP_CEO_AGENT_TOKEN` once the CEO is registered as a real Paperclip agent (see AGENTS.md "CEO as Paperclip Agent — Registration Path"). |
| `PAPERCLIP_COMPANY_ID` | Go-North company ID — `a951bb35-24a9-412a-bbcc-629c5acae619` |
| `PAPERCLIP_BASE_URL` | Paperclip base URL. Defaults to `http://localhost:3000`. |

## Discovering board and list IDs

### 1. List the boards the token can see

```bash
curl -sf "https://api.trello.com/1/members/me/boards?key=${TRELLO_KEY}&token=${TRELLO_TOKEN}&fields=id,name" | jq .
```

Pick the Go-North board's `id` — that is `TRELLO_BOARD_ID`.

### 2. List the lists on that board

```bash
curl -sf "https://api.trello.com/1/boards/${TRELLO_BOARD_ID}/lists?key=${TRELLO_KEY}&token=${TRELLO_TOKEN}&fields=id,name" | jq .
```

Map each list name to its `id`, then assemble `TRELLO_LIST_IDS` as a single-line JSON blob (no whitespace — shells hate multi-line env values).

## Paperclip status → Trello list mapping

| Paperclip status | Trello list name | Intent |
|---|---|---|
| `todo` / `backlog` / `ready` | **To Do** | Not yet started |
| `in_progress` | **In Dev** | An agent is actively working |
| `in_review` | **In QA** | QA Lead is running gates |
| `done` | **Done** | Shipped / verified live |
| `blocked` | **Blocked** | Waiting on human / infra |

Unmapped statuses fall back to **To Do**.

## Dedup key rule

Card description **line 1 MUST begin with `[GON-XX]`**. The sync script searches all board cards for this marker and upserts (moves list / updates description / posts commentCard) instead of creating duplicates. If an operator renames a card title the sync still finds it — the dedup key lives in the description, not the title.

Only one card per Paperclip issue. Never create a second card for the same `GON-XX`. If you see duplicates on the board, delete the older one manually; the sync will fix up the survivor on its next run.
