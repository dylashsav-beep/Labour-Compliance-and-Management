-- =============================================================================
-- Fix get_worker_portal: add ID-only lookup for code-login path
-- Applied: 2026-06-14 via Supabase MCP
-- Safe to re-run (CREATE OR REPLACE, but must DROP old 2-param overload first)
--
-- Context: the upload-code login path (worker.html wpDirectLogin) fetches workers
-- by upload_code via get_worker_profiles_by_code, then loads the portal with
-- p_worker_id only (no email, because code-login workers may have no email set).
-- The prior function required a non-empty p_email — workers without email were
-- unreachable via the code-login path.
--
-- Change: adds an OR branch to the WHERE clause:
--   ((p_email IS NULL OR p_email = '') AND p_worker_id IS NOT NULL AND id = p_worker_id)
-- Security maintained: p_org_id is still required (NULL raises exception);
-- the ID-only branch checks org_id = p_org_id so cross-org lookup is impossible.
--
-- Also contains all previously applied changes:
--   • p_org_id NULL guard (from harden_get_worker_portal_org_id.sql)
--   • p_worker_id optional param for profile pinning (from add_worker_profile_switcher.sql)
--   • competency_assignments + comp_records (from extend_worker_portal_competencies.sql)
--   • project_files (from add_project_files.sql)
--
-- This is the FULL LIVE definition as of 2026-06-14. Safe to re-run.
-- =============================================================================

-- Drop old 2-param overload if present (signature change requires DROP first — Lesson 34)
DROP FUNCTION IF EXISTS public.get_worker_portal(text, uuid);

CREATE OR REPLACE FUNCTION public.get_worker_portal(
  p_email     text,
  p_org_id    uuid    DEFAULT NULL::uuid,
  p_worker_id uuid    DEFAULT NULL::uuid
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public' AS $function$
DECLARE
  v_worker            workers%ROWTYPE;
  v_tool_assignments  json := '[]'::json;
  v_tools             json := '[]'::json;
  v_return_requests   json := '[]'::json;
  v_submissions       json := '[]'::json;
  v_issued_docs       json := '[]'::json;
  v_comp_assignments  json := '[]'::json;
  v_comp_records      json := '[]'::json;
BEGIN
  IF p_org_id IS NULL THEN
    RAISE EXCEPTION 'p_org_id is required';
  END IF;

  SELECT * INTO v_worker
  FROM workers
  WHERE org_id = p_org_id
    AND active = true
    AND (
      -- Normal email lookup (email present)
      (p_email IS NOT NULL AND p_email != '' AND lower(email) = lower(p_email) AND (p_worker_id IS NULL OR id = p_worker_id))
      OR
      -- ID-only lookup: used by code-login path when worker has no email
      ((p_email IS NULL OR p_email = '') AND p_worker_id IS NOT NULL AND id = p_worker_id)
    )
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='tool_assignments') THEN
    SELECT COALESCE(json_agg(ta ORDER BY ta.start_date DESC), '[]'::json) INTO v_tool_assignments
    FROM tool_assignments ta WHERE ta.worker_id = v_worker.id AND ta.active = true;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='tools') THEN
    SELECT COALESCE(json_agg(t ORDER BY t.name), '[]'::json) INTO v_tools
    FROM tools t WHERE t.active = true AND t.org_id = v_worker.org_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_resource_return_requests') THEN
    SELECT COALESCE(json_agg(rr ORDER BY rr.submitted_at DESC), '[]'::json) INTO v_return_requests
    FROM worker_resource_return_requests rr WHERE rr.worker_id = v_worker.id AND rr.status = 'pending';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_document_submissions') THEN
    SELECT COALESCE(json_agg(s ORDER BY s.submitted_at DESC), '[]'::json) INTO v_submissions
    FROM worker_document_submissions s
    WHERE s.worker_id = v_worker.id
      AND s.active = true
      AND (
        s.status = 'pending'
        OR (s.status = 'rejected' AND s.review_notes IS NOT NULL)
      );
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='issued_documents') THEN
    SELECT COALESCE(json_agg(id_doc ORDER BY id_doc.issued_at DESC), '[]'::json) INTO v_issued_docs
    FROM issued_documents id_doc
    WHERE id_doc.worker_id = v_worker.id
      AND id_doc.active = true
      AND id_doc.status = 'pending_signature';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_competency_assignments') THEN
    SELECT COALESCE(json_agg(json_build_object(
        'assignment_id',      ca.id,
        'competency_id',      c.id,
        'name',               c.name,
        'category',           c.category,
        'info_text',          c.info_text,
        'info_url',           c.info_url,
        'template_file_name', c.template_file_name,
        'template_file_path', c.template_file_path,
        'allow_issue',        c.allow_issue,
        'expiry_tracking',    c.expiry_tracking,
        'required',           ca.required,
        'notes',              ca.notes,
        'sort_order',         c.sort_order
      ) ORDER BY c.sort_order, c.name), '[]'::json)
    INTO v_comp_assignments
    FROM worker_competency_assignments ca
    JOIN worker_competencies c ON c.id = ca.competency_id
    WHERE ca.worker_id = v_worker.id
      AND ca.org_id    = v_worker.org_id
      AND ca.active    = true
      AND c.active     = true;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_competency_records') THEN
    SELECT COALESCE(json_agg(json_build_object(
        'id',            r.id,
        'competency_id', r.competency_id,
        'file_path',     r.file_path,
        'file_name',     r.file_name,
        'issued_date',   r.issued_date,
        'expiry_date',   r.expiry_date,
        'status',        r.status,
        'submitted_at',  r.submitted_at,
        'review_notes',  r.review_notes
      ) ORDER BY r.submitted_at DESC), '[]'::json)
    INTO v_comp_records
    FROM worker_competency_records r
    WHERE r.worker_id = v_worker.id
      AND r.org_id    = v_worker.org_id
      AND r.active    = true;
  END IF;

  RETURN json_build_object(
    'worker', json_build_object(
      'id',              v_worker.id,
      'full_name',       v_worker.full_name,
      'worker_type',     v_worker.worker_type,
      'reference',       v_worker.reference,
      'nationality',     v_worker.nationality,
      'agency_name',     v_worker.agency_name,
      'email',           v_worker.email,
      'notes',           v_worker.notes,
      'document_set_id', v_worker.document_set_id,
      'org_id',          v_worker.org_id
    ),
    'doc_sets',          (SELECT COALESCE(json_agg(s ORDER BY s.name),        '[]'::json) FROM document_sets s          WHERE s.active = true AND s.org_id = v_worker.org_id),
    'doc_set_items',     (SELECT COALESCE(json_agg(i ORDER BY i.sort_order),  '[]'::json) FROM document_set_items i     WHERE i.active = true AND i.org_id = v_worker.org_id),
    'worker_docs',       (SELECT COALESCE(json_agg(d),                        '[]'::json) FROM worker_documents d       WHERE d.worker_id = v_worker.id AND d.active = true),
    'worker_doc_files',  (SELECT COALESCE(json_agg(f),                        '[]'::json) FROM worker_document_files f  WHERE f.worker_id = v_worker.id AND f.active = true),
    'assignments',       (SELECT COALESCE(json_agg(a),                        '[]'::json) FROM project_assignments a    WHERE a.worker_id = v_worker.id AND a.active = true),
    'projects',          (SELECT COALESCE(json_agg(p ORDER BY p.name),        '[]'::json) FROM projects p               WHERE p.active = true AND p.org_id = v_worker.org_id),
    'submissions',       v_submissions,
    'accom_assignments', (SELECT COALESCE(json_agg(aa ORDER BY aa.start_date DESC), '[]'::json) FROM accommodation_assignments aa WHERE aa.worker_id = v_worker.id AND aa.active = true),
    'properties',        (SELECT COALESCE(json_agg(p ORDER BY p.name),        '[]'::json) FROM properties p             WHERE p.active = true AND p.org_id = v_worker.org_id),
    'veh_assignments',   (SELECT COALESCE(json_agg(va ORDER BY va.start_date DESC), '[]'::json) FROM vehicle_assignments va WHERE va.worker_id = v_worker.id AND va.active = true),
    'vehicles',          (SELECT COALESCE(json_agg(v ORDER BY v.description), '[]'::json) FROM vehicles v               WHERE v.active = true AND v.org_id = v_worker.org_id),
    'tool_assignments',  v_tool_assignments,
    'tools',             v_tools,
    'return_requests',   v_return_requests,
    'issued_docs',       v_issued_docs,
    'competency_assignments', v_comp_assignments,
    'comp_records',           v_comp_records,
    'project_files', (
      SELECT COALESCE(json_agg(json_build_object(
          'id',          pf.id,
          'project_id',  pf.project_id,
          'file_name',   pf.file_name,
          'file_path',   pf.file_path,
          'caption',     pf.caption,
          'mime_type',   pf.mime_type
        ) ORDER BY pf.sort_order, pf.created_at), '[]'::json)
      FROM project_files pf
      WHERE pf.org_id = v_worker.org_id
        AND pf.visible_to_workers = true
        AND pf.active = true
        AND pf.project_id IN (
          SELECT pa.project_id FROM project_assignments pa
          WHERE pa.worker_id = v_worker.id AND pa.active = true
        )
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_worker_portal(text, uuid, uuid) TO anon, authenticated;

-- Verify: should find the worker and return data
-- SELECT get_worker_portal('worker@example.com', 'your-org-id'::uuid) IS NOT NULL;
-- Verify NULL guard: should raise exception
-- SELECT get_worker_portal('test@test.com', NULL);
-- Verify ID-only lookup (code-login path with no email):
-- SELECT get_worker_portal('', 'your-org-id'::uuid, 'worker-uuid'::uuid) IS NOT NULL;
