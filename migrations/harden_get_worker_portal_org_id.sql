-- =============================================================================
-- Harden get_worker_portal: reject NULL p_org_id
-- Run in: Supabase → Database → SQL Editor
--
-- Problem: the current function signature is
--   get_worker_portal(p_email text, p_org_id uuid DEFAULT NULL)
-- with the lookup condition:
--   AND (p_org_id IS NULL OR org_id = p_org_id)
--
-- This means a direct anon API call without p_org_id (or with p_org_id=NULL)
-- would match a worker by email alone, regardless of which org they belong to.
-- In a multi-org system this is a cross-org data leak via the anon API.
-- The app clients all pass a concrete org (currentOrgId||SITE_ORG_ID), so this
-- gap is latent (not triggered by any app code). But it is open to a direct
-- PostgREST/RPC call from outside the app.
--
-- Fix: add an explicit NULL guard at the top of the function and remove the
-- IS NULL branch from the worker lookup. p_org_id still has DEFAULT NULL so
-- the call signature is unchanged (no client code needs updating), but a NULL
-- value now raises an error rather than silently matching any org.
--
-- Safe to re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_worker_portal(
  p_email  text,
  p_org_id uuid DEFAULT NULL
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  v_worker            workers%ROWTYPE;
  v_tool_assignments  json := '[]'::json;
  v_tools             json := '[]'::json;
  v_return_requests   json := '[]'::json;
  v_submissions       json := '[]'::json;
  v_issued_docs       json := '[]'::json;
BEGIN
  -- Reject NULL org — NULL means "match any org", which is a cross-org hole.
  -- All app clients pass a concrete org_id. Direct API callers must do the same.
  IF p_org_id IS NULL THEN
    RAISE EXCEPTION 'p_org_id is required';
  END IF;

  SELECT * INTO v_worker
  FROM workers
  WHERE lower(email) = lower(p_email)
    AND active = true
    AND org_id = p_org_id
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
    FROM worker_document_submissions s WHERE s.worker_id = v_worker.id AND s.active = true AND s.status = 'pending';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='issued_documents') THEN
    SELECT COALESCE(json_agg(id_doc ORDER BY id_doc.issued_at DESC), '[]'::json) INTO v_issued_docs
    FROM issued_documents id_doc
    WHERE id_doc.worker_id = v_worker.id
      AND id_doc.active = true
      AND id_doc.status = 'pending_signature';
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
    'issued_docs',       v_issued_docs
  );
END;
$func$;

GRANT EXECUTE ON FUNCTION get_worker_portal(text, uuid) TO anon, authenticated;

-- Verify: calling with NULL should now raise an error, not return data.
-- SELECT get_worker_portal('any@email.com', NULL);  -- should raise: p_org_id is required
