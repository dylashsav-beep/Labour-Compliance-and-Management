-- Recover worker documents + files that the group-delete bug deactivated.
--
-- BACKGROUND
--   A "document_set_item_group_delete" archived entry re-ran on EVERY sync. When a question
--   (e.g. BSN) was deleted and later RE-ADDED, that stale entry kept switching the question's
--   worker_documents AND worker_document_files back to active=false on every sync — so freshly
--   uploaded files vanished on the next reload. The first recovery script looked for "active file
--   with inactive parent" and found 0 because BOTH the parent doc and the file were deactivated
--   together. This script reactivates both, but only for questions that are ACTIVE AGAIN.
--
-- WHY IT IS SAFE
--   * It ONLY turns rows back on (active=true). It never deletes and never touches Storage.
--   * It ONLY reactivates documents whose doc_key is still an ACTIVE question
--     (exists in document_set_items with active=true) — so genuinely-removed questions stay removed.
--   * For files, it ONLY reactivates those whose PARENT document was also inactive (i.e. deactivated
--     as part of the group delete). Files you deleted individually (via the ✕ button) leave their
--     parent active, so they are NOT matched and stay deleted — your intentional deletions are kept.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — PREVIEW: what will be recovered, grouped by document key
-- ─────────────────────────────────────────────────────────────────────────────
SELECT d.doc_key,
       count(DISTINCT d.id)                              AS documents_to_reactivate,
       count(f.id) FILTER (WHERE f.active = false)       AS files_to_reactivate
FROM worker_documents d
LEFT JOIN worker_document_files f ON f.worker_document_id = d.id
WHERE d.active = false
  AND EXISTS (SELECT 1 FROM document_set_items i WHERE i.doc_key = d.doc_key AND i.active = true)
GROUP BY d.doc_key
ORDER BY d.doc_key;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — REACTIVATE FILES that were deactivated together with their parent document.
--          (Parent still inactive here = deactivated by the group delete, not an individual ✕ delete.)
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE worker_document_files f
SET active = true
WHERE f.active = false
  AND EXISTS (
    SELECT 1 FROM worker_documents d
    WHERE d.id = f.worker_document_id
      AND d.active = false
      AND EXISTS (SELECT 1 FROM document_set_items i WHERE i.doc_key = d.doc_key AND i.active = true)
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — REACTIVATE the parent documents for questions that are active again
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE worker_documents d
SET active = true, updated_at = NOW()
WHERE d.active = false
  AND EXISTS (SELECT 1 FROM document_set_items i WHERE i.doc_key = d.doc_key AND i.active = true);

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — VERIFY: how many active files now have a matching active parent? (should cover BSN etc.)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT d.doc_key, count(f.id) AS active_files_with_active_parent
FROM worker_documents d
JOIN worker_document_files f ON f.worker_document_id = d.id AND f.active = true
WHERE d.active = true
GROUP BY d.doc_key
ORDER BY d.doc_key;
