-- =============================================================================
-- Add contract_signed to project_assignments
-- Run in: Supabase → Database → SQL Editor. Safe to re-run.
--
-- Adds an app-owned boolean that lets admins mark an assignment contract as
-- "signed / executed" directly in the app, independently of the Dropbox Sign
-- e-signature workflow. Both channels (manual mark + Dropbox Sign) produce the
-- same "✅ Signed" badge — the field is separate so sbPersistAll can safely
-- write it without conflicting with the webhook-owned signature_status field.
-- =============================================================================

ALTER TABLE project_assignments
  ADD COLUMN IF NOT EXISTS contract_signed boolean NOT NULL DEFAULT false;

-- Verify
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='project_assignments'
  AND column_name='contract_signed';
