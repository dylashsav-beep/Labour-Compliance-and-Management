-- =============================================================================
-- Add e-signature fields to project_assignments and issued_documents
-- Run in: Supabase → Database → SQL Editor
-- Safe to re-run.
--
-- Adds:
--   project_assignments.signature_status  — 'none'|'pending'|'signed'|'declined'
--   project_assignments.signature_request_id — Dropbox Sign request ID
--   issued_documents.signature_request_id — Dropbox Sign request ID
--   issued_documents.signed_file_path     — Storage path of the signed PDF
-- =============================================================================

ALTER TABLE project_assignments
  ADD COLUMN IF NOT EXISTS signature_status     text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS signature_request_id text;

ALTER TABLE issued_documents
  ADD COLUMN IF NOT EXISTS signature_request_id text,
  ADD COLUMN IF NOT EXISTS signed_file_path     text;

-- Verify
SELECT 'project_assignments.signature_status' AS col,
       (column_name IS NOT NULL) AS ok
FROM information_schema.columns
WHERE table_schema='public' AND table_name='project_assignments' AND column_name='signature_status'
UNION ALL
SELECT 'issued_documents.signature_request_id',
       (column_name IS NOT NULL)
FROM information_schema.columns
WHERE table_schema='public' AND table_name='issued_documents' AND column_name='signature_request_id';
