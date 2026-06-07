-- =============================================================================
-- Phase 1: Self-Serve Workspace Creation
-- Run in: Supabase → Database → SQL Editor
-- Run AFTER add_multi_tenancy.sql and add_org_id_indexes.sql
--
-- Creates:
--   1. create_workspace()   — RPC called after a new user signs up to
--                             create their organisation and become its admin.
--   2. join_workspace()     — RPC for invited users to join an existing org
--                             via a valid slug (no secret token needed for MVP;
--                             add invite tokens in Phase 2 if required).
--   3. Enum / helper: workspace_plan column on organisations table.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Add plan + subscription columns to organisations (safe to re-run)
-- ---------------------------------------------------------------------------

ALTER TABLE organisations
  ADD COLUMN IF NOT EXISTS plan          text NOT NULL DEFAULT 'trial',
  ADD COLUMN IF NOT EXISTS plan_started  timestamptz,
  ADD COLUMN IF NOT EXISTS plan_ends     timestamptz,
  ADD COLUMN IF NOT EXISTS stripe_customer_id    text,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id text,
  ADD COLUMN IF NOT EXISTS max_workers   int NOT NULL DEFAULT 25,
  ADD COLUMN IF NOT EXISTS trial_ends    timestamptz;

-- Set a 30-day trial end for the TMC org (it's already live — extend indefinitely)
UPDATE organisations
SET plan = 'pro', plan_started = now()
WHERE id = '00000000-0000-0000-0001-000000000001'
  AND plan = 'trial';


-- ---------------------------------------------------------------------------
-- 2. create_workspace(slug, org_name)
--    Called immediately after a user signs up (they must be authenticated).
--    Creates the organisation + reassigns the caller's profile to it as admin.
--    Returns the new org_id on success, raises an exception on conflict.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_workspace(
  p_slug     text,
  p_org_name text
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid      uuid  := auth.uid();
  v_email    text;
  v_org_id   uuid;
  v_trial_end timestamptz := now() + interval '30 days';
BEGIN
  -- Must be authenticated
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- Validate slug: lowercase letters, numbers, hyphens only, 3-40 chars
  IF p_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' THEN
    RAISE EXCEPTION 'invalid_slug';
  END IF;

  -- Reserved slugs
  IF p_slug = ANY(ARRAY['tmc','admin','api','app','www','mail','support','billing','help','demo','test','staging','prod','production']) THEN
    RAISE EXCEPTION 'reserved_slug';
  END IF;

  -- Check slug is not taken
  IF EXISTS (SELECT 1 FROM organisations WHERE slug = p_slug) THEN
    RAISE EXCEPTION 'slug_taken';
  END IF;

  -- Get caller email from auth.users
  SELECT email INTO v_email FROM auth.users WHERE id = v_uid;

  -- Create the organisation
  INSERT INTO organisations (
    name, slug, owner_email,
    plan, trial_ends,
    warning_days
  ) VALUES (
    p_org_name, p_slug, v_email,
    'trial', v_trial_end,
    60
  )
  RETURNING id INTO v_org_id;

  -- Create a settings row for the new org
  INSERT INTO settings (id, org_id, warning_days)
  VALUES (v_org_id, v_org_id, 60)
  ON CONFLICT (id) DO NOTHING;

  -- Assign the caller's profile to this org as admin
  UPDATE profiles
  SET org_id = v_org_id,
      role   = 'admin',
      active = true
  WHERE id = v_uid;

  -- Copy built-in document sets into the new org so they can use them immediately
  INSERT INTO document_sets (id, name, built_in, active, org_id)
  SELECT gen_random_uuid(), name, built_in, true, v_org_id
  FROM document_sets
  WHERE org_id = '00000000-0000-0000-0001-000000000001'
    AND built_in = true
  ON CONFLICT DO NOTHING;

  RETURN v_org_id;
END;
$$;

GRANT EXECUTE ON FUNCTION create_workspace(text, text) TO authenticated;


-- ---------------------------------------------------------------------------
-- 3. join_workspace(slug)
--    Lets a user whose profile has org_id = NULL join an existing org.
--    Role defaults to 'no_access' — an admin of that org must approve.
--    Guards against joining if already in an org.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION join_workspace(p_slug text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_org    organisations%ROWTYPE;
  v_cur_org uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT org_id INTO v_cur_org FROM profiles WHERE id = v_uid;
  IF v_cur_org IS NOT NULL THEN
    RAISE EXCEPTION 'already_in_org';
  END IF;

  SELECT * INTO v_org FROM organisations WHERE slug = p_slug;
  IF NOT FOUND THEN RAISE EXCEPTION 'org_not_found'; END IF;

  UPDATE profiles
  SET org_id = v_org.id,
      role   = 'no_access',
      active = false
  WHERE id = v_uid;

  RETURN v_org.id;
END;
$$;

GRANT EXECUTE ON FUNCTION join_workspace(text) TO authenticated;


-- ---------------------------------------------------------------------------
-- 4. check_slug_available(slug) — fast availability check before submission
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_slug_available(p_slug text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT NOT EXISTS (SELECT 1 FROM organisations WHERE slug = p_slug)
    AND p_slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'
    AND p_slug <> ALL(ARRAY['tmc','admin','api','app','www','mail','support','billing','help','demo','test','staging','prod','production']);
$$;

GRANT EXECUTE ON FUNCTION check_slug_available(text) TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- 5. handle_new_user() trigger update
--    New signups get role='no_access', active=FALSE, org_id=NULL
--    (They must call create_workspace or join_workspace before accessing data)
--    Only update if it hasn't already been set by block_new_signups_pending_approval.sql
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email, full_name, role, active, org_id)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)),
    'no_access',
    false,
    NULL   -- org_id set by create_workspace() or join_workspace()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;
