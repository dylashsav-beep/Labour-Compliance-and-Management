-- Add email address field to workers table
-- Run in Supabase → Database → SQL Editor

ALTER TABLE workers ADD COLUMN IF NOT EXISTS email text;
