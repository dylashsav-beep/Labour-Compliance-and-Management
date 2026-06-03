-- Allow any user (authenticated or anon worker portal session) to
-- generate signed URLs / read files in the doc-templates/ folder.
-- Run ONCE in: Supabase → Database → SQL Editor

CREATE POLICY "Anyone can read doc-templates"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'doc-templates'
);
