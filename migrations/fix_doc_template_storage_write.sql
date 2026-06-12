-- =============================================================================
-- Fix doc-template uploads (document sets + competencies)
-- Run in: Supabase → Database → SQL Editor
--
-- ✅ APPLIED to production (TMC Compliance) 2026-06-12 via Supabase MCP.
--
-- Problem: authenticated org staff could not upload a document-set or
-- competency template. `fix_storage_org_isolation.sql` dropped the bucket-wide
-- "authenticated_upload" policy. The surviving "org insert documents" policy
-- only allows objects whose FIRST path segment = current_org_id() (plus a few
-- TMC-grandfathered legacy folders). Templates live under doc-templates/ — kept
-- PUBLIC READ for the anon worker portal — so NO insert policy matched
-- doc-templates/ and every template upload was RLS-blocked:
--   "new row violates row-level security policy" / "Template upload failed".
--
-- Fix: mirror the org-logos write pattern. Templates are now uploaded under
-- doc-templates/{org_id}/...  (app.html updated to prefix the org id as the 2nd
-- path segment). These policies allow authenticated write/update/delete only
-- within the caller's own org prefix. The public read policy
-- ("Anyone can read doc-templates", foldername[1]='doc-templates') is untouched,
-- so anon worker-portal template downloads keep working.
--
-- Storage paths after this fix:
--   document set:  doc-templates/{org_id}/{set_id}/{doc_id}/{file}
--   competency:    doc-templates/{org_id}/competencies/{key}/{file}
--
-- Safe to re-run.
-- =============================================================================

DROP POLICY IF EXISTS "org write doc-templates"  ON storage.objects;
DROP POLICY IF EXISTS "org update doc-templates"  ON storage.objects;
DROP POLICY IF EXISTS "org delete doc-templates"  ON storage.objects;

CREATE POLICY "org write doc-templates" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'doc-templates'
  AND (storage.foldername(name))[2] = current_org_id()::text
);

CREATE POLICY "org update doc-templates" ON storage.objects
FOR UPDATE TO authenticated USING (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'doc-templates'
  AND (storage.foldername(name))[2] = current_org_id()::text
) WITH CHECK (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'doc-templates'
  AND (storage.foldername(name))[2] = current_org_id()::text
);

CREATE POLICY "org delete doc-templates" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'doc-templates'
  AND (storage.foldername(name))[2] = current_org_id()::text
);

-- Verify (should return the three policies above):
--   SELECT policyname, cmd FROM pg_policies
--   WHERE schemaname='storage' AND tablename='objects'
--     AND policyname LIKE '%doc-templates%';
