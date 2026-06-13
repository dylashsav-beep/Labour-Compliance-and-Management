-- =============================================================================
-- Worker Profile Switcher
-- Run in: Supabase → Database → SQL Editor
-- Safe to re-run (all CREATE OR REPLACE / IF NOT EXISTS).
--
-- Adds:
--   1. list_worker_profiles(p_email, p_org_id) — returns all active workers
--      matching an email in an org. Used when multiple workers share one email
--      (e.g. a company managing several profiles) so the worker portal can
--      show a profile-switcher after login.
--   2. Extends get_worker_portal() with optional p_worker_id — when supplied,
--      enforces email + org + id match instead of LIMIT 1 (default). Callers
--      that omit p_worker_id get existing LIMIT 1 behaviour unchanged.
-- =============================================================================

-- 1. list_worker_profiles
-- Returns [{id, full_name, reference, worker_type}] — no PII beyond name.
-- Caller must already know the email (they typed it or received it in the link).
-- SECURITY DEFINER so anon clients can call it; org is mandatory (null = reject).
CREATE OR REPLACE FUNCTION public.list_worker_profiles(
  p_email   text,
  p_org_id  uuid
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_org_id IS NULL THEN RAISE EXCEPTION 'p_org_id is required'; END IF;
  IF p_email  IS NULL OR trim(p_email) = '' THEN RAISE EXCEPTION 'p_email is required'; END IF;
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id',          w.id,
      'full_name',   w.full_name,
      'reference',   w.reference,
      'worker_type', w.worker_type
    ) ORDER BY w.full_name), '[]'::json)
    FROM workers w
    WHERE lower(w.email) = lower(trim(p_email))
      AND w.org_id = p_org_id
      AND w.active = true
  );
END; $$;

GRANT EXECUTE ON FUNCTION public.list_worker_profiles TO anon, authenticated;

-- 2. Extend get_worker_portal with optional p_worker_id
-- When p_worker_id is supplied the WHERE adds AND id = p_worker_id so the
-- caller pins a specific profile. Email + org + id must all match — p_worker_id
-- alone cannot bypass the email/org checks (safe for anon callers).
-- The rest of the body is IDENTICAL to the live definition (see Lesson 31 —
-- always start from pg_get_functiondef, never from memory).
CREATE OR REPLACE FUNCTION public.get_worker_portal(
  p_email      text,
  p_org_id     uuid     DEFAULT NULL::uuid,
  p_worker_id  uuid     DEFAULT NULL::uuid
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
  WHERE lower(email) = lower(p_email)
    AND active = true
    AND org_id = p_org_id
    AND (p_worker_id IS NULL OR id = p_worker_id)
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
END; $$;

GRANT EXECUTE ON FUNCTION public.get_worker_portal TO anon, authenticated;

-- Verify
SELECT 'list_worker_profiles exists' AS check,
       (SELECT count(*) FROM pg_proc WHERE proname='list_worker_profiles' AND pronamespace='public'::regnamespace) > 0 AS ok;
SELECT 'get_worker_portal has p_worker_id param' AS check,
       (SELECT count(*) FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='public'
        WHERE p.proname='get_worker_portal' AND pg_get_function_arguments(p.oid) LIKE '%p_worker_id%') > 0 AS ok;
