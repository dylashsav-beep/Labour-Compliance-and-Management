-- =============================================================================
-- Phase 0: org_id Performance Indexes
-- Run AFTER add_multi_tenancy.sql
-- Run in: Supabase → Database → SQL Editor
--
-- Without these, RLS policy evaluation does a full table scan on every query
-- as organisations accumulate data. These bring that down to index seeks.
-- All CREATE INDEX CONCURRENTLY — safe to run on a live production database.
-- =============================================================================

-- ── workers ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_workers_org_id
  ON workers (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_workers_org_active
  ON workers (org_id, active);

-- ── worker_documents ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_worker_documents_org_id
  ON worker_documents (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_worker_documents_org_worker
  ON worker_documents (org_id, worker_id, active);

-- ── worker_document_files ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_worker_document_files_org_id
  ON worker_document_files (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_worker_document_files_org_worker
  ON worker_document_files (org_id, worker_id, active);

-- ── document_sets ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_document_sets_org_id
  ON document_sets (org_id);

-- ── document_set_items ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_document_set_items_org_id
  ON document_set_items (org_id);

-- ── projects ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_projects_org_id
  ON projects (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_projects_org_active
  ON projects (org_id, active);

-- ── project_assignments ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_project_assignments_org_id
  ON project_assignments (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_project_assignments_org_worker
  ON project_assignments (org_id, worker_id, active);

-- ── project_assignment_files ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_project_assignment_files_org_id
  ON project_assignment_files (org_id);

-- ── properties ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_properties_org_id
  ON properties (org_id);

-- ── vehicles ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_vehicles_org_id
  ON vehicles (org_id);

-- ── accommodation_assignments ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_accommodation_assignments_org_id
  ON accommodation_assignments (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_accommodation_assignments_org_worker
  ON accommodation_assignments (org_id, worker_id, active);

-- ── vehicle_assignments ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_vehicle_assignments_org_id
  ON vehicle_assignments (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_vehicle_assignments_org_worker
  ON vehicle_assignments (org_id, worker_id, active);

-- ── accommodation_charges ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_accommodation_charges_org_id
  ON accommodation_charges (org_id);

-- ── vehicle_charges ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_vehicle_charges_org_id
  ON vehicle_charges (org_id);

-- ── resource_events ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_resource_events_org_id
  ON resource_events (org_id);

-- ── compliance_documents ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_compliance_documents_org_id
  ON compliance_documents (org_id);

-- ── deleted_items ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_deleted_items_org_id
  ON deleted_items (org_id);

-- ── profiles (org_id lookup for RLS helper) ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_profiles_org_id
  ON profiles (org_id);
-- current_org_id() does WHERE id = auth.uid() — make sure that's indexed:
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_profiles_id
  ON profiles (id);

-- ── Optional tables (skip if not present) ──
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='tools') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_tools_org_id ON tools (org_id)';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='tool_assignments') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_tool_assignments_org_id ON tool_assignments (org_id)';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='tool_charges') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_tool_charges_org_id ON tool_charges (org_id)';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_resource_return_requests') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_return_requests_org_id ON worker_resource_return_requests (org_id)';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='worker_document_submissions') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_submissions_org_id ON worker_document_submissions (org_id)';
  END IF;
END $$;
