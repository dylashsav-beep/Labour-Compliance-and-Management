-- Add charge_to_operative to accommodation_assignments
ALTER TABLE accommodation_assignments ADD COLUMN IF NOT EXISTS charge_to_operative BOOLEAN NOT NULL DEFAULT FALSE;

-- Add charge_to_operative and weekly_charge_amount to vehicle_assignments
ALTER TABLE vehicle_assignments ADD COLUMN IF NOT EXISTS charge_to_operative BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE vehicle_assignments ADD COLUMN IF NOT EXISTS weekly_charge_amount NUMERIC(10,2) DEFAULT NULL;

-- Accommodation charges tracker
CREATE TABLE IF NOT EXISTS accommodation_charges (
  id             TEXT PRIMARY KEY,
  assignment_id  UUID NOT NULL REFERENCES accommodation_assignments(id) ON DELETE CASCADE,
  week_key       TEXT NOT NULL,
  charged        BOOLEAN NOT NULL DEFAULT FALSE,
  invoice_number TEXT DEFAULT NULL,
  invoice_amount NUMERIC(10,2) DEFAULT NULL,
  charged_at     TIMESTAMPTZ DEFAULT NOW(),
  charged_by     TEXT DEFAULT '',
  active         BOOLEAN NOT NULL DEFAULT TRUE
);

-- Vehicle charges tracker
CREATE TABLE IF NOT EXISTS vehicle_charges (
  id             TEXT PRIMARY KEY,
  assignment_id  UUID NOT NULL REFERENCES vehicle_assignments(id) ON DELETE CASCADE,
  week_key       TEXT NOT NULL,
  charged        BOOLEAN NOT NULL DEFAULT FALSE,
  invoice_number TEXT DEFAULT NULL,
  invoice_amount NUMERIC(10,2) DEFAULT NULL,
  charged_at     TIMESTAMPTZ DEFAULT NOW(),
  charged_by     TEXT DEFAULT '',
  active         BOOLEAN NOT NULL DEFAULT TRUE
);

-- RLS
ALTER TABLE accommodation_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_charges ENABLE ROW LEVEL SECURITY;
CREATE POLICY accom_charges_all ON accommodation_charges FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY vehicle_charges_all ON vehicle_charges FOR ALL TO authenticated USING (true) WITH CHECK (true);
