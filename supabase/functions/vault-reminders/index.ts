import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — document expiry / missing reminders ───────────────────────
// Cron-triggered (daily). Service-role; for each vault account with reminders
// enabled it aggregates documents across ALL the orgs the worker is linked to
// (worker_org_links → worker_documents, scoped to each membership's document
// set) plus the worker's own vault_documents and training certificates, then
// emails ONE batched reminder. Throttled via vault_notification_log so each
// milestone (advance / expiry_day / expired / weekly-missing) sends once.
//
// Identity model: worker-owned (worker_account_id), cross-org. Service role
// bypasses RLS — every query is explicitly scoped by worker_account_id / the
// worker's own worker_row_ids.

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const FROM      = Deno.env.get('DIGEST_FROM') || 'Work Force Vault <onboarding@resend.dev>'
const VAULT_URL = Deno.env.get('VAULT_URL')   || 'https://work-force.nl/vault.html'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } })
}
function esc(s: string) { return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') }
function fmt(s: string) { return new Date(s).toLocaleDateString('en-GB', { day:'numeric', month:'short', year:'numeric' }) }
function addDays(d: Date, n: number): string { return new Date(+d + n * 86400000).toISOString().slice(0, 10) }
function daysUntil(dateStr: string, today: Date): number {
  return Math.ceil((new Date(dateStr).setHours(0,0,0,0) - today.getTime()) / 86400000)
}

// ── Lucide icons (inline SVG) — render in Apple/iOS Mail; text labels remain
//    where a client strips SVG (graceful degradation). ──
const ICON_PATHS: Record<string, string> = {
  'alert-triangle': '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  'clock': '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  'file-text': '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M16 13H8"/><path d="M16 17H8"/><path d="M10 9H8"/>',
  'shield-check': '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1Z"/><path d="m9 12 2 2 4-4"/>',
  'arrow-right': '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
  'check-circle': '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><path d="m9 11 3 3L22 4"/>',
}
function icon(name: string, colour = 'currentColor', size = 14): string {
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${colour}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-2px;">${ICON_PATHS[name] || ''}</svg>`
}

interface Dated { name: string; date: string; days: number }

function docTable(colour: string, ic: string, title: string, rows: string[]): string {
  return `<div style="margin-bottom:16px;">
    <div style="background:${colour};border-radius:6px 6px 0 0;padding:10px 16px;">
      <span style="font-size:13px;font-weight:700;color:#fff;">${ic} ${esc(title)}</span>
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

function buildEmail(workerName: string, expired: Dated[], expiring: Dated[], missing: string[]): string {
  const secs: string[] = []
  if (expired.length) secs.push(docTable('#c53030', icon('alert-triangle','#fff',14), `Expired (${expired.length})`,
    expired.map(d => dRow(d.name, `<span style="color:#c53030;font-weight:600;">Expired · ${fmt(d.date)}</span>`))))
  if (expiring.length) secs.push(docTable('#b45309', icon('clock','#fff',14), `Expiring soon (${expiring.length})`,
    expiring.map(d => dRow(d.name, `<span style="color:#b45309;font-weight:600;">${d.days === 0 ? 'Expires today' : `Expires in ${d.days} day${d.days!==1?'s':''}`} · ${fmt(d.date)}</span>`))))
  if (missing.length) secs.push(docTable('#7c3aed', icon('file-text','#fff',14), `Missing (${missing.length})`,
    missing.map(n => dRow(n, `<span style="color:#c53030;font-weight:600;">Not on file — please add</span>`))))

  const total = expired.length + expiring.length + missing.length
  return `<!DOCTYPE html><html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/></head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:600px;margin:24px auto;padding:0 12px;">
  <div style="background:linear-gradient(135deg,#7c3aed 0%,#6d28d9 55%,#4c1d95 100%);background-color:#6d28d9;border-radius:10px 10px 0 0;padding:24px;">
    <div style="font-size:18px;font-weight:800;color:#fff;">${icon('shield-check','#fff',18)} &nbsp;Work Force Vault</div>
    <div style="font-size:12px;color:rgba(255,255,255,.7);margin-top:3px;">Document reminders</div>
  </div>
  <div style="background:#fff;padding:24px;border-left:1px solid #e2e8f0;border-right:1px solid #e2e8f0;">
    <p style="font-size:15px;color:#1a2035;margin:0 0 6px 0;font-weight:600;">Hi ${esc(workerName || 'there')},</p>
    <p style="font-size:14px;color:#374151;margin:0 0 24px 0;line-height:1.55;">You have <strong>${total} document${total!==1?'s':''}</strong> in your vault that need your attention. Keep them current so you're always ready for your next job.</p>
    ${secs.join('')}
    <div style="text-align:center;margin-top:28px;padding-top:20px;border-top:1px solid #f0f4f8;">
      <a href="${esc(VAULT_URL)}" style="display:inline-block;background:#7c3aed;color:#fff;text-decoration:none;font-size:15px;font-weight:700;padding:14px 36px;border-radius:8px;">Open My Vault &nbsp;${icon('arrow-right','#fff',15)}</a>
      <div style="font-size:11px;color:#94a3b8;margin-top:10px;word-break:break-all;">Or copy: ${esc(VAULT_URL)}</div>
    </div>
  </div>
  <div style="background:#f8fafc;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 10px 10px;padding:14px 24px;text-align:center;">
    <span style="font-size:11px;color:#94a3b8;">Work Force Vault · You can change or turn off these reminders in your vault settings.</span>
  </div>
</div></body></html>`
}

// ── Per-account reminder ──────────────────────────────────────────────────────
async function remindAccount(sb: any, acct: any, today: Date, todayStr: string) {
  const reminderDays = Math.max(1, acct.reminder_days || 30)
  const windowStr = addDays(today, reminderDays)

  // Candidate dated docs: {key (for throttle), name, date}; and missing names.
  type Cand = { key: string; name: string; date: string }
  const dated: Cand[] = []
  const missing: { key: string; name: string }[] = []
  const seenDated = new Set<string>()   // de-dupe identical (key|date)
  const seenMissing = new Set<string>()

  // (a) Compliance docs across all active org memberships.
  const { data: links } = await sb.from('worker_org_links')
    .select('worker_row_id, org_id').eq('worker_account_id', acct.id).eq('status', 'active')
  const workerRowIds = [...new Set((links || []).map((l: any) => l.worker_row_id).filter(Boolean))]

  if (workerRowIds.length) {
    const { data: wkrs } = await sb.from('workers').select('id, document_set_id').in('id', workerRowIds)
    const setByWorker: Record<string, string> = Object.fromEntries((wkrs || []).map((w: any) => [w.id, w.document_set_id]))
    const setIds = [...new Set((wkrs || []).map((w: any) => w.document_set_id).filter(Boolean))]

    const itemBySetKey: Record<string, { name: string; required: boolean }> = {}
    if (setIds.length) {
      const { data: items } = await sb.from('document_set_items')
        .select('id, name, required, document_set_id').in('document_set_id', setIds).eq('active', true)
      for (const it of (items || [])) {
        const shortKey = it.id.includes('__') ? it.id.split('__').slice(1).join('__') : it.id
        itemBySetKey[`${it.document_set_id}__${shortKey}`] = { name: it.name, required: !!it.required }
      }
    }

    const { data: wdocs } = await sb.from('worker_documents')
      .select('worker_id, doc_key, status, expiry_date').in('worker_id', workerRowIds).eq('active', true)
    const docByWorkerKey: Record<string, any> = {}
    for (const d of (wdocs || [])) docByWorkerKey[`${d.worker_id}__${d.doc_key}`] = d

    // For each worker row, walk its required doc-set items.
    for (const wid of workerRowIds) {
      const setId = setByWorker[wid]
      if (!setId) continue
      for (const fullKey of Object.keys(itemBySetKey)) {
        if (!fullKey.startsWith(`${setId}__`)) continue
        const item = itemBySetKey[fullKey]
        if (!item.required) continue
        const docKey = fullKey.slice(setId.length + 2)
        const doc = docByWorkerKey[`${wid}__${docKey}`]
        const name = item.name
        if (!doc || doc.status === 'missing') {
          if (!seenMissing.has(name)) { seenMissing.add(name); missing.push({ key: docKey, name }) }
        } else if (doc.expiry_date) {
          const k = `${docKey}|${doc.expiry_date}`
          if (!seenDated.has(k)) { seenDated.add(k); dated.push({ key: docKey, name, date: doc.expiry_date }) }
        }
        // present, no expiry → OK, skip
      }
    }
  }

  // (b) Worker-owned vault documents (always on file; only expiry matters).
  const { data: vdocs } = await sb.from('vault_documents')
    .select('doc_key, display_name, expiry_date').eq('worker_account_id', acct.id).eq('active', true)
  for (const v of (vdocs || [])) {
    if (!v.expiry_date) continue
    const name = v.display_name || v.doc_key || 'Document'
    const k = `vault:${v.doc_key || name}|${v.expiry_date}`
    if (!seenDated.has(k)) { seenDated.add(k); dated.push({ key: `vault:${v.doc_key || name}`, name, date: v.expiry_date }) }
  }

  // (c) Training certificates (approved competency records with an expiry).
  if (workerRowIds.length) {
    const { data: crecs } = await sb.from('worker_competency_records')
      .select('competency_id, expiry_date, status').in('worker_id', workerRowIds).eq('active', true).eq('status', 'approved')
    const compIds = [...new Set((crecs || []).map((r: any) => r.competency_id).filter(Boolean))]
    let compName: Record<string, string> = {}
    if (compIds.length) {
      const { data: comps } = await sb.from('worker_competencies').select('id, name').in('id', compIds)
      compName = Object.fromEntries((comps || []).map((c: any) => [c.id, c.name]))
    }
    for (const r of (crecs || [])) {
      if (!r.expiry_date) continue
      const name = compName[r.competency_id] || 'Certificate'
      const k = `comp:${r.competency_id}|${r.expiry_date}`
      if (!seenDated.has(k)) { seenDated.add(k); dated.push({ key: `comp:${r.competency_id}`, name, date: r.expiry_date }) }
    }
  }

  // ── Throttle: load recent log rows for this account. ──
  const sinceStr = new Date(+today - 60 * 86400000).toISOString()
  const { data: logs } = await sb.from('vault_notification_log')
    .select('doc_key, milestone, target_date, sent_at').eq('worker_account_id', acct.id).gte('sent_at', sinceStr)
  const sentSet = new Set<string>()
  let lastMissingAt = 0
  for (const lg of (logs || [])) {
    if (lg.milestone === 'missing') { lastMissingAt = Math.max(lastMissingAt, +new Date(lg.sent_at)); continue }
    sentSet.add(`${lg.doc_key}|${lg.milestone}|${lg.target_date}`)
  }
  const missingDue = (+today - lastMissingAt) >= 7 * 86400000   // weekly throttle for missing

  // ── Classify candidates into milestones, suppress already-sent ones. ──
  const expired: Dated[] = [], expiring: Dated[] = []
  const toLog: { doc_key: string; milestone: string; target_date: string | null }[] = []

  for (const c of dated) {
    const days = daysUntil(c.date, today)
    let milestone: string | null = null
    if (days < 0) milestone = 'expired'
    else if (days === 0) milestone = 'expiry_day'
    else if (days <= reminderDays) milestone = 'advance'
    if (!milestone) continue
    const logKey = `${c.key}|${milestone}|${c.date}`
    if (sentSet.has(logKey)) continue
    if (milestone === 'expired') expired.push({ name: c.name, date: c.date, days })
    else expiring.push({ name: c.name, date: c.date, days })   // expiry_day & advance share the "expiring" section
    toLog.push({ doc_key: c.key, milestone, target_date: c.date })
  }

  const missingNames: string[] = []
  if (acct.reminder_missing && missing.length && missingDue) {
    for (const m of missing) {
      missingNames.push(m.name)
      toLog.push({ doc_key: m.key, milestone: 'missing', target_date: null })
    }
  }

  if (!expired.length && !expiring.length && !missingNames.length) {
    return { account: acct.id, sent: false, reason: 'nothing due' }
  }

  // Sort expiring by soonest first.
  expiring.sort((a, b) => a.days - b.days)

  const html = buildEmail(acct.full_name, expired, expiring, missingNames)
  const total = expired.length + expiring.length + missingNames.length
  const subject = `${total} document${total!==1?'s':''} in your Work Force Vault need attention`

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to: acct.email, subject, html }),
  })
  if (!res.ok) {
    const t = await res.text()
    console.error('[vault-reminders] resend error', acct.id, res.status, t)
    return { account: acct.id, sent: false, error: `resend ${res.status}` }
  }

  // Record what we sent so it isn't re-sent (until renewal / next week for missing).
  if (toLog.length) {
    await sb.from('vault_notification_log').insert(
      toLog.map(r => ({ worker_account_id: acct.id, doc_key: r.doc_key, milestone: r.milestone, target_date: r.target_date }))
    )
  }
  return { account: acct.id, sent: true, to: acct.email, expired: expired.length, expiring: expiring.length, missing: missingNames.length }
}

// ── main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })
  try {
    const sb = createClient(SUPABASE_URL, SUPABASE_KEY)
    const today = new Date(); today.setHours(0, 0, 0, 0)
    const todayStr = today.toISOString().slice(0, 10)

    const { data: accounts, error } = await sb.from('worker_accounts')
      .select('id, email, full_name, reminder_days, reminder_missing')
      .eq('reminder_enabled', true).not('email', 'is', null)
    if (error) throw error

    const results = []
    for (const acct of (accounts || [])) {
      try { results.push(await remindAccount(sb, acct, today, todayStr)) }
      catch (e: any) {
        console.error('[vault-reminders]', acct.id, e?.message || e)
        results.push({ account: acct.id, sent: false, error: e?.message || String(e) })
      }
    }
    return json({ accounts: (accounts || []).length, sent: results.filter((r: any) => r.sent).length, results })
  } catch (err: any) {
    console.error('[vault-reminders]', err)
    return json({ error: err.message }, 500)
  }
})
