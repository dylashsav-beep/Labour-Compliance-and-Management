-- =============================================================================
-- Add phone to workers table and update save_worker_profile RPC
-- Run ONCE in: Supabase → Database → SQL Editor
-- =============================================================================

-- 1. Add phone column if it doesn't exist yet
ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS phone TEXT DEFAULT '';

-- 2. Replace save_worker_profile to also accept and save phone
CREATE OR REPLACE FUNCTION save_worker_profile(
  p_email     text,
  p_worker_id uuid,
  p_new_email text DEFAULT NULL,
  p_notes     text DEFAULT NULL,
  p_phone     text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $func$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM workers
    WHERE id = p_worker_id AND lower(email) = lower(p_email) AND active = true
  ) THEN
    RAISE EXCEPTION 'Email does not match worker profile';
  END IF;
  UPDATE workers SET
    email      = NULLIF(p_new_email, ''),
    notes      = p_notes,
    phone      = NULLIF(p_phone, ''),
    updated_at = now()
  WHERE id = p_worker_id;
END;
$func$;

GRANT EXECUTE ON FUNCTION save_worker_profile(text, uuid, text, text, text) TO anon, authenticated;
