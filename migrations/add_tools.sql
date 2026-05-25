-- Tools tracking: mirror of accommodation/vehicle system
-- Run in: Supabase → Database → SQL Editor

CREATE TABLE IF NOT EXISTS tools (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  serial_number text,
  notes text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tool_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id uuid,
  tool_id uuid,
  start_date date,
  end_date date,
  notes text,
  charge_to_operative boolean DEFAULT false,
  weekly_charge_amount numeric(10,2),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tool_charges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id uuid,
  week_key text NOT NULL,
  charged boolean DEFAULT false,
  invoice_number text,
  invoice_amount numeric(10,2),
  charged_at timestamptz,
  charged_by text,
  active boolean NOT NULL DEFAULT true
);

ALTER TABLE tools ENABLE ROW LEVEL SECURITY;
ALTER TABLE tool_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE tool_charges ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth users can read tools" ON tools FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth users can write tools" ON tools FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "auth users can read tool_assignments" ON tool_assignments FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth users can write tool_assignments" ON tool_assignments FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "auth users can read tool_charges" ON tool_charges FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth users can write tool_charges" ON tool_charges FOR ALL TO authenticated USING (true) WITH CHECK (true);
