-- =============================================================================
-- Org Logo Storage Policies
-- Run ONCE in: Supabase → Database → SQL Editor
-- Safe to re-run (IF NOT EXISTS guards on each policy).
--
-- Logo files are uploaded to:
--   org-logos/<org_id>/logo_<timestamp>.<ext>
--
-- The timestamp in the filename guarantees a new URL on every re-upload,
-- so browsers always fetch the latest image and never serve a cached old one.
-- Each upload uses INSERT (not upsert/UPDATE), so only an INSERT policy is needed.
-- Old logo files accumulate in storage but logos change rarely so the overhead
-- is negligible; a manual cleanup can remove them via the Supabase Storage UI.
--
-- Public read is needed so the logo URL works in an <img> tag without auth.
-- =============================================================================

-- ── Public read access for org-logos/ ─────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects' AND schemaname = 'storage'
      AND policyname = 'org logos are publicly readable'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "org logos are publicly readable"
      ON storage.objects FOR SELECT TO anon
      USING (
        bucket_id = 'tmc-documents'
        AND (storage.foldername(name))[1] = 'org-logos'
      )
    $p$;
  END IF;
END $$;

-- ── Authenticated INSERT for org-logos/<own-org>/ only ────────────────────────
-- Each org's admins can only upload into their own org-id subfolder.
-- Format: org-logos/<org_id>/logo_<timestamp>.<ext>
-- (storage.foldername(name))[2] is the org_id segment.
DROP POLICY IF EXISTS "authenticated users can upload org logos" ON storage.objects;
CREATE POLICY "authenticated users can upload org logos"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'tmc-documents'
    AND (storage.foldername(name))[1] = 'org-logos'
    AND (storage.foldername(name))[2] = current_org_id()::text
  );

-- Drop the old update policy — no longer needed (timestamped paths = always INSERT).
DROP POLICY IF EXISTS "authenticated users can update org logos" ON storage.objects;

-- ── Verify ────────────────────────────────────────────────────────────────────
SELECT policyname, cmd, roles::text
FROM pg_policies
WHERE tablename = 'objects' AND schemaname = 'storage'
  AND policyname LIKE '%org logo%';
