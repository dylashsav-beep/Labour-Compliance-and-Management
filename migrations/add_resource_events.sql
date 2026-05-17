CREATE TABLE IF NOT EXISTS resource_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_type TEXT NOT NULL,
  resource_id UUID NOT NULL,
  event_date DATE NOT NULL,
  event_type TEXT NOT NULL DEFAULT 'note',
  description TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  created_by TEXT DEFAULT NULL,
  active BOOLEAN DEFAULT TRUE
);
ALTER TABLE resource_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read_resource_events" ON resource_events FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "write_resource_events" ON resource_events FOR ALL TO authenticated USING (is_admin() OR EXISTS (SELECT 1 FROM profiles WHERE id=auth.uid() AND role IN ('admin','planner','compliance'))) WITH CHECK (is_admin() OR EXISTS (SELECT 1 FROM profiles WHERE id=auth.uid() AND role IN ('admin','planner','compliance')));
