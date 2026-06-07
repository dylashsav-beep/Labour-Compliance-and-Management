-- =============================================================================
-- Fix: worker-portal document submissions invisible in Approvals
-- Run in: Supabase → Database → SQL Editor
--
-- Cause: submit_worker_document() inserted into worker_document_submissions
-- WITHOUT org_id, so every submission landed with org_id = NULL. The Approvals
-- tab loads submissions through org-scoped RLS (org_id = current_org_id()), and
-- NULL matches no org — so submissions were invisible to staff ("floating").
--
-- This:
--   1. Recreates submit_worker_document to derive org_id FROM THE WORKER ROW
--      (so each org's worker submissions are scoped to that org only).
--   2. Backfills existing NULL-org submissions from their worker's org — your
--      already-uploaded documents appear in Approvals, no re-upload needed.
-- Safe to re-run.
-- =============================================================================

-- 1. Recreate the RPC: org_id now comes from the matched worker, + search_path
CREATE OR REPLACE FUNCTION submit_worker_document(
  p_email text, p_worker_id uuid, p_doc_key text,
  p_expiry_date date DEFAULT NULL, p_issue_date date DEFAULT NULL,
  p_notes text DEFAULT NULL, p_file_path text DEFAULT NULL,
  p_file_name text DEFAULT NULL, p_file_size bigint DEFAULT NULL,
  p_mime_type text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE v_id uuid; v_org uuid;
BEGIN
  -- Verify the email matches the worker AND capture that worker's org at once.
  SELECT org_id INTO v_org FROM workers
  WHERE id = p_worker_id AND lower(email) = lower(p_email) AND active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Email does not match worker profile';
  END IF;

  INSERT INTO worker_document_submissions
    (worker_id, doc_key, submitted_by_email, expiry_date, issue_date, notes,
     file_path, file_name, file_size, mime_type, status, active, org_id)
  VALUES
    (p_worker_id, p_doc_key, p_email, p_expiry_date, p_issue_date, p_notes,
     p_file_path, p_file_name, p_file_size, p_mime_type, 'pending', true, v_org)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$func$;
GRANT EXECUTE ON FUNCTION submit_worker_document(text, uuid, text, date, date, text, text, text, bigint, text) TO anon, authenticated;

-- 2. Backfill existing NULL-org submissions from their worker's org.
--    (Each row is scoped to the org its worker belongs to — multi-org safe.)
UPDATE worker_document_submissions s
SET org_id = w.org_id
FROM workers w
WHERE s.worker_id = w.id AND s.org_id IS NULL;

-- 3. Verify — should show submissions grouped by their org (no more NULL).
SELECT COALESCE(org_id::text,'(null)') AS org_id, status, COUNT(*) AS n
FROM worker_document_submissions
GROUP BY org_id, status
ORDER BY n DESC;
