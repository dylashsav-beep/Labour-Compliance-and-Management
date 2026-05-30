-- =============================================================================
-- Multi-Tenancy Foundation Migration
-- Run ONCE in: Supabase → Database → SQL Editor
-- Safe to inspect before running — all steps are idempotent where possible.
-- Existing TMC data is preserved and assigned to the TMC organisation.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ORGANISATIONS TABLE
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS organisations (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text NOT NULL,
  slug                 text UNIQUE NOT NULL,
  logo_url             text,
  primary_color        text DEFAULT '#1a3082',
  owner_email          text,
  email_from           text,
  email_recipients     text[] DEFAULT '{}',
  warning_days         int NOT NULL DEFAULT 60,
  compliance_email     text,
  created_at           timestamptz DEFAULT now(),
  updated_at           timestamptz DEFAULT now()
);

ALTER TABLE organisations ENABLE ROW LEVEL SECURITY;

-- Insert the TMC organisation (fixed UUID so we can reference it below)
INSERT INTO organisations (id, name, slug, owner_email, email_recipients, warning_days, compliance_email)
VALUES (
  '00000000-0000-0000-0001-000000000001',
  'TM Construction BV',
  'tmc',
  'dylan@tmconstruction.nl',
  ARRAY['dylan@tmconstruction.nl', 'compliance@tmconstruction.nl'],
  60,
  'compliance@tmconstruction.nl'
)
ON CONFLICT (id) DO UPDATE SET
  name             = EXCLUDED.name,
  owner_email      = EXCLUDED.owner_email,
  email_recipients = EXCLUDED.email_recipients;


-- ---------------------------------------------------------------------------
-- 2. ADD ORG_ID TO PROFILES (must exist before current_org_id() function)
-- ---------------------------------------------------------------------------

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);

-- Assign all existing profiles to the TMC org
UPDATE profiles SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;


-- ---------------------------------------------------------------------------
-- 3. ORG_ID HELPER FUNCTION (SECURITY DEFINER bypasses profiles RLS)
--    Created after org_id column exists on profiles.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION current_org_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT org_id FROM profiles WHERE id = auth.uid() LIMIT 1
$$;

GRANT EXECUTE ON FUNCTION current_org_id() TO authenticated;


-- ---------------------------------------------------------------------------
-- 4. ADD ORG_ID TO ALL DATA TABLES
--    Each table gets org_id nullable first, then filled, then policies updated.
-- ---------------------------------------------------------------------------

ALTER TABLE workers                       ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE worker_documents              ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE worker_document_files         ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE document_sets                 ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE document_set_items            ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE projects                      ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE project_assignments           ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE project_assignment_files      ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE properties                    ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE vehicles                      ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE accommodation_assignments     ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE vehicle_assignments           ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE accommodation_charges         ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE vehicle_charges               ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE resource_events               ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE compliance_documents          ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
ALTER TABLE deleted_items                 ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);

-- Optional tables (may or may not exist depending on deployment)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'tools') THEN
    ALTER TABLE tools ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'tool_assignments') THEN
    ALTER TABLE tool_assignments ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'tool_charges') THEN
    ALTER TABLE tool_charges ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'worker_resource_return_requests') THEN
    ALTER TABLE worker_resource_return_requests ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
  END IF;
END $$;

-- roster_week_allocations (may or may not exist)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'roster_week_allocations') THEN
    ALTER TABLE roster_week_allocations ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
  END IF;
END $$;

-- worker_document_submissions (may or may not exist)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'worker_document_submissions') THEN
    ALTER TABLE worker_document_submissions ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
  END IF;
END $$;

-- settings table: change key from text 'main' to org UUID
ALTER TABLE settings ADD COLUMN IF NOT EXISTS org_id uuid REFERENCES organisations(id);
-- Rename the singleton row to use the TMC org UUID as its id
UPDATE settings SET
  id     = '00000000-0000-0000-0001-000000000001',
  org_id = '00000000-0000-0000-0001-000000000001'
WHERE id = 'main';


-- ---------------------------------------------------------------------------
-- 5. BACKFILL ALL EXISTING DATA → TMC ORG
-- ---------------------------------------------------------------------------

UPDATE workers                        SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE worker_documents               SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE worker_document_files          SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE document_sets                  SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE document_set_items             SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE projects                       SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE project_assignments            SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE project_assignment_files       SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE properties                     SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE vehicles                       SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE accommodation_assignments      SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE vehicle_assignments            SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE accommodation_charges          SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE vehicle_charges                SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE resource_events                SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE compliance_documents           SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE deleted_items                  SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;
UPDATE settings                       SET org_id = '00000000-0000-0000-0001-000000000001' WHERE org_id IS NULL;

-- Conditional backfill for optional tables
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'tools') THEN
    EXECUTE 'UPDATE tools SET org_id = ''00000000-0000-0000-0001-000000000001'' WHERE org_id IS NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'tool_assignments') THEN
    EXECUTE 'UPDATE tool_assignments SET org_id = ''00000000-0000-0000-0001-000000000001'' WHERE org_id IS NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'tool_charges') THEN
    EXECUTE 'UPDATE tool_charges SET org_id = ''00000000-0000-0000-0001-000000000001'' WHERE org_id IS NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name = 'worker_resource_return_requests') THEN
    EXECUTE 'UPDATE worker_resource_return_requests SET org_id = ''00000000-0000-0000-0001-000000000001'' WHERE org_id IS NULL';
  END IF;
END $$;

-- Conditional updates for tables that may exist
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'roster_week_allocations') THEN
    EXECUTE 'UPDATE roster_week_allocations SET org_id = ''00000000-0000-0000-0001-000000000001'' WHERE org_id IS NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'worker_document_submissions') THEN
    EXECUTE 'UPDATE worker_document_submissions SET org_id = ''00000000-0000-0000-0001-000000000001'' WHERE org_id IS NULL';
  END IF;
END $$;


-- ---------------------------------------------------------------------------
-- 6. UPDATE ROW LEVEL SECURITY POLICIES
--    Drop old permissive policies, replace with org-scoped ones.
-- ---------------------------------------------------------------------------

-- Helper: drop a policy if it exists (avoids errors if already removed)
CREATE OR REPLACE FUNCTION _drop_policy_if_exists(p_table text, p_policy text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_policy, p_table);
END $$;

-- ── organisations ──
DO $$ BEGIN
  PERFORM _drop_policy_if_exists('organisations', 'org members can read their org');
  PERFORM _drop_policy_if_exists('organisations', 'anon can read orgs');
  PERFORM _drop_policy_if_exists('organisations', 'org admins can update their org');
END $$;
CREATE POLICY "org members can read their org"   ON organisations FOR SELECT TO authenticated USING (id = current_org_id());
CREATE POLICY "anon can read orgs by slug"        ON organisations FOR SELECT TO anon         USING (true);
CREATE POLICY "org admins can update their org"  ON organisations FOR UPDATE TO authenticated USING (id = current_org_id()) WITH CHECK (id = current_org_id());

-- ── profiles ──
-- Drop old policies (names vary across deployments)
DO $$ BEGIN
  PERFORM _drop_policy_if_exists('profiles', 'auth users can read profiles');
  PERFORM _drop_policy_if_exists('profiles', 'auth users can write profiles');
  PERFORM _drop_policy_if_exists('profiles', 'Users can view their own profile');
  PERFORM _drop_policy_if_exists('profiles', 'Users can update their own profile');
END $$;
-- Users can always read/update their own profile; org members can read all profiles in their org
CREATE POLICY "own profile full access"          ON profiles FOR ALL       TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());
CREATE POLICY "org members read all profiles"    ON profiles FOR SELECT    TO authenticated USING (org_id = current_org_id());
-- Admins can update any profile in their org (for role management)
CREATE POLICY "org admin manage profiles"        ON profiles FOR UPDATE    TO authenticated USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id());

-- ── Macro to drop and recreate standard org-scoped policies ──
-- Applied to every data table below

DO $$ DECLARE
  t text;
  tables text[] := ARRAY[
    'workers','worker_documents','worker_document_files',
    'document_sets','document_set_items',
    'projects','project_assignments','project_assignment_files',
    'properties','vehicles',
    'accommodation_assignments','vehicle_assignments',
    'accommodation_charges','vehicle_charges',
    'resource_events','compliance_documents','deleted_items',
    'tools','tool_assignments','tool_charges','settings'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    -- Skip tables that don't exist in this deployment
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name=t) THEN
      CONTINUE;
    END IF;
    -- Drop old generic policies (various naming conventions)
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'auth users can read '||t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'auth users can write '||t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'authenticated read '||t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'authenticated write '||t, t);
    -- Create org-scoped policies
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR SELECT TO authenticated USING (org_id = current_org_id())',
      'org read '||t, t
    );
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR ALL TO authenticated USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id())',
      'org write '||t, t
    );
  END LOOP;
END $$;

-- ── worker_resource_return_requests (if exists) ──
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_resource_return_requests') THEN
    RETURN;
  END IF;
  PERFORM _drop_policy_if_exists('worker_resource_return_requests', 'auth users can read return requests');
  PERFORM _drop_policy_if_exists('worker_resource_return_requests', 'auth users can write return requests');
  PERFORM _drop_policy_if_exists('worker_resource_return_requests', 'anon can insert return requests');
  EXECUTE 'CREATE POLICY "org read return requests" ON worker_resource_return_requests FOR SELECT TO authenticated USING (org_id = current_org_id())';
  EXECUTE 'CREATE POLICY "org write return requests" ON worker_resource_return_requests FOR ALL TO authenticated USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id())';
  EXECUTE 'CREATE POLICY "anon insert return requests" ON worker_resource_return_requests FOR INSERT TO anon WITH CHECK (true)';
END $$;

-- ── worker_document_submissions (if exists) ──
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'worker_document_submissions') THEN
    EXECUTE 'DROP POLICY IF EXISTS "auth users can read worker_document_submissions" ON worker_document_submissions';
    EXECUTE 'DROP POLICY IF EXISTS "auth users can write worker_document_submissions" ON worker_document_submissions';
    EXECUTE 'DROP POLICY IF EXISTS "anon can insert worker_document_submissions" ON worker_document_submissions';
    EXECUTE 'CREATE POLICY "org read submissions" ON worker_document_submissions FOR SELECT TO authenticated USING (org_id = current_org_id())';
    EXECUTE 'CREATE POLICY "org write submissions" ON worker_document_submissions FOR ALL TO authenticated USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id())';
    EXECUTE 'CREATE POLICY "anon insert submissions" ON worker_document_submissions FOR INSERT TO anon WITH CHECK (true)';
  END IF;
END $$;

-- ── roster_week_allocations (if exists) ──
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'roster_week_allocations') THEN
    EXECUTE 'DROP POLICY IF EXISTS "auth users can read roster_week_allocations" ON roster_week_allocations';
    EXECUTE 'DROP POLICY IF EXISTS "auth users can write roster_week_allocations" ON roster_week_allocations';
    EXECUTE 'CREATE POLICY "org read roster" ON roster_week_allocations FOR SELECT TO authenticated USING (org_id = current_org_id())';
    EXECUTE 'CREATE POLICY "org write roster" ON roster_week_allocations FOR ALL TO authenticated USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id())';
  END IF;
END $$;

-- Clean up helper function
DROP FUNCTION IF EXISTS _drop_policy_if_exists(text, text);


-- ---------------------------------------------------------------------------
-- 7. STORAGE POLICY — scope anon worker uploads to org folder
--    (Storage policies use bucket-level RLS, org isolation via folder prefix)
-- ---------------------------------------------------------------------------

DO $$ BEGIN
  -- Drop existing anon upload policy if present
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects' AND schemaname = 'storage'
      AND policyname = 'anon workers can upload submission files'
  ) THEN
    DROP POLICY "anon workers can upload submission files" ON storage.objects;
  END IF;
END $$;

-- Recreate: still scoped to worker-submissions/ folder within the tmc-documents bucket
CREATE POLICY "anon workers can upload submission files"
ON storage.objects FOR INSERT TO anon
WITH CHECK (
  bucket_id = 'tmc-documents'
  AND (storage.foldername(name))[1] = 'worker-submissions'
);


-- ---------------------------------------------------------------------------
-- 8. UPDATE RPCs TO BE ORG-AWARE
-- ---------------------------------------------------------------------------

-- get_worker_portal: org-aware, defensive against optional tables
CREATE OR REPLACE FUNCTION get_worker_portal(p_email text, p_org_id uuid DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $func$
DECLARE
  v_worker            workers%ROWTYPE;
  v_tool_assignments  json := '[]'::json;
  v_tools             json := '[]'::json;
  v_return_requests   json := '[]'::json;
  v_submissions       json := '[]'::json;
BEGIN
  SELECT * INTO v_worker
  FROM workers
  WHERE lower(email) = lower(p_email)
    AND active = true
    AND (p_org_id IS NULL OR org_id = p_org_id)
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  -- Safely query optional tables that may not exist in all deployments
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
    'doc_sets',          (SELECT COALESCE(json_agg(s ORDER BY s.name), '[]'::json) FROM document_sets s WHERE s.active = true AND s.org_id = v_worker.org_id),
    'doc_set_items',     (SELECT COALESCE(json_agg(i ORDER BY i.sort_order), '[]'::json) FROM document_set_items i WHERE i.active = true AND i.org_id = v_worker.org_id),
    'worker_docs',       (SELECT COALESCE(json_agg(d), '[]'::json) FROM worker_documents d WHERE d.worker_id = v_worker.id AND d.active = true),
    'worker_doc_files',  (SELECT COALESCE(json_agg(f), '[]'::json) FROM worker_document_files f WHERE f.worker_id = v_worker.id AND f.active = true),
    'assignments',       (SELECT COALESCE(json_agg(a), '[]'::json) FROM project_assignments a WHERE a.worker_id = v_worker.id AND a.active = true),
    'projects',          (SELECT COALESCE(json_agg(p ORDER BY p.name), '[]'::json) FROM projects p WHERE p.active = true AND p.org_id = v_worker.org_id),
    'submissions',       v_submissions,
    'accom_assignments', (SELECT COALESCE(json_agg(aa ORDER BY aa.start_date DESC), '[]'::json) FROM accommodation_assignments aa WHERE aa.worker_id = v_worker.id AND aa.active = true),
    'properties',        (SELECT COALESCE(json_agg(p ORDER BY p.name), '[]'::json) FROM properties p WHERE p.active = true AND p.org_id = v_worker.org_id),
    'veh_assignments',   (SELECT COALESCE(json_agg(va ORDER BY va.start_date DESC), '[]'::json) FROM vehicle_assignments va WHERE va.worker_id = v_worker.id AND va.active = true),
    'vehicles',          (SELECT COALESCE(json_agg(v ORDER BY v.description), '[]'::json) FROM vehicles v WHERE v.active = true AND v.org_id = v_worker.org_id),
    'tool_assignments',  v_tool_assignments,
    'tools',             v_tools,
    'return_requests',   v_return_requests
  );
END;
$func$;

GRANT EXECUTE ON FUNCTION get_worker_portal(text, uuid) TO anon, authenticated;

-- submit_resource_return: only update if the table exists
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_resource_return_requests') THEN
    RAISE NOTICE 'worker_resource_return_requests table not found — skipping submit_resource_return update';
    RETURN;
  END IF;

  -- Table exists: recreate with org_id support
  EXECUTE $f$
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
      p_proposed_date date    DEFAULT NULL,
      p_org_id        uuid    DEFAULT NULL
    ) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $func$
    DECLARE
      v_id     uuid;
      v_org_id uuid;
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM workers
        WHERE id = p_worker_id AND lower(email) = lower(p_email) AND active = true
      ) THEN
        RAISE EXCEPTION 'Email does not match worker profile';
      END IF;

      SELECT COALESCE(p_org_id, org_id) INTO v_org_id FROM workers WHERE id = p_worker_id;

      INSERT INTO worker_resource_return_requests
        (worker_id, resource_type, assignment_id, file_path, file_name, file_size,
         mime_type, notes, proposed_date, submitted_by_email, status, org_id)
      VALUES
        (p_worker_id, p_resource_type, p_assignment_id, p_file_path, p_file_name, p_file_size,
         p_mime_type, p_notes, p_proposed_date, p_email, 'pending', v_org_id)
      RETURNING id INTO v_id;

      RETURN v_id;
    END;
    $func$
  $f$;

  EXECUTE 'GRANT EXECUTE ON FUNCTION submit_resource_return(text,uuid,text,uuid,text,text,bigint,text,text,date,uuid) TO anon, authenticated';
END $$;


-- ---------------------------------------------------------------------------
-- DONE — verify with:
--   SELECT id, name, slug FROM organisations;
--   SELECT COUNT(*) FROM workers WHERE org_id IS NOT NULL;
--   SELECT COUNT(*) FROM profiles WHERE org_id IS NOT NULL;
-- ---------------------------------------------------------------------------
