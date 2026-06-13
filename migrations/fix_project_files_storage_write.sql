-- ── Fix: project-files/ storage writes blocked by RLS ────────────────────────
-- `add_project_files.sql` created only SELECT policies (anon + authenticated)
-- for the `project-files/` prefix, and `fix_storage_org_isolation.sql` had
-- already dropped the bucket-wide authenticated upload policy. Result: every
-- authenticated upload to `project-files/{org_id}/{project_id}/…` failed with
-- "new row violates row-level security policy" (Lesson 32 class of bug).
--
-- App write path (app.html uploadProjectFiles):
--   project-files/{org_id}/{project_id}/{ts}_{rand}_{slug}
--   → foldername[1] = 'project-files', foldername[2] = org_id
--
-- These add org-scoped INSERT/UPDATE/DELETE for that prefix, keyed on
-- foldername[2] = current_org_id(). The public/anon SELECT policies
-- (project_files_anon_read / project_files_auth_read) are untouched, so the
-- worker portal (anon) and vault keep reading visible files. Safe to re-run.

DROP POLICY IF EXISTS "project_files_org_insert" ON storage.objects;
CREATE POLICY "project_files_org_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'tmc-documents'
    AND (storage.foldername(name))[1] = 'project-files'
    AND (storage.foldername(name))[2] = (current_org_id())::text
  );

DROP POLICY IF EXISTS "project_files_org_update" ON storage.objects;
CREATE POLICY "project_files_org_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'tmc-documents'
    AND (storage.foldername(name))[1] = 'project-files'
    AND (storage.foldername(name))[2] = (current_org_id())::text
  )
  WITH CHECK (
    bucket_id = 'tmc-documents'
    AND (storage.foldername(name))[1] = 'project-files'
    AND (storage.foldername(name))[2] = (current_org_id())::text
  );

DROP POLICY IF EXISTS "project_files_org_delete" ON storage.objects;
CREATE POLICY "project_files_org_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'tmc-documents'
    AND (storage.foldername(name))[1] = 'project-files'
    AND (storage.foldername(name))[2] = (current_org_id())::text
  );
