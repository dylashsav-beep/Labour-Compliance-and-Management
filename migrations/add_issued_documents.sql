-- =============================================================================
-- ⛔ DO NOT RUN — SUPERSEDED; CREATES WIDE-OPEN POLICIES
-- =============================================================================
-- This file creates issued_documents with USING(true) RLS policies — any
-- authenticated user from any org can read and write any issued document.
-- The correct org-scoped policies are applied by fix_rls_rebuild_all_policies.sql.
-- Running this file would reintroduce cross-org read/write on issued documents.
-- =============================================================================

-- Issued documents: personalised contracts/forms issued to specific workers
-- Run ONCE in: Supabase → Database → SQL Editor

CREATE TABLE IF NOT EXISTS issued_documents (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid,
  worker_id  uuid        NOT NULL,
  doc_key    text        NOT NULL,
  file_path  text        NOT NULL,
  file_name  text        NOT NULL,
  issued_by  text,
  issued_at  timestamptz DEFAULT now(),
  status     text        NOT NULL DEFAULT 'pending_signature',
  active     boolean     NOT NULL DEFAULT true
);

ALTER TABLE issued_documents ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "read_issued_documents"  ON issued_documents FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "write_issued_documents" ON issued_documents FOR ALL    TO authenticated USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Authenticated users can manage files in issued-docs/ path
DO $$ BEGIN
  CREATE POLICY "auth can manage issued docs"
  ON storage.objects FOR ALL TO authenticated
  USING      (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'issued-docs')
  WITH CHECK (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'issued-docs');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- All sessions can download issued docs (worker portal uses anon role)
DO $$ BEGIN
  CREATE POLICY "Anyone can read issued docs"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'issued-docs');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Update get_worker_portal to return pending issued docs for this worker
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
