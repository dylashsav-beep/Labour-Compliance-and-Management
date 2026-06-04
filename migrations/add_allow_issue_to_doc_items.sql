-- Add allow_issue flag to document_set_items
-- Controls whether the "Issue personalised document" button appears on a per-question basis.
-- Run ONCE in: Supabase → Database → SQL Editor

ALTER TABLE document_set_items
  ADD COLUMN IF NOT EXISTS allow_issue boolean NOT NULL DEFAULT false;
