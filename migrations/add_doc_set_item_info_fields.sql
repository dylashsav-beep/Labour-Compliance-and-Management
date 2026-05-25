-- Add info_text and info_url columns to document_set_items
-- info_text: plain-text description shown as a tooltip/expandable note
-- info_url:  link to an external resource or form for the worker
-- Run in: Supabase → Database → SQL Editor

ALTER TABLE document_set_items
  ADD COLUMN IF NOT EXISTS info_text text,
  ADD COLUMN IF NOT EXISTS info_url  text;
