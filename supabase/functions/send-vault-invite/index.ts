import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault invite email ─────────────────────────────────────────────────
// Sends a worker a branded invitation to create their personal Work Force Vault.
// Service-role client (bypasses RLS) — org ownership is verified manually:
// caller JWT → profiles.org_id → worker.org_id must match.

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const FROM       = Deno.env.get('DIGEST_FROM') || 'Work Force Vault <onboarding@resend.dev>'
const VAULT_URL  = Deno.env.get('VAULT_URL')  || 'https://work-force.nl/vault.html'

// ── BRAND — keep in sync with the BRAND object in vault.html ──────────────────
const BRAND = {
  name:         'Work Force',
  vaultName:    'Work Force Vault',
  supportEmail: 'support@work-force.nl',
  accent:       '#7c3aed',
}

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } })
}
function esc(s: string) {
  return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}

function inviteUrl(email: string): string {
  return `${VAULT_URL}?email=${encodeURIComponent(email)}`
}

function buildInviteHtml(workerName: string, orgName: string, link: string): string {
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:600px;margin:24px auto;padding:0 12px;">

  <div style="background:linear-gradient(135deg,${BRAND.accent},#1a3082);border-radius:10px 10px 0 0;padding:24px;">
    <div style="font-size:19px;font-weight:800;color:#fff;">🗂️ ${esc(BRAND.vaultName)}</div>
    <div style="font-size:12px;color:rgba(255,255,255,.85);margin-top:3px;">Your documents, owned by you</div>
  </div>

  <div style="background:#fff;padding:24px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <p style="font-size:15px;color:#1a2035;margin:0 0 6px 0;font-weight:600;">Hi ${esc(workerName)},</p>
    <p style="font-size:14px;color:#374151;margin:0 0 18px 0;line-height:1.55;">
      <strong>${esc(orgName)}</strong> has invited you to create your own free <strong>${esc(BRAND.vaultName)}</strong>
      — a personal, portable home for your compliance documents that <em>you</em> own and control.
    </p>
    <ul style="font-size:14px;color:#374151;line-height:1.7;margin:0 0 18px 0;padding-left:20px;">
      <li>See all your compliance documents and their expiry status in one place</li>
      <li>Keep your records even if you change employer</li>
      <li>Upgrade any time to download and share your documents</li>
    </ul>
    <p style="font-size:13px;color:#64748b;margin:0 0 24px 0;line-height:1.55;">
      No password needed — just enter your email and we'll send you a secure sign-in link.
    </p>

    <div style="text-align:center;margin-top:8px;padding-top:20px;border-top:1px solid #f0f4f8;">
      <a href="${esc(link)}"
         style="display:inline-block;background:${BRAND.accent};color:#fff;text-decoration:none;font-size:15px;font-weight:700;padding:14px 36px;border-radius:8px;letter-spacing:.01em;">
        Open My Vault →
      </a>
      <div style="font-size:11px;color:#94a3b8;margin-top:10px;word-break:break-all;">
        Or copy: ${esc(link)}
      </div>
    </div>
  </div>

  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">Invited by ${esc(orgName)} · ${esc(BRAND.vaultName)} · Questions? ${esc(BRAND.supportEmail)}</span>
  </div>

</div>
</body></html>`
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    // Verify caller JWT
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)

    const sb = createClient(SUPABASE_URL, SUPABASE_KEY)
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)

    // Derive caller's org from profile — never trust a caller-supplied org_id
    const { data: profile } = await sb.from('profiles').select('org_id, email').eq('id', user.id).maybeSingle()
    if (!profile?.org_id) return json({ error: 'No organisation' }, 403)
    const orgId = profile.org_id

    const body = await req.json().catch(() => ({}))
    const workerId = body?.worker_id
    if (!workerId) return json({ error: 'worker_id required' }, 400)

    // Fetch worker — must belong to caller's org (cross-org guard)
    const { data: worker } = await sb.from('workers')
      .select('id, full_name, email, org_id')
      .eq('id', workerId)
      .eq('org_id', orgId)
      .eq('active', true)
      .maybeSingle()
    if (!worker)        return json({ error: 'Worker not found' }, 404)
    if (!worker.email)  return json({ error: 'Worker has no email address on file' }, 400)

    const { data: org } = await sb.from('organisations').select('name').eq('id', orgId).maybeSingle()
    const orgName = org?.name || BRAND.name

    // Record/refresh the invite link (org-scoped). Non-fatal if it fails.
    try {
      await sb.from('worker_org_links').upsert({
        worker_row_id: worker.id,
        org_id: orgId,
        status: 'invited',
        invited_by: profile.email || null,
        invited_at: new Date().toISOString(),
      }, { onConflict: 'worker_row_id' })
    } catch (_e) { /* tracking only — ignore */ }

    // Send the branded invite email
    const link = inviteUrl(worker.email)
    const resp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM,
        to: [worker.email],
        subject: `${orgName} invited you to your ${BRAND.vaultName}`,
        html: buildInviteHtml(worker.full_name || 'there', orgName, link),
      }),
    })
    if (!resp.ok) {
      const errText = await resp.text().catch(() => '')
      return json({ error: 'Email send failed', detail: errText }, 502)
    }

    return json({ ok: true, sent_to: worker.email })
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
