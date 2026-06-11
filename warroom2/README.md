<!-- warroom2/README.md — placeholder.
     TODO: 1-page overview. -->
# War Room 2.0 — placeholder

TODO: Overview of the war-room 2.0 service (FastAPI + xterm.js front-end fronting
the tmux-bound agents inside the squad's war-room container,
`<slug>-war-room-1` — set via `WARROOM2_WARROOM_CONTAINER`).

Started by:
```
docker compose -p <slug> --env-file /srv/squads/<slug>/.env up -d --no-deps warroom2
```
(or `./squadctl apply <slug> warroom2`)

TODO: link to plan, architecture diagram, auth notes.
See also: [docs/MULTI_SQUAD.md](../docs/MULTI_SQUAD.md).
