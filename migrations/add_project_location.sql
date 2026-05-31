-- =============================================================================
-- Add location column to projects table
-- Run ONCE in: Supabase → Database → SQL Editor
-- =============================================================================

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS location TEXT DEFAULT '';
