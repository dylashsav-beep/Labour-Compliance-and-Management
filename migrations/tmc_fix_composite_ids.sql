-- ============================================================================
-- TM Construction Compliance — Fix composite TEXT id columns
-- ============================================================================
-- Problem:
--   Five tables were created in Supabase with UUID primary keys (from an older
--   schema version), but the application inserts composite TEXT strings as ids,
--   e.g. "{worker_id}__{doc_key}". The intended schema (tmc_full_schema.sql)
--   already declares these columns as TEXT PRIMARY KEY, but CREATE TABLE IF
--   NOT EXISTS skipped re-creation, leaving the UUID type in place.
--   Result: "invalid input syntax for type uuid" on every document upload.
--
-- What this script changes:
--   ALTER COLUMN id TYPE TEXT on five tables. No other columns change.
--   UUID → TEXT is lossless: existing UUID values become their text strings.
--
-- FK note:
--   Only one FK is affected: worker_document_files.worker_document_id
--   references worker_documents.id. Because worker_documents.id changes to
--   TEXT, the FK column must also change to TEXT. All other tables' FK
--   columns (worker_id, project_assignment_id, etc.) stay UUID and are
--   NOT touched.
--
-- Tables NOT affected (keep UUID primary keys):
--   workers, projects, project_assignments, properties, vehicles,
--   accommodation_assignments, vehicle_assignments, profiles, settings,
--   document_sets, compliance_documents
--
-- Run in Supabase → Database → SQL Editor → New query → Run
-- ============================================================================


-- ── Step 1: Drop the FK that references worker_documents.id ──────────────────
-- Must be dropped before we can change the column it references.
-- Constraint name in Supabase is auto-generated — try the most likely name;
-- IF EXISTS makes this a no-op if the name differs (the ALTER will still work).
ALTER TABLE worker_document_files
  DROP CONSTRAINT IF EXISTS worker_document_files_worker_document_id_fkey;


-- ── Step 2: Change id columns from UUID → TEXT ───────────────────────────────

ALTER TABLE worker_documents
  ALTER COLUMN id TYPE TEXT;

ALTER TABLE worker_document_files
  ALTER COLUMN id TYPE TEXT;

-- This FK column references worker_documents.id which is now TEXT
ALTER TABLE worker_document_files
  ALTER COLUMN worker_document_id TYPE TEXT;

ALTER TABLE roster_week_allocations
  ALTER COLUMN id TYPE TEXT;

ALTER TABLE project_assignment_files
  ALTER COLUMN id TYPE TEXT;

ALTER TABLE deleted_items
  ALTER COLUMN id TYPE TEXT;


-- ── Step 3: Restore the FK with matching TEXT type ───────────────────────────
ALTER TABLE worker_document_files
  ADD CONSTRAINT worker_document_files_worker_document_id_fkey
  FOREIGN KEY (worker_document_id)
  REFERENCES worker_documents(id)
  ON DELETE CASCADE;


-- ── Verify ────────────────────────────────────────────────────────────────────
-- Should show data_type = 'text' for all five tables:
SELECT table_name, column_name, data_type
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  column_name  = 'id'
  AND  table_name  IN (
    'worker_documents',
    'worker_document_files',
    'roster_week_allocations',
    'project_assignment_files',
    'deleted_items'
  )
ORDER BY table_name;
