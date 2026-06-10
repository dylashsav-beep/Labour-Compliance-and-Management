-- =============================================================================
-- Worker Vault — Phase 2: Stripe billing index
-- Run in: Supabase → Database → SQL Editor
-- Run AFTER add_worker_vault.sql
--
-- The Stripe columns themselves (plan, plan_expires, stripe_customer_id,
-- stripe_subscription_id) already exist on worker_accounts from
-- add_worker_vault.sql — no new columns are needed for Phase 2.
--
-- This adds an index so stripe-worker-webhook can resolve a worker_account from
-- a Stripe customer id quickly when subscription events arrive without metadata.
--
-- Safe to re-run.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_worker_accounts_stripe_customer
  ON worker_accounts (stripe_customer_id)
  WHERE stripe_customer_id IS NOT NULL;
