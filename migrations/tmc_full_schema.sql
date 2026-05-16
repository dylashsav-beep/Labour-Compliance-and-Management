-- ============================================================================
-- TM Construction Compliance — Full Schema Migration
-- ============================================================================
-- Safe to run on a FRESH or EXISTING Supabase database.
-- Every statement uses IF NOT EXISTS / IF EXISTS guards so it is idempotent.
--
-- How to run:
--   1. Open your Supabase project → Database → SQL Editor → New query
--   2. Paste the entire contents of this file
--   3. Click Run
--
-- This script:
--   • Creates all required tables if they do not already exist
--   • Adds any columns that were introduced after the initial setup
--     (safe — does nothing if the column is already present)
--   • Enables Row Level Security on every table
--   • Creates RLS policies for the four app roles:
--       admin      — full read/write on everything
--       planner    — read workers/projects/assignments; write assignments/roster
--       compliance — read/write workers, documents, document sets, settings
--       viewer     — read-only on workers/projects/assignments
--   • Creates the profiles table and its trigger (auto-creates a profile row
--     for every new Supabase Auth user)
-- ============================================================================


-- ────────────────────────────────────────────────────────────────────────────
-- 0. EXTENSIONS
-- ────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- ────────────────────────────────────────────────────────────────────────────
-- 1. PROFILES  (auth users → app roles)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
  id           UUID PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  email        TEXT,
  full_name    TEXT        DEFAULT '',
  role         TEXT        NOT NULL DEFAULT 'viewer'
                           CHECK (role IN ('admin','planner','compliance','viewer','no_access')),
  active       BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Auto-create a profile row whenever a new auth user signs up
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email, full_name, role, active, created_at, updated_at)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)),
    'viewer',
    TRUE,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- ────────────────────────────────────────────────────────────────────────────
-- 2. SETTINGS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS settings (
  id                      TEXT PRIMARY KEY DEFAULT 'main',
  warning_days            INTEGER     NOT NULL DEFAULT 60,
  compliance_report_email TEXT        NOT NULL DEFAULT 'compliance@tmconstruction.nl',
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed the single settings row if absent
INSERT INTO settings (id, warning_days, compliance_report_email, updated_at)
VALUES ('main', 60, 'compliance@tmconstruction.nl', NOW())
ON CONFLICT (id) DO NOTHING;


-- ────────────────────────────────────────────────────────────────────────────
-- 3. DOCUMENT SETS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS document_sets (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name        TEXT        NOT NULL,
  description TEXT        NOT NULL DEFAULT '',
  country     TEXT        NOT NULL DEFAULT '',
  built_in    BOOLEAN     NOT NULL DEFAULT FALSE,
  active      BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS document_set_items (
  id                TEXT PRIMARY KEY, -- format: {set_id}__{doc_key}
  document_set_id   UUID        NOT NULL REFERENCES document_sets ON DELETE CASCADE,
  doc_key           TEXT        NOT NULL,
  name              TEXT        NOT NULL,
  category          TEXT        NOT NULL DEFAULT '',
  icon              TEXT        NOT NULL DEFAULT '',
  tip               TEXT        NOT NULL DEFAULT '',
  required          BOOLEAN     NOT NULL DEFAULT FALSE,
  built_in          BOOLEAN     NOT NULL DEFAULT FALSE,
  archived          BOOLEAN     NOT NULL DEFAULT FALSE,
  archived_at       TIMESTAMPTZ,
  sort_order        INTEGER     NOT NULL DEFAULT 0,
  active            BOOLEAN     NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_doc_set_items_set ON document_set_items(document_set_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 4. WORKERS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workers (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name         TEXT        NOT NULL,
  worker_type       TEXT        NOT NULL DEFAULT 'blue'
                                CHECK (worker_type IN ('zzp','blue')),
  reference         TEXT        NOT NULL DEFAULT '',
  nationality       TEXT        NOT NULL DEFAULT '',
  document_set_id   UUID        REFERENCES document_sets ON DELETE SET NULL,
  doc_req           JSONB                DEFAULT NULL,
  active            BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Add doc_req if it was not present in an earlier version of the schema
ALTER TABLE workers ADD COLUMN IF NOT EXISTS doc_req JSONB DEFAULT NULL;

COMMENT ON COLUMN workers.doc_req IS
  'Per-worker document requirement overrides. '
  'Map of doc_key → boolean: true = required for this worker even if the '
  'document set says optional; false = not required even if the document set '
  'says required; null/absent key = use document set default.';


-- ────────────────────────────────────────────────────────────────────────────
-- 5. WORKER DOCUMENTS  (compliance status per worker per doc)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS worker_documents (
  id           TEXT PRIMARY KEY, -- format: {worker_id}__{doc_key}
  worker_id    UUID        NOT NULL REFERENCES workers ON DELETE CASCADE,
  doc_key      TEXT        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'missing'
                           CHECK (status IN ('ok','expiring','missing')),
  issue_date   DATE,
  expiry_date  DATE,
  active       BOOLEAN     NOT NULL DEFAULT TRUE,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_worker_docs_worker ON worker_documents(worker_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 6. WORKER DOCUMENT FILES  (uploaded files attached to a worker document)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS worker_document_files (
  id                   TEXT PRIMARY KEY,
  worker_document_id   TEXT        NOT NULL REFERENCES worker_documents ON DELETE CASCADE,
  worker_id            UUID        NOT NULL REFERENCES workers ON DELETE CASCADE,
  file_name            TEXT        NOT NULL,
  file_path            TEXT        NOT NULL,
  mime_type            TEXT        NOT NULL DEFAULT '',
  size_bytes           BIGINT      NOT NULL DEFAULT 0,
  active               BOOLEAN     NOT NULL DEFAULT TRUE,
  uploaded_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_worker_doc_files_doc   ON worker_document_files(worker_document_id);
CREATE INDEX IF NOT EXISTS idx_worker_doc_files_worker ON worker_document_files(worker_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 7. PROJECTS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS projects (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name        TEXT        NOT NULL,
  description TEXT        NOT NULL DEFAULT '',
  active      BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ────────────────────────────────────────────────────────────────────────────
-- 8. PROJECT ASSIGNMENTS  (worker ↔ project contracts)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS project_assignments (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  worker_id   UUID        NOT NULL REFERENCES workers ON DELETE CASCADE,
  project_id  UUID        NOT NULL REFERENCES projects ON DELETE CASCADE,
  start_date  DATE,
  end_date    DATE,
  rate        NUMERIC(10,2),
  rate_type   TEXT        NOT NULL DEFAULT 'day'
                          CHECK (rate_type IN ('day','hour','week','fixed')),
  notes       TEXT        NOT NULL DEFAULT '',
  active      BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_proj_assign_worker  ON project_assignments(worker_id);
CREATE INDEX IF NOT EXISTS idx_proj_assign_project ON project_assignments(project_id);

CREATE TABLE IF NOT EXISTS project_assignment_files (
  id                      TEXT PRIMARY KEY, -- format: {assignment_id}__contract
  project_assignment_id   UUID        NOT NULL REFERENCES project_assignments ON DELETE CASCADE,
  file_name               TEXT        NOT NULL,
  file_path               TEXT        NOT NULL,
  mime_type               TEXT        NOT NULL DEFAULT '',
  size_bytes              BIGINT      NOT NULL DEFAULT 0,
  active                  BOOLEAN     NOT NULL DEFAULT TRUE,
  uploaded_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ────────────────────────────────────────────────────────────────────────────
-- 9. ROSTER WEEK ALLOCATIONS  (project name per worker per week)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS roster_week_allocations (
  id           TEXT PRIMARY KEY, -- format: {week_key}__{worker_id}__{index}
  week_key     TEXT        NOT NULL,
  worker_id    UUID        NOT NULL REFERENCES workers ON DELETE CASCADE,
  project_name TEXT        NOT NULL,
  active       BOOLEAN     NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_roster_worker   ON roster_week_allocations(worker_id);
CREATE INDEX IF NOT EXISTS idx_roster_week_key ON roster_week_allocations(week_key);


-- ────────────────────────────────────────────────────────────────────────────
-- 10. PROPERTIES  (accommodation locations)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS properties (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name       TEXT        NOT NULL,
  address    TEXT        NOT NULL DEFAULT '',
  notes      TEXT        NOT NULL DEFAULT '',
  active     BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ────────────────────────────────────────────────────────────────────────────
-- 11. VEHICLES
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vehicles (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  description        TEXT        NOT NULL,
  registration_plate TEXT        NOT NULL DEFAULT '',
  make               TEXT        NOT NULL DEFAULT '',
  model              TEXT        NOT NULL DEFAULT '',
  colour             TEXT        NOT NULL DEFAULT '',
  notes              TEXT        NOT NULL DEFAULT '',
  active             BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ────────────────────────────────────────────────────────────────────────────
-- 12. ACCOMMODATION ASSIGNMENTS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS accommodation_assignments (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  worker_id   UUID        NOT NULL REFERENCES workers ON DELETE CASCADE,
  property_id UUID        NOT NULL REFERENCES properties ON DELETE CASCADE,
  start_date  DATE,
  end_date    DATE,
  notes       TEXT        NOT NULL DEFAULT '',
  active      BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_accom_assign_worker   ON accommodation_assignments(worker_id);
CREATE INDEX IF NOT EXISTS idx_accom_assign_property ON accommodation_assignments(property_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 13. VEHICLE ASSIGNMENTS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vehicle_assignments (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  worker_id   UUID        NOT NULL REFERENCES workers ON DELETE CASCADE,
  vehicle_id  UUID        NOT NULL REFERENCES vehicles ON DELETE CASCADE,
  start_date  DATE,
  end_date    DATE,
  notes       TEXT        NOT NULL DEFAULT '',
  active      BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_veh_assign_worker  ON vehicle_assignments(worker_id);
CREATE INDEX IF NOT EXISTS idx_veh_assign_vehicle ON vehicle_assignments(vehicle_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 14. DELETED ITEMS  (recycle bin / audit trail)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS deleted_items (
  id               TEXT PRIMARY KEY,
  item_type        TEXT        NOT NULL,
  label            TEXT        NOT NULL DEFAULT '',
  payload          JSONB       NOT NULL DEFAULT '{}',
  details          JSONB       NOT NULL DEFAULT '{}',
  deleted_by_email TEXT        NOT NULL DEFAULT '',
  deleted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  restored         BOOLEAN     NOT NULL DEFAULT FALSE
);


-- ────────────────────────────────────────────────────────────────────────────
-- 15. ROW LEVEL SECURITY
-- ────────────────────────────────────────────────────────────────────────────
-- Enable RLS on every table
ALTER TABLE profiles                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE settings                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_sets             ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_set_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE workers                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE worker_documents          ENABLE ROW LEVEL SECURITY;
ALTER TABLE worker_document_files     ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_assignments       ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_assignment_files  ENABLE ROW LEVEL SECURITY;
ALTER TABLE roster_week_allocations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE properties                ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE accommodation_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_assignments       ENABLE ROW LEVEL SECURITY;
ALTER TABLE deleted_items             ENABLE ROW LEVEL SECURITY;

-- Role lookup shorthand (used inline in all write policies below)
-- Reads the calling user's own profile row — always allowed by the SELECT policy.
-- No helper function needed: direct subquery avoids SECURITY DEFINER auth.uid() issues.
-- $role_c = admin or compliance  /  $role_p = admin or planner

-- ── Drop existing policies before recreating (idempotent) ─────────────────
DO $drop$ DECLARE r RECORD; BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname
    FROM   pg_policies
    WHERE  schemaname = 'public'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I',
                   r.policyname, r.schemaname, r.tablename);
  END LOOP;
END $drop$;

-- Inline role expression used in all write policies:
--   (SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1)
-- This reads the calling user's own profile row, which is always allowed by
-- the profiles SELECT policy (id = auth.uid()). No helper function needed.

-- ── profiles ───────────────────────────────────────────────────────────────
CREATE POLICY profiles_select ON profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid() OR (SELECT role FROM profiles p WHERE p.id = auth.uid() AND p.active = TRUE LIMIT 1) = 'admin');

CREATE POLICY profiles_insert ON profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid() OR (SELECT role FROM profiles p WHERE p.id = auth.uid() AND p.active = TRUE LIMIT 1) = 'admin');

CREATE POLICY profiles_update ON profiles
  FOR UPDATE TO authenticated
  USING      (id = auth.uid() OR (SELECT role FROM profiles p WHERE p.id = auth.uid() AND p.active = TRUE LIMIT 1) = 'admin')
  WITH CHECK (id = auth.uid() OR (SELECT role FROM profiles p WHERE p.id = auth.uid() AND p.active = TRUE LIMIT 1) = 'admin');

-- ── settings ──────────────────────────────────────────────────────────────
CREATE POLICY settings_select ON settings FOR SELECT TO authenticated USING (true);
CREATE POLICY settings_write ON settings
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── document_sets ─────────────────────────────────────────────────────────
CREATE POLICY doc_sets_select ON document_sets FOR SELECT TO authenticated USING (true);
CREATE POLICY doc_sets_write ON document_sets
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── document_set_items ────────────────────────────────────────────────────
CREATE POLICY doc_set_items_select ON document_set_items FOR SELECT TO authenticated USING (true);
CREATE POLICY doc_set_items_write ON document_set_items
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── workers ───────────────────────────────────────────────────────────────
CREATE POLICY workers_select ON workers FOR SELECT TO authenticated USING (true);
CREATE POLICY workers_write ON workers
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── worker_documents ──────────────────────────────────────────────────────
CREATE POLICY worker_docs_select ON worker_documents FOR SELECT TO authenticated USING (true);
CREATE POLICY worker_docs_write ON worker_documents
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── worker_document_files ─────────────────────────────────────────────────
CREATE POLICY worker_doc_files_select ON worker_document_files FOR SELECT TO authenticated USING (true);
CREATE POLICY worker_doc_files_write ON worker_document_files
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── projects ──────────────────────────────────────────────────────────────
CREATE POLICY projects_select ON projects FOR SELECT TO authenticated USING (true);
CREATE POLICY projects_write ON projects
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── project_assignments ───────────────────────────────────────────────────
CREATE POLICY proj_assign_select ON project_assignments FOR SELECT TO authenticated USING (true);
CREATE POLICY proj_assign_write ON project_assignments
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── project_assignment_files ──────────────────────────────────────────────
CREATE POLICY proj_assign_files_select ON project_assignment_files FOR SELECT TO authenticated USING (true);
CREATE POLICY proj_assign_files_write ON project_assignment_files
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── roster_week_allocations ───────────────────────────────────────────────
CREATE POLICY roster_select ON roster_week_allocations FOR SELECT TO authenticated USING (true);
CREATE POLICY roster_write ON roster_week_allocations
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── properties ────────────────────────────────────────────────────────────
CREATE POLICY properties_select ON properties FOR SELECT TO authenticated USING (true);
CREATE POLICY properties_write ON properties
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── vehicles ──────────────────────────────────────────────────────────────
CREATE POLICY vehicles_select ON vehicles FOR SELECT TO authenticated USING (true);
CREATE POLICY vehicles_write ON vehicles
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── accommodation_assignments ─────────────────────────────────────────────
CREATE POLICY accom_assign_select ON accommodation_assignments FOR SELECT TO authenticated USING (true);
CREATE POLICY accom_assign_write ON accommodation_assignments
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── vehicle_assignments ───────────────────────────────────────────────────
CREATE POLICY veh_assign_select ON vehicle_assignments FOR SELECT TO authenticated USING (true);
CREATE POLICY veh_assign_write ON vehicle_assignments
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── deleted_items (role check on reads too) ───────────────────────────────
CREATE POLICY deleted_items_select ON deleted_items
  FOR SELECT TO authenticated
  USING ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

CREATE POLICY deleted_items_write ON deleted_items
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));



-- ────────────────────────────────────────────────────────────────────────────
-- 16. STORAGE BUCKET  (uploaded compliance documents)
-- ────────────────────────────────────────────────────────────────────────────
-- Run this in the Supabase Dashboard → Storage → New bucket if not already done:
--   Name:   tmc-documents
--   Public: false
--   File size limit: 20 MB
--   Allowed MIME types: application/pdf, image/jpeg, image/png,
--                       application/msword,
--                       application/vnd.openxmlformats-officedocument.wordprocessingml.document
--
-- Then add these Storage policies in Dashboard → Storage → Policies:
--   SELECT (download): authenticated users whose profile role IN ('admin','planner','compliance','viewer')
--   INSERT (upload):   authenticated users whose profile role IN ('admin','compliance')
--   DELETE:            authenticated users whose profile role = 'admin'
--
-- (Storage bucket policies cannot be created via SQL in all Supabase tiers;
--  use the Dashboard UI if the INSERT below is not available on your plan.)

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'tmc-documents',
  'tmc-documents',
  FALSE,
  20971520, -- 20 MB
  ARRAY[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO NOTHING;
