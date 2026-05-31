-- =============================================================================
-- Add contact_phone column to projects table
-- Run ONCE in: Supabase → Database → SQL Editor
-- =============================================================================

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS contact_phone TEXT DEFAULT '';
