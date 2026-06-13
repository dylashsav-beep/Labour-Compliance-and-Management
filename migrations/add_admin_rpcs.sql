-- ── Super-Admin RPCs ─────────────────────────────────────────────────────────
-- All functions are SECURITY DEFINER (bypass RLS) and hard-gated on the
-- super-admin email. Any other caller receives 'not_authorized'.

-- ── helper macro (inlined in each function) ──────────────────────────────────
-- IF (SELECT email FROM auth.users WHERE id = auth.uid()) != 'dylashsav@gmail.com'
-- THEN RAISE EXCEPTION 'not_authorized'; END IF;

-- ── admin_get_stats ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_stats()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  RETURN (
    SELECT json_build_object(
      'total_orgs',      (SELECT COUNT(*) FROM organisations),
      'trial_orgs',      (SELECT COUNT(*) FROM organisations WHERE plan = 'trial' AND (trial_ends IS NULL OR trial_ends > now())),
      'paid_orgs',       (SELECT COUNT(*) FROM organisations WHERE plan IN ('starter','growth','enterprise')),
      'suspended_orgs',  (SELECT COUNT(*) FROM organisations WHERE plan = 'suspended'),
      'expired_trials',  (SELECT COUNT(*) FROM organisations WHERE plan = 'trial' AND trial_ends IS NOT NULL AND trial_ends < now()),
      'total_workers',   (SELECT COUNT(*) FROM worker_accounts),
      'paid_workers',    (SELECT COUNT(*) FROM worker_accounts WHERE plan = 'vault' AND (plan_expires IS NULL OR plan_expires > now())),
      'total_profiles',  (SELECT COUNT(*) FROM profiles WHERE active = true AND role != 'no_access')
    )
  );
END;
$$;

-- ── admin_get_orgs ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_orgs(p_search text DEFAULT NULL)
RETURNS SETOF json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  RETURN QUERY
  SELECT json_build_object(
    'id',                   o.id,
    'name',                 o.name,
    'slug',                 o.slug,
    'plan',                 o.plan,
    'trial_ends',           o.trial_ends,
    'plan_started',         o.plan_started,
    'plan_ends',            o.plan_ends,
    'owner_email',          o.owner_email,
    'compliance_email',     o.compliance_email,
    'max_workers',          o.max_workers,
    'stripe_customer_id',   o.stripe_customer_id,
    'stripe_subscription_id', o.stripe_subscription_id,
    'created_at',           o.created_at,
    'member_count',         (SELECT COUNT(*) FROM profiles p WHERE p.org_id = o.id AND p.active = true),
    'worker_count',         (SELECT COUNT(*) FROM workers w WHERE w.org_id = o.id AND w.active = true)
  )
  FROM organisations o
  WHERE (
    p_search IS NULL
    OR o.name ILIKE '%' || p_search || '%'
    OR o.slug ILIKE '%' || p_search || '%'
    OR o.owner_email ILIKE '%' || p_search || '%'
  )
  ORDER BY o.created_at DESC;
END;
$$;

-- ── admin_get_org_detail ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_org_detail(p_org_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
  v_org    json;
  v_members json;
  v_payments json;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  SELECT json_build_object(
    'id',                   o.id,
    'name',                 o.name,
    'slug',                 o.slug,
    'plan',                 o.plan,
    'trial_ends',           o.trial_ends,
    'plan_started',         o.plan_started,
    'plan_ends',            o.plan_ends,
    'owner_email',          o.owner_email,
    'compliance_email',     o.compliance_email,
    'max_workers',          o.max_workers,
    'stripe_customer_id',   o.stripe_customer_id,
    'stripe_subscription_id', o.stripe_subscription_id,
    'created_at',           o.created_at,
    'worker_count',         (SELECT COUNT(*) FROM workers w WHERE w.org_id = o.id AND w.active = true)
  )
  INTO v_org
  FROM organisations o
  WHERE o.id = p_org_id;

  SELECT json_agg(json_build_object(
    'id',        p.id,
    'email',     p.email,
    'full_name', p.full_name,
    'role',      p.role,
    'active',    p.active,
    'created_at', p.created_at
  ) ORDER BY p.created_at)
  INTO v_members
  FROM profiles p
  WHERE p.org_id = p_org_id;

  SELECT json_agg(json_build_object(
    'id',                 pl.id,
    'amount',             pl.amount,
    'currency',           pl.currency,
    'method',             pl.method,
    'stripe_payment_id',  pl.stripe_payment_id,
    'notes',              pl.notes,
    'paid_at',            pl.paid_at,
    'recorded_by',        pl.recorded_by
  ) ORDER BY pl.paid_at DESC)
  INTO v_payments
  FROM payment_log pl
  WHERE pl.entity_type = 'org' AND pl.entity_id = p_org_id;

  RETURN json_build_object(
    'org',      v_org,
    'members',  COALESCE(v_members, '[]'::json),
    'payments', COALESCE(v_payments, '[]'::json)
  );
END;
$$;

-- ── admin_update_org ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_org(
  p_org_id                  uuid,
  p_plan                    text        DEFAULT NULL,
  p_trial_ends              timestamptz DEFAULT NULL,
  p_max_workers             int         DEFAULT NULL,
  p_owner_email             text        DEFAULT NULL,
  p_compliance_email        text        DEFAULT NULL,
  p_stripe_customer_id      text        DEFAULT NULL,
  p_stripe_subscription_id  text        DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  UPDATE organisations SET
    plan                    = COALESCE(p_plan,                    plan),
    trial_ends              = CASE WHEN p_trial_ends IS NOT NULL THEN p_trial_ends ELSE trial_ends END,
    max_workers             = COALESCE(p_max_workers,             max_workers),
    owner_email             = COALESCE(p_owner_email,             owner_email),
    compliance_email        = COALESCE(p_compliance_email,        compliance_email),
    stripe_customer_id      = CASE WHEN p_stripe_customer_id      IS NOT NULL THEN NULLIF(p_stripe_customer_id,'')      ELSE stripe_customer_id END,
    stripe_subscription_id  = CASE WHEN p_stripe_subscription_id  IS NOT NULL THEN NULLIF(p_stripe_subscription_id,'')  ELSE stripe_subscription_id END
  WHERE id = p_org_id;
END;
$$;

-- ── admin_get_workers ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_workers(p_search text DEFAULT NULL)
RETURNS SETOF json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  RETURN QUERY
  SELECT json_build_object(
    'id',                   wa.id,
    'email',                wa.email,
    'full_name',            wa.full_name,
    'plan',                 wa.plan,
    'plan_expires',         wa.plan_expires,
    'stripe_customer_id',   wa.stripe_customer_id,
    'stripe_subscription_id', wa.stripe_subscription_id,
    'created_at',           wa.created_at,
    'linked_org_count',     (SELECT COUNT(*) FROM worker_org_links wol WHERE wol.worker_account_id = wa.id AND wol.status = 'active'),
    'linked_org_names',     (
      SELECT json_agg(o.name ORDER BY o.name)
      FROM worker_org_links wol
      JOIN organisations o ON o.id = wol.org_id
      WHERE wol.worker_account_id = wa.id AND wol.status = 'active'
    )
  )
  FROM worker_accounts wa
  WHERE (
    p_search IS NULL
    OR wa.email ILIKE '%' || p_search || '%'
    OR wa.full_name ILIKE '%' || p_search || '%'
  )
  ORDER BY wa.created_at DESC;
END;
$$;

-- ── admin_get_worker_detail ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_worker_detail(p_worker_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller  text;
  v_worker  json;
  v_links   json;
  v_payments json;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  SELECT json_build_object(
    'id',                   wa.id,
    'email',                wa.email,
    'full_name',            wa.full_name,
    'plan',                 wa.plan,
    'plan_expires',         wa.plan_expires,
    'stripe_customer_id',   wa.stripe_customer_id,
    'stripe_subscription_id', wa.stripe_subscription_id,
    'created_at',           wa.created_at
  )
  INTO v_worker
  FROM worker_accounts wa
  WHERE wa.id = p_worker_id;

  SELECT json_agg(json_build_object(
    'id',              wol.id,
    'org_id',          wol.org_id,
    'org_name',        o.name,
    'worker_row_id',   wol.worker_row_id,
    'worker_name',     w.full_name,
    'status',          wol.status,
    'invited_at',      wol.invited_at,
    'linked_at',       wol.linked_at
  ) ORDER BY wol.linked_at DESC NULLS LAST)
  INTO v_links
  FROM worker_org_links wol
  JOIN organisations o ON o.id = wol.org_id
  LEFT JOIN workers w ON w.id = wol.worker_row_id
  WHERE wol.worker_account_id = p_worker_id;

  SELECT json_agg(json_build_object(
    'id',                pl.id,
    'amount',            pl.amount,
    'currency',          pl.currency,
    'method',            pl.method,
    'stripe_payment_id', pl.stripe_payment_id,
    'notes',             pl.notes,
    'paid_at',           pl.paid_at,
    'recorded_by',       pl.recorded_by
  ) ORDER BY pl.paid_at DESC)
  INTO v_payments
  FROM payment_log pl
  WHERE pl.entity_type = 'worker' AND pl.entity_id = p_worker_id;

  RETURN json_build_object(
    'worker',   v_worker,
    'links',    COALESCE(v_links, '[]'::json),
    'payments', COALESCE(v_payments, '[]'::json)
  );
END;
$$;

-- ── admin_update_worker ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_worker(
  p_worker_id              uuid,
  p_plan                   text        DEFAULT NULL,
  p_plan_expires           timestamptz DEFAULT NULL,
  p_stripe_customer_id     text        DEFAULT NULL,
  p_stripe_subscription_id text        DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  UPDATE worker_accounts SET
    plan                   = COALESCE(p_plan,         plan),
    plan_expires           = CASE WHEN p_plan_expires IS NOT NULL THEN p_plan_expires ELSE plan_expires END,
    stripe_customer_id     = CASE WHEN p_stripe_customer_id     IS NOT NULL THEN NULLIF(p_stripe_customer_id,'')     ELSE stripe_customer_id END,
    stripe_subscription_id = CASE WHEN p_stripe_subscription_id IS NOT NULL THEN NULLIF(p_stripe_subscription_id,'') ELSE stripe_subscription_id END
  WHERE id = p_worker_id;
END;
$$;

-- ── admin_update_member ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_member(
  p_profile_id uuid,
  p_role       text    DEFAULT NULL,
  p_active     boolean DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  UPDATE profiles SET
    role   = COALESCE(p_role,   role),
    active = COALESCE(p_active, active)
  WHERE id = p_profile_id;
END;
$$;

-- ── admin_move_member_org ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_move_member_org(
  p_profile_id uuid,
  p_new_org_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  UPDATE profiles SET org_id = p_new_org_id WHERE id = p_profile_id;
END;
$$;

-- ── admin_log_payment ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_log_payment(
  p_entity_type text,
  p_entity_id   uuid,
  p_amount      numeric,
  p_currency    text    DEFAULT 'EUR',
  p_notes       text    DEFAULT NULL,
  p_paid_at     timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
  v_id     uuid;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  INSERT INTO payment_log (entity_type, entity_id, amount, currency, method, notes, paid_at, recorded_by)
  VALUES (p_entity_type, p_entity_id, p_amount, p_currency, 'manual', p_notes, p_paid_at, v_caller)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ── admin_get_payment_log ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_payment_log(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS SETOF json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  RETURN QUERY
  SELECT json_build_object(
    'id',                pl.id,
    'amount',            pl.amount,
    'currency',          pl.currency,
    'method',            pl.method,
    'stripe_payment_id', pl.stripe_payment_id,
    'notes',             pl.notes,
    'paid_at',           pl.paid_at,
    'recorded_by',       pl.recorded_by
  )
  FROM payment_log pl
  WHERE pl.entity_type = p_entity_type AND pl.entity_id = p_entity_id
  ORDER BY pl.paid_at DESC;
END;
$$;

-- ── admin_create_org ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_create_org(
  p_slug        text,
  p_name        text,
  p_owner_email text,
  p_plan        text        DEFAULT 'trial',
  p_trial_ends  timestamptz DEFAULT (now() + interval '30 days'),
  p_max_workers int         DEFAULT 25
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
  v_org_id uuid;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  IF EXISTS (SELECT 1 FROM organisations WHERE slug = p_slug) THEN
    RAISE EXCEPTION 'slug_taken';
  END IF;

  INSERT INTO organisations (name, slug, owner_email, plan, trial_ends, max_workers)
  VALUES (p_name, p_slug, p_owner_email, p_plan, p_trial_ends, p_max_workers)
  RETURNING id INTO v_org_id;

  INSERT INTO settings (id) VALUES (v_org_id) ON CONFLICT DO NOTHING;

  RETURN v_org_id;
END;
$$;

-- ── admin_suspend_org ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_suspend_org(
  p_org_id    uuid,
  p_suspended boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  UPDATE organisations SET
    plan = CASE WHEN p_suspended THEN 'suspended' ELSE 'trial' END
  WHERE id = p_org_id;
END;
$$;
