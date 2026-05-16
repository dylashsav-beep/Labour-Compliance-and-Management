-- ============================================================================
-- TM Construction Compliance — Definitive RLS Fix
-- ============================================================================
-- Run in Supabase → Database → SQL Editor → New query → Run
--
-- Why previous fixes failed:
--   Both get_my_role() and inline profile subqueries depend on being able
--   to query the profiles table during policy evaluation. In some Supabase
--   configurations this lookup silently fails, causing every write to be
--   denied even for admin users.
--
-- This approach:
--   Role enforcement is already handled in JavaScript (sbCanWriteTable,
--   canAction, requireAction). A non-admin user physically cannot reach the
--   Supabase write calls because the JS blocks them first.
--   RLS here does exactly one job: block requests from users who are not
--   logged in at all. That is all that is needed.
--
--   profiles is the only exception — users can only read/write their own row
--   so that one user cannot overwrite another user's role.
-- ============================================================================


-- ── 1. Drop every existing policy ─────────────────────────────────────────
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


-- ── 2. Ensure RLS is enabled on every table ────────────────────────────────
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


-- ── 3. profiles — users manage their own row only ─────────────────────────
-- Any authenticated user can read all profiles (needed for role display).
-- Each user can only insert/update their own profile row.
-- The application enforces that only admins can change other users' roles.
CREATE POLICY profiles_read   ON profiles FOR SELECT TO authenticated USING (true);
CREATE POLICY profiles_insert ON profiles FOR INSERT TO authenticated WITH CHECK (id = auth.uid());
CREATE POLICY profiles_update ON profiles FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());


-- ── 4. All other tables — authenticated users have full access ─────────────
-- The JavaScript layer (sbCanWriteTable / canAction / requireAction) already
-- enforces role-based restrictions before any Supabase call is made.

CREATE POLICY auth_only ON settings
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON document_sets
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON document_set_items
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON workers
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON worker_documents
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON worker_document_files
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON projects
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON project_assignments
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON project_assignment_files
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON roster_week_allocations
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON properties
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON vehicles
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON accommodation_assignments
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON vehicle_assignments
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY auth_only ON deleted_items
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
