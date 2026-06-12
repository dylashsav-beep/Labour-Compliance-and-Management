-- =============================================================================
-- Competencies & Training — Vault Portal Extension
-- Run in: Supabase → Database → SQL Editor
-- Run AFTER add_worker_competencies.sql and add_get_vault_portal.sql
--
-- Recreates get_vault_portal() to add per-org competency data to each
-- membership entry. New fields per membership:
--   competencies  — catalogue items assigned to this worker in this org
--   comp_records  — submitted evidence records for this worker in this org
--
-- Safe to re-run (CREATE OR REPLACE).
-- =============================================================================

CREATE OR REPLACE FUNCTION get_vault_portal()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
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

    -- One entry per linked org, each carrying that org's worker row,
    -- document requirements, worker documents, assignments, and competencies.
    'memberships', (
      SELECT COALESCE(json_agg(mem), '[]'::json) FROM (
        SELECT
          l.org_id        AS org_id,
          o.name          AS org_name,
          o.slug          AS org_slug,
          json_build_object(
            'id',              w.id,
            'full_name',       w.full_name,
            'worker_type',     w.worker_type,
            'reference',       w.reference,
            'nationality',     w.nationality,
            'document_set_id', w.document_set_id,
            'email',           w.email
          ) AS worker,

          -- Document set items for the compliance docs tab
          (SELECT COALESCE(json_agg(i ORDER BY i.sort_order), '[]'::json)
             FROM document_set_items i
            WHERE i.active = true AND i.document_set_id = w.document_set_id
          ) AS doc_set_items,

          -- Worker's compliance document statuses
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

          -- Project assignments for the worker
          (SELECT COALESCE(json_agg(json_build_object(
                'id',               a.id,
                'project_name',     p.name,
                'start_date',       a.start_date,
                'end_date',         a.end_date,
                'signature_status', a.signature_status,
                'has_contract',     EXISTS (SELECT 1 FROM project_assignment_files f
                                              WHERE f.project_assignment_id = a.id
                                                AND f.active = true)
             ) ORDER BY a.start_date DESC), '[]'::json)
             FROM project_assignments a
             LEFT JOIN projects p ON p.id = a.project_id
            WHERE a.worker_id = l.worker_row_id AND a.active = true
          ) AS assignments,

          -- ── Competency catalogue items assigned to this worker ──────────
          -- Joins worker_competency_assignments → worker_competencies so the
          -- vault knows what's required for this worker in this org.
          (SELECT COALESCE(json_agg(json_build_object(
                'assignment_id',     ca.id,
                'competency_id',     c.id,
                'name',              c.name,
                'category',          c.category,
                'info_text',         c.info_text,
                'info_url',          c.info_url,
                'template_file_name', c.template_file_name,
                'template_file_path', c.template_file_path,
                'allow_issue',       c.allow_issue,
                'expiry_tracking',   c.expiry_tracking,
                'required',          ca.required,
                'notes',             ca.notes,
                'sort_order',        c.sort_order
             ) ORDER BY c.sort_order, c.name), '[]'::json)
             FROM worker_competency_assignments ca
             JOIN worker_competencies c ON c.id = ca.competency_id
            WHERE ca.worker_id = l.worker_row_id
              AND ca.org_id    = l.org_id
              AND ca.active    = true
              AND c.active     = true
          ) AS competencies,

          -- ── Worker's submitted competency evidence records ──────────────
          -- Latest active record per competency (all statuses — worker sees
          -- pending/approved/rejected). History shown in admin only.
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

    -- The worker's own vault documents (personal + org-approved copies).
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

    -- Worker-owned contract copies (assignment history across orgs).
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
$$;

GRANT EXECUTE ON FUNCTION get_vault_portal() TO authenticated;

-- Verify:
--   SELECT get_vault_portal();
--   Result should include 'competencies' and 'comp_records' arrays per membership.
