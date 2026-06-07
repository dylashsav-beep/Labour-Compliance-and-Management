-- =============================================================================
-- ⛔ DO NOT RUN — SUPERSEDED; CREATES WIDE-OPEN POLICIES
-- =============================================================================
-- This file creates RLS policies on issued_documents with USING(true) — meaning
-- every authenticated user from every org can read and write every row. It also
-- recreates storage policies that were dropped by fix_storage_org_isolation.sql.
-- Running this file would UNDO the storage org-isolation fix.
--
-- issued_documents is covered by fix_rls_rebuild_all_policies.sql (org-scoped).
-- fix_storage_org_isolation.sql handles the storage policies correctly.
-- =============================================================================

-- Fix: enable RLS on the issued_documents table that was created without it.
-- Safe to run even if RLS is already enabled — all statements are idempotent.
-- Run in: Supabase → Database → SQL Editor

-- 1. Enable RLS on the table (safe to re-run)
ALTER TABLE issued_documents ENABLE ROW LEVEL SECURITY;

-- 2. Table policies — drop first so re-running never fails
DROP POLICY IF EXISTS "read_issued_documents"  ON issued_documents;
DROP POLICY IF EXISTS "write_issued_documents" ON issued_documents;

CREATE POLICY "read_issued_documents"
  ON issued_documents FOR SELECT TO authenticated USING (true);

CREATE POLICY "write_issued_documents"
  ON issued_documents FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- 3. Storage policies for issued-docs/ path
DROP POLICY IF EXISTS "auth can manage issued docs"  ON storage.objects;
DROP POLICY IF EXISTS "Anyone can read issued docs"  ON storage.objects;

CREATE POLICY "auth can manage issued docs"
  ON storage.objects FOR ALL TO authenticated
  USING      (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'issued-docs')
  WITH CHECK (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'issued-docs');

CREATE POLICY "Anyone can read issued docs"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'issued-docs');

-- 4. Update get_worker_portal RPC to include pending issued docs
CREATE OR REPLACE FUNCTION get_worker_portal(p_email text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $func$
DECLARE v_worker workers%ROWTYPE;
BEGIN
  SELECT * INTO v_worker FROM workers WHERE lower(email) = lower(p_email) AND active = true LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN json_build_object(
    'worker', json_build_object(
      'id', v_worker.id, 'full_name', v_worker.full_name,
      'worker_type', v_worker.worker_type, 'reference', v_worker.reference,
      'nationality', v_worker.nationality, 'agency_name', v_worker.agency_name,
      'email', v_worker.email, 'notes', v_worker.notes,
      'document_set_id', v_worker.document_set_id
    ),
    'doc_sets',          (SELECT COALESCE(json_agg(s ORDER BY s.name), '[]'::json) FROM document_sets s WHERE s.active = true),
    'doc_set_items',     (SELECT COALESCE(json_agg(i ORDER BY i.sort_order), '[]'::json) FROM document_set_items i WHERE i.active = true),
    'worker_docs',       (SELECT COALESCE(json_agg(d), '[]'::json) FROM worker_documents d WHERE d.worker_id = v_worker.id AND d.active = true),
    'worker_doc_files',  (SELECT COALESCE(json_agg(f), '[]'::json) FROM worker_document_files f WHERE f.worker_id = v_worker.id AND f.active = true),
    'assignments',       (SELECT COALESCE(json_agg(a), '[]'::json) FROM project_assignments a WHERE a.worker_id = v_worker.id AND a.active = true),
    'projects',          (SELECT COALESCE(json_agg(p ORDER BY p.name), '[]'::json) FROM projects p WHERE p.active = true),
    'submissions',       (SELECT COALESCE(json_agg(s ORDER BY s.submitted_at DESC), '[]'::json) FROM worker_document_submissions s WHERE s.worker_id = v_worker.id AND s.active = true AND s.status = 'pending'),
    'issued_docs',       (SELECT COALESCE(json_agg(id_doc ORDER BY id_doc.issued_at DESC), '[]'::json) FROM issued_documents id_doc WHERE id_doc.worker_id = v_worker.id AND id_doc.active = true AND id_doc.status = 'pending_signature'),
    'accom_assignments', (SELECT COALESCE(json_agg(aa), '[]'::json) FROM accommodation_assignments aa WHERE aa.worker_id = v_worker.id AND aa.active = true),
    'veh_assignments',   (SELECT COALESCE(json_agg(va), '[]'::json) FROM vehicle_assignments va WHERE va.worker_id = v_worker.id AND va.active = true),
    'tool_assignments',  (SELECT COALESCE(json_agg(ta), '[]'::json) FROM tool_assignments ta WHERE ta.worker_id = v_worker.id AND ta.active = true),
    'properties',        (SELECT COALESCE(json_agg(p ORDER BY p.name), '[]'::json) FROM properties p WHERE p.active = true),
    'vehicles',          (SELECT COALESCE(json_agg(v ORDER BY v.description), '[]'::json) FROM vehicles v WHERE v.active = true),
    'tools',             (SELECT COALESCE(json_agg(t ORDER BY t.name), '[]'::json) FROM tools t WHERE t.active = true),
    'return_requests',   (SELECT COALESCE(json_agg(r ORDER BY r.requested_at DESC), '[]'::json) FROM resource_return_requests r WHERE r.worker_id = v_worker.id AND r.active = true AND r.status = 'pending')
  );
END;
$func$;
GRANT EXECUTE ON FUNCTION get_worker_portal(text) TO anon, authenticated;
