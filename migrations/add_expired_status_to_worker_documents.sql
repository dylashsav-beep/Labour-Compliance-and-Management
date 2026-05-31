-- =============================================================================
-- Allow 'expired' as a valid status value in worker_documents
-- Run ONCE in: Supabase → Database → SQL Editor
--
-- The app currently stores expired docs as 'ok' (display-only computed state).
-- Running this migration lets the app store 'expired' directly if desired.
-- =============================================================================

ALTER TABLE worker_documents
  DROP CONSTRAINT IF EXISTS worker_documents_status_check;

ALTER TABLE worker_documents
  ADD CONSTRAINT worker_documents_status_check
  CHECK (status IN ('ok', 'expiring', 'expired', 'missing'));
