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

// Lucide icons (2px stroke) as inline SVG for email. Rendered by Apple Mail /
// iOS Mail / most modern clients; Gmail strips inline SVG, in which case the
// paired text label remains (graceful degradation). Single stroke colour.
const ICON_PATHS: Record<string, string> = {
  'alert-triangle': '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  'clock': '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  'file-text': '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M16 13H8"/><path d="M16 17H8"/><path d="M10 9H8"/>',
  'folder': '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  'check-circle': '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><path d="m9 11 3 3L22 4"/>',
  'shield-check': '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1Z"/><path d="m9 12 2 2 4-4"/>',
  'send': '<path d="M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"/><path d="m21.854 2.147-10.94 10.939"/>',
  'arrow-right': '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
  'lock': '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  'briefcase': '<path d="M16 20V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/><rect width="20" height="14" x="2" y="6" rx="2"/>',
}
function icon(name: string, colour = 'currentColor', size = 14): string {
  const p = ICON_PATHS[name] || ''
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${colour}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-2px;">${p}</svg>`
}

// Premium Worker Vault advert block (worker-facing reminder emails).
function vaultAd(link: string): string {
  const feat = (ic: string, text: string) => `
    <tr>
      <td style="padding:5px 10px 5px 0;vertical-align:top;width:22px;">${icon(ic, '#fff', 16)}</td>
      <td style="padding:5px 0;font-size:13px;color:#ffffff;font-weight:600;">${text}</td>
    </tr>`
  return `
  <div style="margin:4px 0 18px;border-radius:16px;overflow:hidden;background-color:#6d28d9;background:linear-gradient(135deg,#7c3aed 0%,#6d28d9 55%,#4c1d95 100%);">
    <div style="padding:24px 26px;">
      <span style="display:inline-block;background:rgba(255,255,255,0.16);color:#fff;font-size:10px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;padding:5px 11px;border-radius:999px;">${icon('shield-check','#fff',12)} &nbsp;Worker Vault · Premium</span>
      <div style="font-size:21px;font-weight:800;color:#fff;margin:15px 0 7px;letter-spacing:-.01em;line-height:1.2;">Your documents. Yours forever.</div>
      <div style="font-size:13px;color:rgba(255,255,255,0.82);line-height:1.6;margin-bottom:16px;">Keep every compliance document in one secure place — then carry them to any employer and share them with anyone you choose, instantly, with a private link that expires when you say so.</div>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin-bottom:20px;">
        ${feat('lock', 'Store every document securely in one vault')}
        ${feat('send', 'Share with anyone — a recruiter, an agency, an employer')}
        ${feat('briefcase', 'Carry your compliance between every job')}
      </table>
      <a href="${esc(link)}" style="display:inline-block;background:#ffffff;color:#4c1d95;text-decoration:none;font-size:14px;font-weight:800;padding:13px 30px;border-radius:9px;">Upgrade to Vault &nbsp;${icon('arrow-right','#4c1d95',15)}</a>
      <div style="font-size:11px;color:rgba(255,255,255,0.6);margin-top:12px;">Already on Vault? Your documents are safe and ready to share.</div>
    </div>
  </div>`
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
  logoUrl?: string | null,
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
    sections.push(docTable('#c53030', icon('alert-triangle','#fff',14), `Expired Documents (${expired.length})`,
      expired.map(d => docRow(d.name, `<span style="color:#c53030;font-weight:600;">Expired · ${fmt(d.date!)}</span>`))
    ))
  }
  if (expiring.length) {
    sections.push(docTable('#b45309', icon('clock','#fff',14), `Expiring Soon (${expiring.length})`,
      expiring.map(d => docRow(d.name, `<span style="color:#b45309;font-weight:600;">Expires in ${d.days} day${d.days!==1?'s':''} · ${fmt(d.date!)}</span>`))
    ))
  }
  if (missing.length) {
    sections.push(docTable('#7c3aed', icon('file-text','#fff',14), `Missing Documents (${missing.length})`,
      missing.map(n => docRow(n, `<span style="color:#c53030;font-weight:600;">Missing — please upload</span>`))
    ))
  }

  // Premium Vault advert — placed below the document sections.
  sections.push(vaultAd(link))

  if (contracts.length) {
    const contractRows = contracts.map(c => `<tr>
      <td style="padding:10px 16px;font-size:13px;color:#1a2035;border-bottom:1px solid #f0f4f8;">${esc(c.project)}</td>
      <td style="padding:10px 16px;font-size:13px;color:#64748b;border-bottom:1px solid #f0f4f8;">${fmt(c.start)} – ${c.end ? fmt(c.end) : 'Ongoing'}</td>
    </tr>`).join('')
    sections.push(`
    <div style="margin-bottom:16px;">
      <div style="background:#1d4ed8;border-radius:6px 6px 0 0;padding:10px 16px;">
        <span style="font-size:13px;font-weight:700;color:#fff;">${icon('folder','#fff',14)} Your Active Contracts (${contracts.length})</span>
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

  // Reassuring green banner when there are no document issues — placed first,
  // above the advert / contracts.
  if (!hasIssues) {
    sections.unshift(`<div style="background:#dcfce7;border:1px solid #bbf7d0;border-radius:8px;padding:16px;text-align:center;color:#166534;font-size:14px;font-weight:600;margin-bottom:16px;">${icon('check-circle','#166534',16)} &nbsp;All your compliance documents are up to date.</div>`)
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
    ${logoUrl ? `<img src="${esc(logoUrl)}" alt="${esc(orgName)}" height="40" style="height:40px;max-width:200px;width:auto;display:block;margin-bottom:12px;border:0;outline:none;text-decoration:none;"/>` : ''}
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
        Open My Portal &nbsp;${icon('arrow-right','#fff',15)}
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

    // Load org info (name + slug for portal link, logo for email header)
    const { data: org } = await sb.from('organisations').select('id, name, slug, logo_url').eq('id', callerOrgId).maybeSingle()

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
      true,  // isManual = true
      org?.logo_url || null
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
