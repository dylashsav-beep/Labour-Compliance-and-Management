-- Add template_file_name and template_file_path to document_set_items
-- Run ONCE in: Supabase → Database → SQL Editor
--
-- After running, also add a storage policy so workers can read doc-templates/:
--   INSERT INTO storage.policies (name, bucket_id, operation, definition)
--   VALUES ('workers read doc-templates', 'tmc-documents', 'SELECT',
--     '(bucket_id = ''tmc-documents'' AND (storage.foldername(name))[1] = ''doc-templates'')');
-- Or extend worker_storage_policy.sql to include doc-templates/ path.

ALTER TABLE document_set_items
  ADD COLUMN IF NOT EXISTS template_file_name text,
  ADD COLUMN IF NOT EXISTS template_file_path text;
