-- ── Leads / lightweight sales CRM ────────────────────────────────────────────
-- Tracks potential customers captured from the marketing site (trial requests
-- and demo try-outs). NOT a sign-in / auth mechanism — purely interest tracking.
-- Surfaced in admin.html "Leads" tab (super-admin only).
--
-- Capture is via the anon-callable SECURITY DEFINER capture_lead() RPC.
-- All reads/management go through admin_* RPCs gated to the super-admin email.
-- RLS is admin-only so the anon key can never read the lead list directly.

CREATE TABLE IF NOT EXISTS leads (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text,
  company           text,
  email             text,
  phone             text,
  source            text NOT NULL DEFAULT 'trial_request'
                      CHECK (source IN ('trial_request','demo','manual','contact')),
  interest          text,          -- free text: workers band, message, etc.
  status            text NOT NULL DEFAULT 'new'
                      CHECK (status IN ('new','contacted','qualified','trial','won','lost')),
  owner_note        text,          -- super-admin's freeform working note
  last_contacted_at timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS leads_status_idx     ON leads (status);
CREATE INDEX IF NOT EXISTS leads_created_at_idx ON leads (created_at DESC);
CREATE INDEX IF NOT EXISTS leads_email_idx      ON leads (lower(email));

CREATE TABLE IF NOT EXISTS lead_notes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id    uuid NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  body       text NOT NULL,
  author     text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lead_notes_lead_idx ON lead_notes (lead_id, created_at DESC);

ALTER TABLE leads      ENABLE ROW LEVEL SECURITY;
ALTER TABLE lead_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "leads_admin_only" ON leads;
CREATE POLICY "leads_admin_only" ON leads FOR ALL
  USING ((SELECT email FROM auth.users WHERE id = auth.uid()) = 'dylashsav@gmail.com');

DROP POLICY IF EXISTS "lead_notes_admin_only" ON lead_notes;
CREATE POLICY "lead_notes_admin_only" ON lead_notes FOR ALL
  USING ((SELECT email FROM auth.users WHERE id = auth.uid()) = 'dylashsav@gmail.com');

-- ── capture_lead — anon-callable public capture (dedupe by email) ─────────────
CREATE OR REPLACE FUNCTION public.capture_lead(
  p_name     text DEFAULT NULL,
  p_company  text DEFAULT NULL,
  p_email    text DEFAULT NULL,
  p_phone    text DEFAULT NULL,
  p_source   text DEFAULT 'trial_request',
  p_interest text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id     uuid;
  v_source text := COALESCE(NULLIF(p_source,''), 'trial_request');
BEGIN
  IF v_source NOT IN ('trial_request','demo','manual','contact') THEN
    v_source := 'trial_request';
  END IF;

  -- Dedupe by email: update the most recent existing lead instead of piling
  -- up duplicates every time someone clicks "Try demo".
  IF p_email IS NOT NULL AND p_email <> '' THEN
    SELECT id INTO v_id FROM leads
    WHERE lower(email) = lower(p_email)
    ORDER BY created_at DESC LIMIT 1;
  END IF;

  IF v_id IS NOT NULL THEN
    UPDATE leads SET
      name       = COALESCE(NULLIF(p_name,''),    name),
      company    = COALESCE(NULLIF(p_company,''), company),
      phone      = COALESCE(NULLIF(p_phone,''),   phone),
      interest   = COALESCE(NULLIF(p_interest,''),interest),
      -- a fresh trial request from an existing demo lead upgrades the source
      source     = CASE WHEN v_source = 'trial_request' THEN 'trial_request' ELSE source END,
      updated_at = now()
    WHERE id = v_id;
    RETURN v_id;
  END IF;

  INSERT INTO leads (name, company, email, phone, source, interest)
  VALUES (NULLIF(p_name,''), NULLIF(p_company,''), NULLIF(p_email,''), NULLIF(p_phone,''), v_source, NULLIF(p_interest,''))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.capture_lead(text,text,text,text,text,text) TO anon, authenticated;

-- ── admin_get_leads ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_leads(p_search text DEFAULT NULL, p_status text DEFAULT NULL)
RETURNS SETOF json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN RAISE EXCEPTION 'not_authorized'; END IF;
  RETURN QUERY
  SELECT json_build_object(
    'id', l.id, 'name', l.name, 'company', l.company, 'email', l.email, 'phone', l.phone,
    'source', l.source, 'interest', l.interest, 'status', l.status, 'owner_note', l.owner_note,
    'last_contacted_at', l.last_contacted_at, 'created_at', l.created_at, 'updated_at', l.updated_at,
    'note_count', (SELECT COUNT(*) FROM lead_notes n WHERE n.lead_id = l.id)
  )
  FROM leads l
  WHERE (p_status IS NULL OR p_status = '' OR l.status = p_status)
    AND (p_search IS NULL OR p_search = ''
         OR l.name ILIKE '%'||p_search||'%' OR l.company ILIKE '%'||p_search||'%'
         OR l.email ILIKE '%'||p_search||'%')
  ORDER BY l.updated_at DESC;
END; $$;

-- ── admin_get_lead_detail ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_lead_detail(p_lead_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller text; v_lead json; v_notes json;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT json_build_object(
    'id', l.id, 'name', l.name, 'company', l.company, 'email', l.email, 'phone', l.phone,
    'source', l.source, 'interest', l.interest, 'status', l.status, 'owner_note', l.owner_note,
    'last_contacted_at', l.last_contacted_at, 'created_at', l.created_at, 'updated_at', l.updated_at
  ) INTO v_lead FROM leads l WHERE l.id = p_lead_id;
  SELECT json_agg(json_build_object('id', n.id, 'body', n.body, 'author', n.author, 'created_at', n.created_at)
                  ORDER BY n.created_at DESC)
    INTO v_notes FROM lead_notes n WHERE n.lead_id = p_lead_id;
  RETURN json_build_object('lead', v_lead, 'notes', COALESCE(v_notes, '[]'::json));
END; $$;

-- ── admin_update_lead ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_lead(
  p_lead_id uuid, p_status text DEFAULT NULL, p_name text DEFAULT NULL,
  p_company text DEFAULT NULL, p_email text DEFAULT NULL, p_phone text DEFAULT NULL,
  p_owner_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN RAISE EXCEPTION 'not_authorized'; END IF;
  UPDATE leads SET
    status     = COALESCE(p_status, status),
    name       = COALESCE(p_name, name),
    company    = COALESCE(p_company, company),
    email      = COALESCE(p_email, email),
    phone      = COALESCE(p_phone, phone),
    owner_note = CASE WHEN p_owner_note IS NOT NULL THEN p_owner_note ELSE owner_note END,
    updated_at = now()
  WHERE id = p_lead_id;
END; $$;

-- ── admin_add_lead_note ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_add_lead_note(p_lead_id uuid, p_body text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller text; v_id uuid;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN RAISE EXCEPTION 'not_authorized'; END IF;
  INSERT INTO lead_notes (lead_id, body, author) VALUES (p_lead_id, p_body, v_caller) RETURNING id INTO v_id;
  -- logging a note counts as a contact touch
  UPDATE leads SET last_contacted_at = now(), updated_at = now(),
    status = CASE WHEN status = 'new' THEN 'contacted' ELSE status END
  WHERE id = p_lead_id;
  RETURN v_id;
END; $$;

-- ── admin_create_lead (manual entry) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_create_lead(
  p_name text, p_company text DEFAULT NULL, p_email text DEFAULT NULL,
  p_phone text DEFAULT NULL, p_interest text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller text; v_id uuid;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN RAISE EXCEPTION 'not_authorized'; END IF;
  INSERT INTO leads (name, company, email, phone, source, interest)
  VALUES (NULLIF(p_name,''), NULLIF(p_company,''), NULLIF(p_email,''), NULLIF(p_phone,''), 'manual', NULLIF(p_interest,''))
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

-- ── admin_delete_lead ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_delete_lead(p_lead_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller text;
BEGIN
  SELECT email INTO v_caller FROM auth.users WHERE id = auth.uid();
  IF v_caller IS DISTINCT FROM 'dylashsav@gmail.com' THEN RAISE EXCEPTION 'not_authorized'; END IF;
  DELETE FROM leads WHERE id = p_lead_id;
END; $$;
