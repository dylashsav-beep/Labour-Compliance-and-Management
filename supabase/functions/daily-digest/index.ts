import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// NOTE: This function uses the SERVICE ROLE key, which BYPASSES RLS. It is
// therefore MANDATORY that every query is filtered by org_id and the whole
// run loops per organisation. Never query a tenant table here without
// .eq('org_id', org.id) — doing so leaks one org's data into another's email.

// Set DIGEST_FROM in Supabase → Settings → Edge Functions → Secrets once your
// domain is verified in Resend. Until then the sandbox fallback is used.
const FROM      = Deno.env.get('DIGEST_FROM') || 'Work Force Compliance <onboarding@resend.dev>'
const SITE_URL  = Deno.env.get('SITE_URL')    || 'https://work-force.nl'
const VAULT_URL = Deno.env.get('VAULT_URL')   || 'https://work-force.nl/vault.html'

// Default section config — merged with whatever the org has stored in settings.
const SECTION_DEFAULTS: Record<string, { enabled: boolean; days?: number }> = {
  expired_docs:            { enabled: true },
  expiring_docs:           { enabled: true,  days: 60 },
  missing_contracts:       { enabled: true },
  assignments_ending:      { enabled: true,  days: 14 },
  workers_unassigned:      { enabled: true },
  accommodation_ending:    { enabled: true,  days: 7  },
  uncharged_accommodation: { enabled: true },
  uncharged_vehicles:      { enabled: true },
}

// ── date helpers ──────────────────────────────────────────────────────────────
function addDays(d: Date, n: number): string {
  return new Date(+d + n * 86400000).toISOString().slice(0, 10)
}
function weekMonday(d: Date): Date {
  const day = d.getDay() || 7
  const m = new Date(d); m.setDate(m.getDate() - day + 1); m.setHours(0,0,0,0)
  return m
}
function isoWeekKey(d: Date): string {
  const thu = new Date(d); thu.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7))
  const year = thu.getFullYear()
  const wk = Math.ceil(((+thu - +new Date(year, 0, 4)) / 86400000 + 1) / 7)
  return `${year}-W${String(wk).padStart(2, '0')}`
}
function fmt(s: string) {
  return new Date(s).toLocaleDateString('en-GB', { day:'numeric', month:'short', year:'numeric' })
}
function daysUntil(dateStr: string, today: Date): number {
  return Math.ceil((new Date(dateStr).setHours(0,0,0,0) - today.getTime()) / 86400000)
}

// ── icons (Lucide, inline SVG) ──────────────────────────────────────────────
// Rendered by Apple Mail / iOS Mail / most modern clients; Gmail strips inline
// SVG, in which case the paired text label remains (graceful degradation).
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

// ── worker email helpers ──────────────────────────────────────────────────────
function classifyDocs(
  workerDocs: any[],
  docItemMap: Record<string, any>,
  todayStr: string,
  in7Str: string,
  today: Date
): { missing: string[]; expired: Array<{name:string;date:string}>; expiring: Array<{name:string;date:string;days:number}> } {
  const missing: string[]   = []
  const expired: Array<{name:string;date:string}> = []
  const expiring: Array<{name:string;date:string;days:number}> = []
  for (const d of workerDocs) {
    const item = docItemMap[d.doc_key]
    if (!item?.required) continue
    if (!d.expiry_date || d.status === 'missing') {
      missing.push(item.name)
    } else if (d.expiry_date < todayStr) {
      expired.push({ name: item.name, date: d.expiry_date })
    } else if (d.expiry_date <= in7Str) {
      expiring.push({ name: item.name, date: d.expiry_date, days: daysUntil(d.expiry_date, today) })
    }
  }
  return { missing, expired, expiring }
}

function buildWorkerEmailHtml(
  workerName: string,
  orgName: string,
  link: string,
  missing: string[],
  expired: Array<{name:string;date:string}>,
  expiring: Array<{name:string;date:string;days:number}>,
  contracts: Array<{project:string;start:string;end:string|null}>,
  logoUrl?: string | null,
): string {
  function docTable(colour: string, icon: string, title: string, rows: string[]): string {
    return `<div style="margin-bottom:16px;">
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
  function dRow(name: string, statusHtml: string): string {
    return `<tr>
      <td style="padding:10px 16px;font-size:13px;color:#1a2035;border-bottom:1px solid #f0f4f8;">${esc(name)}</td>
      <td style="padding:10px 16px;font-size:13px;border-bottom:1px solid #f0f4f8;">${statusHtml}</td>
    </tr>`
  }

  const secs: string[] = []
  if (expired.length)  secs.push(docTable('#c53030',icon('alert-triangle','#fff',14),`Expired Documents (${expired.length})`, expired.map(d=>dRow(d.name,`<span style="color:#c53030;font-weight:600;">Expired · ${fmt(d.date)}</span>`))))
  if (expiring.length) secs.push(docTable('#b45309',icon('clock','#fff',14),`Expiring Soon (${expiring.length})`, expiring.map(d=>dRow(d.name,`<span style="color:#b45309;font-weight:600;">Expires in ${d.days} day${d.days!==1?'s':''} · ${fmt(d.date)}</span>`))))
  if (missing.length)  secs.push(docTable('#7c3aed',icon('file-text','#fff',14),`Missing Documents (${missing.length})`, missing.map(n=>dRow(n,`<span style="color:#c53030;font-weight:600;">Missing — please upload</span>`))))

  // Premium Vault advert — below the document sections.
  secs.push(vaultAd(link))

  if (contracts.length) {
    const cRows = contracts.map(c=>`<tr>
      <td style="padding:10px 16px;font-size:13px;color:#1a2035;border-bottom:1px solid #f0f4f8;">${esc(c.project)}</td>
      <td style="padding:10px 16px;font-size:13px;color:#64748b;border-bottom:1px solid #f0f4f8;">${fmt(c.start)} – ${c.end ? fmt(c.end) : 'Ongoing'}</td>
    </tr>`).join('')
    secs.push(`<div style="margin-bottom:16px;">
      <div style="background:#1d4ed8;border-radius:6px 6px 0 0;padding:10px 16px;">
        <span style="font-size:13px;font-weight:700;color:#fff;">${icon('folder','#fff',14)} Your Active Contracts (${contracts.length})</span>
      </div>
      <table style="width:100%;border-collapse:collapse;background:#fff;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 6px 6px;">
        <tr>
          <th style="padding:7px 16px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;background:#f8fafc;border-bottom:1px solid #e2e8f0;text-align:left;">Project</th>
          <th style="padding:7px 16px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;background:#f8fafc;border-bottom:1px solid #e2e8f0;text-align:left;">Duration</th>
        </tr>
        ${cRows}
      </table>
    </div>`)
  }

  const totalIssues = missing.length + expired.length + expiring.length
  const intro = totalIssues > 0
    ? `You have <strong>${totalIssues} compliance document${totalIssues!==1?'s':''}</strong> that require your attention. Please log in to your worker portal to upload the required files.`
    : `Your compliance records are up to date. Log in to review your documents and assignments.`

  return `<!DOCTYPE html><html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:600px;margin:24px auto;padding:0 12px;">
  <div style="background:#1a2035;border-radius:10px 10px 0 0;padding:24px;">
    ${logoUrl ? `<img src="${esc(logoUrl)}" alt="${esc(orgName)}" height="40" style="height:40px;max-width:200px;width:auto;display:block;margin-bottom:12px;border:0;outline:none;text-decoration:none;"/>` : ''}
    <div style="font-size:18px;font-weight:700;color:#fff;">${esc(orgName)}</div>
    <div style="font-size:12px;color:#94a3b8;margin-top:3px;">Worker Compliance Portal</div>
  </div>
  <div style="background:#fff;padding:24px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <p style="font-size:15px;color:#1a2035;margin:0 0 6px 0;font-weight:600;">Hi ${esc(workerName)},</p>
    <p style="font-size:14px;color:#374151;margin:0 0 24px 0;line-height:1.55;">${intro}</p>
    ${secs.join('')}
    <div style="text-align:center;margin-top:28px;padding-top:20px;border-top:1px solid #f0f4f8;">
      <a href="${esc(link)}" style="display:inline-block;background:#1a2035;color:#fff;text-decoration:none;font-size:15px;font-weight:600;padding:14px 36px;border-radius:8px;">Open My Portal &nbsp;${icon('arrow-right','#fff',15)}</a>
      <div style="font-size:11px;color:#94a3b8;margin-top:10px;word-break:break-all;">Or copy: ${esc(link)}</div>
    </div>
  </div>
  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">${esc(orgName)} · Automated compliance reminder · Do not reply</span>
  </div>
</div></body></html>`
}

// ── admin email helpers ───────────────────────────────────────────────────────
function esc(s: string) {
  return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}
function colHdr(cols: string[]): string {
  return `<tr>${cols.map(c=>`<th style="padding:7px 14px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:.04em;text-align:left;background:#f8fafc;border-bottom:1px solid #e2e8f0;">${c}</th>`).join('')}</tr>`
}
function row(...cells: string[]): string {
  return `<tr>${cells.map(c=>`<td style="padding:8px 14px;font-size:12px;color:#1a2035;border-bottom:1px solid #f0f4f8;">${c}</td>`).join('')}</tr>`
}
function section(title: string, colour: string, rows: string[]): string {
  if (!rows.length) return ''
  return `
    <div style="margin-bottom:24px;">
      <div style="background:${colour};border-radius:6px 6px 0 0;padding:10px 16px;">
        <span style="font-size:13px;font-weight:700;color:#fff;">${title} · ${rows.length}</span>
      </div>
      <table style="width:100%;border-collapse:collapse;background:#fff;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 6px 6px;">
        ${rows.join('')}
      </table>
    </div>`
}

// ── per-organisation digest ───────────────────────────────────────────────────
async function digestForOrg(sb: any, org: any, today: Date) {
  const orgId   = org.id
  const orgName = org.name || 'Work Force'
  const todayStr = today.toISOString().slice(0, 10)

  // Load org settings first (used for recipients AND section prefs below).
  const { data: orgSettings } = await sb.from('settings').select('digest_sections, notify_workers_enabled, notify_worker_types, digest_emails').eq('id', orgId).maybeSingle()

  // Recipients: org compliance email + owner. Skip if neither.
  // Use digest_emails from settings if configured; fall back to org compliance_email + owner_email
  const configuredEmails = Array.isArray(orgSettings?.digest_emails) && orgSettings.digest_emails.length > 0
    ? orgSettings.digest_emails
    : [org.compliance_email, org.owner_email].filter(Boolean)
  const recipients = [...new Set(configuredEmails)]
  if (!recipients.length) return { org: orgName, sent: false, reason: 'no recipient configured' }

  // Merge org section prefs with defaults (org overrides defaults per key).
  const stored: Record<string, any> = orgSettings?.digest_sections || {}
  const sec = (key: string) => {
    const def = SECTION_DEFAULTS[key]
    const ov  = stored[key] || {}
    return {
      enabled: ov.enabled !== undefined ? ov.enabled : def.enabled,
      days:    ov.days    !== undefined ? ov.days    : def.days,
    }
  }

  const warningDays       = sec('expiring_docs').days     ?? 60
  const assignWarnDays    = sec('assignments_ending').days ?? 14
  const accomEndingDays   = sec('accommodation_ending').days ?? 7
  const warnStr           = addDays(today, warningDays)
  const assignWarnStr     = addDays(today, assignWarnDays)
  const accomEndingStr    = addDays(today, accomEndingDays)

  // ── 1. Workers + documents ────────────────────────────────────────────────
  const [{ data: workers }, { data: wdocs }, { data: docItems }] = await Promise.all([
    sb.from('workers').select('id, full_name, email, document_set_id, worker_type, vault_account_id').eq('org_id', orgId).eq('active', true),
    sb.from('worker_documents').select('worker_id, doc_key, status, expiry_date').eq('org_id', orgId).eq('active', true),
    sb.from('document_set_items').select('id, name, required, document_set_id').eq('org_id', orgId).eq('active', true),
  ])

  // workerMap stores name + assigned document set id for per-worker doc lookups.
  const workerMap = Object.fromEntries((workers||[]).map((w:any)=>[w.id, { name: w.full_name, setId: w.document_set_id }]))

  // Build a per-set docItemMap so each worker's docs are checked against their
  // own set only. A global map would match ZZP docs for Blue Card workers etc.
  // Key structure: docItemsBySet[setId][shortDocKey] = docItem
  const docItemsBySet: Record<string, Record<string, any>> = {}
  for (const d of (docItems||[])) {
    const setId = d.document_set_id
    const shortKey = d.id.includes('__') ? d.id.split('__').slice(1).join('__') : d.id
    if (!docItemsBySet[setId]) docItemsBySet[setId] = {}
    docItemsBySet[setId][shortKey] = d
  }
  // Helper: get the doc item map for a given worker id
  const workerDocItemMap = (wid: string): Record<string, any> =>
    docItemsBySet[workerMap[wid]?.setId] || {}

  const expiredRows: string[]  = []
  const expiringRows: string[] = []
  const docHdr = colHdr(['Worker','Document','Status','Expiry date'])

  if (sec('expired_docs').enabled || sec('expiring_docs').enabled) {
    for (const d of (wdocs||[])) {
      const item = workerDocItemMap(d.worker_id)[d.doc_key]
      if (!item?.required) continue
      const wName = esc(workerMap[d.worker_id]?.name || 'Unknown worker')
      const dName = esc(item.name)
      if (!d.expiry_date || d.status === 'missing') {
        if (sec('expired_docs').enabled)
          expiredRows.push(row(wName, dName, '<span style="color:#c53030;font-weight:600;">Missing</span>', '—'))
      } else if (d.expiry_date < todayStr) {
        if (sec('expired_docs').enabled)
          expiredRows.push(row(wName, dName, '<span style="color:#c53030;font-weight:600;">Expired</span>', fmt(d.expiry_date)))
      } else if (d.expiry_date <= warnStr) {
        if (sec('expiring_docs').enabled) {
          const days = daysUntil(d.expiry_date, today)
          expiringRows.push(row(wName, dName, `<span style="color:#b45309;font-weight:600;">Expires in ${days}d</span>`, fmt(d.expiry_date)))
        }
      }
    }
  }

  // ── 2. Assignments ending soon ────────────────────────────────────────────
  const assignEndingRows: string[] = []
  const assignHdr = colHdr(['Worker','Project','Status','End date'])

  if (sec('assignments_ending').enabled) {
    const [{ data: endingRaw }, { data: projects }] = await Promise.all([
      sb.from('project_assignments').select('end_date, worker_id, project_id')
        .eq('org_id', orgId).eq('active', true)
        .gte('end_date', todayStr).lte('end_date', assignWarnStr)
        .order('end_date', { ascending: true }),
      sb.from('projects').select('id, name').eq('org_id', orgId).eq('active', true),
    ])
    const projMap = Object.fromEntries((projects||[]).map((p:any)=>[p.id, p.name]))
    for (const a of (endingRaw||[])) {
      assignEndingRows.push(row(
        esc(workerMap[a.worker_id]?.name || 'Unknown'),
        esc(projMap[a.project_id]  || 'Unknown project'),
        `<span style="color:#b45309;font-weight:600;">Ends in ${daysUntil(a.end_date, today)}d</span>`,
        fmt(a.end_date)
      ))
    }
  }

  // ── 3. Missing contracts ──────────────────────────────────────────────────
  const missingContractRows: string[] = []
  const contractHdr = colHdr(['Worker','Project','Start date',''])

  if (sec('missing_contracts').enabled) {
    const [{ data: allAssign }, { data: paFiles }, { data: projects }] = await Promise.all([
      sb.from('project_assignments').select('id, worker_id, project_id, start_date')
        .eq('org_id', orgId).eq('active', true).gte('end_date', todayStr),
      sb.from('project_assignment_files').select('assignment_id').eq('org_id', orgId).eq('active', true),
      sb.from('projects').select('id, name').eq('org_id', orgId).eq('active', true),
    ])
    const assignmentsWithFiles = new Set((paFiles||[]).map((f:any)=>f.assignment_id))
    const projMap = Object.fromEntries((projects||[]).map((p:any)=>[p.id, p.name]))
    for (const a of (allAssign||[])) {
      if (!assignmentsWithFiles.has(a.id)) {
        missingContractRows.push(row(
          esc(workerMap[a.worker_id]?.name || 'Unknown'),
          esc(projMap[a.project_id]  || 'Unknown project'),
          fmt(a.start_date),
          '<span style="color:#c53030;font-weight:600;">No contract</span>'
        ))
      }
    }
  }

  // ── 4. Workers with no current assignment ─────────────────────────────────
  const unassignedRows: string[] = []
  const unassignedHdr = colHdr(['Worker','','',''])

  if (sec('workers_unassigned').enabled) {
    const { data: currentAssign } = await sb.from('project_assignments')
      .select('worker_id').eq('org_id', orgId).eq('active', true)
      .lte('start_date', todayStr)
      .or(`end_date.is.null,end_date.gte.${todayStr}`)
    const assignedIds = new Set((currentAssign||[]).map((a:any)=>a.worker_id))
    for (const w of (workers||[])) {
      if (!assignedIds.has(w.id)) {
        unassignedRows.push(row(esc(w.full_name||''), '', '', '<span style="color:#64748b;">No active assignment</span>'))
      }
    }
  }

  // ── 5. Accommodation ending soon ──────────────────────────────────────────
  const accomEndingRows: string[] = []
  const accomEndingHdr = colHdr(['Worker','Property','Status','End date'])

  if (sec('accommodation_ending').enabled) {
    const [{ data: accomEnding }, { data: properties }] = await Promise.all([
      sb.from('accommodation_assignments').select('worker_id, property_id, end_date')
        .eq('org_id', orgId).eq('active', true)
        .gte('end_date', todayStr).lte('end_date', accomEndingStr)
        .order('end_date', { ascending: true }),
      sb.from('properties').select('id, name').eq('org_id', orgId).eq('active', true),
    ])
    const propMap = Object.fromEntries((properties||[]).map((p:any)=>[p.id, p.name]))
    for (const a of (accomEnding||[])) {
      accomEndingRows.push(row(
        esc(workerMap[a.worker_id]?.name || 'Unknown'),
        esc(propMap[a.property_id] || 'Unknown property'),
        `<span style="color:#b45309;font-weight:600;">Ends in ${daysUntil(a.end_date, today)}d</span>`,
        fmt(a.end_date)
      ))
    }
  }

  // ── 6. Uncharged weeks (accommodation + vehicles) ─────────────────────────
  const unchargedAccomRows: string[] = []
  const unchargedVehRows:   string[] = []
  const billingHdr = colHdr(['Worker','Resource','Week','Rate/wk','Status'])

  if (sec('uncharged_accommodation').enabled || sec('uncharged_vehicles').enabled) {
    const [
      { data: accomAssign }, { data: accomCharges },
      { data: vehAssign },   { data: vehCharges },
      { data: properties },  { data: vehicles }
    ] = await Promise.all([
      sb.from('accommodation_assignments').select('id, worker_id, property_id, start_date, end_date, weekly_charge_amount').eq('org_id', orgId).eq('active', true).eq('charge_to_operative', true),
      sb.from('accommodation_charges').select('assignment_id, week_key').eq('org_id', orgId).eq('active', true).eq('charged', true),
      sb.from('vehicle_assignments').select('id, worker_id, vehicle_id, start_date, end_date, weekly_charge_amount').eq('org_id', orgId).eq('active', true).eq('charge_to_operative', true),
      sb.from('vehicle_charges').select('assignment_id, week_key').eq('org_id', orgId).eq('active', true).eq('charged', true),
      sb.from('properties').select('id, name').eq('org_id', orgId).eq('active', true),
      sb.from('vehicles').select('id, description').eq('org_id', orgId).eq('active', true),
    ])
    const propMap = Object.fromEntries((properties||[]).map((p:any)=>[p.id, p.name]))
    const vehMap  = Object.fromEntries((vehicles||[]).map((v:any)=>[v.id, v.description]))
    const chargedAccom = new Set((accomCharges||[]).map((c:any)=>`${c.assignment_id}__${c.week_key}`))
    const chargedVeh   = new Set((vehCharges||[]).map((c:any)=>`${c.assignment_id}__${c.week_key}`))

    function buildUncharged(assignments: any[], charged: Set<string>, resourceMap: Record<string,string>): string[] {
      const out: string[] = []
      for (const a of (assignments||[])) {
        const start = weekMonday(new Date(a.start_date))
        const end   = a.end_date ? new Date(a.end_date) : today
        const rateCell = a.weekly_charge_amount ? `€${Number(a.weekly_charge_amount).toFixed(2)}/wk` : '—'
        let cur = new Date(start)
        while (cur < today && cur <= end) {
          const wk = isoWeekKey(cur)
          if (!charged.has(`${a.id}__${wk}`)) {
            out.push(row(
              esc(workerMap[a.worker_id]?.name || 'Unknown'),
              esc(resourceMap[a.property_id || a.vehicle_id] || 'Unknown'),
              `<span style="color:#b45309;font-weight:600;">${wk}</span>`,
              rateCell,
              'Not charged'
            ))
          }
          cur = new Date(+cur + 7 * 86400000)
        }
      }
      return out
    }

    if (sec('uncharged_accommodation').enabled) unchargedAccomRows.push(...buildUncharged(accomAssign||[], chargedAccom, propMap))
    if (sec('uncharged_vehicles').enabled)      unchargedVehRows.push(...buildUncharged(vehAssign||[],   chargedVeh,   vehMap))
  }

  // ── Build email ───────────────────────────────────────────────────────────
  const totalItems = expiredRows.length + expiringRows.length + missingContractRows.length +
    assignEndingRows.length + unassignedRows.length + accomEndingRows.length +
    unchargedAccomRows.length + unchargedVehRows.length

  if (totalItems === 0) return { org: orgName, sent: false, reason: 'nothing to report' }

  const html = `<!DOCTYPE html>
<html><head><meta charset="utf-8"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:680px;margin:32px auto;padding:0 16px;">

  <div style="background:#1a2035;border-radius:8px 8px 0 0;padding:20px 24px;">
    ${org.logo_url ? `<img src="${esc(org.logo_url)}" alt="${esc(orgName)}" height="36" style="height:36px;max-width:180px;width:auto;display:block;margin-bottom:10px;border:0;outline:none;text-decoration:none;"/>` : ''}
    <div style="font-size:18px;font-weight:700;color:#fff;">${esc(orgName)} Compliance · Daily Digest</div>
    <div style="font-size:12px;color:#94a3b8;margin-top:4px;">${new Date().toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long',year:'numeric'})} · ${totalItems} item${totalItems!==1?'s':''} requiring attention</div>
  </div>

  <div style="background:#f8fafc;padding:20px 0;">

    ${section(`${icon('alert-triangle','#fff',13)} &nbsp;No-Go — Expired / Missing Documents`, '#c53030',
      expiredRows.length ? [docHdr, ...expiredRows] : [])}

    ${section(`${icon('clock','#fff',13)} &nbsp;Warning — Documents Expiring Soon`, '#b45309',
      expiringRows.length ? [docHdr, ...expiringRows] : [])}

    ${section(`${icon('file-text','#fff',13)} &nbsp;Missing Contracts on Assignments`, '#7c3aed',
      missingContractRows.length ? [contractHdr, ...missingContractRows] : [])}

    ${section(`${icon('clock','#fff',13)} &nbsp;Assignments Ending Soon`, '#1d4ed8',
      assignEndingRows.length ? [assignHdr, ...assignEndingRows] : [])}

    ${section(`${icon('briefcase','#fff',13)} &nbsp;Workers With No Current Assignment`, '#374151',
      unassignedRows.length ? [unassignedHdr, ...unassignedRows] : [])}

    ${section(`${icon('folder','#fff',13)} &nbsp;Accommodation Ending Soon`, '#0f766e',
      accomEndingRows.length ? [accomEndingHdr, ...accomEndingRows] : [])}

    ${section(`${icon('folder','#fff',13)} &nbsp;Uncharged Accommodation Weeks`, '#065f46',
      unchargedAccomRows.length ? [billingHdr, ...unchargedAccomRows] : [])}

    ${section(`${icon('send','#fff',13)} &nbsp;Uncharged Vehicle Weeks`, '#065f46',
      unchargedVehRows.length ? [billingHdr, ...unchargedVehRows] : [])}

  </div>

  <div style="background:#1a2035;border-radius:0 0 8px 8px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#64748b;">${esc(orgName)} · Labour Compliance & Management · Automated digest — do not reply</span>
  </div>

</div>
</body></html>`

  const sends = await Promise.all(recipients.map(to =>
    fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM, to,
        subject: `${orgName} Compliance Digest — ${totalItems} item${totalItems!==1?'s':''} · ${todayStr}`,
        html,
      }),
    }).then(r => r.json())
  ))

  // ── Worker reminder notifications ─────────────────────────────────────────
  // Sends personalised emails to workers with missing/expiring docs.
  // Throttled to once per 7 days per worker; repeat weekly until resolved.
  if (orgSettings?.notify_workers_enabled) {
    const in7Str       = addDays(today, 7)
    const sevenDaysAgo = new Date(+today - 7 * 86400000).toISOString()
    // Empty array = all types included; populated = only those type IDs
    const allowedTypes: string[] | null =
      Array.isArray(orgSettings.notify_worker_types) && orgSettings.notify_worker_types.length > 0
        ? orgSettings.notify_worker_types
        : null
    const workersWithEmail = (workers||[]).filter((w: any) =>
      w.email && (allowedTypes === null || allowedTypes.includes(w.worker_type))
    )

    if (workersWithEmail.length) {
      const { data: recentLogs } = await sb.from('worker_notification_log')
        .select('worker_id').eq('org_id', orgId).gte('sent_at', sevenDaysAgo)
      const recentlyNotified = new Set((recentLogs||[]).map((l: any) => l.worker_id))

      const { data: wProjects } = await sb.from('projects').select('id, name').eq('org_id', orgId).eq('active', true)
      const workerProjMap: Record<string, string> = Object.fromEntries((wProjects||[]).map((p: any) => [p.id, p.name]))

      for (const worker of workersWithEmail) {
        if (recentlyNotified.has(worker.id)) continue

        const workerDocs = (wdocs||[]).filter((d: any) => d.worker_id === worker.id)
        const { missing, expired, expiring } = classifyDocs(workerDocs, workerDocItemMap(worker.id), todayStr, in7Str, today)
        if (!missing.length && !expired.length && !expiring.length) continue

        const { data: workerAssigns } = await sb.from('project_assignments')
          .select('project_id, start_date, end_date')
          .eq('worker_id', worker.id).eq('active', true).eq('org_id', orgId)
          .or(`end_date.is.null,end_date.gte.${todayStr}`)
          .order('start_date', { ascending: false })

        const contracts = (workerAssigns||[]).map((a: any) => ({
          project: workerProjMap[a.project_id] || 'Project',
          start: a.start_date,
          end: a.end_date || null,
        }))

        // All worker reminder links go to the vault.
        const portalLink = VAULT_URL

        const workerHtml = buildWorkerEmailHtml(
          worker.full_name, orgName, portalLink,
          missing, expired, expiring, contracts,
          org.logo_url || null
        )

        const totalIssues = missing.length + expired.length + expiring.length
        await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: FROM,
            to: worker.email,
            subject: `Action required: ${totalIssues} compliance document${totalIssues!==1?'s':''} need your attention`,
            html: workerHtml,
          }),
        })

        await sb.from('worker_notification_log').insert({
          worker_id: worker.id,
          org_id: orgId,
          notification_type: 'auto',
          doc_keys: [...missing, ...expired.map((d: any) => d.name), ...expiring.map((d: any) => d.name)],
        })
      }
    }
  }

  return { org: orgName, sent: true, items: totalItems, recipients, sends }
}

// ── main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (_req) => {
  try {
    const sb = createClient(SUPABASE_URL, SUPABASE_KEY)
    const today = new Date(); today.setHours(0,0,0,0)

    const { data: orgs, error: orgErr } = await sb
      .from('organisations')
      .select('id, name, slug, owner_email, compliance_email, warning_days, logo_url')
    if (orgErr) throw orgErr

    const results = []
    for (const org of (orgs||[])) {
      try {
        results.push(await digestForOrg(sb, org, today))
      } catch(e: any) {
        console.error('[daily-digest]', org?.name, e?.message||e)
        results.push({ org: org?.name, sent: false, error: e?.message||String(e) })
      }
    }

    return new Response(JSON.stringify({ orgs: results.length, results }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch(err: any) {
    console.error('[daily-digest]', err)
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    })
  }
})
