-- =============================================================================
-- Drop the workers_worker_type_check constraint
-- Run in: Supabase → Database → SQL Editor
-- Safe to re-run.
--
-- The original CHECK constraint only allowed hardcoded worker type values
-- (e.g. 'zzp', 'blue'). Custom worker types added via Settings → Worker Types
-- are stored as free-form text and must not be blocked by this constraint.
-- =============================================================================

ALTER TABLE workers DROP CONSTRAINT IF EXISTS workers_worker_type_check;

-- Verify constraint is gone
SELECT 'workers_worker_type_check removed' AS check,
       NOT EXISTS (
         SELECT 1 FROM pg_constraint
         WHERE conname = 'workers_worker_type_check'
       ) AS ok;
