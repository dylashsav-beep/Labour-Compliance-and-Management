import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Super-Admin Action Edge Function ──────────────────────────────────────────
// Gated hard to dylashsav@gmail.com. Handles three actions:
//   send_magic_link     — generates a Supabase magic link and emails it
//   send_payment_reminder — sends a branded payment reminder email
//   send_custom_message — sends a freeform email to any address
//
// Uses SERVICE_ROLE_KEY (never exposed to browser) for Admin Auth API calls.

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const RESEND_KEY    = Deno.env.get('RESEND_API_KEY')!
const FROM          = Deno.env.get('DIGEST_FROM') || 'Work Force <onboarding@resend.dev>'
const APP_URL       = 'https://work-force.nl/app.html'
const VAULT_URL     = 'https://work-force.nl/vault.html'
const ADMIN_EMAIL   = 'dylashsav@gmail.com'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  })
}
function esc(s: string) {
  return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

async function sendEmail(to: string, subject: string, html: string) {
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${RESEND_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ from: FROM, to, subject, html }),
  })
  const data = await res.json()
  if (!res.ok) throw new Error(data?.message || `Resend error ${res.status}`)
  return data
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    // Verify JWT and check super-admin email
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)

    const sb = createClient(SUPABASE_URL, SERVICE_KEY)
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)
    if (user.email !== ADMIN_EMAIL) return json({ error: 'Forbidden' }, 403)

    const body = await req.json().catch(() => ({}))
    const { action, payload } = body

    // ── send_magic_link ───────────────────────────────────────────────────────
    if (action === 'send_magic_link') {
      const { email, type, name } = payload || {}
      if (!email) return json({ error: 'email required' }, 400)

      const redirectTo = type === 'worker' ? VAULT_URL : APP_URL

      // Use Supabase Admin API to generate a magic link
      const genRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${SERVICE_KEY}`,
          'Content-Type': 'application/json',
          'apikey': SERVICE_KEY,
        },
        body: JSON.stringify({
          type: 'magiclink',
          email,
          options: { redirect_to: redirectTo },
        }),
      })
      const genData = await genRes.json()
      if (!genRes.ok) throw new Error(genData?.message || 'Failed to generate magic link')

      const link = genData.action_link || genData.properties?.action_link
      if (!link) throw new Error('No action_link in response')

      const destination = type === 'worker' ? 'Worker Vault' : 'Management Portal'
      const html = `<!DOCTYPE html><html><head><meta charset="utf-8"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:560px;margin:32px auto;padding:0 16px;">
  <div style="background:#1a2035;border-radius:10px 10px 0 0;padding:28px 32px;">
    <div style="font-size:20px;font-weight:700;color:#fff;">Work Force</div>
    <div style="font-size:12px;color:#94a3b8;margin-top:3px;">${esc(destination)}</div>
  </div>
  <div style="background:#fff;padding:32px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <p style="font-size:15px;color:#1a2340;margin:0 0 8px;font-weight:600;">Hi${name ? ` ${esc(name)}` : ''},</p>
    <p style="font-size:14px;color:#4a5568;margin:0 0 28px;line-height:1.6;">
      Click the button below to sign in to your ${esc(destination)}. This link expires in 1 hour and can only be used once.
    </p>
    <div style="text-align:center;margin-bottom:28px;">
      <a href="${esc(link)}" style="display:inline-block;background:#7c3aed;color:#fff;text-decoration:none;font-size:15px;font-weight:600;padding:14px 36px;border-radius:8px;">
        Sign in to ${esc(destination)} →
      </a>
    </div>
    <p style="font-size:11px;color:#94a3b8;margin:0;text-align:center;word-break:break-all;">
      Or copy this link: ${esc(link)}
    </p>
  </div>
  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">Work Force · Do not reply to this email</span>
  </div>
</div></body></html>`

      await sendEmail(email, `Your sign-in link for Work Force ${destination}`, html)
      return json({ ok: true, sent_to: email })
    }

    // ── send_payment_reminder ─────────────────────────────────────────────────
    if (action === 'send_payment_reminder') {
      const { email, name, amount, currency, due_date, plan_name, notes } = payload || {}
      if (!email || !amount) return json({ error: 'email and amount required' }, 400)

      const curr = currency || 'EUR'
      const symbol = curr === 'EUR' ? '€' : curr === 'GBP' ? '£' : '$'
      const dueTxt = due_date
        ? new Date(due_date).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
        : 'as soon as possible'

      const html = `<!DOCTYPE html><html><head><meta charset="utf-8"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:560px;margin:32px auto;padding:0 16px;">
  <div style="background:#1a2035;border-radius:10px 10px 0 0;padding:28px 32px;">
    <div style="font-size:20px;font-weight:700;color:#fff;">Work Force</div>
    <div style="font-size:12px;color:#94a3b8;margin-top:3px;">Payment Reminder</div>
  </div>
  <div style="background:#fff;padding:32px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <p style="font-size:15px;color:#1a2340;margin:0 0 8px;font-weight:600;">Hi${name ? ` ${esc(name)}` : ''},</p>
    <p style="font-size:14px;color:#4a5568;margin:0 0 24px;line-height:1.6;">
      This is a friendly reminder that a payment is due for your Work Force${plan_name ? ` ${esc(plan_name)}` : ''} subscription.
    </p>
    <div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:10px;padding:20px 24px;margin-bottom:24px;">
      <div style="display:flex;justify-content:space-between;margin-bottom:8px;">
        <span style="font-size:13px;color:#64748b;">Amount due</span>
        <span style="font-size:16px;font-weight:700;color:#1a2340;">${symbol}${Number(amount).toFixed(2)} ${curr}</span>
      </div>
      <div style="display:flex;justify-content:space-between;">
        <span style="font-size:13px;color:#64748b;">Due date</span>
        <span style="font-size:13px;font-weight:600;color:#c53030;">${esc(dueTxt)}</span>
      </div>
    </div>
    ${notes ? `<p style="font-size:13px;color:#64748b;margin:0 0 24px;line-height:1.6;">${esc(notes)}</p>` : ''}
    <p style="font-size:13px;color:#4a5568;margin:0;line-height:1.6;">
      To arrange payment or if you have any questions, please reply to this email or contact us at
      <a href="mailto:sales@work-force.nl" style="color:#7c3aed;">sales@work-force.nl</a>.
    </p>
  </div>
  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">Work Force · Labour Compliance &amp; Management</span>
  </div>
</div></body></html>`

      await sendEmail(email, `Payment reminder — ${symbol}${Number(amount).toFixed(2)} due ${dueTxt}`, html)
      return json({ ok: true, sent_to: email })
    }

    // ── send_custom_message ───────────────────────────────────────────────────
    if (action === 'send_custom_message') {
      const { email, subject, message } = payload || {}
      if (!email || !subject || !message) return json({ error: 'email, subject and message required' }, 400)

      const html = `<!DOCTYPE html><html><head><meta charset="utf-8"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:560px;margin:32px auto;padding:0 16px;">
  <div style="background:#1a2035;border-radius:10px 10px 0 0;padding:28px 32px;">
    <div style="font-size:20px;font-weight:700;color:#fff;">Work Force</div>
  </div>
  <div style="background:#fff;padding:32px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <div style="font-size:14px;color:#4a5568;line-height:1.7;white-space:pre-wrap;">${esc(message)}</div>
  </div>
  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">Work Force · Do not reply to this email</span>
  </div>
</div></body></html>`

      await sendEmail(email, subject, html)
      return json({ ok: true, sent_to: email })
    }

    return json({ error: `Unknown action: ${action}` }, 400)
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
