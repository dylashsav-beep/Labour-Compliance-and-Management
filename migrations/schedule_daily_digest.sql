-- Schedule the daily compliance digest Edge Function
-- Run this in Supabase → Database → SQL Editor
--
-- Prerequisites:
--   1. pg_cron extension enabled  (Database → Extensions → pg_cron)
--   2. pg_net extension enabled   (Database → Extensions → pg_net)
--   3. RESEND_API_KEY secret added (Edge Functions → Manage secrets)
--   4. daily-digest function deployed (see deployment steps below)
--
-- Replace the two placeholders before running:
--   YOUR_PROJECT_REF  → found in Supabase → Project Settings → General → Reference ID
--   YOUR_SERVICE_ROLE_KEY → found in Supabase → Project Settings → API → service_role key

-- Enable pg_net so pg_cron can make HTTP calls
CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;

-- Remove any existing schedule with this name before re-creating
SELECT cron.unschedule('tmc-daily-digest') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'tmc-daily-digest'
);

-- Schedule: every day at 07:00 UTC
SELECT cron.schedule(
  'tmc-daily-digest',
  '0 7 * * *',
  $$
  SELECT extensions.http_post(
    url     := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/daily-digest',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer YOUR_SERVICE_ROLE_KEY'
    ),
    body    := '{}'::jsonb
  );
  $$
);

-- Verify the schedule was created
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'tmc-daily-digest';
