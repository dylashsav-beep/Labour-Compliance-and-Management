-- =============================================================================
-- ⛔ DO NOT RUN — SUPERSEDED; CREATES WIDE-OPEN POLICIES
-- =============================================================================
-- This file creates worker_resource_return_requests with USING(true) policies —
-- meaning every authenticated user from every org can read every return request.
-- The correct org-scoped policies (via worker_id join to workers.org_id) are
-- applied by fix_rls_rebuild_all_policies.sql.
-- Running this file would reintroduce wide-open return request access.
-- =============================================================================

-- Return request table: workers submit proof of return for resources
-- Run in: Supabase → Database → SQL Editor

CREATE TABLE IF NOT EXISTS worker_resource_return_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id uuid NOT NULL,
  resource_type text NOT NULL CHECK (resource_type IN ('accommodation','vehicle','tool')),
  assignment_id uuid NOT NULL,
  file_path text,
  file_name text,
  file_size bigint,
  mime_type text,
  notes text,
  proposed_date date,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  submitted_at timestamptz DEFAULT now(),
  submitted_by_email text,
  reviewed_at timestamptz,
  reviewed_by text,
  review_notes text
);

ALTER TABLE worker_resource_return_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth users can read return requests" ON worker_resource_return_requests FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth users can write return requests" ON worker_resource_return_requests FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "anon can insert return requests" ON worker_resource_return_requests FOR INSERT TO anon WITH CHECK (true);

-- RPC to submit a return request (validates email matches worker)
CREATE OR REPLACE FUNCTION submit_resource_return(
  p_email text, p_worker_id uuid, p_resource_type text, p_assignment_id uuid,
  p_file_path text DEFAULT NULL, p_file_name text DEFAULT NULL,
  p_file_size bigint DEFAULT NULL, p_mime_type text DEFAULT NULL,
  p_notes text DEFAULT NULL, p_proposed_date date DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $func$
DECLARE v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM workers WHERE id = p_worker_id AND lower(email) = lower(p_email) AND active = true) THEN
    RAISE EXCEPTION 'Email does not match worker profile';
  END IF;
  INSERT INTO worker_resource_return_requests
    (worker_id, resource_type, assignment_id, file_path, file_name, file_size, mime_type,
     notes, proposed_date, submitted_by_email, status)
  VALUES
    (p_worker_id, p_resource_type, p_assignment_id, p_file_path, p_file_name, p_file_size,
     p_mime_type, p_notes, p_proposed_date, p_email, 'pending')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$func$;
GRANT EXECUTE ON FUNCTION submit_resource_return(text, uuid, text, uuid, text, text, bigint, text, text, date) TO anon, authenticated;

-- If table already exists, add the proposed_date column:
-- ALTER TABLE worker_resource_return_requests ADD COLUMN IF NOT EXISTS proposed_date date;
