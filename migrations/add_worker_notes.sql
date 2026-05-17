-- Migration: add notes column to workers
-- Run in Supabase → Database → SQL Editor → New query → Run

ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS notes TEXT DEFAULT NULL;
