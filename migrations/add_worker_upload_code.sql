-- Migration: add upload_code to workers + get_worker_profiles_by_code RPC
-- Purpose: enables the worker-portal code-login path (manager uploads on behalf of workers)
-- Run via: Supabase SQL Editor (already applied via MCP 2026-06-14)

ALTER TABLE workers ADD COLUMN IF NOT EXISTS upload_code text;
CREATE INDEX IF NOT EXISTS workers_upload_code_idx ON workers (org_id, upload_code)
  WHERE upload_code IS NOT NULL;

-- Returns all active workers in an org matching a case-insensitive upload code.
-- One match → portal loads directly. Multiple matches → profile-switcher cards.
-- Includes email so the caller can pass it to get_worker_portal.
CREATE OR REPLACE FUNCTION get_worker_profiles_by_code(p_code text, p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_org_id IS NULL THEN RAISE EXCEPTION 'p_org_id required'; END IF;
  IF p_code IS NULL OR trim(p_code)='' THEN RAISE EXCEPTION 'p_code required'; END IF;
  RETURN (
    SELECT jsonb_agg(jsonb_build_object(
      'id', w.id, 'full_name', w.full_name,
      'reference', w.reference, 'worker_type', w.worker_type,
      'email', w.email
    ))
    FROM workers w
    WHERE w.org_id = p_org_id
      AND lower(w.upload_code) = lower(trim(p_code))
      AND w.active = true
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_worker_profiles_by_code(text, uuid) TO anon, authenticated;
