-- =============================================================================
-- Worker Email Notification Settings
-- Run in: Supabase → Database → SQL Editor
-- Safe to re-run.
--
-- Adds:
--   1. notify_workers_enabled column to settings (per-org toggle)
--   2. worker_notification_log table — tracks when reminders were sent per
--      worker so the daily-digest throttles to once per 7 days, preventing
--      spam while still sending weekly repeat reminders for unresolved issues.
--
-- Multi-tenancy: worker_notification_log has org_id + RLS (current_org_id()).
-- Service-role code (daily-digest edge fn) filters by org_id manually.
-- =============================================================================

-- 1. Add the toggle to the existing settings table
ALTER TABLE settings
  ADD COLUMN IF NOT EXISTS notify_workers_enabled boolean NOT NULL DEFAULT false;

-- 2. Notification log table
CREATE TABLE IF NOT EXISTS worker_notification_log (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id         uuid        NOT NULL REFERENCES workers(id)       ON DELETE CASCADE,
  org_id            uuid        NOT NULL REFERENCES organisations(id)  ON DELETE CASCADE,
  sent_at           timestamptz NOT NULL DEFAULT now(),
  notification_type text        NOT NULL DEFAULT 'auto',  -- 'auto' | 'manual'
  doc_keys          text[]      NOT NULL DEFAULT '{}',
  active            boolean     NOT NULL DEFAULT true
);

ALTER TABLE worker_notification_log ENABLE ROW LEVEL SECURITY;

-- Drop any existing policies before recreating (safe to re-run)
DO $$ BEGIN
  EXECUTE 'DROP POLICY IF EXISTS "wnl_select" ON worker_notification_log';
  EXECUTE 'DROP POLICY IF EXISTS "wnl_all" ON worker_notification_log';
EXCEPTION WHEN undefined_table THEN NULL; END $$;

CREATE POLICY "wnl_select" ON worker_notification_log
  FOR SELECT USING (org_id = current_org_id());

CREATE POLICY "wnl_all" ON worker_notification_log
  FOR ALL USING (org_id = current_org_id())
  WITH CHECK (org_id = current_org_id());

CREATE INDEX IF NOT EXISTS wnl_worker_sent_idx ON worker_notification_log(worker_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS wnl_org_id_idx      ON worker_notification_log(org_id);

-- Verify
SELECT 'settings.notify_workers_enabled exists' AS check,
       (column_name IS NOT NULL) AS ok
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'settings'
  AND column_name  = 'notify_workers_enabled';

SELECT 'worker_notification_log RLS on' AS check,
       pc.relrowsecurity AS ok
FROM pg_class pc
JOIN pg_namespace n ON n.oid = pc.relnamespace AND n.nspname = 'public'
WHERE pc.relname = 'worker_notification_log';
