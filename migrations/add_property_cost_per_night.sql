-- Migration: add cost_per_night to properties
-- Run in Supabase → Database → SQL Editor → New query → Run

ALTER TABLE properties
  ADD COLUMN IF NOT EXISTS cost_per_night NUMERIC(10,2) DEFAULT NULL;
