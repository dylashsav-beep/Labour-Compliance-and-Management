-- Migration: add_compliance_documents
-- Creates the compliance_documents table and storage bucket policy.
-- Run this in the Supabase SQL Editor.

CREATE TABLE IF NOT EXISTS compliance_documents (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title       TEXT NOT NULL,
  category    TEXT NOT NULL DEFAULT 'general',
  scope_type  TEXT NOT NULL CHECK (scope_type IN ('project','country')),
  scope_id    TEXT NOT NULL,
  scope_label TEXT NOT NULL DEFAULT '',
  notes       TEXT NOT NULL DEFAULT '',
  file_name   TEXT NOT NULL DEFAULT '',
  file_path   TEXT NOT NULL DEFAULT '',
  file_size   BIGINT NOT NULL DEFAULT 0,
  mime_type   TEXT NOT NULL DEFAULT '',
  uploaded_by TEXT NOT NULL DEFAULT '',
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_comp_docs_scope ON compliance_documents(scope_type, scope_id);
CREATE INDEX IF NOT EXISTS idx_comp_docs_active ON compliance_documents(active);

ALTER TABLE compliance_documents ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read, insert and update.
-- Deletion/deactivation is enforced at the JS layer via the active flag.
CREATE POLICY auth_only ON compliance_documents
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Ensure the tmc-documents storage bucket exists (idempotent).
-- If the bucket already exists this is a no-op.
INSERT INTO storage.buckets (id, name, public)
  VALUES ('tmc-documents', 'tmc-documents', false)
  ON CONFLICT (id) DO NOTHING;

-- Allow authenticated users to upload/download from tmc-documents bucket.
CREATE POLICY IF NOT EXISTS "tmc_documents_auth_select"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'tmc-documents');

CREATE POLICY IF NOT EXISTS "tmc_documents_auth_insert"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'tmc-documents');

CREATE POLICY IF NOT EXISTS "tmc_documents_auth_update"
  ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'tmc-documents');
