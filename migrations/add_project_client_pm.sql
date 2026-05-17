-- Migration: add client and project_manager columns to projects
-- Run in Supabase → Database → SQL Editor → New query → Run

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS client          TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS project_manager TEXT NOT NULL DEFAULT '';
