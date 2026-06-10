import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — submit a vault document into an org's compliance request ────
// A vault worker pushes one of their own documents (personal upload or an
// org-approved copy) back into a specific employer's pending-review queue. The
// function copies the file into that org's submission path and inserts a
// worker_document_submissions row (status='pending') so it surfaces in the
// org's Approvals tab — exactly like an anon worker-portal submission.
//
// Identity from JWT only. The worker must own the vault doc AND be actively
// linked to the target org (verified via worker_org_links).

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
function extOf(name: string){ const m = /\.([a-zA-Z0-9]{1,6})$/.exec(name || ''); return m ? m[1].toLowerCase() : 'dat' }

const sb = createClient(SUPABASE_URL, SERVICE_KEY)

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)
    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)
    const uid = user.id

    const body = await req.json().catch(() => ({}))
    const vaultDocId = body?.vault_doc_id
    const orgId      = body?.org_id
    const docKey     = String(body?.doc_key || '').trim()
    const notes      = body?.notes ? String(body.notes).slice(0, 500) : null
    if (!vaultDocId || !orgId || !docKey) {
      return json({ error: 'vault_doc_id, org_id and doc_key are required' }, 400)
    }

    // 1. The vault document must belong to the caller.
    const { data: vd } = await sb.from('vault_documents')
      .select('id, worker_account_id, file_path, file_name, expiry_date, issued_date, active')
      .eq('id', vaultDocId).maybeSingle()
    if (!vd || vd.worker_account_id !== uid || vd.active === false || !vd.file_path) {
      return json({ error: 'Document not found' }, 404)
    }

    // 2. The caller must be actively linked to the target org; get the worker row.
    const { data: link } = await sb.from('worker_org_links')
      .select('worker_row_id').eq('worker_account_id', uid)
      .eq('org_id', orgId).eq('status', 'active').maybeSingle()
    if (!link?.worker_row_id) return json({ error: 'You are not linked to that organisation' }, 403)

    const { data: w } = await sb.from('workers')
      .select('id, email, org_id, active').eq('id', link.worker_row_id).maybeSingle()
    if (!w || w.active === false) return json({ error: 'Worker record unavailable' }, 404)

    // 3. Copy the file into the org's submission path (org-isolated prefix).
    const dest = `${orgId}/worker-submissions/${w.id}/${docKey}/${Date.now()}.${extOf(vd.file_name || '')}`
    const { error: cpErr } = await sb.storage.from(BUCKET).copy(vd.file_path, dest)
    if (cpErr) return json({ error: 'Could not stage the file: ' + cpErr.message }, 502)

    // 4. Insert the pending submission (org-scoped) so staff see it in Approvals.
    const { data: ins, error: insErr } = await sb.from('worker_document_submissions').insert({
      worker_id: w.id,
      doc_key: docKey,
      submitted_by_email: w.email || user.email || null,
      expiry_date: vd.expiry_date || null,
      issue_date: vd.issued_date || null,
      notes: notes || 'Submitted from Work Force Vault',
      file_path: dest,
      file_name: vd.file_name || `${docKey}.${extOf(vd.file_name || '')}`,
      file_size: null,
      mime_type: null,
      status: 'pending',
      active: true,
      org_id: w.org_id,
    }).select('id').single()
    if (insErr) return json({ error: 'Could not record the submission: ' + insErr.message }, 500)

    return json({ ok: true, submission_id: ins.id })
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
