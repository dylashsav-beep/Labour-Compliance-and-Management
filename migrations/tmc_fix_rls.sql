-- ============================================================================
-- TM Construction Compliance — Emergency RLS Fix
-- ============================================================================
-- Run this immediately in Supabase → Database → SQL Editor → New query → Run
--
-- What went wrong:
--   The full schema migration dropped ALL existing RLS policies and replaced
--   them with new ones that depend on a get_my_role() helper function.
--   If that function returns NULL for any reason, every policy denies access,
--   which is why everything is broken.
--
-- What this script does:
--   1. Drops all broken policies
--   2. Recreates get_my_role() with a safe COALESCE fallback
--   3. Replaces all policies with a proven, simple pattern:
--      - SELECT: any authenticated (logged-in) user can read
--      - INSERT/UPDATE/DELETE: only allowed roles can write
--      This matches how the app already works — the JS already enforces
--      role restrictions client-side; RLS is the server-side safety net.
-- ============================================================================


-- ────────────────────────────────────────────────────────────────────────────
-- STEP 1: Drop every existing policy on every public table
-- ────────────────────────────────────────────────────────────────────────────
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


-- ────────────────────────────────────────────────────────────────────────────
-- STEP 2: Recreate get_my_role() with a robust fallback
-- ────────────────────────────────────────────────────────────────────────────
-- Uses SECURITY DEFINER so it can bypass RLS on profiles itself.
-- COALESCE means: if there is no profile row (or the row is inactive),
-- return 'viewer' instead of NULL — NULL breaks IN() checks.
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(
    (SELECT role FROM profiles
     WHERE  id = auth.uid()
     AND    active = TRUE
     LIMIT  1),
    'viewer'
  );
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- STEP 3: Recreate RLS policies
-- Pattern:
--   SELECT  → any authenticated user (login is sufficient to read)
--   ALL     → role must be in the allowed write set
--
-- All policies use TO authenticated so they never apply to anonymous
-- or service-role requests (service role bypasses RLS entirely).
-- ────────────────────────────────────────────────────────────────────────────

-- profiles
CREATE POLICY profiles_select ON profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid() OR get_my_role() = 'admin');

CREATE POLICY profiles_insert ON profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid() OR get_my_role() = 'admin');

CREATE POLICY profiles_update ON profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid() OR get_my_role() = 'admin');

-- settings
CREATE POLICY settings_select ON settings
  FOR SELECT TO authenticated USING (true);

CREATE POLICY settings_write ON settings
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','compliance'));

-- document_sets
CREATE POLICY doc_sets_select ON document_sets
  FOR SELECT TO authenticated USING (true);

CREATE POLICY doc_sets_write ON document_sets
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','compliance'));

-- document_set_items
CREATE POLICY doc_set_items_select ON document_set_items
  FOR SELECT TO authenticated USING (true);

CREATE POLICY doc_set_items_write ON document_set_items
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','compliance'));

-- workers
CREATE POLICY workers_select ON workers
  FOR SELECT TO authenticated USING (true);

CREATE POLICY workers_write ON workers
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','compliance'));

-- worker_documents
CREATE POLICY worker_docs_select ON worker_documents
  FOR SELECT TO authenticated USING (true);

CREATE POLICY worker_docs_write ON worker_documents
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','compliance'));

-- worker_document_files
CREATE POLICY worker_doc_files_select ON worker_document_files
  FOR SELECT TO authenticated USING (true);

CREATE POLICY worker_doc_files_write ON worker_document_files
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','compliance'));

-- projects
CREATE POLICY projects_select ON projects
  FOR SELECT TO authenticated USING (true);

CREATE POLICY projects_write ON projects
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- project_assignments
CREATE POLICY proj_assign_select ON project_assignments
  FOR SELECT TO authenticated USING (true);

CREATE POLICY proj_assign_write ON project_assignments
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- project_assignment_files
CREATE POLICY proj_assign_files_select ON project_assignment_files
  FOR SELECT TO authenticated USING (true);

CREATE POLICY proj_assign_files_write ON project_assignment_files
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- roster_week_allocations
CREATE POLICY roster_select ON roster_week_allocations
  FOR SELECT TO authenticated USING (true);

CREATE POLICY roster_write ON roster_week_allocations
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- properties
CREATE POLICY properties_select ON properties
  FOR SELECT TO authenticated USING (true);

CREATE POLICY properties_write ON properties
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- vehicles
CREATE POLICY vehicles_select ON vehicles
  FOR SELECT TO authenticated USING (true);

CREATE POLICY vehicles_write ON vehicles
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- accommodation_assignments
CREATE POLICY accom_assign_select ON accommodation_assignments
  FOR SELECT TO authenticated USING (true);

CREATE POLICY accom_assign_write ON accommodation_assignments
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- vehicle_assignments
CREATE POLICY veh_assign_select ON vehicle_assignments
  FOR SELECT TO authenticated USING (true);

CREATE POLICY veh_assign_write ON vehicle_assignments
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','planner'));

-- deleted_items
CREATE POLICY deleted_items_select ON deleted_items
  FOR SELECT TO authenticated
  USING (get_my_role() IN ('admin','compliance'));

CREATE POLICY deleted_items_write ON deleted_items
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','compliance'));


-- ────────────────────────────────────────────────────────────────────────────
-- STEP 4: Verify — run this SELECT to confirm your role is resolving correctly
-- (should return 'admin' for the owner account)
-- ────────────────────────────────────────────────────────────────────────────
-- SELECT get_my_role();
