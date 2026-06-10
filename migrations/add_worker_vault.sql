-- =============================================================================
-- Worker Vault — Phase 0: Database Foundation
-- Run in: Supabase → Database → SQL Editor
-- Run AFTER add_multi_tenancy.sql, fix_rls_rebuild_all_policies.sql,
--           create_workspace_signup.sql, add_worker_email.sql
--
-- Creates the portable, worker-owned vault layer that sits ALONGSIDE the
-- existing org-scoped compliance system. A vault account is keyed to a
-- Supabase Auth user (auth.uid) and is independent of any organisation.
--
--   1. worker_accounts        — one row per worker auth account (portable)
--   2. worker_org_links       — junction: one account → many org `workers` rows
--   3. vault_documents        — worker-owned document metadata + expiry
--   4. vault_assignment_links — worker-owned copies of assignment contracts
--   5. workers.vault_account_id — back-reference set when a worker claims a row
--   6. ensure_vault_account() — RPC called by vault.html after magic-link auth
--   7. RLS + indexes
--
-- ⚠️ ISOLATION MODEL NOTE (read before running the tenancy audit in CLAUDE.md):
-- These tables carry an `org_id` column but are NOT scoped by
-- `org_id = current_org_id()` like the rest of the app. They are WORKER-scoped
-- by `worker_account_id = auth.uid()`. This is intentional and correct — the
-- vault belongs to the worker, not the org. The standard audit query (b) will
-- flag policies here as "lacking org_id = current_org_id()"; that is expected.
-- Do NOT "fix" them by adding org-scoped-only policies — that would break a
-- worker's access to their own portable vault. worker_org_links additionally
-- grants org staff an org-scoped path (so they can invite/track), which ORs
-- with the worker path; both sides are properly scoped so there is no leak.
--
-- Safe to re-run (idempotent).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. worker_accounts — portable worker identity (id = auth.uid)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS worker_accounts (
  id                     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email                  text NOT NULL,
  full_name              text,
  plan                   text NOT NULL DEFAULT 'free',   -- 'free' | 'vault'
  plan_expires           timestamptz,
  stripe_customer_id     text,
  stripe_subscription_id text,
  created_at             timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. worker_org_links — bridge between a vault account and an org's worker row
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS worker_org_links (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_account_id uuid REFERENCES worker_accounts(id) ON DELETE CASCADE,
  worker_row_id     uuid NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES organisations(id) ON DELETE CASCADE,
  status            text NOT NULL DEFAULT 'invited',  -- 'invited' | 'active' | 'unlinked'
  invited_by        text,
  invited_at        timestamptz NOT NULL DEFAULT now(),
  linked_at         timestamptz,
  UNIQUE (worker_row_id)   -- an org worker row links to at most one vault account
);

-- ---------------------------------------------------------------------------
-- 3. vault_documents — worker-owned document metadata (with expiry)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vault_documents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_account_id uuid NOT NULL REFERENCES worker_accounts(id) ON DELETE CASCADE,
  doc_key           text,             -- e.g. 'bsn','vca' or a worker-defined key
  display_name      text,             -- worker-editable for personal docs
  file_path         text,             -- vault storage path: vault/{account_id}/...
  file_name         text,
  expiry_date       date,             -- worker-managed
  issued_date       date,
  source            text NOT NULL DEFAULT 'worker_upload', -- 'org_approved' | 'worker_upload'
  source_org_id     uuid REFERENCES organisations(id) ON DELETE SET NULL,
  approved_at       timestamptz,      -- when org approved (org_approved rows)
  created_at        timestamptz NOT NULL DEFAULT now(),
  active            boolean NOT NULL DEFAULT true
);

-- ---------------------------------------------------------------------------
-- 4. vault_assignment_links — worker-owned copies of assignment contracts
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vault_assignment_links (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_account_id uuid NOT NULL REFERENCES worker_accounts(id) ON DELETE CASCADE,
  assignment_id     uuid NOT NULL REFERENCES project_assignments(id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES organisations(id) ON DELETE CASCADE,
  project_name      text,             -- denormalised snapshot (no rate data)
  org_name          text,
  start_date        date,
  end_date          date,
  contract_status   text,             -- 'signed' | 'unsigned' | 'missing'
  file_path         text,             -- vault copy of the contract PDF
  file_name         text,
  copied_at         timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (worker_account_id, assignment_id)
);

-- ---------------------------------------------------------------------------
-- 5. workers.vault_account_id — set when a worker claims their org row
-- ---------------------------------------------------------------------------
ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS vault_account_id uuid REFERENCES worker_accounts(id) ON DELETE SET NULL;


-- ---------------------------------------------------------------------------
-- 6. Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_worker_accounts_email
  ON worker_accounts (lower(email));
CREATE INDEX IF NOT EXISTS idx_worker_org_links_account
  ON worker_org_links (worker_account_id);
CREATE INDEX IF NOT EXISTS idx_worker_org_links_org
  ON worker_org_links (org_id);
CREATE INDEX IF NOT EXISTS idx_worker_org_links_worker_row
  ON worker_org_links (worker_row_id);
CREATE INDEX IF NOT EXISTS idx_vault_documents_account
  ON vault_documents (worker_account_id, active);
CREATE INDEX IF NOT EXISTS idx_vault_assignment_links_account
  ON vault_assignment_links (worker_account_id);
CREATE INDEX IF NOT EXISTS idx_workers_vault_account
  ON workers (vault_account_id);


-- ---------------------------------------------------------------------------
-- 7. RLS — worker-scoped (auth.uid). Drop ALL existing policies first so the
--    script is safe to re-run and no legacy/wide policy can survive.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  t   text;
  pol record;
  vault_tables text[] := ARRAY[
    'worker_accounts','worker_org_links','vault_documents','vault_assignment_links'
  ];
BEGIN
  FOREACH t IN ARRAY vault_tables LOOP
    FOR pol IN
      SELECT policyname FROM pg_policies
      WHERE schemaname = 'public' AND tablename = t
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, t);
    END LOOP;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- worker_accounts — a worker reads/updates only their own account row.
-- INSERT happens via ensure_vault_account() (SECURITY DEFINER) only.
CREATE POLICY "own account read"   ON worker_accounts
  FOR SELECT TO authenticated USING (id = auth.uid());
CREATE POLICY "own account update" ON worker_accounts
  FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- worker_org_links — TWO legitimately-scoped paths (OR is safe here):
--   (a) the worker reads their own links
--   (b) org staff read/manage links into their own org (invite + track)
CREATE POLICY "worker reads own links" ON worker_org_links
  FOR SELECT TO authenticated USING (worker_account_id = auth.uid());
CREATE POLICY "org reads its links" ON worker_org_links
  FOR SELECT TO authenticated USING (org_id = current_org_id());
CREATE POLICY "org manages its links" ON worker_org_links
  FOR ALL TO authenticated
  USING (org_id = current_org_id())
  WITH CHECK (org_id = current_org_id());

-- vault_documents — purely worker-owned. Service-role copy-to-vault bypasses RLS.
CREATE POLICY "own vault docs" ON vault_documents
  FOR ALL TO authenticated
  USING (worker_account_id = auth.uid())
  WITH CHECK (worker_account_id = auth.uid());

-- vault_assignment_links — worker reads own; org may create/track its own.
CREATE POLICY "worker reads own assignment links" ON vault_assignment_links
  FOR SELECT TO authenticated USING (worker_account_id = auth.uid());
CREATE POLICY "org manages its assignment links" ON vault_assignment_links
  FOR ALL TO authenticated
  USING (org_id = current_org_id())
  WITH CHECK (org_id = current_org_id());


-- ---------------------------------------------------------------------------
-- 8. ensure_vault_account() — called by vault.html immediately after the
--    magic-link session is established. Creates the worker_accounts row if it
--    does not exist, then auto-links every org `workers` row matching the
--    caller's email (one email = one account; links span all orgs).
--    Returns the worker_accounts row as json.
--
--    SECURITY DEFINER: it must read workers across ALL orgs by email (RLS would
--    otherwise hide them), but it derives identity from auth.uid()/auth.users
--    — never from a caller-supplied parameter — so there is no cross-org hole.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ensure_vault_account()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
  v_name  text;
  v_acct  worker_accounts%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT email, COALESCE(raw_user_meta_data->>'full_name', split_part(email,'@',1))
    INTO v_email, v_name
  FROM auth.users WHERE id = v_uid;

  -- Create the portable account row if missing
  INSERT INTO worker_accounts (id, email, full_name)
  VALUES (v_uid, v_email, v_name)
  ON CONFLICT (id) DO NOTHING;

  -- Auto-link every org worker row that matches this email (case-insensitive)
  -- and is not already claimed by another account. Marks them active.
  UPDATE workers w
  SET vault_account_id = v_uid
  WHERE lower(w.email) = lower(v_email)
    AND (w.vault_account_id IS NULL OR w.vault_account_id = v_uid);

  INSERT INTO worker_org_links (worker_account_id, worker_row_id, org_id, status, linked_at)
  SELECT v_uid, w.id, w.org_id, 'active', now()
  FROM workers w
  WHERE w.vault_account_id = v_uid
  ON CONFLICT (worker_row_id) DO UPDATE
    SET worker_account_id = EXCLUDED.worker_account_id,
        status            = 'active',
        linked_at         = COALESCE(worker_org_links.linked_at, now());

  SELECT * INTO v_acct FROM worker_accounts WHERE id = v_uid;
  RETURN row_to_json(v_acct);
END;
$$;

GRANT EXECUTE ON FUNCTION ensure_vault_account() TO authenticated;


-- ---------------------------------------------------------------------------
-- 9. VERIFY — confirm RLS on, and policies are worker/org scoped (no qual='true')
-- ---------------------------------------------------------------------------
SELECT tablename, policyname, cmd, roles::text, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('worker_accounts','worker_org_links','vault_documents','vault_assignment_links')
ORDER BY tablename, policyname;
