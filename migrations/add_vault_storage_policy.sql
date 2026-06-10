-- =============================================================================
-- Worker Vault — Storage RLS for the worker-owned `vault/` path
-- Run in: Supabase → Database → SQL Editor
-- Run AFTER fix_storage_org_isolation.sql and add_worker_vault.sql
--
-- Vault files live in the shared `tmc-documents` bucket under a DISTINCT
-- top-level prefix:
--
--     vault/{worker_account_id}/...
--            └ folder[2] = auth.uid()::text
--
-- Why a `vault/` prefix and NOT `workers/{account_id}/vault/`:
-- fix_storage_org_isolation.sql grants TMC staff a grandfather over the
-- legacy top-level `workers/` folder. Putting vault files under `workers/`
-- would expose a worker's PRIVATE vault to TMC staff. `vault/` is matched by
-- no org policy (its first segment is never a valid org uuid) and is not in
-- the TMC grandfather list, so these worker-scoped policies are the ONLY
-- access path. The vault is the worker's, not any org's.
--
-- Each worker may only touch objects whose SECOND path segment equals their
-- own auth.uid. The service-role `copy-to-vault` edge function bypasses RLS
-- and is the writer for org-approved copies.
--
-- Safe to re-run.
-- =============================================================================

DROP POLICY IF EXISTS "vault owner read"   ON storage.objects;
DROP POLICY IF EXISTS "vault owner insert" ON storage.objects;
DROP POLICY IF EXISTS "vault owner update" ON storage.objects;
DROP POLICY IF EXISTS "vault owner delete" ON storage.objects;

CREATE POLICY "vault owner read" ON storage.objects
FOR SELECT TO authenticated USING (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'vault'
  AND (storage.foldername(name))[2] = auth.uid()::text
);

CREATE POLICY "vault owner insert" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'vault'
  AND (storage.foldername(name))[2] = auth.uid()::text
);

CREATE POLICY "vault owner update" ON storage.objects
FOR UPDATE TO authenticated USING (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'vault'
  AND (storage.foldername(name))[2] = auth.uid()::text
);

CREATE POLICY "vault owner delete" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'vault'
  AND (storage.foldername(name))[2] = auth.uid()::text
);

-- VERIFY
SELECT policyname, cmd, roles::text, qual, with_check
FROM pg_policies
WHERE schemaname='storage' AND tablename='objects'
  AND policyname LIKE 'vault owner%'
ORDER BY policyname;
