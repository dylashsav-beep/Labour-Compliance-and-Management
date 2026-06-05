-- ONE-TIME recovery: retire stale worker_document_file deletion records and
-- bring back the files they were killing on every sync.
--
-- ROOT CAUSE
--   sbApplyArchivedDeletionsToSupabase runs on EVERY sync and, for each
--   'worker_document_file' entry in deleted_items, runs:
--       UPDATE worker_document_files SET active=false WHERE file_path = <path>
--   A one-time x deletion therefore re-fires forever. Any file that becomes
--   active again (recovery migration, or a current file on an older worker)
--   is switched back off on the very next sync and vanishes on reload.
--   New workers were never affected — they have no stale deletion records.
--
-- THE CODE FIX (already deployed) makes the sync auto-retire any such entry
--   whose file is currently live. This SQL does the same retirement for the
--   files that are already dead (so they cannot be re-loaded into fileStore
--   to trigger the code path) and reactivates them in one shot.
--
-- IMPORTANT
--   Hard-refresh the app IMMEDIATELY after running this, before doing anything
--   else, so the browser reloads clean state (active files + no stale entries).
--
-- NOTE
--   This reactivates ALL files whose parent document is active and retires ALL
--   worker_document_file deletion records. If any were files you genuinely meant
--   to delete, just click the x on them again afterwards — with the code fix in
--   place, a fresh deletion now sticks correctly.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — PREVIEW: stale deletion records that will be retired
-- ─────────────────────────────────────────────────────────────────────────────
SELECT count(*) AS file_deletion_records_to_retire
FROM deleted_items
WHERE item_type = 'worker_document_file'
  AND restored = false;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — RETIRE the stale deletion records so the sync stops replaying them
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE deleted_items
SET restored = true
WHERE item_type = 'worker_document_file'
  AND restored = false;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — REACTIVATE the files (parent worker_document must be active)
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE worker_document_files f
SET active = true
WHERE f.active = false
  AND EXISTS (
    SELECT 1 FROM worker_documents d
    WHERE d.id = f.worker_document_id
      AND d.active = true
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — VERIFY: both should now be 0
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM deleted_items
     WHERE item_type='worker_document_file' AND restored=false) AS remaining_stale_records,
  (SELECT count(*) FROM worker_document_files f
     JOIN worker_documents d ON d.id = f.worker_document_id
     WHERE f.active=false AND d.active=true)                    AS remaining_inactive_files;
