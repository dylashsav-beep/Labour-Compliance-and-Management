-- Update get_worker_portal to also return resource assignments
-- Run in: Supabase → Database → SQL Editor
-- Prerequisites: worker_resource_return_requests.sql must be run first

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
    'doc_sets',       (SELECT COALESCE(json_agg(s ORDER BY s.name), '[]'::json) FROM document_sets s WHERE s.active = true),
    'doc_set_items',  (SELECT COALESCE(json_agg(i ORDER BY i.sort_order), '[]'::json) FROM document_set_items i WHERE i.active = true),
    'worker_docs',    (SELECT COALESCE(json_agg(d), '[]'::json) FROM worker_documents d WHERE d.worker_id = v_worker.id AND d.active = true),
    'worker_doc_files', (SELECT COALESCE(json_agg(f), '[]'::json) FROM worker_document_files f WHERE f.worker_id = v_worker.id AND f.active = true),
    'assignments',    (SELECT COALESCE(json_agg(a), '[]'::json) FROM project_assignments a WHERE a.worker_id = v_worker.id AND a.active = true),
    'projects',       (SELECT COALESCE(json_agg(p ORDER BY p.name), '[]'::json) FROM projects p WHERE p.active = true),
    'submissions',    (SELECT COALESCE(json_agg(s ORDER BY s.submitted_at DESC), '[]'::json) FROM worker_document_submissions s WHERE s.worker_id = v_worker.id AND s.active = true AND s.status = 'pending'),
    'accom_assignments', (SELECT COALESCE(json_agg(aa ORDER BY aa.start_date DESC), '[]'::json) FROM accommodation_assignments aa WHERE aa.worker_id = v_worker.id AND aa.active = true),
    'properties',     (SELECT COALESCE(json_agg(p ORDER BY p.name), '[]'::json) FROM properties p WHERE p.active = true),
    'veh_assignments', (SELECT COALESCE(json_agg(va ORDER BY va.start_date DESC), '[]'::json) FROM vehicle_assignments va WHERE va.worker_id = v_worker.id AND va.active = true),
    'vehicles',       (SELECT COALESCE(json_agg(v ORDER BY v.description), '[]'::json) FROM vehicles v WHERE v.active = true),
    'tool_assignments', (SELECT COALESCE(json_agg(ta ORDER BY ta.start_date DESC), '[]'::json) FROM tool_assignments ta WHERE ta.worker_id = v_worker.id AND ta.active = true),
    'tools',          (SELECT COALESCE(json_agg(t ORDER BY t.name), '[]'::json) FROM tools t WHERE t.active = true),
    'return_requests', (SELECT COALESCE(json_agg(rr ORDER BY rr.submitted_at DESC), '[]'::json) FROM worker_resource_return_requests rr WHERE rr.worker_id = v_worker.id AND rr.status = 'pending')
  );
END;
$func$;
GRANT EXECUTE ON FUNCTION get_worker_portal(text) TO anon, authenticated;
