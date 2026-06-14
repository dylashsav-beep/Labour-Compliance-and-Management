-- ── Schedule the Worker Vault reminder edge function (pg_cron) ────────────────
-- Runs daily at 08:00 UTC (one hour after the org daily-digest at 07:00).
-- The vault-reminders function creates its OWN service-role client from its
-- env vars, so the cron call only needs any valid project JWT to pass the
-- gateway's verify_jwt check — the public anon key (already shipped in the
-- client apps) is sufficient and exposes no secret. Idempotent: re-running
-- unschedules the old job first.

CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;

SELECT cron.unschedule('vault-reminders')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vault-reminders');

SELECT cron.schedule(
  'vault-reminders',
  '0 8 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://gmuyvostwcqorspgzvjv.supabase.co/functions/v1/vault-reminders',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtdXl2b3N0d2Nxb3JzcGd6dmp2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg4NTE5NjgsImV4cCI6MjA5NDQyNzk2OH0.XHzdr_9_MZXtv1UJW58y7qUq-_mhvWyb56KQi9RHfR8'
    ),
    body    := '{}'::jsonb
  );
  $$
);

SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'vault-reminders';
