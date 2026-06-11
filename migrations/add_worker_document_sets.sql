-- =============================================================================
-- Worker Document Sets — per-worker set history & management
-- Tracks every document set ever applied to a worker, with active/inactive
-- status. workers.document_set_id remains the single requirements driver
-- (primary set). This table is a management layer for history and cleanup.
--
-- Run in: Supabase → Database → SQL Editor
-- Idempotent — safe to re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS worker_document_sets (
  id                 uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  org_id             uuid        NOT NULL REFERENCES organisations(id)   ON DELETE CASCADE,
  worker_id          uuid        NOT NULL REFERENCES workers(id)         ON DELETE CASCADE,
  document_set_id    uuid        NOT NULL REFERENCES document_sets(id),
  active             boolean     NOT NULL DEFAULT true,
  applied_at         timestamptz NOT NULL DEFAULT now(),
  applied_by         text,
  UNIQUE (worker_id, document_set_id)
);

ALTER TABLE worker_document_sets ENABLE ROW LEVEL SECURITY;

-- Drop and recreate policies cleanly (idempotent)
DO $$ DECLARE r RECORD;
BEGIN
  FOR r IN SELECT policyname FROM pg_policies
           WHERE schemaname='public' AND tablename='worker_document_sets'
  LOOP EXECUTE 'DROP POLICY IF EXISTS ' || quote_ident(r.policyname) || ' ON worker_document_sets'; END LOOP;
END $$;

CREATE POLICY "wds_select" ON worker_document_sets
  FOR SELECT USING (org_id = current_org_id());
CREATE POLICY "wds_all" ON worker_document_sets
  FOR ALL USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id());

CREATE INDEX IF NOT EXISTS idx_wds_worker ON worker_document_sets(worker_id);
CREATE INDEX IF NOT EXISTS idx_wds_org    ON worker_document_sets(org_id);

-- Backfill: record each worker's current primary set as an active entry
INSERT INTO worker_document_sets (org_id, worker_id, document_set_id, active)
SELECT w.org_id, w.id, w.document_set_id, true
FROM   workers w
WHERE  w.document_set_id IS NOT NULL
  AND  w.org_id          IS NOT NULL
  AND  w.active = true
ON CONFLICT (worker_id, document_set_id) DO NOTHING;
