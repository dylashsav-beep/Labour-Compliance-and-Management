-- ============================================================================
-- TM Construction Compliance — Fix composite TEXT id columns
-- ============================================================================
-- Problem:
--   Several tables were created with UUID primary keys in the original schema,
--   but the application inserts composite TEXT keys (e.g. "{worker_id}__{doc_key}").
--   Because the full schema used CREATE TABLE IF NOT EXISTS, pre-existing tables
--   kept their UUID id columns, causing "invalid input syntax for type uuid" errors.
--
-- Fix:
--   ALTER COLUMN id TYPE TEXT on the five affected tables.
--   Drop any FK constraints that reference these columns first, then re-add them.
--
-- Run in Supabase → Database → SQL Editor → New query → Run
-- ============================================================================


-- ── 1. worker_documents ───────────────────────────────────────────────────────
-- id format: "{worker_id}__{doc_key}"  e.g. "uuid1__passport"

-- Drop FK from worker_document_files → worker_documents if it exists
ALTER TABLE worker_document_files
  DROP CONSTRAINT IF EXISTS worker_document_files_worker_document_id_fkey;

ALTER TABLE worker_documents
  ALTER COLUMN id TYPE TEXT;


-- ── 2. worker_document_files ──────────────────────────────────────────────────
-- id format: "{worker_id}__{doc_key}__{file_slug}"

ALTER TABLE worker_document_files
  ALTER COLUMN id TYPE TEXT;

-- worker_document_id references worker_documents.id — re-add as TEXT FK
ALTER TABLE worker_document_files
  ALTER COLUMN worker_document_id TYPE TEXT;

-- Restore FK (both columns are now TEXT)
ALTER TABLE worker_document_files
  ADD CONSTRAINT worker_document_files_worker_document_id_fkey
  FOREIGN KEY (worker_document_id) REFERENCES worker_documents(id) ON DELETE CASCADE;


-- ── 3. roster_week_allocations ────────────────────────────────────────────────
-- id format: "{week_key}__{worker_id}__{index}"

ALTER TABLE roster_week_allocations
  ALTER COLUMN id TYPE TEXT;


-- ── 4. project_assignment_files ───────────────────────────────────────────────
-- id format: "{assignment_id}__contract" or similar

-- Drop FK from project_assignment_files → project_assignments if it exists
ALTER TABLE project_assignment_files
  DROP CONSTRAINT IF EXISTS project_assignment_files_assignment_id_fkey;

ALTER TABLE project_assignment_files
  ALTER COLUMN id TYPE TEXT;

-- Re-add FK (assignment_id references project_assignments.id which is UUID — leave as UUID)
ALTER TABLE project_assignment_files
  ADD CONSTRAINT project_assignment_files_assignment_id_fkey
  FOREIGN KEY (assignment_id) REFERENCES project_assignments(id) ON DELETE CASCADE;


-- ── 5. deleted_items ──────────────────────────────────────────────────────────
-- id is a composite text key

ALTER TABLE deleted_items
  ALTER COLUMN id TYPE TEXT;


-- ── Verify ────────────────────────────────────────────────────────────────────
-- Run these SELECTs after applying to confirm all id columns are now text:
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name = 'id'
  AND table_name IN (
    'worker_documents',
    'worker_document_files',
    'roster_week_allocations',
    'project_assignment_files',
    'deleted_items'
  )
ORDER BY table_name;
