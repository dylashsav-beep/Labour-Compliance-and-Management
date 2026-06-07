-- =============================================================================
-- Add digest_sections JSONB to settings table
-- Run in: Supabase → Database → SQL Editor
--
-- Stores per-org digest preferences: which sections are enabled and the
-- look-ahead window (days) for time-based sections.
--
-- Multi-tenancy: settings already has RLS enabled and org-scoped policies
-- from fix_rls_rebuild_all_policies.sql (org_id = current_org_id()).
-- This migration only adds a column — no policy changes needed.
--
-- Safe to re-run (ADD COLUMN IF NOT EXISTS + WHERE digest_sections IS NULL).
-- =============================================================================

ALTER TABLE settings ADD COLUMN IF NOT EXISTS digest_sections JSONB;

-- Backfill all existing org rows with defaults (all sections on, standard thresholds).
-- New orgs created by create_workspace() will also get this default because
-- sbPersistAll stamps digest_sections when it first writes settings for a new org.
UPDATE settings
SET digest_sections = '{
  "expired_docs":            {"enabled": true},
  "expiring_docs":           {"enabled": true,  "days": 60},
  "missing_contracts":       {"enabled": true},
  "assignments_ending":      {"enabled": true,  "days": 14},
  "workers_unassigned":      {"enabled": true},
  "accommodation_ending":    {"enabled": true,  "days": 7},
  "uncharged_accommodation": {"enabled": true},
  "uncharged_vehicles":      {"enabled": true}
}'::jsonb
WHERE digest_sections IS NULL;

-- Verify — every org should now have a non-null digest_sections row.
SELECT
  s.id                                          AS org_id,
  o.name                                        AS org_name,
  s.digest_sections IS NOT NULL                 AS has_digest_sections,
  (s.digest_sections->>'expired_docs')::text    AS expired_docs,
  (s.digest_sections->>'expiring_docs')::text   AS expiring_docs
FROM settings s
LEFT JOIN organisations o ON o.id = s.id
ORDER BY o.name;
