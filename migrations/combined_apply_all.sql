-- =============================================================================
-- TMC Labour Compliance — Combined migration (safe to re-run)
-- Run in: Supabase → Database → SQL Editor
-- All statements use IF NOT EXISTS / CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS
-- so this file is idempotent — running it twice causes no harm.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. TOOLS TABLES
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS tools (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL,
  description      text,
  serial_number    text,
  notes            text,
  active           boolean NOT NULL DEFAULT true,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tool_assignments (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id            uuid,
  tool_id              uuid,
  start_date           date,
  end_date             date,
  notes                text,
  charge_to_operative  boolean DEFAULT false,
  weekly_charge_amount numeric(10,2),
  active               boolean NOT NULL DEFAULT true,
  created_at           timestamptz DEFAULT now(),
  updated_at           timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tool_charges (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id   uuid,
  week_key        text NOT NULL,
  charged         boolean DEFAULT false,
  invoice_number  text,
  invoice_amount  numeric(10,2),
  charged_at      timestamptz,
  charged_by      text,
  active          boolean NOT NULL DEFAULT true
);

ALTER TABLE tools            ENABLE ROW LEVEL SECURITY;
ALTER TABLE tool_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE tool_charges     ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='tools' AND policyname='auth users can read tools') THEN
    CREATE POLICY "auth users can read tools" ON tools FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='tools' AND policyname='auth users can write tools') THEN
    CREATE POLICY "auth users can write tools" ON tools FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='tool_assignments' AND policyname='auth users can read tool_assignments') THEN
    CREATE POLICY "auth users can read tool_assignments" ON tool_assignments FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='tool_assignments' AND policyname='auth users can write tool_assignments') THEN
    CREATE POLICY "auth users can write tool_assignments" ON tool_assignments FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='tool_charges' AND policyname='auth users can read tool_charges') THEN
    CREATE POLICY "auth users can read tool_charges" ON tool_charges FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='tool_charges' AND policyname='auth users can write tool_charges') THEN
    CREATE POLICY "auth users can write tool_charges" ON tool_charges FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;


-- ---------------------------------------------------------------------------
-- 2. TOOL ASSIGNMENT PROOF FILE COLUMNS
-- ---------------------------------------------------------------------------

ALTER TABLE tool_assignments
  ADD COLUMN IF NOT EXISTS issue_file_path  text,
  ADD COLUMN IF NOT EXISTS issue_file_name  text,
  ADD COLUMN IF NOT EXISTS return_file_path text,
  ADD COLUMN IF NOT EXISTS return_file_name text;


-- ---------------------------------------------------------------------------
-- 3. WORKER RESOURCE RETURN REQUESTS TABLE + RPC
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS worker_resource_return_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id        uuid NOT NULL,
  resource_type    text NOT NULL CHECK (resource_type IN ('accommodation','vehicle','tool')),
  assignment_id    uuid NOT NULL,
  file_path        text,
  file_name        text,
  file_size        bigint,
  mime_type        text,
  notes            text,
  proposed_date    date,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  submitted_at     timestamptz DEFAULT now(),
  submitted_by_email text,
  reviewed_at      timestamptz,
  reviewed_by      text,
  review_notes     text
);

-- Add proposed_date in case the table was created by an older migration without it
ALTER TABLE worker_resource_return_requests
  ADD COLUMN IF NOT EXISTS proposed_date date;

ALTER TABLE worker_resource_return_requests ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='worker_resource_return_requests' AND policyname='auth users can read return requests') THEN
    CREATE POLICY "auth users can read return requests" ON worker_resource_return_requests FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='worker_resource_return_requests' AND policyname='auth users can write return requests') THEN
    CREATE POLICY "auth users can write return requests" ON worker_resource_return_requests FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='worker_resource_return_requests' AND policyname='anon can insert return requests') THEN
    CREATE POLICY "anon can insert return requests" ON worker_resource_return_requests FOR INSERT TO anon WITH CHECK (true);
  END IF;
END $$;

-- RPC: workers submit a return request (validates email matches worker)
CREATE OR REPLACE FUNCTION submit_resource_return(
  p_email         text,
  p_worker_id     uuid,
  p_resource_type text,
  p_assignment_id uuid,
  p_file_path     text    DEFAULT NULL,
  p_file_name     text    DEFAULT NULL,
  p_file_size     bigint  DEFAULT NULL,
  p_mime_type     text    DEFAULT NULL,
  p_notes         text    DEFAULT NULL,
  p_proposed_date date    DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $func$
DECLARE v_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM workers
    WHERE id = p_worker_id AND lower(email) = lower(p_email) AND active = true
  ) THEN
    RAISE EXCEPTION 'Email does not match worker profile';
  END IF;

  INSERT INTO worker_resource_return_requests
    (worker_id, resource_type, assignment_id, file_path, file_name, file_size,
     mime_type, notes, proposed_date, submitted_by_email, status)
  VALUES
    (p_worker_id, p_resource_type, p_assignment_id, p_file_path, p_file_name, p_file_size,
     p_mime_type, p_notes, p_proposed_date, p_email, 'pending')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$func$;

GRANT EXECUTE ON FUNCTION submit_resource_return(text, uuid, text, uuid, text, text, bigint, text, text, date)
  TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. UPDATE get_worker_portal RPC TO INCLUDE RESOURCE ASSIGNMENTS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_worker_portal(p_email text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $func$
DECLARE v_worker workers%ROWTYPE;
BEGIN
  SELECT * INTO v_worker
  FROM workers
  WHERE lower(email) = lower(p_email) AND active = true
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

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


-- ---------------------------------------------------------------------------
-- 5. WORKER PHONE NUMBER COLUMN
-- ---------------------------------------------------------------------------

ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS phone text;


-- ---------------------------------------------------------------------------
-- 6. DOCUMENT SET ITEM INFO FIELDS
-- ---------------------------------------------------------------------------

ALTER TABLE document_set_items
  ADD COLUMN IF NOT EXISTS info_text text,
  ADD COLUMN IF NOT EXISTS info_url  text;


-- ---------------------------------------------------------------------------
-- 7. STORAGE POLICY — ALLOW ANON WORKERS TO UPLOAD PROOF FILES
-- ---------------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects'
      AND schemaname = 'storage'
      AND policyname = 'anon workers can upload submission files'
  ) THEN
    CREATE POLICY "anon workers can upload submission files"
    ON storage.objects FOR INSERT TO anon
    WITH CHECK (
      bucket_id = 'tmc-documents'
      AND (storage.foldername(name))[1] = 'worker-submissions'
    );
  END IF;
END $$;
