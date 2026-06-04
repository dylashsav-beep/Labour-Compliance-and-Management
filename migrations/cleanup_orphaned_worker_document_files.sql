-- Tidy up orphaned worker_document_files rows.
--
-- WHAT THIS DOES
--   A "worker_document_files" row is orphaned when its worker_document_id does
--   not match ANY row in worker_documents (not even an inactive one). The app
--   logs "worker_document_file orphaned — no matching worker_document record"
--   for these. They are dangling pointers that can never display in the UI.
--
-- WHY IT IS SAFE
--   1. It NEVER hard-deletes. It only sets active=false (soft delete), exactly
--      like the rest of the app's delete model. The rows stay in the table.
--   2. It first copies every affected row into a backup table, so you can fully
--      restore with one statement (see RESTORE at the bottom).
--   3. It checks against ALL worker_documents (active AND inactive), so files
--      whose parent was merely soft-deleted are LEFT UNTOUCHED.
--   4. It does NOT touch Supabase Storage — the actual files remain in the
--      bucket and are unaffected.
--
-- HOW TO USE
--   Run the STEP blocks one at a time in Supabase → SQL Editor, reviewing the
--   output of STEP 1 and STEP 2 before running STEP 3.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — PREVIEW: how many rows are truly orphaned? (read-only, deletes nothing)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT count(*) AS orphaned_rows
FROM worker_document_files f
WHERE f.active = true
  AND NOT EXISTS (
    SELECT 1 FROM worker_documents d WHERE d.id = f.worker_document_id
  );

-- Optional: eyeball the actual rows that would be affected
-- SELECT f.id, f.worker_id, f.worker_document_id, f.file_name, f.file_path
-- FROM worker_document_files f
-- WHERE f.active = true
--   AND NOT EXISTS (SELECT 1 FROM worker_documents d WHERE d.id = f.worker_document_id)
-- ORDER BY f.worker_id;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — BACKUP: copy the orphaned rows into a backup table (no data lost)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS worker_document_files_orphan_backup
  (LIKE worker_document_files INCLUDING ALL);

INSERT INTO worker_document_files_orphan_backup
SELECT f.*
FROM worker_document_files f
WHERE f.active = true
  AND NOT EXISTS (
    SELECT 1 FROM worker_documents d WHERE d.id = f.worker_document_id
  )
ON CONFLICT (id) DO NOTHING;

-- Confirm the backup holds the same count you saw in STEP 1
SELECT count(*) AS rows_backed_up FROM worker_document_files_orphan_backup;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — SOFT DELETE: hide the orphans (active=false). Reversible. No hard delete.
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE worker_document_files f
SET active = false
WHERE f.active = true
  AND NOT EXISTS (
    SELECT 1 FROM worker_documents d WHERE d.id = f.worker_document_id
  );

-- Verify: STEP 1's query should now return 0
SELECT count(*) AS remaining_orphans
FROM worker_document_files f
WHERE f.active = true
  AND NOT EXISTS (
    SELECT 1 FROM worker_documents d WHERE d.id = f.worker_document_id
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- RESTORE (only if you ever need to undo STEP 3)
-- ─────────────────────────────────────────────────────────────────────────────
-- UPDATE worker_document_files f
-- SET active = true
-- FROM worker_document_files_orphan_backup b
-- WHERE f.id = b.id;
