-- Clamp's production database is provisioned manually. Apply this migration
-- through KB_DATABASE_DIRECT_URL; .agents/setup must never apply it remotely.
BEGIN;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

COMMIT;
