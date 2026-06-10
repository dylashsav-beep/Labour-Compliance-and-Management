import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — share documents by email (paid tier) ───────────────────────
// A Vault-plan worker selects documents (compliance + personal) and sends them
// to any email (new employer, accountant…). The function resolves each file
// SERVER-SIDE from the worker's own records (never a caller-supplied path),
// signs a 7-day download URL for each, and emails a branded summary that keeps
// "verified by organisation" docs visually separate from "personal/unverified".
//
// Paywall enforced server-side: non-Vault accounts get 402.

const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const FROM           = Deno.env.get('DIGEST_FROM') || 'Work Force Vault <onboarding@resend.dev>'
const BUCKET         = 'tmc-documents'
const SHARE_TTL      = 60 * 60 * 24 * 7   // 7 days

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
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}

type Resolved = { label: string; url: string; verified: boolean; expiry?: string | null }

function buildEmail(senderName: string, message: string, verified: Resolved[], personal: Resolved[]): string {
  const row = (r: Resolved) => `
    <tr>
      <td style="padding:10px 0;border-bottom:1px solid #f0f4f8;">
        <div style="font-size:14px;font-weight:600;color:#1a2035;">${esc(r.label)}</div>
        ${r.expiry ? `<div style="font-size:12px;color:#64748b;margin-top:2px;">Expires ${esc(r.expiry)}</div>` : ''}
      </td>
      <td style="padding:10px 0;border-bottom:1px solid #f0f4f8;text-align:right;">
        <a href="${esc(r.url)}" style="display:inline-block;background:${BRAND.accent};color:#fff;text-decoration:none;font-size:13px;font-weight:700;padding:8px 16px;border-radius:7px;">Download</a>
      </td>
    </tr>`
  const section = (title: string, sub: string, items: Resolved[], color: string) => items.length ? `
    <div style="margin-top:22px;">
      <div style="font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:${color};">${esc(title)}</div>
      <div style="font-size:12px;color:#94a3b8;margin:2px 0 8px;">${esc(sub)}</div>
      <table style="width:100%;border-collapse:collapse;">${items.map(row).join('')}</table>
    </div>` : ''

  return `<!DOCTYPE html><html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:600px;margin:24px auto;padding:0 12px;">
  <div style="background:linear-gradient(135deg,${BRAND.accent},#1a3082);border-radius:10px 10px 0 0;padding:24px;">
    <div style="font-size:19px;font-weight:800;color:#fff;">🗂️ ${esc(BRAND.vaultName)}</div>
    <div style="font-size:12px;color:rgba(255,255,255,.85);margin-top:3px;">Documents shared with you</div>
  </div>
  <div style="background:#fff;padding:24px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <p style="font-size:14px;color:#374151;margin:0 0 6px;line-height:1.55;">
      <strong>${esc(senderName)}</strong> has shared the documents below with you via their ${esc(BRAND.vaultName)}.
    </p>
    ${message ? `<div style="font-size:13px;color:#475569;background:#f8fafc;border:1px solid #eef2f7;border-radius:8px;padding:12px 14px;margin:12px 0;line-height:1.5;">${esc(message)}</div>` : ''}
    ${section('Compliance documents', 'Verified by the organisations the sender works with.', verified, '#166534')}
    ${section('Personal documents', 'Self-managed by the sender — NOT independently verified.', personal, '#92400e')}
    <p style="font-size:12px;color:#94a3b8;margin-top:22px;line-height:1.55;">
      These download links expire in 7 days. If a link has expired, ask the sender to share again.
    </p>
  </div>
  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">${esc(BRAND.vaultName)} · Questions? ${esc(BRAND.supportEmail)}</span>
  </div>
</div></body></html>`
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)

    const sb = createClient(SUPABASE_URL, SERVICE_KEY)
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)
    const uid = user.id

    // Paywall
    const { data: acct } = await sb.from('worker_accounts')
      .select('plan, plan_expires, full_name, email').eq('id', uid).maybeSingle()
    const expired = acct?.plan_expires && new Date(acct.plan_expires) < new Date()
    if (!acct || acct.plan !== 'vault' || expired) return json({ error: 'upgrade_required' }, 402)

    const body = await req.json().catch(() => ({}))
    const to = String(body?.to || '').trim()
    const message = String(body?.message || '').slice(0, 1000)
    const items = Array.isArray(body?.items) ? body.items : []
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return json({ error: 'A valid recipient email is required' }, 400)
    if (!items.length) return json({ error: 'Select at least one document to share' }, 400)
    if (items.length > 40) return json({ error: 'Too many documents selected' }, 400)

    // Worker's owned org rows
    const { data: links } = await sb.from('worker_org_links')
      .select('worker_row_id').eq('worker_account_id', uid).eq('status', 'active')
    const workerRowIds = (links || []).map(l => l.worker_row_id).filter(Boolean)

    async function sign(path: string, name: string): Promise<string | null> {
      const { data } = await sb.storage.from(BUCKET).createSignedUrl(path, SHARE_TTL, { download: name })
      return data?.signedUrl || null
    }

    const verified: Resolved[] = []
    const personal: Resolved[] = []

    for (const it of items) {
      let path: string | null = null, name = 'document', label = it.label || 'Document'
      let isVerified = true, expiry: string | null = null

      if (it.type === 'vault_doc') {
        const { data: vd } = await sb.from('vault_documents')
          .select('file_path, file_name, display_name, worker_account_id, active, source, expiry_date')
          .eq('id', it.vault_doc_id).maybeSingle()
        if (!vd || vd.worker_account_id !== uid || vd.active === false) continue
        path = vd.file_path; name = vd.file_name || name
        label = it.label || vd.display_name || name
        isVerified = vd.source === 'org_approved'
        expiry = vd.expiry_date

      } else if (it.type === 'document') {
        if (!workerRowIds.length) continue
        const { data: files } = await sb.from('worker_document_files')
          .select('file_path, file_name, name, doc_key, worker_id, active, superseded, created_at')
          .in('worker_id', workerRowIds).eq('doc_key', it.doc_key).eq('active', true)
          .order('created_at', { ascending: false })
        const pick = (files || []).find(f => !f.superseded) || (files || [])[0]
        if (!pick) continue
        path = pick.file_path; name = pick.file_name || pick.name || name
        isVerified = true

      } else if (it.type === 'contract') {
        if (!workerRowIds.length) continue
        const { data: asg } = await sb.from('project_assignments')
          .select('id, worker_id').eq('id', it.assignment_id).maybeSingle()
        if (!asg || !workerRowIds.includes(asg.worker_id)) continue
        const { data: cf } = await sb.from('project_assignment_files')
          .select('file_path, file_name, active, created_at')
          .eq('project_assignment_id', asg.id).eq('active', true)
          .order('created_at', { ascending: false })
        const pick = (cf || [])[0]
        if (!pick) continue
        path = pick.file_path; name = pick.file_name || 'contract'
        isVerified = true
      } else continue

      if (!path) continue
      const url = await sign(path, name)
      if (!url) continue
      ;(isVerified ? verified : personal).push({ label, url, verified: isVerified, expiry })
    }

    if (!verified.length && !personal.length) {
      return json({ error: 'None of the selected documents had a downloadable file' }, 404)
    }

    const senderName = acct.full_name || acct.email || 'A worker'
    const resp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM,
        to: [to],
        reply_to: acct.email || undefined,
        subject: `${senderName} shared documents with you`,
        html: buildEmail(senderName, message, verified, personal),
      }),
    })
    if (!resp.ok) {
      const detail = await resp.text().catch(() => '')
      return json({ error: 'Email send failed', detail }, 502)
    }

    return json({ ok: true, sent_to: to, count: verified.length + personal.length })
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
