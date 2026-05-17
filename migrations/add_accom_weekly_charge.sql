-- Add weekly_charge_amount to accommodation_assignments for parity with vehicles
ALTER TABLE accommodation_assignments
  ADD COLUMN IF NOT EXISTS weekly_charge_amount NUMERIC(10,2) DEFAULT NULL;
