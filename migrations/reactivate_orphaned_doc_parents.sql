-- Recover worker documents that were wrongly deactivated by the group-delete bug.
--
-- BACKGROUND
--   A "document_set_item_group_delete" archived entry used to re-run on EVERY sync and
--   blanket-deactivated worker_documents by doc_key (e.g. doc_key='bsn') across ALL
--   workers — including freshly uploaded ones. The uploaded FILE row often stayed
--   active=true while its PARENT worker_documents row was flipped active=false. On the
--   next page load the app matches files only against ACTIVE worker_documents, so the
--   file was treated as "orphaned" and silently dropped from the UI (BSN was the common
--   victim). The code fix scopes that deactivation to the original workers, so this can
--   no longer happen. This script reconnects the files that were already orphaned.
--
-- WHY IT IS SAFE
--   It ONLY reactivates a worker_documents row when it still has at least one ACTIVE
--   worker_document_files row pointing at it. A document that was genuinely deleted has
--   its files deactivated too, so it has no active file and is therefore LEFT UNTOUCHED.
--   It never hard-deletes and never touches Storage.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — PREVIEW: which worker_documents are inactive but still have active files?
-- ─────────────────────────────────────────────────────────────────────────────
SELECT d.id, d.worker_id, d.doc_key, count(f.id) AS active_files
FROM worker_documents d
JOIN worker_document_files f
  ON f.worker_document_id = d.id AND f.active = true
WHERE d.active = false
GROUP BY d.id, d.worker_id, d.doc_key
ORDER BY d.doc_key, d.worker_id;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — REACTIVATE: bring those parent documents back so their files display again
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE worker_documents d
SET active = true, updated_at = NOW()
WHERE d.active = false
  AND EXISTS (
    SELECT 1 FROM worker_document_files f
    WHERE f.worker_document_id = d.id AND f.active = true
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — VERIFY: STEP 1's query should now return 0 rows
-- ─────────────────────────────────────────────────────────────────────────────
SELECT count(*) AS remaining_orphaned_parents
FROM worker_documents d
JOIN worker_document_files f
  ON f.worker_document_id = d.id AND f.active = true
WHERE d.active = false;
