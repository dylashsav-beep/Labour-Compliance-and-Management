import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — Stripe subscription webhook ────────────────────────────────
// Sole writer of worker_accounts.plan / plan_expires / stripe_subscription_id.
// Handles the subscription lifecycle and flips the worker between 'free' and
// 'vault'. verify_jwt = false (Stripe sends no Supabase JWT) — security is the
// REQUIRED Stripe-Signature HMAC check below. A missing/invalid signature is
// rejected (never skipped).

const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const WEBHOOK_SECRET = Deno.env.get('STRIPE_WEBHOOK_SECRET')!

// Stripe requires a 2xx or it retries; we still verify before acting.
function ok(body = 'ok') { return new Response(body, { status: 200, headers: { 'Content-Type': 'text/plain' } }) }
function bad(msg: string, status = 400) { return new Response(msg, { status }) }

// ── Stripe signature verification (HMAC-SHA256 over `${t}.${payload}`) ─────────
// Header: `t=<unix>,v1=<hex>` (possibly multiple v1=). We recompute and compare.
async function verifyStripe(payload: string, header: string | null): Promise<boolean> {
  if (!header || !WEBHOOK_SECRET) return false
  const parts = Object.fromEntries(
    header.split(',').map(kv => { const i = kv.indexOf('='); return [kv.slice(0, i), kv.slice(i + 1)] })
  ) as Record<string, string>
  const t = parts['t']
  const v1 = parts['v1']
  if (!t || !v1) return false

  // Reject stale timestamps (>5 min) to blunt replay attacks.
  const age = Math.abs(Date.now() / 1000 - Number(t))
  if (!Number.isFinite(age) || age > 300) return false

  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(WEBHOOK_SECRET),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  )
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${payload}`))
  const expected = [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, '0')).join('')
  // constant-time-ish compare
  if (expected.length !== v1.length) return false
  let diff = 0
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ v1.charCodeAt(i)
  return diff === 0
}

const sb = createClient(SUPABASE_URL, SERVICE_KEY)

// Resolve the worker_accounts row id from a Stripe object's metadata/customer.
async function resolveAccountId(obj: any): Promise<string | null> {
  const fromMeta = obj?.metadata?.worker_account_id
  if (fromMeta) return fromMeta
  const customer = obj?.customer
  if (customer) {
    const { data } = await sb.from('worker_accounts')
      .select('id').eq('stripe_customer_id', customer).maybeSingle()
    if (data?.id) return data.id
  }
  return null
}

async function applySubscription(sub: any) {
  const accountId = await resolveAccountId(sub)
  if (!accountId) return
  const active = sub.status === 'active' || sub.status === 'trialing'
  const plan = active ? 'vault' : 'free'
  const expires = sub.current_period_end
    ? new Date(sub.current_period_end * 1000).toISOString()
    : null
  await sb.from('worker_accounts').update({
    plan,
    plan_expires: expires,
    stripe_subscription_id: sub.id,
    stripe_customer_id: sub.customer || undefined,
  }).eq('id', accountId)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return bad('Method not allowed', 405)

  const payload = await req.text()
  const sigHeader = req.headers.get('stripe-signature')

  // REQUIRED signature check — missing header is treated as invalid.
  if (!(await verifyStripe(payload, sigHeader))) {
    return bad('Invalid signature', 401)
  }

  let event: any
  try { event = JSON.parse(payload) } catch { return bad('Bad JSON', 400) }

  try {
    const obj = event?.data?.object
    switch (event.type) {
      case 'checkout.session.completed': {
        // Subscription id may need expansion; fetch the subscription if present.
        if (obj?.mode === 'subscription' && obj?.subscription) {
          const accountId = await resolveAccountId(obj)
          if (accountId) {
            await sb.from('worker_accounts').update({
              stripe_subscription_id: obj.subscription,
              stripe_customer_id: obj.customer || undefined,
            }).eq('id', accountId)
          }
        }
        break
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
        await applySubscription(obj)
        break
      case 'customer.subscription.deleted': {
        const accountId = await resolveAccountId(obj)
        if (accountId) {
          await sb.from('worker_accounts').update({
            plan: 'free',
            plan_expires: obj?.current_period_end
              ? new Date(obj.current_period_end * 1000).toISOString() : null,
          }).eq('id', accountId)
        }
        break
      }
      default:
        // ignore other event types
        break
    }
  } catch (e) {
    // Log but still ACK — Stripe retries on non-2xx; we don't want infinite loops
    // on a transient DB hiccup once the signature is already verified.
    console.error('[stripe-worker-webhook]', (e as Error).message)
  }

  return ok()
})
