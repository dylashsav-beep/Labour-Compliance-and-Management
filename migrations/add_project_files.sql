-- =============================================================================
-- Project Files — Org-scoped file attachments per project
-- Run in: Supabase → Database → SQL Editor
-- Run AFTER add_worker_competencies.sql (depends on organisations table existing)
--
-- ✅ APPLIED to production (TMC Compliance) 2026-06-12 via Supabase MCP.
--
-- Creates project_files table + anon-read storage policies + extends
-- get_worker_portal() and get_vault_portal() to include project files.
--
-- IMPORTANT: This file contains the FULL live RPC definitions + project_files
-- fields. Do not replace the RPC bodies with simplified versions — see Lesson 31.
--
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE).
-- =============================================================================

-- ── Table: project_files ─────────────────────────────────────────────────────
-- Org-scoped. project_id is TEXT to match projects.id (which is TEXT/UUID stored as text).
-- visible_to_workers controls portal display; admins always see all files.
-- Storage path: project-files/{org_id}/{project_id}/{timestamp}_{random}_{slug}

CREATE TABLE IF NOT EXISTS project_files (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              UUID        NOT NULL REFERENCES organisations(id) ON DELETE CASCADE,
  project_id          TEXT        NOT NULL,
  file_name           TEXT        NOT NULL,
  file_path           TEXT        NOT NULL,
  caption             TEXT,
  mime_type           TEXT,
  size_bytes          BIGINT,
  visible_to_workers  BOOLEAN     NOT NULL DEFAULT true,
  sort_order          INT         DEFAULT 0,
  active              BOOLEAN     NOT NULL DEFAULT true,
  uploaded_by         TEXT,
  created_at          TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE project_files ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pf_select" ON project_files;
DROP POLICY IF EXISTS "pf_all"    ON project_files;
CREATE POLICY "pf_select" ON project_files
  FOR SELECT USING (org_id = current_org_id());
CREATE POLICY "pf_all" ON project_files
  FOR ALL USING (org_id = current_org_id())
  WITH CHECK (org_id = current_org_id());
CREATE INDEX IF NOT EXISTS pf_org_proj_idx   ON project_files(org_id, project_id);
CREATE INDEX IF NOT EXISTS pf_org_active_idx ON project_files(org_id, active);

-- ── Storage: public-read prefix for project-files/ ──────────────────────────
-- Worker portal is anonymous — files must be readable without auth.
-- Unguessable filenames provide sufficient isolation for project info/images
-- (not worker PII). Admins upload via org-scoped authenticated INSERT.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects' AND policyname='project_files_anon_read') THEN
    EXECUTE $pol$
      CREATE POLICY "project_files_anon_read" ON storage.objects
        FOR SELECT TO anon
        USING (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'project-files')
    $pol$;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects' AND policyname='project_files_auth_read') THEN
    EXECUTE $pol$
      CREATE POLICY "project_files_auth_read" ON storage.objects
        FOR SELECT TO authenticated
        USING (bucket_id = 'tmc-documents' AND (storage.foldername(name))[1] = 'project-files')
    $pol$;
  END IF;
END $$;

-- ── Extend get_worker_portal ─────────────────────────────────────────────────
-- Full live definition (competency fields preserved) + new project_files field.
CREATE OR REPLACE FUNCTION public.get_worker_portal(p_email text, p_org_id uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

GRANT EXECUTE ON FUNCTION get_worker_portal(text, uuid) TO anon, authenticated;

-- ── Extend get_vault_portal ──────────────────────────────────────────────────
-- Full live definition (competency fields preserved) +
--   project_id added to each assignment (needed for file lookup)
--   project_files array per membership (all visible files for this worker's projects)
CREATE OR REPLACE FUNCTION public.get_vault_portal()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_acct worker_accounts%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT * INTO v_acct FROM worker_accounts WHERE id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_vault_account';
  END IF;

  RETURN json_build_object(
    'account', json_build_object(
      'id',           v_acct.id,
      'email',        v_acct.email,
      'full_name',    v_acct.full_name,
      'plan',         v_acct.plan,
      'plan_expires', v_acct.plan_expires
    ),

    'memberships', (
      SELECT COALESCE(json_agg(mem), '[]'::json) FROM (
        SELECT
          l.org_id,
          o.name          AS org_name,
          o.slug          AS org_slug,
          json_build_object(
            'id',              w.id,
            'full_name',       w.full_name,
            'worker_type',     w.worker_type,
            'reference',       w.reference,
            'nationality',     w.nationality,
            'document_set_id', w.document_set_id,
            'email',           w.email,
            'phone',           w.phone,
            'notes',           w.notes
          ) AS worker,
          (SELECT COALESCE(json_agg(i ORDER BY i.sort_order), '[]'::json)
             FROM document_set_items i
            WHERE i.active = true AND i.document_set_id = w.document_set_id
          ) AS doc_set_items,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',          d.id,
                'doc_key',     d.doc_key,
                'status',      d.status,
                'expiry_date', d.expiry_date,
                'issue_date',  d.issue_date,
                'has_file',    EXISTS (SELECT 1 FROM worker_document_files f
                                        WHERE f.worker_document_id = d.id
                                          AND f.active = true)
             )), '[]'::json)
             FROM worker_documents d
            WHERE d.worker_id = l.worker_row_id AND d.active = true
          ) AS worker_docs,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',        f.id,
                'doc_key',   wd.doc_key,
                'file_name', f.file_name,
                'file_path', f.file_path
             ) ORDER BY f.created_at DESC), '[]'::json)
             FROM worker_document_files f
             JOIN worker_documents wd ON wd.id = f.worker_document_id
            WHERE f.worker_id = l.worker_row_id
              AND f.active = true
              AND NOT COALESCE(f.superseded, false)
          ) AS worker_doc_files,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',           s.id,
                'doc_key',      s.doc_key,
                'status',       s.status,
                'submitted_at', s.submitted_at,
                'review_notes', s.review_notes,
                'reviewed_at',  s.reviewed_at
             ) ORDER BY s.submitted_at DESC), '[]'::json)
             FROM worker_document_submissions s
            WHERE s.worker_id = l.worker_row_id
              AND s.org_id = l.org_id
              AND s.active = true
              AND s.status IN ('pending','rejected')
          ) AS submissions,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',                   id_doc.id,
                'doc_key',              id_doc.doc_key,
                'file_path',            id_doc.file_path,
                'file_name',            id_doc.file_name,
                'issued_by',            id_doc.issued_by,
                'issued_at',            id_doc.issued_at,
                'status',               id_doc.status,
                'signature_request_id', id_doc.signature_request_id,
                'signed_file_path',     id_doc.signed_file_path
             ) ORDER BY id_doc.issued_at DESC), '[]'::json)
             FROM issued_documents id_doc
            WHERE id_doc.worker_id = l.worker_row_id
              AND id_doc.org_id = l.org_id
              AND id_doc.active = true
          ) AS issued_docs,
          -- Project assignments — now includes project_id for file lookups
          (SELECT COALESCE(json_agg(json_build_object(
                'id',               a.id,
                'project_id',       a.project_id,
                'project_name',     p.name,
                'project_client',   p.client,
                'project_manager',  p.project_manager,
                'project_phone',    p.contact_phone,
                'project_location', p.location,
                'project_desc',     p.description,
                'start_date',       a.start_date,
                'end_date',         a.end_date,
                'notes',            a.notes,
                'signature_status', a.signature_status,
                'has_contract',     EXISTS (SELECT 1 FROM project_assignment_files pf
                                             WHERE pf.project_assignment_id = a.id
                                               AND pf.active = true)
             ) ORDER BY a.start_date DESC), '[]'::json)
             FROM project_assignments a
             LEFT JOIN projects p ON p.id = a.project_id
            WHERE a.worker_id = l.worker_row_id AND a.active = true
          ) AS assignments,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',               aa.id,
                'property_name',    prop.name,
                'property_address', prop.address,
                'start_date',       aa.start_date,
                'end_date',         aa.end_date,
                'notes',            aa.notes
             ) ORDER BY aa.start_date DESC), '[]'::json)
             FROM accommodation_assignments aa
             LEFT JOIN properties prop ON prop.id = aa.property_id
            WHERE aa.worker_id = l.worker_row_id
              AND aa.active = true
          ) AS accom_assignments,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',            va.id,
                'vehicle_desc',  veh.description,
                'vehicle_reg',   veh.registration_plate,
                'vehicle_make',  veh.make,
                'vehicle_model', veh.model,
                'start_date',    va.start_date,
                'end_date',      va.end_date,
                'notes',         va.notes
             ) ORDER BY va.start_date DESC), '[]'::json)
             FROM vehicle_assignments va
             LEFT JOIN vehicles veh ON veh.id = va.vehicle_id
            WHERE va.worker_id = l.worker_row_id
              AND va.active = true
          ) AS veh_assignments,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',          ta.id,
                'tool_name',   tl.name,
                'tool_desc',   tl.description,
                'tool_serial', tl.serial_number,
                'start_date',  ta.start_date,
                'end_date',    ta.end_date,
                'notes',       ta.notes
             ) ORDER BY ta.start_date DESC), '[]'::json)
             FROM tool_assignments ta
             LEFT JOIN tools tl ON tl.id = ta.tool_id
            WHERE ta.worker_id = l.worker_row_id
              AND ta.active = true
          ) AS tool_assignments,
          (SELECT COALESCE(json_agg(json_build_object(
                'id',            rr.id,
                'resource_type', rr.resource_type,
                'assignment_id', rr.assignment_id,
                'status',        rr.status,
                'submitted_at',  rr.submitted_at,
                'review_notes',  rr.review_notes
             )), '[]'::json)
             FROM worker_resource_return_requests rr
            WHERE rr.worker_id = l.worker_row_id
              AND rr.org_id = l.org_id
              AND rr.status = 'pending'
          ) AS return_requests,
          (SELECT COALESCE(json_agg(json_build_object(
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
             FROM worker_competency_assignments ca
             JOIN worker_competencies c ON c.id = ca.competency_id
            WHERE ca.worker_id = l.worker_row_id
              AND ca.org_id    = l.org_id
              AND ca.active    = true
              AND c.active     = true
          ) AS competencies,
          (SELECT COALESCE(json_agg(json_build_object(
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
             FROM worker_competency_records r
            WHERE r.worker_id = l.worker_row_id
              AND r.org_id    = l.org_id
              AND r.active    = true
          ) AS comp_records,
          -- Project files visible to workers, for all projects this worker is assigned to
          (SELECT COALESCE(json_agg(json_build_object(
                'id',          pf.id,
                'project_id',  pf.project_id,
                'file_name',   pf.file_name,
                'file_path',   pf.file_path,
                'caption',     pf.caption,
                'mime_type',   pf.mime_type
             ) ORDER BY pf.sort_order, pf.created_at), '[]'::json)
             FROM project_files pf
            WHERE pf.org_id = l.org_id
              AND pf.visible_to_workers = true
              AND pf.active = true
              AND EXISTS (
                SELECT 1 FROM project_assignments pa
                WHERE pa.worker_id = l.worker_row_id
                  AND pa.project_id = pf.project_id
                  AND pa.active = true
              )
          ) AS project_files
        FROM worker_org_links l
        JOIN workers       w ON w.id = l.worker_row_id
        JOIN organisations o ON o.id = l.org_id
        WHERE l.worker_account_id = v_uid
          AND l.status = 'active'
        ORDER BY o.name
      ) mem
    ),

    'vault_docs', (
      SELECT COALESCE(json_agg(json_build_object(
          'id',            vd.id,
          'doc_key',       vd.doc_key,
          'display_name',  vd.display_name,
          'file_path',     vd.file_path,
          'file_name',     vd.file_name,
          'expiry_date',   vd.expiry_date,
          'issued_date',   vd.issued_date,
          'source',        vd.source,
          'source_org_id', vd.source_org_id,
          'approved_at',   vd.approved_at
        ) ORDER BY vd.created_at DESC), '[]'::json)
      FROM vault_documents vd
      WHERE vd.worker_account_id = v_uid AND vd.active = true
    ),

    'vault_assignments', (
      SELECT COALESCE(json_agg(json_build_object(
          'id',              va.id,
          'assignment_id',   va.assignment_id,
          'org_name',        va.org_name,
          'project_name',    va.project_name,
          'start_date',      va.start_date,
          'end_date',        va.end_date,
          'contract_status', va.contract_status,
          'file_path',       va.file_path,
          'file_name',       va.file_name
        ) ORDER BY va.start_date DESC), '[]'::json)
      FROM vault_assignment_links va
      WHERE va.worker_account_id = v_uid
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION get_vault_portal() TO authenticated;

-- Verify:
--   SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name='project_files';
--   SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='get_worker_portal'; -- should include 'project_files'
--   SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='get_vault_portal';  -- should include 'project_files' and 'project_id' on assignments
