-- Fix: handle_new_user trigger fails with "Database error saving new user"
--
-- Root cause: the trigger fires in the auth schema context, so without an
-- explicit search_path it cannot resolve the unqualified table name "profiles"
-- (which lives in public). The insert fails and rolls back the entire
-- auth.users insert, blocking all new user creation.
--
-- Fix: add SET search_path = public, fully-qualify the table as public.profiles,
-- and add an EXCEPTION block so a future insert error never blocks sign-up.
--
-- Run in Supabase → Database → SQL Editor → New query → Run

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role, active, created_at, updated_at)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    'viewer',
    TRUE,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never block user creation even if the profile insert fails.
  -- The app will create/repair the profile row on first login.
  RETURN NEW;
END;
$$;

-- Recreate the trigger (no-op if it already exists in the right form)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
