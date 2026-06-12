-- =============================================================================
-- Competencies & Training — Phase 1: Core Tables + RPCs
-- Run in: Supabase → Database → SQL Editor
--
-- Creates three new org-scoped tables for tracking extra competencies and
-- training requirements per worker. Purely additive — does not touch any
-- existing document set, worker_documents, or vault tables.
--
-- Tables created:
--   worker_competencies          — org's competency/training catalogue
--   worker_competency_assignments — per-worker competency requirements
--   worker_competency_records    — evidence files submitted per competency
--
-- RPCs created:
--   submit_worker_competency     — worker portal (anon) submission
--   submit_vault_competency      — vault worker (authenticated) submission
--
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE).
-- =============================================================================

-- ── Table 1: Org competency catalogue ────────────────────────────────────────
-- Analogous to document_set_items but per-org rather than per-set.
-- Admin creates/edits competencies in Settings; assigns to individual workers.

CREATE TABLE IF NOT EXISTS worker_competencies (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             UUID        NOT NULL REFERENCES organisations(id) ON DELETE CASCADE,
  competency_key     TEXT        NOT NULL,
  name               TEXT        NOT NULL,
  category           TEXT        NOT NULL DEFAULT 'General',
  info_text          TEXT,
  info_url           TEXT,
  template_file_name TEXT,
  template_file_path TEXT,
  allow_issue        BOOLEAN     DEFAULT false,
  expiry_tracking    BOOLEAN     DEFAULT true,
  sort_order         INT         DEFAULT 0,
  active             BOOLEAN     DEFAULT true,
  created_by         TEXT,
  created_at         TIMESTAMPTZ DEFAULT now(),
  updated_at         TIMESTAMPTZ DEFAULT now(),
  UNIQUE(org_id, competency_key)
);

ALTER TABLE worker_competencies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "wc_select" ON worker_competencies;
DROP POLICY IF EXISTS "wc_all"    ON worker_competencies;

CREATE POLICY "wc_select" ON worker_competencies
  FOR SELECT USING (org_id = current_org_id());

CREATE POLICY "wc_all" ON worker_competencies
  FOR ALL USING (org_id = current_org_id())
  WITH CHECK (org_id = current_org_id());

CREATE INDEX IF NOT EXISTS wc_org_idx     ON worker_competencies(org_id);
CREATE INDEX IF NOT EXISTS wc_org_key_idx ON worker_competencies(org_id, competency_key);

-- ── Table 2: Per-worker competency requirements ────────────────────────────
-- Admin assigns specific competencies from the org catalogue to individual workers.
-- One row per (worker, competency) pair.

CREATE TABLE IF NOT EXISTS worker_competency_assignments (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID        NOT NULL REFERENCES organisations(id) ON DELETE CASCADE,
  worker_id     UUID        NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  competency_id UUID        NOT NULL REFERENCES worker_competencies(id) ON DELETE CASCADE,
  required      BOOLEAN     DEFAULT true,
  notes         TEXT,
  active        BOOLEAN     DEFAULT true,
  assigned_by   TEXT,
  assigned_at   TIMESTAMPTZ DEFAULT now(),
  UNIQUE(org_id, worker_id, competency_id)
);

ALTER TABLE worker_competency_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "wcas_select" ON worker_competency_assignments;
DROP POLICY IF EXISTS "wcas_all"    ON worker_competency_assignments;

CREATE POLICY "wcas_select" ON worker_competency_assignments
  FOR SELECT USING (org_id = current_org_id());

CREATE POLICY "wcas_all" ON worker_competency_assignments
  FOR ALL USING (org_id = current_org_id())
  WITH CHECK (org_id = current_org_id());

CREATE INDEX IF NOT EXISTS wcas_worker_idx ON worker_competency_assignments(org_id, worker_id);
CREATE INDEX IF NOT EXISTS wcas_comp_idx   ON worker_competency_assignments(org_id, competency_id);

-- ── Table 3: Evidence/submission records ─────────────────────────────────────
-- Actual files submitted as evidence for a competency. Workers submit; admins
-- approve or reject. Multiple records per competency are allowed (history).

CREATE TABLE IF NOT EXISTS worker_competency_records (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID        NOT NULL REFERENCES organisations(id) ON DELETE CASCADE,
  worker_id     UUID        NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  competency_id UUID        NOT NULL REFERENCES worker_competencies(id) ON DELETE CASCADE,
  file_path     TEXT,
  file_name     TEXT,
  issued_date   DATE,
  expiry_date   DATE,
  status        TEXT        NOT NULL DEFAULT 'pending',
  submitted_by  TEXT        DEFAULT 'worker',
  submitted_at  TIMESTAMPTZ DEFAULT now(),
  reviewed_by   TEXT,
  reviewed_at   TIMESTAMPTZ,
  review_notes  TEXT,
  active        BOOLEAN     DEFAULT true
);

ALTER TABLE worker_competency_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "wcr_select" ON worker_competency_records;
DROP POLICY IF EXISTS "wcr_all"    ON worker_competency_records;

CREATE POLICY "wcr_select" ON worker_competency_records
  FOR SELECT USING (org_id = current_org_id());

CREATE POLICY "wcr_all" ON worker_competency_records
  FOR ALL USING (org_id = current_org_id())
  WITH CHECK (org_id = current_org_id());

CREATE INDEX IF NOT EXISTS wcr_worker_idx ON worker_competency_records(org_id, worker_id);
CREATE INDEX IF NOT EXISTS wcr_comp_idx   ON worker_competency_records(org_id, competency_id);
CREATE INDEX IF NOT EXISTS wcr_status_idx ON worker_competency_records(org_id, status) WHERE active = true;

-- ── Storage: anon upload path for worker portal submissions ──────────────────
-- Worker portal is unauthenticated (email-only). Workers upload evidence to
-- worker-submissions/{org_id}/competency/ and then call submit_worker_competency.
-- Only adds the INSERT policy; admins read via their org-scoped storage RLS.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'competency_anon_upload'
  ) THEN
    EXECUTE $pol$
      CREATE POLICY "competency_anon_upload" ON storage.objects
        FOR INSERT TO anon
        WITH CHECK (
          bucket_id = 'tmc-documents'
          AND (storage.foldername(name))[1] = 'worker-submissions'
          AND (storage.foldername(name))[3] = 'competency'
        )
    $pol$;
  END IF;
END;
$$;

-- Allow authenticated org users (admins) to read worker-submissions/competency files.
-- They already have org-scoped read on the bucket root; this covers the anon-upload path.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'competency_org_read'
  ) THEN
    EXECUTE $pol$
      CREATE POLICY "competency_org_read" ON storage.objects
        FOR SELECT TO authenticated
        USING (
          bucket_id = 'tmc-documents'
          AND (storage.foldername(name))[1] = 'worker-submissions'
          AND (storage.foldername(name))[3] = 'competency'
        )
    $pol$;
  END IF;
END;
$$;

-- ── RPC 1: submit_worker_competency ──────────────────────────────────────────
-- Called from worker.html (anon) after the worker uploads a file to storage.
-- Resolves worker_id from email + org. Grants to anon + authenticated so both
-- the worker portal (anon) and the vault (authenticated) can call it.
-- p_worker_email is used only when auth.uid() returns NULL (anon sessions).

CREATE OR REPLACE FUNCTION submit_worker_competency(
  p_org_id        UUID,
  p_competency_id UUID,
  p_file_path     TEXT,
  p_file_name     TEXT,
  p_issued_date   DATE    DEFAULT NULL,
  p_expiry_date   DATE    DEFAULT NULL,
  p_worker_email  TEXT    DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_worker_id UUID;
  v_record_id UUID;
  v_email     TEXT;
BEGIN
  IF p_org_id IS NULL THEN
    RAISE EXCEPTION 'p_org_id is required';
  END IF;

  -- Prefer auth.uid() email (authenticated); fall back to caller-supplied email (anon portal).
  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();
  v_email := COALESCE(v_email, p_worker_email);

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'worker identity required — supply p_worker_email for anon sessions';
  END IF;

  -- Resolve the workers.id for this email in this org.
  SELECT id INTO v_worker_id
    FROM workers
   WHERE org_id = p_org_id
     AND lower(email) = lower(v_email)
     AND active = true
   LIMIT 1;

  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'worker not found in org';
  END IF;

  -- Confirm competency belongs to this org and is active.
  IF NOT EXISTS (
    SELECT 1 FROM worker_competencies
     WHERE id = p_competency_id AND org_id = p_org_id AND active = true
  ) THEN
    RAISE EXCEPTION 'competency not found';
  END IF;

  INSERT INTO worker_competency_records (
    org_id, worker_id, competency_id,
    file_path, file_name, issued_date, expiry_date,
    status, submitted_by
  ) VALUES (
    p_org_id, v_worker_id, p_competency_id,
    p_file_path, p_file_name, p_issued_date, p_expiry_date,
    'pending', 'worker'
  )
  RETURNING id INTO v_record_id;

  RETURN v_record_id;
END;
$$;

GRANT EXECUTE ON FUNCTION submit_worker_competency TO anon, authenticated;

-- ── RPC 2: submit_vault_competency ───────────────────────────────────────────
-- Called from vault.html (authenticated vault worker). Resolves worker_id
-- from worker_org_links using auth.uid() — never a caller-supplied identity.

CREATE OR REPLACE FUNCTION submit_vault_competency(
  p_org_id        UUID,
  p_competency_id UUID,
  p_file_path     TEXT,
  p_file_name     TEXT,
  p_issued_date   DATE DEFAULT NULL,
  p_expiry_date   DATE DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_account_id UUID := auth.uid();
  v_worker_id  UUID;
  v_record_id  UUID;
BEGIN
  IF p_org_id IS NULL THEN
    RAISE EXCEPTION 'p_org_id is required';
  END IF;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- Resolve worker row via the vault account's active org link.
  SELECT worker_row_id INTO v_worker_id
    FROM worker_org_links
   WHERE worker_account_id = v_account_id
     AND org_id = p_org_id
     AND status = 'active'
   LIMIT 1;

  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'no active link to this org';
  END IF;

  -- Confirm competency belongs to this org and is active.
  IF NOT EXISTS (
    SELECT 1 FROM worker_competencies
     WHERE id = p_competency_id AND org_id = p_org_id AND active = true
  ) THEN
    RAISE EXCEPTION 'competency not found';
  END IF;

  INSERT INTO worker_competency_records (
    org_id, worker_id, competency_id,
    file_path, file_name, issued_date, expiry_date,
    status, submitted_by
  ) VALUES (
    p_org_id, v_worker_id, p_competency_id,
    p_file_path, p_file_name, p_issued_date, p_expiry_date,
    'pending', 'vault'
  )
  RETURNING id INTO v_record_id;

  RETURN v_record_id;
END;
$$;

GRANT EXECUTE ON FUNCTION submit_vault_competency TO authenticated;

-- ── Verification ─────────────────────────────────────────────────────────────
-- Run after applying to confirm tables exist and RLS is on:
--
-- SELECT table_name FROM information_schema.tables
--   WHERE table_schema='public'
--     AND table_name IN ('worker_competencies','worker_competency_assignments','worker_competency_records');
-- → should return 3 rows
--
-- SELECT pc.relname, pc.relrowsecurity
--   FROM pg_class pc JOIN pg_namespace n ON n.oid = pc.relnamespace
--  WHERE n.nspname='public'
--    AND pc.relname IN ('worker_competencies','worker_competency_assignments','worker_competency_records');
-- → relrowsecurity must be true for all three
