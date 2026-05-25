-- Add proof-of-issue and proof-of-return file columns to tool_assignments
ALTER TABLE tool_assignments
  ADD COLUMN IF NOT EXISTS issue_file_path  text,
  ADD COLUMN IF NOT EXISTS issue_file_name  text,
  ADD COLUMN IF NOT EXISTS return_file_path text,
  ADD COLUMN IF NOT EXISTS return_file_name text;
