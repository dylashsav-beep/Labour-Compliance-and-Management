-- ============================================================================
-- TMC Pending Migrations — Combined Script
-- Run ONCE in: Supabase → Database → SQL Editor
-- Safe to run on an existing database — all statements are idempotent.
-- ============================================================================


-- ── 1. Settings table — missing columns ─────────────────────────────────────

ALTER TABLE settings
  ADD COLUMN IF NOT EXISTS reject_delete_days integer NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS worker_types       jsonb   DEFAULT '[]'::jsonb;


-- ── 2. Document set items — missing columns ──────────────────────────────────

ALTER TABLE document_set_items
  ADD COLUMN IF NOT EXISTS info_text          text,
  ADD COLUMN IF NOT EXISTS info_url           text,
  ADD COLUMN IF NOT EXISTS template_file_name text,
  ADD COLUMN IF NOT EXISTS template_file_path text;


-- ── 3. Resource events table ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS resource_events (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid,
  resource_type text        NOT NULL,
  resource_id   uuid        NOT NULL,
  event_date    date        NOT NULL,
  event_type    text        NOT NULL DEFAULT 'note',
  description   text        NOT NULL,
  created_at    timestamptz DEFAULT now(),
  created_by    text        DEFAULT NULL,
  active        boolean     DEFAULT true
);

ALTER TABLE resource_events ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "read_resource_events"  ON resource_events FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "write_resource_events" ON resource_events FOR ALL    TO authenticated
    USING      (true)
    WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ── 4. Tools, tool assignments, tool charges ─────────────────────────────────

CREATE TABLE IF NOT EXISTS tools (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid,
  name          text        NOT NULL,
  description   text,
  serial_number text,
  notes         text,
  active        boolean     NOT NULL DEFAULT true,
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tool_assignments (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid,
  worker_id           uuid,
  tool_id             uuid,
  start_date          date,
  end_date            date,
  notes               text,
  charge_to_operative boolean     DEFAULT false,
  weekly_charge_amount numeric(10,2),
  issue_file_path     text,
  issue_file_name     text,
  return_file_path    text,
  return_file_name    text,
  active              boolean     NOT NULL DEFAULT true,
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tool_charges (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid,
  assignment_id  uuid,
  week_key       text        NOT NULL,
  charged        boolean     DEFAULT false,
  invoice_number text,
  invoice_amount numeric(10,2),
  charged_at     timestamptz,
  charged_by     text,
  active         boolean     NOT NULL DEFAULT true
);

-- If the tables already existed without these columns, add them now
ALTER TABLE tool_assignments
  ADD COLUMN IF NOT EXISTS issue_file_path     text,
  ADD COLUMN IF NOT EXISTS issue_file_name     text,
  ADD COLUMN IF NOT EXISTS return_file_path    text,
  ADD COLUMN IF NOT EXISTS return_file_name    text,
  ADD COLUMN IF NOT EXISTS org_id              uuid;

ALTER TABLE tools        ADD COLUMN IF NOT EXISTS org_id uuid;
ALTER TABLE tool_charges ADD COLUMN IF NOT EXISTS org_id uuid;

ALTER TABLE tools            ENABLE ROW LEVEL SECURITY;
ALTER TABLE tool_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE tool_charges     ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "read_tools"  ON tools FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "write_tools" ON tools FOR ALL    TO authenticated USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "read_tool_assignments"  ON tool_assignments FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "write_tool_assignments" ON tool_assignments FOR ALL    TO authenticated USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "read_tool_charges"  ON tool_charges FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "write_tool_charges" ON tool_charges FOR ALL    TO authenticated USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ── 5. Storage policies ───────────────────────────────────────────────────────

-- Allow anonymous workers to upload document submissions
DO $$ BEGIN
  CREATE POLICY "anon workers can upload submission files"
  ON storage.objects FOR INSERT TO anon
  WITH CHECK (
    bucket_id = 'tmc-documents'
    AND (storage.foldername(name))[1] = 'worker-submissions'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Allow all sessions to read downloadable form templates
DO $$ BEGIN
  CREATE POLICY "Anyone can read doc-templates"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'tmc-documents'
    AND (storage.foldername(name))[1] = 'doc-templates'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
