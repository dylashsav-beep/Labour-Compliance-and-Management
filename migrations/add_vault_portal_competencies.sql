-- =============================================================================
-- Competencies & Training — Vault Portal Extension
-- Run in: Supabase → Database → SQL Editor
-- Run AFTER add_worker_competencies.sql and add_get_vault_portal.sql
--
-- ✅ APPLIED to production (TMC Compliance) 2026-06-12 via Supabase MCP.
--
-- This is the FULL live get_vault_portal() definition with two competency
-- fields added per membership (competencies + comp_records). It deliberately
-- reproduces EVERY existing field — worker_doc_files, submissions, issued_docs,
-- full project/accommodation/vehicle/tool detail, return_requests, etc. — so a
-- re-run never regresses the live function. Earlier drafts of this file were
-- drastically simplified and would have wiped most of vault.html's data; do NOT
-- restore those.
--
-- Safe to re-run (CREATE OR REPLACE).
-- =============================================================================

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
          -- Active non-superseded files (for downloading existing org docs)
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
          -- Pending + rejected submissions
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
          -- Issued documents (Dropbox Sign etc.)
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
          -- Project assignments (full project detail, no financial data)
          (SELECT COALESCE(json_agg(json_build_object(
                'id',               a.id,
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
          -- Accommodation assignments
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
          -- Vehicle assignments
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
          -- Tool assignments
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
          -- Return requests (pending)
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
          -- ── Competency catalogue items assigned to this worker ─────────────
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
          -- ── Worker's submitted competency evidence records ─────────────────
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
          ) AS comp_records
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
--   SELECT get_vault_portal();
--   Result should include 'competencies' and 'comp_records' arrays per membership.
