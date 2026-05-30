-- Add superseded flag to worker document files
-- Superseded files are collapsed in the UI but kept for history
ALTER TABLE worker_document_files
  ADD COLUMN IF NOT EXISTS superseded boolean NOT NULL DEFAULT false;
