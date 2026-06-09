-- =============================================================================
-- Route e-signed assignment contracts through the Approvals review step
-- Run in: Supabase → Database → SQL Editor. Safe to re-run.
--
-- Previously the dropbox-sign-webhook auto-applied a signed assignment contract
-- (deactivated originals + inserted the signed PDF + set signature_status='signed').
-- Now the webhook instead parks the signed PDF and sets signature_status='pending_review';
-- an admin reviews it in the Approvals tab and approves it, which attaches the signed
-- PDF to the assignment. These two columns hold the parked signed PDF + timestamp.
--
-- signature_status has NO check constraint (text NOT NULL DEFAULT 'none'), so the
-- new 'pending_review' value is already accepted — no constraint change needed.
-- =============================================================================

ALTER TABLE project_assignments
  ADD COLUMN IF NOT EXISTS signed_file_path text,
  ADD COLUMN IF NOT EXISTS signed_at        timestamptz;

-- Verify
SELECT 'project_assignments.signed_file_path' AS col,
       (column_name IS NOT NULL) AS ok
FROM information_schema.columns
WHERE table_schema='public' AND table_name='project_assignments' AND column_name='signed_file_path'
UNION ALL
SELECT 'project_assignments.signed_at',
       (column_name IS NOT NULL)
FROM information_schema.columns
WHERE table_schema='public' AND table_name='project_assignments' AND column_name='signed_at';
