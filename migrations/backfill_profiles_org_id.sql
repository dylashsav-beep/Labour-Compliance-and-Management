-- Backfill org_id on profiles that have NULL org_id.
-- The handle_new_user() trigger did not include org_id, so new signups
-- created after block_new_signups_pending_approval.sql was applied have
-- org_id = NULL. This also caused the admin approval to silently fail
-- because the update query was filtering .eq('org_id', SITE_ORG_ID).
--
-- The app code has been updated to no longer filter by org_id when
-- updating profiles (id is unique), but run this to make the data clean.
--
-- Safe to re-run.

UPDATE public.profiles
SET org_id = '00000000-0000-0000-0001-000000000001'
WHERE org_id IS NULL;

-- Also fix the trigger so future signups get org_id set correctly
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role, active, org_id, created_at, updated_at)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    'no_access',
    FALSE,
    '00000000-0000-0000-0001-000000000001',
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;
