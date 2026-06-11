import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — create Stripe Checkout session ─────────────────────────────
// Authenticated worker (vault.html magic-link session) clicks "Upgrade".
// This creates (or reuses) a Stripe customer for their worker_account and opens
// a subscription Checkout session. On payment, stripe-worker-webhook flips
// worker_accounts.plan -> 'vault'.
//
// Identity is ALWAYS derived from the caller JWT (auth.uid) — never a body param.

const SUPABASE_URL    = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY     = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const STRIPE_KEY      = Deno.env.get('STRIPE_SECRET_KEY')!
const VAULT_PRICE_ID  = Deno.env.get('STRIPE_VAULT_PRICE_ID')!
const VAULT_URL       = Deno.env.get('VAULT_URL') || 'https://vault.work-force.nl'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } })
}

// Stripe REST helper — form-urlencoded, Bearer secret key.
async function stripe(path: string, params: Record<string, string>) {
  const body = new URLSearchParams(params).toString()
  const resp = await fetch('https://api.stripe.com/v1/' + path, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${STRIPE_KEY}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  })
  const data = await resp.json()
  if (!resp.ok) throw new Error(data?.error?.message || `Stripe ${path} failed`)
  return data
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    if (!STRIPE_KEY || !VAULT_PRICE_ID) {
      return json({ error: 'Billing is not configured yet. Please contact support.' }, 503)
    }

    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)

    const sb = createClient(SUPABASE_URL, SERVICE_KEY)
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)

    // Read (or lazily reconcile) the worker_accounts row for this auth user.
    const { data: acct } = await sb.from('worker_accounts')
      .select('id, email, full_name, plan, stripe_customer_id')
      .eq('id', user.id)
      .maybeSingle()
    if (!acct) return json({ error: 'No vault account. Open your vault first, then upgrade.' }, 404)
    if (acct.plan === 'vault') return json({ already: true, message: 'You are already on the Vault plan.' })

    // Ensure a Stripe customer exists for this worker account.
    let customerId = acct.stripe_customer_id
    if (!customerId) {
      const cust = await stripe('customers', {
        email: acct.email || user.email || '',
        name: acct.full_name || '',
        'metadata[worker_account_id]': user.id,
      })
      customerId = cust.id
      await sb.from('worker_accounts').update({ stripe_customer_id: customerId }).eq('id', user.id)
    }

    // Create the subscription Checkout session.
    // iDEAL is converted to a SEPA Direct Debit mandate for recurring charges.
    const session = await stripe('checkout/sessions', {
      mode: 'subscription',
      customer: customerId,
      'payment_method_types[0]': 'card',
      'payment_method_types[1]': 'ideal',
      'payment_method_types[2]': 'sepa_debit',
      'line_items[0][price]': VAULT_PRICE_ID,
      'line_items[0][quantity]': '1',
      client_reference_id: user.id,
      'subscription_data[metadata][worker_account_id]': user.id,
      'metadata[worker_account_id]': user.id,
      success_url: `${VAULT_URL}/?upgraded=1`,
      cancel_url: `${VAULT_URL}/?upgrade_cancelled=1`,
      allow_promotion_codes: 'true',
    })

    return json({ url: session.url })
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
