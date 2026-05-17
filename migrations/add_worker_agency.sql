-- Migration: add agency_name column to workers
-- Stores the ZZP company name or agency name for agency workers.
-- Run in Supabase → Database → SQL Editor → New query → Run

ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS agency_name TEXT DEFAULT NULL;
