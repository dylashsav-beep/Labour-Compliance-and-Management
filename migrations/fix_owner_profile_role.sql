-- Fix: owner profile row in Supabase has wrong role value, causing
-- wouldRemoveLastAdmin to count 0 active admins and block all role changes.
--
-- Run in Supabase → Database → SQL Editor → New query → Run

INSERT INTO public.profiles (id, email, full_name, role, active, created_at, updated_at)
SELECT id, email, COALESCE(raw_user_meta_data->>'full_name', split_part(email,'@',1)), 'admin', true, NOW(), NOW()
FROM auth.users WHERE email = 'dylan@tmconstruction.nl'
ON CONFLICT (id) DO UPDATE SET role = 'admin', active = true, updated_at = NOW();
