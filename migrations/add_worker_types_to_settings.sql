-- Add worker_types JSONB column to settings table for custom worker type definitions.
-- Run ONCE in: Supabase → Database → SQL Editor

ALTER TABLE settings
  ADD COLUMN IF NOT EXISTS worker_types jsonb DEFAULT '[]'::jsonb;
