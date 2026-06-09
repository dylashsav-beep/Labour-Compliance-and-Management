-- =============================================================================
-- Add signed_at timestamp to issued_documents
-- Run in: Supabase → Database → SQL Editor
-- Safe to re-run.
--
-- Records when Dropbox Sign confirmed all signers completed (webhook fires).
-- Used to pre-fill the "Issue date" field in the Approvals e-sign review UI.
-- =============================================================================

ALTER TABLE issued_documents
  ADD COLUMN IF NOT EXISTS signed_at timestamptz;

-- Verify
SELECT 'issued_documents.signed_at' AS col,
       (column_name IS NOT NULL) AS ok
FROM information_schema.columns
WHERE table_schema='public' AND table_name='issued_documents' AND column_name='signed_at';
