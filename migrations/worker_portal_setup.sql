-- =============================================================================
-- ⛔ DO NOT RUN — SUPERSEDED; CREATES POLICIES THAT CAUSE CROSS-ORG DATA LEAKS
-- =============================================================================
-- This file creates `workers_staff` and `workers_own` policies on the workers
-- table. These are the EXACT legacy policies (auth_only, workers_staff,
-- workers_own) that caused the catastrophic cross-org data leak documented in
-- CLAUDE.md Lesson #13. Running this file would re-introduce those policies.
--
-- It also creates worker_document_submissions WITHOUT an org_id column and with
-- non-org-scoped RLS policies.
--
-- The correct state is applied by:
--   - fix_rls_rebuild_all_policies.sql  (workers RLS, submissions RLS)
--   - add_multi_tenancy.sql             (org_id column on all tables)
-- =============================================================================

-- Worker self-service portal setup
-- Run in Supabase → Database → SQL Editor
-- NOTE: This supersedes add_worker_email.sql — no need to run that separately.

-- Step 1: Add email column to workers (safe to run even if already exists)
ALTER TABLE workers ADD COLUMN IF NOT EXISTS email text;

-- Step 2: Submissions table: worker-submitted doc updates awaiting admin review
CREATE TABLE IF NOT EXISTS worker_document_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id uuid NOT NULL REFERENCES workers(id),
  doc_key text NOT NULL,
  submitted_at timestamptz DEFAULT now() NOT NULL,
  submitted_by_email text,
  expiry_date date,
  issue_date date,
  notes text,
  file_name text,
  file_path text,
  file_size bigint,
  mime_type text,
  status text DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  reviewed_at timestamptz,
  reviewed_by text,
  review_notes text,
  active boolean DEFAULT true NOT NULL
);

-- RLS on submissions: staff see all, workers see/write their own
ALTER TABLE worker_document_submissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "subs_staff" ON worker_document_submissions FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin','compliance') AND active = true));

CREATE POLICY "subs_worker_insert" ON worker_document_submissions FOR INSERT TO authenticated
  WITH CHECK (worker_id IN (SELECT id FROM workers WHERE email = auth.email() AND active = true));

CREATE POLICY "subs_worker_read" ON worker_document_submissions FOR SELECT TO authenticated
  USING (worker_id IN (SELECT id FROM workers WHERE email = auth.email() AND active = true));

-- RLS on workers table: staff see all, workers see only their own row
ALTER TABLE workers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "workers_staff" ON workers FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin','compliance','planner','viewer') AND active = true)
         OR email = 'dylan@tmconstruction.nl');

CREATE POLICY "workers_own" ON workers FOR SELECT TO authenticated
  USING (email = auth.email() AND active = true);
