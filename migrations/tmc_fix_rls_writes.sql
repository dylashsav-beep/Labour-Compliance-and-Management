-- ============================================================================
-- TM Construction Compliance — Fix write RLS policies
-- ============================================================================
-- Run in Supabase → Database → SQL Editor → New query → Run
--
-- Problem:
--   get_my_role() uses SECURITY DEFINER, but in some Supabase versions
--   auth.uid() returns NULL inside SECURITY DEFINER functions.
--   SELECT policies work because they use USING (true) — no function call.
--   Write policies fail because get_my_role() returns 'viewer' instead of
--   the real role, so every insert/update/delete is rejected.
--
-- Fix:
--   Replace get_my_role() in write policies with a direct inline subquery
--   against the profiles table. The user can always read their own profile
--   row (id = auth.uid()), so no SECURITY DEFINER is needed.
--   Both USING and WITH CHECK are set so INSERT, UPDATE and DELETE all work.
-- ============================================================================

-- Drop all write policies (leave SELECT policies alone — they work)
DROP POLICY IF EXISTS settings_write              ON settings;
DROP POLICY IF EXISTS doc_sets_write              ON document_sets;
DROP POLICY IF EXISTS doc_set_items_write         ON document_set_items;
DROP POLICY IF EXISTS workers_write               ON workers;
DROP POLICY IF EXISTS worker_docs_write           ON worker_documents;
DROP POLICY IF EXISTS worker_doc_files_write      ON worker_document_files;
DROP POLICY IF EXISTS projects_write              ON projects;
DROP POLICY IF EXISTS proj_assign_write           ON project_assignments;
DROP POLICY IF EXISTS proj_assign_files_write     ON project_assignment_files;
DROP POLICY IF EXISTS roster_write                ON roster_week_allocations;
DROP POLICY IF EXISTS properties_write            ON properties;
DROP POLICY IF EXISTS vehicles_write              ON vehicles;
DROP POLICY IF EXISTS accom_assign_write          ON accommodation_assignments;
DROP POLICY IF EXISTS veh_assign_write            ON vehicle_assignments;
DROP POLICY IF EXISTS deleted_items_select        ON deleted_items;
DROP POLICY IF EXISTS deleted_items_write         ON deleted_items;
DROP POLICY IF EXISTS profiles_insert             ON profiles;
DROP POLICY IF EXISTS profiles_update             ON profiles;

-- Convenience: inline expression used in every write policy below
-- Reads the calling user's own profile row — always allowed by the SELECT policy.
-- Returns their role; NULL if no profile exists (treated as denied).

-- ── settings ──────────────────────────────────────────────────────────────
CREATE POLICY settings_write ON settings
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── document_sets ─────────────────────────────────────────────────────────
CREATE POLICY doc_sets_write ON document_sets
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── document_set_items ────────────────────────────────────────────────────
CREATE POLICY doc_set_items_write ON document_set_items
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── workers ───────────────────────────────────────────────────────────────
CREATE POLICY workers_write ON workers
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── worker_documents ──────────────────────────────────────────────────────
CREATE POLICY worker_docs_write ON worker_documents
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── worker_document_files ─────────────────────────────────────────────────
CREATE POLICY worker_doc_files_write ON worker_document_files
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── projects ──────────────────────────────────────────────────────────────
CREATE POLICY projects_write ON projects
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── project_assignments ───────────────────────────────────────────────────
CREATE POLICY proj_assign_write ON project_assignments
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── project_assignment_files ──────────────────────────────────────────────
CREATE POLICY proj_assign_files_write ON project_assignment_files
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── roster_week_allocations ───────────────────────────────────────────────
CREATE POLICY roster_write ON roster_week_allocations
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── properties ────────────────────────────────────────────────────────────
CREATE POLICY properties_write ON properties
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── vehicles ──────────────────────────────────────────────────────────────
CREATE POLICY vehicles_write ON vehicles
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── accommodation_assignments ─────────────────────────────────────────────
CREATE POLICY accom_assign_write ON accommodation_assignments
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── vehicle_assignments ───────────────────────────────────────────────────
CREATE POLICY veh_assign_write ON vehicle_assignments
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','planner'));

-- ── deleted_items (read + write both need role check) ─────────────────────
CREATE POLICY deleted_items_select ON deleted_items
  FOR SELECT TO authenticated
  USING ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

CREATE POLICY deleted_items_write ON deleted_items
  FOR ALL TO authenticated
  USING      ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'))
  WITH CHECK ((SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) IN ('admin','compliance'));

-- ── profiles (own row + admin) ────────────────────────────────────────────
CREATE POLICY profiles_insert ON profiles
  FOR INSERT TO authenticated
  WITH CHECK (
    id = auth.uid()
    OR (SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) = 'admin'
  );

CREATE POLICY profiles_update ON profiles
  FOR UPDATE TO authenticated
  USING (
    id = auth.uid()
    OR (SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) = 'admin'
  )
  WITH CHECK (
    id = auth.uid()
    OR (SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) = 'admin'
  );

-- ── Verify: run this after applying — should return your role (e.g. 'admin')
-- SELECT (SELECT role FROM profiles WHERE id = auth.uid() AND active = TRUE LIMIT 1) AS my_role;
