-- =============================================================================
-- Add notify_worker_types column to settings
-- Run in: Supabase → Database → SQL Editor
-- Safe to re-run.
--
-- Stores the list of worker type IDs that should receive automatic email
-- reminders. An empty array means all types are included (default / no filter).
-- =============================================================================

ALTER TABLE settings
  ADD COLUMN IF NOT EXISTS notify_worker_types text[] NOT NULL DEFAULT '{}';

-- Verify
SELECT 'settings.notify_worker_types exists' AS check,
       (column_name IS NOT NULL) AS ok
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'settings'
  AND column_name  = 'notify_worker_types';
