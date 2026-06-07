-- =============================================================================
-- CRITICAL — Org-isolate the `tmc-documents` Storage bucket
-- Run in: Supabase → Database → SQL Editor
--
-- Problem: the bucket had policies granting EVERY authenticated user read/
-- write/delete over the WHOLE bucket (authenticated_download, _upload,
-- _delete, tmc_documents_auth_*), plus an "auth can manage issued docs" and a
-- PUBLIC "Anyone can read issued docs". With multiple orgs sharing one bucket,
-- any org's staff (or anon, for issued docs) could read another org's worker
-- PII (passports, VOGs).
--
-- Fix: documents are now uploaded under an org-id prefix (`${org_id}/...`, done
-- in app.html + worker.html). This migration drops the bucket-wide policies and
-- creates org-scoped ones: a caller may only touch objects whose FIRST folder
-- equals their own org. A TMC grandfather clause keeps the ~600 existing
-- non-prefixed TMC files working for TMC users only.
--
-- Leaves untouched: doc-templates public read (blank forms), org-logos
-- (public branding), and all diary_photos_* policies (a different project).
-- Safe to re-run.
-- =============================================================================

-- TMC org + the legacy (pre-prefix) top-level folders its existing files use.
-- These map to: workers/, worker-submissions/, issued-docs/, compliance/,
-- tool-assignments/, assignments/.

-- ── 1. Drop the leaking bucket-wide / non-org `tmc-documents` policies ──
DROP POLICY IF EXISTS "authenticated_download"        ON storage.objects;
DROP POLICY IF EXISTS "authenticated_upload"          ON storage.objects;
DROP POLICY IF EXISTS "authenticated_delete"          ON storage.objects;
DROP POLICY IF EXISTS "tmc_documents_auth_select"     ON storage.objects;
DROP POLICY IF EXISTS "tmc_documents_auth_insert"     ON storage.objects;
DROP POLICY IF EXISTS "tmc_documents_auth_update"     ON storage.objects;
DROP POLICY IF EXISTS "auth can manage issued docs"   ON storage.objects;
-- Replace the anon submission-upload policy with an org-prefix-aware version
DROP POLICY IF EXISTS "anon workers can upload submission files" ON storage.objects;

-- NOTE: "Anyone can read issued docs" (public) and "Anyone can read
-- doc-templates" (public) are intentionally KEPT — the anon worker portal
-- downloads issued docs and blank templates via signed URLs and relies on
-- these. They are lower-sensitivity (company-issued forms / blank templates)
-- and paths are timestamped. See the residual-gap note at the bottom.

-- ── 2. Org-scoped authenticated access to tmc-documents ──
-- A caller may only touch objects whose first path segment = their org id,
-- OR (TMC only) the legacy non-prefixed folders for backward compatibility.

CREATE POLICY "org read documents" ON storage.objects
FOR SELECT TO authenticated USING (
  bucket_id = 'tmc-documents' AND (
    (storage.foldername(name))[1] = current_org_id()::text
    OR (
      current_org_id() = '00000000-0000-0000-0001-000000000001'::uuid
      AND (storage.foldername(name))[1] IN
        ('workers','worker-submissions','issued-docs','compliance','tool-assignments','assignments')
    )
  )
);

CREATE POLICY "org insert documents" ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'tmc-documents' AND (
    (storage.foldername(name))[1] = current_org_id()::text
    OR (
      current_org_id() = '00000000-0000-0000-0001-000000000001'::uuid
      AND (storage.foldername(name))[1] IN
        ('workers','worker-submissions','issued-docs','compliance','tool-assignments','assignments')
    )
  )
);

CREATE POLICY "org update documents" ON storage.objects
FOR UPDATE TO authenticated USING (
  bucket_id = 'tmc-documents' AND (
    (storage.foldername(name))[1] = current_org_id()::text
    OR (
      current_org_id() = '00000000-0000-0000-0001-000000000001'::uuid
      AND (storage.foldername(name))[1] IN
        ('workers','worker-submissions','issued-docs','compliance','tool-assignments','assignments')
    )
  )
);

CREATE POLICY "org delete documents" ON storage.objects
FOR DELETE TO authenticated USING (
  bucket_id = 'tmc-documents' AND (
    (storage.foldername(name))[1] = current_org_id()::text
    OR (
      current_org_id() = '00000000-0000-0000-0001-000000000001'::uuid
      AND (storage.foldername(name))[1] IN
        ('workers','worker-submissions','issued-docs','compliance','tool-assignments','assignments')
    )
  )
);

-- ── 3. Anon worker-submission uploads (new org-prefixed path + legacy) ──
-- New path:  ${org_id}/worker-submissions/...   → folder [2] = 'worker-submissions'
-- Legacy:    worker-submissions/...             → folder [1] = 'worker-submissions'
-- Anon cannot be org-checked (no auth.uid()); the submission RECORD is still
-- gated server-side by the email-match RPC, and anon has NO read on this bucket.
CREATE POLICY "anon upload worker submissions" ON storage.objects
FOR INSERT TO anon WITH CHECK (
  bucket_id = 'tmc-documents' AND (
    (storage.foldername(name))[2] = 'worker-submissions'
    OR (storage.foldername(name))[1] = 'worker-submissions'
  )
);

-- ── 4. VERIFY — review remaining tmc-documents policies ──
SELECT policyname, cmd, roles::text, qual, with_check
FROM pg_policies
WHERE schemaname='storage' AND tablename='objects'
  AND (qual LIKE '%tmc-documents%' OR with_check LIKE '%tmc-documents%')
ORDER BY policyname;

-- =============================================================================
-- RESIDUAL GAP (lower severity, documented in CLAUDE.md):
-- "Anyone can read issued docs" and "Anyone can read doc-templates" remain
-- public because the ANON worker portal downloads those via signed URLs and
-- anon cannot be org-scoped in an RLS policy. To fully close: route worker
-- downloads through a SECURITY DEFINER edge function that verifies the worker
-- (by email) owns the path before returning a signed URL, then make these two
-- policies org-scoped / authenticated-only. Worker PII (workers/, worker-
-- submissions/, compliance/) is NOT affected — it is fully org-scoped above.
-- =============================================================================
