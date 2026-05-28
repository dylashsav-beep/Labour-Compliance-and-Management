-- Add phone number column to workers table
ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS phone text;
