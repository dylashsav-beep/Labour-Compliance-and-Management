import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — create Stripe Billing Portal session ───────────────────────
// Authenticated worker opens the hosted Stripe portal to update card, view
// invoices, or cancel their Vault subscription. Identity from JWT only.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const STRIPE_KEY   = Deno.env.get('STRIPE_SECRET_KEY')!
const VAULT_URL    = Deno.env.get('VAULT_URL') || 'https://work-force.nl/vault.html'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } })
}

async function stripe(path: string, params: Record<string, string>) {
  const resp = await fetch('https://api.stripe.com/v1/' + path, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${STRIPE_KEY}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams(params).toString(),
  })
  const data = await resp.json()
  if (!resp.ok) throw new Error(data?.error?.message || `Stripe ${path} failed`)
  return data
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    if (!STRIPE_KEY) return json({ error: 'Billing is not configured yet.' }, 503)

    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)

    const sb = createClient(SUPABASE_URL, SERVICE_KEY)
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)

    const { data: acct } = await sb.from('worker_accounts')
      .select('stripe_customer_id')
      .eq('id', user.id)
      .maybeSingle()
    if (!acct?.stripe_customer_id) {
      return json({ error: 'No billing account yet. Upgrade to Vault first.' }, 400)
    }

    const session = await stripe('billing_portal/sessions', {
      customer: acct.stripe_customer_id,
      return_url: VAULT_URL,
    })

    return json({ url: session.url })
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
