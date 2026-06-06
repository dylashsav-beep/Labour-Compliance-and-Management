-- Require admin approval before new signups get any access.
--
-- PROBLEM
--   The handle_new_user() trigger (created in tmc_full_schema.sql) sets
--   role='viewer' and active=TRUE for every new signup. This gives immediate
--   read access to the dashboard to anyone who creates an account.
--
-- FIX
--   Set role='no_access' and active=FALSE by default. The app already has
--   a "pending approval" screen that shows for no_access / inactive users;
--   this migration activates that flow for all new signups.
--
--   To approve a user: Settings → Users → find the pending account → click
--   "Quick Approve" (sets viewer role + active) or choose a specific role.
--
-- EXISTING USERS
--   Only affects NEW signups. Existing accounts are untouched.
--
-- SAFE TO RE-RUN: the trigger function is replaced with CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role, active, created_at, updated_at)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    'no_access',   -- changed from 'viewer' — requires admin approval
    FALSE,         -- changed from TRUE  — account inactive until approved
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never fail a signup due to profile creation issues
  RETURN NEW;
END;
$$;

-- Verify the trigger still points to the right function
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- Verify: should show handle_new_user on auth.users
SELECT trigger_name, event_manipulation, event_object_table, action_statement
FROM information_schema.triggers
WHERE trigger_name = 'on_auth_user_created';
