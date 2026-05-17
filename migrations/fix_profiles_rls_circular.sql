-- Fix: profiles RLS policies use a circular self-referencing subquery.
-- To check if the current user is admin, the policy queries profiles —
-- but querying profiles requires the SELECT policy to pass, which runs
-- the same subquery. Supabase resolves this as NULL, so the admin check
-- always fails silently and updates/selects by admin are blocked.
--
-- Fix: create a SECURITY DEFINER function that reads profiles as the
-- function owner (bypassing RLS), then reference it in all policies.
--
-- Run in Supabase → Database → SQL Editor → New query → Run

-- Step 1: helper function that bypasses RLS to check admin status
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND role = 'admin'
      AND active = TRUE
  );
$$;

-- Step 2: drop and recreate profiles policies using the function
DROP POLICY IF EXISTS profiles_select ON public.profiles;
DROP POLICY IF EXISTS profiles_insert ON public.profiles;
DROP POLICY IF EXISTS profiles_update ON public.profiles;

CREATE POLICY profiles_select ON public.profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.is_admin());

CREATE POLICY profiles_insert ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid() OR public.is_admin());

CREATE POLICY profiles_update ON public.profiles
  FOR UPDATE TO authenticated
  USING      (id = auth.uid() OR public.is_admin())
  WITH CHECK (id = auth.uid() OR public.is_admin());
