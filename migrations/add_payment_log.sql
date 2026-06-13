-- ── Payment Log ──────────────────────────────────────────────────────────────
-- Tracks both manual and Stripe-originated payments for organisations and
-- vault worker accounts. Accessible only via admin SECURITY DEFINER RPCs —
-- the anon key cannot read or write this table directly.

CREATE TABLE IF NOT EXISTS payment_log (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type       text        NOT NULL CHECK (entity_type IN ('org','worker')),
  entity_id         uuid        NOT NULL,
  amount            numeric(10,2),
  currency          text        NOT NULL DEFAULT 'EUR',
  method            text        NOT NULL DEFAULT 'manual' CHECK (method IN ('manual','stripe')),
  stripe_payment_id text,
  notes             text,
  paid_at           timestamptz NOT NULL DEFAULT now(),
  recorded_by       text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE payment_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_only" ON payment_log;
CREATE POLICY "admin_only" ON payment_log
  FOR ALL
  USING (
    (SELECT email FROM auth.users WHERE id = auth.uid()) = 'dylashsav@gmail.com'
  );

CREATE INDEX IF NOT EXISTS payment_log_entity_idx ON payment_log (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS payment_log_paid_at_idx ON payment_log (paid_at DESC);
