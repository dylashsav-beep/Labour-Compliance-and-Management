-- Worker portal: secure RPC functions for no-verification email login
-- Run in Supabase → Database → SQL Editor

-- Returns all data needed for the worker portal for a given email.
-- SECURITY DEFINER means it runs as the DB owner (bypasses RLS) — safe because
-- it only returns data for the single worker whose email matches.
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
    'submissions',    (SELECT COALESCE(json_agg(s ORDER BY s.submitted_at DESC), '[]'::json) FROM worker_document_submissions s WHERE s.worker_id = v_worker.id AND s.active = true AND s.status = 'pending')
  );
END;
$func$;
GRANT EXECUTE ON FUNCTION get_worker_portal(text) TO anon, authenticated;


-- Inserts a worker document submission after verifying email matches the worker.
CREATE OR REPLACE FUNCTION submit_worker_document(
  p_email text, p_worker_id uuid, p_doc_key text,
  p_expiry_date date DEFAULT NULL, p_issue_date date DEFAULT NULL,
  p_notes text DEFAULT NULL, p_file_path text DEFAULT NULL,
  p_file_name text DEFAULT NULL, p_file_size bigint DEFAULT NULL,
  p_mime_type text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $func$
DECLARE v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM workers WHERE id = p_worker_id AND lower(email) = lower(p_email) AND active = true) THEN
    RAISE EXCEPTION 'Email does not match worker profile';
  END IF;
  INSERT INTO worker_document_submissions
    (worker_id, doc_key, submitted_by_email, expiry_date, issue_date, notes,
     file_path, file_name, file_size, mime_type, status, active)
  VALUES
    (p_worker_id, p_doc_key, p_email, p_expiry_date, p_issue_date, p_notes,
     p_file_path, p_file_name, p_file_size, p_mime_type, 'pending', true)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$func$;
GRANT EXECUTE ON FUNCTION submit_worker_document(text, uuid, text, date, date, text, text, text, bigint, text) TO anon, authenticated;


-- Updates a worker's own email and notes after verifying the current email.
CREATE OR REPLACE FUNCTION save_worker_profile(
  p_email text, p_worker_id uuid,
  p_new_email text DEFAULT NULL, p_notes text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $func$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM workers WHERE id = p_worker_id AND lower(email) = lower(p_email) AND active = true) THEN
    RAISE EXCEPTION 'Email does not match worker profile';
  END IF;
  UPDATE workers SET
    email = NULLIF(p_new_email, ''),
    notes = p_notes,
    updated_at = now()
  WHERE id = p_worker_id;
END;
$func$;
GRANT EXECUTE ON FUNCTION save_worker_profile(text, uuid, text, text) TO anon, authenticated;
