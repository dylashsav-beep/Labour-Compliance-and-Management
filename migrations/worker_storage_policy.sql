-- Allow anonymous (unauthenticated) workers to upload files into the
-- worker-submissions/ folder of the tmc-documents bucket.
--
-- Workers use direct email login (no Supabase Auth session) so they hit
-- the API as the `anon` role. The path pattern restricts uploads to the
-- correct sub-folder; the submit_worker_document RPC validates identity.
--
-- Run in: Supabase → Database → SQL Editor

CREATE POLICY "anon workers can upload submission files"
ON storage.objects FOR INSERT TO anon
WITH CHECK (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'worker-submissions'
);
