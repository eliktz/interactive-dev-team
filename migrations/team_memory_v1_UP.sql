-- M3 team_memory v1 — UP migration
-- Applies the DDL from design/memory-architecture.md §6
-- Reversible via team_memory_v1_DOWN.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS team_memory (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  company_id      text NOT NULL,
  author_agent_slug text NOT NULL,
  body_md         text NOT NULL,
  tags            text[] NOT NULL DEFAULT '{}',
  importance      smallint NOT NULL DEFAULT 2
                    CHECK (importance BETWEEN 1 AND 5),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  archived_at     timestamptz NULL,
  superseded_by   uuid NULL REFERENCES team_memory(id) ON DELETE SET NULL,
  source          text NOT NULL DEFAULT 'agent'
                    CHECK (source IN ('agent','operator','consolidator')),
  tsv             tsvector GENERATED ALWAYS AS
                    (to_tsvector('english', coalesce(body_md,''))) STORED
);

CREATE INDEX IF NOT EXISTS team_memory_company_idx       ON team_memory (company_id);
CREATE INDEX IF NOT EXISTS team_memory_tags_gin_idx      ON team_memory USING gin(tags);
CREATE INDEX IF NOT EXISTS team_memory_tsv_gin_idx       ON team_memory USING gin(tsv);
CREATE INDEX IF NOT EXISTS team_memory_created_idx       ON team_memory (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS team_memory_live_idx          ON team_memory (company_id, importance DESC)
                                                            WHERE archived_at IS NULL;

CREATE OR REPLACE FUNCTION touch_team_memory() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS team_memory_touch ON team_memory;
CREATE TRIGGER team_memory_touch BEFORE UPDATE ON team_memory
FOR EACH ROW EXECUTE FUNCTION touch_team_memory();
