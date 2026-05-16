-- Migration: add per-worker document requirement overrides
-- Run this once in the Supabase SQL Editor (Database → SQL Editor → New query).
--
-- What this does:
--   Adds a JSONB column `doc_req` to the `workers` table.
--   The app stores per-worker overrides here as a map of { doc_key: true|false }.
--   A true value means "required for this worker even if the document set says optional."
--   A false value means "not required for this worker even if the document set says required."
--   NULL (default) means "use the document set default — no override."

ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS doc_req JSONB DEFAULT NULL;

-- Optional: add a comment so the column purpose is clear in the Supabase UI
COMMENT ON COLUMN workers.doc_req IS
  'Per-worker document requirement overrides. Map of doc_key → boolean. '
  'true = required for this worker; false = not required; null/absent = use document set default.';
