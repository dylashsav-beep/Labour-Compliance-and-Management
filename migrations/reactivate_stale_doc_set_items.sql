-- Reactivate document_set_items that were stale-deactivated by the group-delete bug.
--
-- BACKGROUND
--   A stale "document_set_item_group_delete" archived entry re-fired on every sync,
--   setting document_set_items.active=false for affected doc_keys. Once a row went
--   inactive, sbLoadAll stopped loading it into docSetItems. The _docKeyActive guard
--   (which reads DB state) then returned false, causing the stale deletion to keep
--   firing — a self-reinforcing loop. New uploads appeared in the UI but vanished on
--   every refresh because worker_documents was repeatedly deactivated.
--
-- WHO NEEDS THIS
--   Any doc_key that currently has active=false in document_set_items but ALSO has
--   worker records (worker_documents rows) using it. These are doc_keys that were
--   stale-deactivated even though workers still actively use them.
--
-- WHY IT IS SAFE
--   Only touches rows where active=false AND archived=false (not intentionally removed)
--   AND at least one worker_documents row exists for that doc_key. Doc_keys that were
--   genuinely removed by the admin have no corresponding worker_documents rows
--   (they were removed too), so they are left untouched.
--
-- AFTER RUNNING
--   The next sync will load these doc_keys, see them as active, and the
--   auto-resolve code will permanently mark the stale deleted_items entries as
--   restored=true so they never re-fire again.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — PREVIEW: which document_set_items will be reactivated?
-- ─────────────────────────────────────────────────────────────────────────────
SELECT dsi.id, dsi.doc_key, dsi.document_set_id, dsi.name
FROM document_set_items dsi
WHERE dsi.active = false
  AND dsi.archived = false
  AND EXISTS (
    SELECT 1 FROM worker_documents wd WHERE wd.doc_key = dsi.doc_key
  )
ORDER BY dsi.doc_key;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — REACTIVATE
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE document_set_items dsi
SET active = true, updated_at = NOW()
WHERE dsi.active = false
  AND dsi.archived = false
  AND EXISTS (
    SELECT 1 FROM worker_documents wd WHERE wd.doc_key = dsi.doc_key
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — VERIFY: should return 0 rows (no more stale-deactivated items in use)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT count(*) AS remaining_stale
FROM document_set_items dsi
WHERE dsi.active = false
  AND dsi.archived = false
  AND EXISTS (
    SELECT 1 FROM worker_documents wd WHERE wd.doc_key = dsi.doc_key
  );
