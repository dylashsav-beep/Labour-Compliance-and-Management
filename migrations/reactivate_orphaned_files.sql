-- Reactivate worker_document_files that have an active parent worker_document
-- but are themselves still inactive.
--
-- BACKGROUND
--   The group-delete bug deactivated both worker_documents AND worker_document_files
--   together. The recovery ran in two SQL steps — but a sync that fired between steps
--   reactivated the parent worker_documents first. When the file-reactivation step ran
--   (which requires the parent to still be inactive), it found no matches and skipped
--   these files. Result: active parent, inactive file — files never load after reload.
--
-- AFFECTED DOC KEYS (as of 2026-06-05)
--   payroll (1), scc (1), twv (1), vca (7), vca_vol (51), vog (1)
--
-- WHY IT IS SAFE
--   Only reactivates files whose parent worker_document is currently active.
--   If you see any file in the preview that you intentionally deleted via the ✕ button,
--   you can re-delete it after this runs. The counts above (especially vca_vol: 51)
--   confirm these are stale-deactivated by the bug, not individual admin deletions.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — PREVIEW: which files will be reactivated, grouped by doc_key?
-- ─────────────────────────────────────────────────────────────────────────────
SELECT d.doc_key, count(f.id) AS files_to_reactivate
FROM worker_document_files f
JOIN worker_documents d ON d.id = f.worker_document_id
WHERE f.active = false
  AND d.active = true
GROUP BY d.doc_key
ORDER BY d.doc_key;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — REACTIVATE
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
-- STEP 3 — VERIFY: should return 0
-- ─────────────────────────────────────────────────────────────────────────────
SELECT count(*) AS remaining_orphaned_files
FROM worker_document_files f
JOIN worker_documents d ON d.id = f.worker_document_id
WHERE f.active = false
  AND d.active = true;
