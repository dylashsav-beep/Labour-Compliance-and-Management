import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const FROM      = Deno.env.get('DIGEST_FROM') || 'Work Force Compliance <onboarding@resend.dev>'
const SITE_URL  = Deno.env.get('SITE_URL')    || 'https://work-force.nl'
const VAULT_URL = Deno.env.get('VAULT_URL')   || 'https://work-force.nl/vault.html'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } })
}

// NOTE: Uses service-role key (bypasses RLS). Org ownership is verified
// manually: caller JWT → profiles.org_id → worker.org_id must match.

function esc(s: string) {
  return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}
function fmt(s: string) {
  return new Date(s).toLocaleDateString('en-GB', { day:'numeric', month:'short', year:'numeric' })
}
function daysUntil(dateStr: string): number {
  const now = new Date(); now.setHours(0,0,0,0)
  return Math.ceil((new Date(dateStr).setHours(0,0,0,0) - now.getTime()) / 86400000)
}

// All reminder emails now link to the vault. Workers without a vault account
// will be prompted to create one on arrival — vault.html handles unauthenticated
// visitors with a magic-link sign-in flow.
function buildPortalLink(_worker: any, _slug: string | null): string {
  return VAULT_URL
}

interface DocIssue  { name: string; date?: string; days?: number }
interface Contract  { project: string; start: string; end: string | null }

function buildWorkerEmailHtml(
  workerName: string,
  orgName: string,
  link: string,
  missing:  string[],
  expired:  DocIssue[],
  expiring: DocIssue[],
  contracts: Contract[],
  isManual: boolean,
): string {
  const totalIssues = missing.length + expired.length + expiring.length
  const hasIssues   = totalIssues > 0

  function docTable(colour: string, icon: string, title: string, rows: string[]): string {
    return `
    <div style="margin-bottom:16px;">
      <div style="background:${colour};border-radius:6px 6px 0 0;padding:10px 16px;">
        <span style="font-size:13px;font-weight:700;color:#fff;">${icon} ${esc(title)}</span>
      </div>
      <table style="width:100%;border-collapse:collapse;background:#fff;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 6px 6px;">
        <tr>
          <th style="padding:7px 16px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;background:#f8fafc;border-bottom:1px solid #e2e8f0;text-align:left;">Document</th>
          <th style="padding:7px 16px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;background:#f8fafc;border-bottom:1px solid #e2e8f0;text-align:left;">Status</th>
        </tr>
        ${rows.join('')}
      </table>
    </div>`
  }

  function docRow(name: string, statusHtml: string): string {
    return `<tr>
      <td style="padding:10px 16px;font-size:13px;color:#1a2035;border-bottom:1px solid #f0f4f8;">${esc(name)}</td>
      <td style="padding:10px 16px;font-size:13px;border-bottom:1px solid #f0f4f8;">${statusHtml}</td>
    </tr>`
  }

  const sections: string[] = []

  if (expired.length) {
    sections.push(docTable('#c53030', '⚠️', `Expired Documents (${expired.length})`,
      expired.map(d => docRow(d.name, `<span style="color:#c53030;font-weight:600;">Expired · ${fmt(d.date!)}</span>`))
    ))
  }
  if (expiring.length) {
    sections.push(docTable('#b45309', '⏰', `Expiring Soon (${expiring.length})`,
      expiring.map(d => docRow(d.name, `<span style="color:#b45309;font-weight:600;">Expires in ${d.days} day${d.days!==1?'s':''} · ${fmt(d.date!)}</span>`))
    ))
  }
  if (missing.length) {
    sections.push(docTable('#7c3aed', '📋', `Missing Documents (${missing.length})`,
      missing.map(n => docRow(n, `<span style="color:#c53030;font-weight:600;">Missing — please upload</span>`))
    ))
  }

  if (contracts.length) {
    const contractRows = contracts.map(c => `<tr>
      <td style="padding:10px 16px;font-size:13px;color:#1a2035;border-bottom:1px solid #f0f4f8;">${esc(c.project)}</td>
      <td style="padding:10px 16px;font-size:13px;color:#64748b;border-bottom:1px solid #f0f4f8;">${fmt(c.start)} – ${c.end ? fmt(c.end) : 'Ongoing'}</td>
    </tr>`).join('')
    sections.push(`
    <div style="margin-bottom:16px;">
      <div style="background:#1d4ed8;border-radius:6px 6px 0 0;padding:10px 16px;">
        <span style="font-size:13px;font-weight:700;color:#fff;">📁 Your Active Contracts (${contracts.length})</span>
      </div>
      <table style="width:100%;border-collapse:collapse;background:#fff;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 6px 6px;">
        <tr>
          <th style="padding:7px 16px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;background:#f8fafc;border-bottom:1px solid #e2e8f0;text-align:left;">Project</th>
          <th style="padding:7px 16px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;background:#f8fafc;border-bottom:1px solid #e2e8f0;text-align:left;">Duration</th>
        </tr>
        ${contractRows}
      </table>
    </div>`)
  }

  if (!hasIssues && !sections.length) {
    sections.push(`<div style="background:#dcfce7;border:1px solid #bbf7d0;border-radius:8px;padding:16px;text-align:center;color:#166534;font-size:14px;font-weight:600;margin-bottom:16px;">✅ All your compliance documents are up to date.</div>`)
  }

  const introText = hasIssues
    ? `You have <strong>${totalIssues} compliance document${totalIssues!==1?'s':''}</strong> that require your attention. Please log in to your worker portal to upload the required files.`
    : isManual
      ? `This is a reminder from your compliance team. Please log in to your worker portal to review your documents and assignments.`
      : `Your compliance records are up to date. Log in any time to view your documents and assignments.`

  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
</head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:600px;margin:24px auto;padding:0 12px;">

  <div style="background:#1a2035;border-radius:10px 10px 0 0;padding:24px;">
    <div style="font-size:18px;font-weight:700;color:#fff;">${esc(orgName)}</div>
    <div style="font-size:12px;color:#94a3b8;margin-top:3px;">Worker Compliance Portal</div>
  </div>

  <div style="background:#fff;padding:24px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <p style="font-size:15px;color:#1a2035;margin:0 0 6px 0;font-weight:600;">Hi ${esc(workerName)},</p>
    <p style="font-size:14px;color:#374151;margin:0 0 24px 0;line-height:1.55;">${introText}</p>

    ${sections.join('')}

    <div style="text-align:center;margin-top:28px;padding-top:20px;border-top:1px solid #f0f4f8;">
      <a href="${esc(link)}"
         style="display:inline-block;background:#1a2035;color:#fff;text-decoration:none;font-size:15px;font-weight:600;padding:14px 36px;border-radius:8px;letter-spacing:.01em;">
        Open My Portal →
      </a>
      <div style="font-size:11px;color:#94a3b8;margin-top:10px;word-break:break-all;">
        Or copy: ${esc(link)}
      </div>
    </div>
  </div>

  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">${esc(orgName)} · Automated compliance reminder · Do not reply to this email</span>
  </div>

</div>
</body></html>`
}

// ── main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  // CORS pre-flight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS })
  }

  try {
    // Verify caller JWT
    const authHeader = req.headers.get('Authorization') || ''
    const jwt = authHeader.replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)

    const sb = createClient(SUPABASE_URL, SUPABASE_KEY)

    // Verify JWT via Supabase Auth
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)

    // Derive caller's org from their profile — NEVER trust a caller-supplied org_id
    const { data: profile } = await sb.from('profiles').select('org_id, role').eq('id', user.id).maybeSingle()
    if (!profile?.org_id) return json({ error: 'No organisation' }, 403)
    const callerOrgId = profile.org_id

    // Parse request body
    const body = await req.json().catch(() => ({}))
    const workerId = body?.worker_id
    if (!workerId) return json({ error: 'worker_id required' }, 400)

    // Fetch worker — verify it belongs to caller's org (cross-org guard)
    const { data: worker } = await sb.from('workers')
      .select('id, full_name, email, org_id, document_set_id, vault_account_id')
      .eq('id', workerId)
      .eq('org_id', callerOrgId)
      .eq('active', true)
      .maybeSingle()

    if (!worker) return json({ error: 'Worker not found' }, 404)
    if (!worker.email) return json({ error: 'Worker has no email address on file' }, 400)

    // Load org info (name + slug for portal link)
    const { data: org } = await sb.from('organisations').select('id, name, slug').eq('id', callerOrgId).maybeSingle()

    // Load document set items scoped to this worker's assigned set only.
    // Fetching all sets would show docs from other sets (e.g. ZZP docs for a Blue Card worker).
    const docItemsQuery = sb.from('document_set_items')
      .select('id, name, required').eq('org_id', callerOrgId).eq('active', true)
    if (worker.document_set_id) docItemsQuery.eq('document_set_id', worker.document_set_id)
    const { data: docItems } = await docItemsQuery
    const docItemMap: Record<string, any> = Object.fromEntries(
      (docItems||[]).map((d: any) => [d.id.includes('__') ? d.id.split('__').slice(1).join('__') : d.id, d])
    )

    // Load worker's documents
    const { data: wdocs } = await sb.from('worker_documents')
      .select('doc_key, status, expiry_date').eq('worker_id', worker.id).eq('active', true)

    const todayStr = new Date().toISOString().slice(0, 10)
    const in7Str   = new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10)

    const missing:  string[]   = []
    const expired:  DocIssue[] = []
    const expiring: DocIssue[] = []

    for (const d of (wdocs||[])) {
      const item = docItemMap[d.doc_key]
      if (!item?.required) continue
      if (!d.expiry_date || d.status === 'missing') {
        missing.push(item.name)
      } else if (d.expiry_date < todayStr) {
        expired.push({ name: item.name, date: d.expiry_date })
      } else if (d.expiry_date <= in7Str) {
        expiring.push({ name: item.name, date: d.expiry_date, days: daysUntil(d.expiry_date) })
      }
    }

    // Load active contracts
    const { data: assigns } = await sb.from('project_assignments')
      .select('project_id, start_date, end_date')
      .eq('worker_id', worker.id).eq('active', true).eq('org_id', callerOrgId)
      .or(`end_date.is.null,end_date.gte.${todayStr}`)
      .order('start_date', { ascending: false })

    const { data: projects } = await sb.from('projects')
      .select('id, name').eq('org_id', callerOrgId).eq('active', true)
    const projMap: Record<string, string> = Object.fromEntries((projects||[]).map((p: any) => [p.id, p.name]))

    const contracts: Contract[] = (assigns||[]).map((a: any) => ({
      project: projMap[a.project_id] || 'Project',
      start: a.start_date,
      end: a.end_date || null,
    }))

    const link    = buildPortalLink(worker, org?.slug || null)
    const orgName = org?.name || 'Your company'

    const html = buildWorkerEmailHtml(
      worker.full_name, orgName, link,
      missing, expired, expiring, contracts,
      true  // isManual = true
    )

    const totalIssues = missing.length + expired.length + expiring.length
    const subject = totalIssues > 0
      ? `Action required: ${totalIssues} compliance document${totalIssues!==1?'s':''} need your attention`
      : `${orgName}: compliance reminder`

    const sendRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM, to: worker.email, subject, html }),
    })

    if (!sendRes.ok) {
      const errBody = await sendRes.text()
      console.error('[send-worker-reminder] Resend error:', sendRes.status, errBody)
      return json({ error: `Email send failed: ${sendRes.status}` }, 502)
    }

    // Log the manual send
    await sb.from('worker_notification_log').insert({
      worker_id: worker.id,
      org_id: callerOrgId,
      notification_type: 'manual',
      doc_keys: [...missing, ...expired.map(d => d.name), ...expiring.map(d => d.name)],
    })

    return json({ sent: true, to: worker.email, issues: totalIssues })
  } catch (err: any) {
    console.error('[send-worker-reminder]', err)
    return json({ error: err.message }, 500)
  }
})
