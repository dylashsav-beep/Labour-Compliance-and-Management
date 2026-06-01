-- Add reject_delete_days to settings table
-- Run ONCE in: Supabase → Database → SQL Editor

ALTER TABLE settings
  ADD COLUMN IF NOT EXISTS reject_delete_days integer NOT NULL DEFAULT 30;
