-- =============================================================================
-- Org Logo Storage Policies
-- Run ONCE in: Supabase → Database → SQL Editor
-- Allows authenticated users (admins) to upload org logos and makes them
-- publicly readable so they can appear in the header <img> tag.
-- =============================================================================

-- ── Public read access for org-logos/ folder ─────────────────────────────────
-- Needed so the logo URL works in an <img> tag without auth cookies.

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

-- ── Authenticated upload / overwrite for org-logos/ ───────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects' AND schemaname = 'storage'
      AND policyname = 'authenticated users can upload org logos'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "authenticated users can upload org logos"
      ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (
        bucket_id = 'tmc-documents'
        AND (storage.foldername(name))[1] = 'org-logos'
      )
    $p$;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects' AND schemaname = 'storage'
      AND policyname = 'authenticated users can update org logos'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "authenticated users can update org logos"
      ON storage.objects FOR UPDATE TO authenticated
      USING (
        bucket_id = 'tmc-documents'
        AND (storage.foldername(name))[1] = 'org-logos'
      )
      WITH CHECK (
        bucket_id = 'tmc-documents'
        AND (storage.foldername(name))[1] = 'org-logos'
      )
    $p$;
  END IF;
END $$;

-- ── Verify ────────────────────────────────────────────────────────────────────
-- SELECT policyname, cmd, roles FROM pg_policies
-- WHERE tablename = 'objects' AND schemaname = 'storage'
--   AND policyname LIKE '%org logo%';
