-- =============================================================================
-- Add digest_emails column to settings
-- Run in: Supabase → Database → SQL Editor
-- Safe to re-run.
--
-- Stores the list of email addresses that receive the daily digest for this
-- org. An empty array means only the organisation owner_email is used.
-- =============================================================================

ALTER TABLE settings
  ADD COLUMN IF NOT EXISTS digest_emails text[] NOT NULL DEFAULT '{}';

-- Verify
SELECT 'settings.digest_emails exists' AS check,
       (column_name IS NOT NULL) AS ok
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'settings'
  AND column_name  = 'digest_emails';
