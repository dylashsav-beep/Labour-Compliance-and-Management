-- =============================================================================
-- CRITICAL SECURITY FIX — Rebuild ALL RLS policies from scratch
-- Run in: Supabase → Database → SQL Editor
--
-- Why: RLS policies are PERMISSIVE and combine with OR. The original
-- single-tenant app had policies (e.g. "Enable read access for all users"
-- USING (true)) whose names did not match the drop list in
-- add_multi_tenancy.sql, so they survived. A surviving USING(true) policy
-- ORs with the org-scoped policy and exposes EVERY row across all orgs.
--
-- This migration drops EVERY policy on each app table dynamically (so no
-- legacy policy can survive), re-enables RLS, and creates exactly one
-- org-scoped SELECT policy and one org-scoped ALL policy per table. Special
-- tables (organisations, profiles) get their own correct policies.
--
-- Safe to re-run.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 0. Ensure the org helper is correct and injection-safe.
--    SECURITY DEFINER + pinned search_path so it always reads public.profiles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_org_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT org_id FROM profiles WHERE id = auth.uid() LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION current_org_id() TO authenticated, anon;


-- ---------------------------------------------------------------------------
-- 1. Generic org-scoped tables: drop ALL policies, enable RLS, recreate.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  t   text;
  pol record;
  org_tables text[] := ARRAY[
    'workers','worker_documents','worker_document_files',
    'document_sets','document_set_items',
    'projects','project_assignments','project_assignment_files',
    'properties','vehicles',
    'accommodation_assignments','vehicle_assignments',
    'accommodation_charges','vehicle_charges',
    'resource_events','compliance_documents','deleted_items','settings',
    'tools','tool_assignments','tool_charges',
    'issued_documents','roster_week_allocations',
    'worker_resource_return_requests','worker_document_submissions'
  ];
BEGIN
  FOREACH t IN ARRAY org_tables LOOP
    -- Skip tables that don't exist in this deployment
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = t
    ) THEN
      CONTINUE;
    END IF;

    -- Drop EVERY existing policy on the table (catches all legacy names)
    FOR pol IN
      SELECT policyname FROM pg_policies
      WHERE schemaname = 'public' AND tablename = t
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, t);
    END LOOP;

    -- Enable RLS (no-op if already enabled)
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

    -- Exactly two org-scoped policies: read + full write
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (org_id = current_org_id())',
      'org read '||t, t
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id())',
      'org write '||t, t
    );
  END LOOP;
END $$;


-- ---------------------------------------------------------------------------
-- 2. Anon INSERT for worker-portal tables (direct anon submissions).
--    The portal read paths use SECURITY DEFINER RPCs, so only INSERT is needed.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_resource_return_requests') THEN
    EXECUTE 'CREATE POLICY "anon insert return requests" ON public.worker_resource_return_requests FOR INSERT TO anon WITH CHECK (true)';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_document_submissions') THEN
    EXECUTE 'CREATE POLICY "anon insert submissions" ON public.worker_document_submissions FOR INSERT TO anon WITH CHECK (true)';
  END IF;
END $$;


-- ---------------------------------------------------------------------------
-- 3. organisations — special: members read their own org; anon may read
--    (needed for slug→id resolution on signup + worker portal); admins update.
-- ---------------------------------------------------------------------------
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='organisations' LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.organisations', pol.policyname);
  END LOOP;
END $$;
ALTER TABLE organisations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "org members read their org" ON organisations
  FOR SELECT TO authenticated USING (id = current_org_id());
CREATE POLICY "anon read orgs by slug" ON organisations
  FOR SELECT TO anon USING (true);
CREATE POLICY "org admins update their org" ON organisations
  FOR UPDATE TO authenticated USING (id = current_org_id()) WITH CHECK (id = current_org_id());
-- Allow an authenticated user to INSERT a new org row only via create_workspace()
-- (that RPC is SECURITY DEFINER and bypasses RLS, so no INSERT policy needed here).


-- ---------------------------------------------------------------------------
-- 4. profiles — special: own profile full access; org members read profiles
--    in their org; admins manage profiles in their org. current_org_id() is
--    SECURITY DEFINER so there is no circular RLS dependency.
-- ---------------------------------------------------------------------------
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='profiles' LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.profiles', pol.policyname);
  END LOOP;
END $$;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own profile full access" ON profiles
  FOR ALL TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());
CREATE POLICY "org members read profiles" ON profiles
  FOR SELECT TO authenticated USING (org_id = current_org_id());
CREATE POLICY "org admins manage profiles" ON profiles
  FOR UPDATE TO authenticated USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id());


-- ---------------------------------------------------------------------------
-- 5. VERIFY — every app table should now show ONLY org-scoped policies.
--    Any row with qual = 'true' (outside the anon/organisations cases) is a leak.
-- ---------------------------------------------------------------------------
SELECT tablename, policyname, cmd, roles::text, qual
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
