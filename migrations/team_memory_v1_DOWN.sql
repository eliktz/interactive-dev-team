-- M3 team_memory v1 — DOWN migration (reversible)
-- Restores schema to pre-M3 state.

DROP TRIGGER IF EXISTS team_memory_touch ON team_memory;
DROP FUNCTION IF EXISTS touch_team_memory();
DROP INDEX IF EXISTS team_memory_live_idx;
DROP INDEX IF EXISTS team_memory_created_idx;
DROP INDEX IF EXISTS team_memory_tsv_gin_idx;
DROP INDEX IF EXISTS team_memory_tags_gin_idx;
DROP INDEX IF EXISTS team_memory_company_idx;
DROP TABLE IF EXISTS team_memory;
-- Note: uuid-ossp extension intentionally retained (other tables may use it).
