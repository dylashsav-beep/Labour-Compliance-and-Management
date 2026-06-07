import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const RESEND_API_KEY  = Deno.env.get('RESEND_API_KEY')!
const SUPABASE_URL    = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// NOTE: This function uses the SERVICE ROLE key, which BYPASSES RLS. It is
// therefore MANDATORY that every query is filtered by org_id and the whole
// run loops per organisation. Never query a tenant table here without
// .eq('org_id', org.id) — doing so leaks one org's data into another's email.

// Set DIGEST_FROM in Supabase → Settings → Edge Functions → Secrets once your
// domain is verified in Resend. Until then the sandbox fallback is used.
const FROM = Deno.env.get('DIGEST_FROM') || 'Work Force Compliance <onboarding@resend.dev>'
const DEFAULT_WARNING_DAYS = 60   // fallback when an org has no warning_days set
const ASSIGN_WARN     = 14        // days before assignment end to flag

// ── date helpers ─────────────────────────────────────────────────────────────
function weekMonday(d: Date): Date {
  const day = d.getDay() || 7
  const m = new Date(d)
  m.setDate(m.getDate() - day + 1)
  m.setHours(0, 0, 0, 0)
  return m
}
function isoWeekKey(d: Date): string {
  const thu = new Date(d); thu.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7))
  const year = thu.getFullYear()
  const wk = Math.ceil(((+thu - +new Date(year, 0, 4)) / 86400000 + 1) / 7)
  return `${year}-W${String(wk).padStart(2, '0')}`
}
function fmt(s: string) {
  return new Date(s).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
}
function daysUntil(dateStr: string, today: Date): number {
  return Math.ceil((new Date(dateStr).setHours(0,0,0,0) - today.getTime()) / 86400000)
}

// ── email helpers ─────────────────────────────────────────────────────────────
function esc(s: string) {
  return (s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
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
function row(...cells: string[]): string {
  return `<tr>${cells.map(c => `<td style="padding:8px 14px;font-size:12px;color:#1a2035;border-bottom:1px solid #f0f4f8;">${c}</td>`).join('')}</tr>`
}

// ── per-organisation digest ─────────────────────────────────────────────────
// Builds and sends the digest for a SINGLE org. Every query is org-scoped.
async function digestForOrg(sb: any, org: any, today: Date) {
  const orgId       = org.id
  const orgName     = org.name || 'Work Force'
  const warningDays = org.warning_days || DEFAULT_WARNING_DAYS
  const todayStr      = today.toISOString().slice(0, 10)
  const warnStr       = new Date(+today + warningDays * 86400000).toISOString().slice(0, 10)
  const assignWarnStr = new Date(+today + ASSIGN_WARN * 86400000).toISOString().slice(0, 10)

  // Recipients: org's own compliance email, then owner email. Skip if neither.
  const recipients = [...new Set([org.compliance_email, org.owner_email].filter(Boolean))]
  if (!recipients.length) return { org: orgName, sent: false, reason: 'no recipient configured' }

  // ── 1. Worker documents ──────────────────────────────────────────────────
  const [{ data: workers }, { data: wdocs }, { data: docItems }] = await Promise.all([
    sb.from('workers').select('id, full_name').eq('org_id', orgId).eq('active', true),
    sb.from('worker_documents').select('worker_id, doc_key, status, expiry_date').eq('org_id', orgId).eq('active', true),
    sb.from('document_set_items').select('id, name, required').eq('org_id', orgId).eq('active', true),
  ])

  const workerMap  = Object.fromEntries((workers || []).map((w: any) => [w.id, w.full_name]))
  const docItemMap = Object.fromEntries((docItems || []).map((d: any) => [d.id, d]))

  const expiredRows:  string[] = []
  const expiringRows: string[] = []

  for (const d of (wdocs || [])) {
    const item = docItemMap[d.doc_key]
    if (!item?.required) continue  // only flag required documents
    const workerName = esc(workerMap[d.worker_id] || 'Unknown worker')
    const docName    = esc(item.name)

    if (!d.expiry_date || d.status === 'missing') {
      expiredRows.push(row(workerName, docName, '<span style="color:#c53030;font-weight:600;">Missing</span>', '—'))
    } else if (d.expiry_date < todayStr) {
      expiredRows.push(row(workerName, docName, '<span style="color:#c53030;font-weight:600;">Expired</span>', fmt(d.expiry_date)))
    } else if (d.expiry_date <= warnStr) {
      const days = daysUntil(d.expiry_date, today)
      expiringRows.push(row(workerName, docName, `<span style="color:#b45309;font-weight:600;">Expires in ${days}d</span>`, fmt(d.expiry_date)))
    }
  }

  // ── 2. Assignments ending soon ───────────────────────────────────────────
  const { data: endingRaw } = await sb
    .from('project_assignments')
    .select('end_date, worker_id, project_id')
    .eq('org_id', orgId)
    .eq('active', true)
    .gte('end_date', todayStr)
    .lte('end_date', assignWarnStr)
    .order('end_date', { ascending: true })

  const { data: projects } = await sb.from('projects').select('id, name').eq('org_id', orgId).eq('active', true)
  const projMap = Object.fromEntries((projects || []).map((p: any) => [p.id, p.name]))

  const assignRows: string[] = (endingRaw || []).map((a: any) => {
    const days = daysUntil(a.end_date, today)
    return row(
      esc(workerMap[a.worker_id] || 'Unknown'),
      esc(projMap[a.project_id]  || 'Unknown project'),
      `<span style="color:#b45309;font-weight:600;">Ends in ${days}d</span>`,
      fmt(a.end_date)
    )
  })

  // ── 3. Uncharged billable weeks ──────────────────────────────────────────
  const [
    { data: accomAssign }, { data: accomCharges },
    { data: vehAssign },   { data: vehCharges },
    { data: properties },  { data: vehicles }
  ] = await Promise.all([
    sb.from('accommodation_assignments').select('id, worker_id, property_id, start_date, end_date').eq('org_id', orgId).eq('active', true).eq('charge_to_operative', true),
    sb.from('accommodation_charges').select('assignment_id, week_key').eq('org_id', orgId).eq('active', true).eq('charged', true),
    sb.from('vehicle_assignments').select('id, worker_id, vehicle_id, start_date, end_date').eq('org_id', orgId).eq('active', true).eq('charge_to_operative', true),
    sb.from('vehicle_charges').select('assignment_id, week_key').eq('org_id', orgId).eq('active', true).eq('charged', true),
    sb.from('properties').select('id, name').eq('org_id', orgId).eq('active', true),
    sb.from('vehicles').select('id, description').eq('org_id', orgId).eq('active', true),
  ])

  const propMap = Object.fromEntries((properties || []).map((p: any) => [p.id, p.name]))
  const vehMap  = Object.fromEntries((vehicles  || []).map((v: any) => [v.id, v.description]))

  const chargedAccomSet = new Set((accomCharges || []).map((c: any) => `${c.assignment_id}__${c.week_key}`))
  const chargedVehSet   = new Set((vehCharges   || []).map((c: any) => `${c.assignment_id}__${c.week_key}`))

  function unchargedWeeks(assignments: any[], chargedSet: Set<string>, resourceMap: Record<string, string>): string[] {
    const rows: string[] = []
    for (const a of (assignments || [])) {
      const start = weekMonday(new Date(a.start_date))
      const end   = a.end_date ? new Date(a.end_date) : today
      let cur = new Date(start)
      while (cur < today && cur <= end) {
        const wk = isoWeekKey(cur)
        if (!chargedSet.has(`${a.id}__${wk}`)) {
          rows.push(row(
            esc(workerMap[a.worker_id] || 'Unknown'),
            esc(resourceMap[a.property_id || a.vehicle_id] || 'Unknown'),
            `<span style="color:#b45309;font-weight:600;">${wk}</span>`,
            'Not charged'
          ))
        }
        cur = new Date(+cur + 7 * 86400000)
      }
    }
    return rows
  }

  const unchargedAccomRows = unchargedWeeks(accomAssign || [], chargedAccomSet, propMap)
  const unchargedVehRows   = unchargedWeeks(vehAssign   || [], chargedVehSet,   vehMap)

  // ── Build email ──────────────────────────────────────────────────────────
  const totalItems = expiredRows.length + expiringRows.length + assignRows.length +
    unchargedAccomRows.length + unchargedVehRows.length

  if (totalItems === 0) return { org: orgName, sent: false, reason: 'nothing to report' }

  const colHdr = (cols: string[]) =>
    `<tr>${cols.map(c => `<th style="padding:7px 14px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:.04em;text-align:left;background:#f8fafc;border-bottom:1px solid #e2e8f0;">${c}</th>`).join('')}</tr>`

  const docTableHdr     = colHdr(['Worker', 'Document', 'Status', 'Expiry date'])
  const assignTableHdr  = colHdr(['Worker', 'Project', 'Status', 'End date'])
  const billingTableHdr = colHdr(['Worker', 'Resource', 'Week', 'Status'])

  const html = `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:680px;margin:32px auto;padding:0 16px;">

  <!-- Header -->
  <div style="background:#1a2035;border-radius:8px 8px 0 0;padding:20px 24px;">
    <div style="font-size:18px;font-weight:700;color:#fff;">${esc(orgName)} Compliance · Daily Digest</div>
    <div style="font-size:12px;color:#94a3b8;margin-top:4px;">${new Date().toLocaleDateString('en-GB', { weekday:'long', day:'numeric', month:'long', year:'numeric' })} · ${totalItems} item${totalItems !== 1 ? 's' : ''} requiring attention</div>
  </div>

  <!-- Body -->
  <div style="background:#f8fafc;padding:20px 0;">

    ${section('🔴 &nbsp;No-Go — Expired / Missing Documents', '#c53030',
      expiredRows.length ? [docTableHdr, ...expiredRows] : [])}

    ${section('🟠 &nbsp;Warning — Documents Expiring Soon', '#b45309',
      expiringRows.length ? [docTableHdr, ...expiringRows] : [])}

    ${section('📋 &nbsp;Assignments Ending Within 14 Days', '#1d4ed8',
      assignRows.length ? [assignTableHdr, ...assignRows] : [])}

    ${section('🏠 &nbsp;Uncharged Accommodation Weeks', '#065f46',
      unchargedAccomRows.length ? [billingTableHdr, ...unchargedAccomRows] : [])}

    ${section('🚗 &nbsp;Uncharged Vehicle Weeks', '#065f46',
      unchargedVehRows.length ? [billingTableHdr, ...unchargedVehRows] : [])}

  </div>

  <!-- Footer -->
  <div style="background:#1a2035;border-radius:0 0 8px 8px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#64748b;">${esc(orgName)} · Labour Compliance & Management · Automated digest — do not reply</span>
  </div>

</div>
</body>
</html>`

  // ── Send (only to THIS org's recipients) ─────────────────────────────────
  const sends = await Promise.all(recipients.map(to =>
    fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: FROM,
        to,
        subject: `${orgName} Compliance Digest — ${totalItems} item${totalItems !== 1 ? 's' : ''} · ${todayStr}`,
        html,
      }),
    }).then(r => r.json())
  ))

  return { org: orgName, sent: true, items: totalItems, recipients, sends }
}

// ── main handler — loops every organisation ─────────────────────────────────
Deno.serve(async (_req) => {
  try {
    const sb = createClient(SUPABASE_URL, SUPABASE_KEY)
    const today = new Date(); today.setHours(0, 0, 0, 0)

    // One digest per organisation, each scoped to and sent to that org only.
    const { data: orgs, error: orgErr } = await sb
      .from('organisations')
      .select('id, name, owner_email, compliance_email, warning_days')
    if (orgErr) throw orgErr

    const results = []
    for (const org of (orgs || [])) {
      try {
        results.push(await digestForOrg(sb, org, today))
      } catch (e: any) {
        console.error('[daily-digest]', org?.name, e?.message || e)
        results.push({ org: org?.name, sent: false, error: e?.message || String(e) })
      }
    }

    return new Response(JSON.stringify({ orgs: results.length, results }), {
      headers: { 'Content-Type': 'application/json' },
    })

  } catch (err: any) {
    console.error('[daily-digest]', err)
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
