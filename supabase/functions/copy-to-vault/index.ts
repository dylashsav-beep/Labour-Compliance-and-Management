import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — copy org-approved documents into the worker's vault ────────
// Delivers the permanence invariant: once an org approves a document, a copy is
// made into the worker-owned `vault/{account_id}/approved/{org_id}/{doc_key}/...`
// prefix + a vault_documents row (source='org_approved'). That copy survives the
// org later deleting their own file.
//
// Two call shapes:
//   • Org approval (from app.html):  { worker_row_id, doc_key? }
//       authorised when the caller is org staff for that worker's org.
//   • Worker self-backfill (from vault.html on sign-in):  {}  (no body)
//       copies every approved doc across all the caller's linked org rows.
//
// Idempotent: a file already copied (same dest path) is skipped, expiry kept
// fresh. Service-role; identity always derived from the JWT, never a body param.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const BUCKET       = 'tmc-documents'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } })
}

const sb = createClient(SUPABASE_URL, SERVICE_KEY)

function lastSeg(p: string){ return (p || '').split('/').filter(Boolean).pop() || 'file' }

// Copy every active approved file for one worker row into that worker's vault.
async function copyWorkerRow(workerRow: any, docKeyFilter: string | null): Promise<{copied:number; skipped:number}> {
  const account = workerRow.vault_account_id
  if (!account) return { copied: 0, skipped: 0 }   // worker hasn't joined the vault yet

  let q = sb.from('worker_document_files')
    .select('file_path, file_name, name, doc_key, mime_type, active')
    .eq('worker_id', workerRow.id).eq('active', true)
  if (docKeyFilter) q = q.eq('doc_key', docKeyFilter)
  const { data: files } = await q

  let copied = 0, skipped = 0
  for (const f of (files || [])) {
    if (!f.file_path || !f.doc_key) { skipped++; continue }
    const dest = `vault/${account}/approved/${workerRow.org_id}/${f.doc_key}/${lastSeg(f.file_path)}`

    // Already have this exact copy? refresh metadata only.
    const { data: existing } = await sb.from('vault_documents')
      .select('id').eq('worker_account_id', account).eq('file_path', dest).maybeSingle()

    // Pull current expiry/issue + a friendly name.
    const { data: wd } = await sb.from('worker_documents')
      .select('expiry_date, issue_date')
      .eq('id', `${workerRow.id}__${f.doc_key}`).maybeSingle()
    const { data: setItem } = await sb.from('document_set_items')
      .select('name').ilike('id', `%__${f.doc_key}`).eq('org_id', workerRow.org_id).limit(1).maybeSingle()
    const displayName = setItem?.name || f.doc_key

    if (existing) {
      await sb.from('vault_documents').update({
        expiry_date: wd?.expiry_date || null,
        issued_date: wd?.issue_date || null,
        display_name: displayName,
        active: true,
      }).eq('id', existing.id)
      skipped++
      continue
    }

    // Copy the object inside the bucket (service role bypasses RLS).
    const { error: cpErr } = await sb.storage.from(BUCKET).copy(f.file_path, dest)
    if (cpErr && !/exist|dupl/i.test(cpErr.message || '')) { skipped++; continue }

    await sb.from('vault_documents').insert({
      worker_account_id: account,
      doc_key: f.doc_key,
      display_name: displayName,
      file_path: dest,
      file_name: f.file_name || f.name || lastSeg(f.file_path),
      expiry_date: wd?.expiry_date || null,
      issued_date: wd?.issue_date || null,
      source: 'org_approved',
      source_org_id: workerRow.org_id,
      approved_at: new Date().toISOString(),
      active: true,
    })
    copied++
  }
  return { copied, skipped }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)
    const uid = user.id

    const body = await req.json().catch(() => ({}))
    let totals = { copied: 0, skipped: 0 }

    if (body?.worker_row_id) {
      // Single-worker mode — authorise as staff of the worker's org OR the worker.
      const { data: w } = await sb.from('workers')
        .select('id, org_id, vault_account_id').eq('id', body.worker_row_id).maybeSingle()
      if (!w) return json({ error: 'Worker not found' }, 404)

      let allowed = w.vault_account_id === uid
      if (!allowed) {
        const { data: profile } = await sb.from('profiles').select('org_id').eq('id', uid).maybeSingle()
        allowed = !!profile?.org_id && profile.org_id === w.org_id
      }
      if (!allowed) return json({ error: 'Forbidden' }, 403)

      totals = await copyWorkerRow(w, body.doc_key || null)

    } else {
      // Self-backfill — every active org link of the caller.
      const { data: links } = await sb.from('worker_org_links')
        .select('worker_row_id').eq('worker_account_id', uid).eq('status', 'active')
      const ids = (links || []).map(l => l.worker_row_id).filter(Boolean)
      if (ids.length) {
        const { data: rows } = await sb.from('workers')
          .select('id, org_id, vault_account_id').in('id', ids)
        for (const w of (rows || [])) {
          // Ensure the back-reference is set so the vault owns the copy.
          if (w.vault_account_id !== uid) {
            await sb.from('workers').update({ vault_account_id: uid }).eq('id', w.id)
            w.vault_account_id = uid
          }
          const r = await copyWorkerRow(w, null)
          totals.copied += r.copied; totals.skipped += r.skipped
        }
      }
    }

    return json({ ok: true, ...totals })
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
