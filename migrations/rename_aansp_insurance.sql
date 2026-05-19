-- Update the renamed insurance document in the NL ZZP built-in document set
-- Run in Supabase → Database → SQL Editor

UPDATE document_set_items
SET
  name = 'Company insurance (WA verzekering)',
  tip  = 'Company liability insurance (WA verzekering)'
WHERE id = '00000000-0000-0000-0000-000000000001__aansp';
