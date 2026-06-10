import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Worker Vault — signed-download broker (paywall enforced server-side) ──────
// vault.html (authenticated worker) requests a download. The worker's own
// session CANNOT read org-scoped Storage (org RLS blocks it), so this
// service-role function brokers a short-lived signed URL — but ONLY after:
//   1. verifying the caller JWT (auth.uid),
//   2. confirming worker_accounts.plan === 'vault' (and not expired),
//   3. confirming the requested file belongs to a worker row the caller owns
//      (via worker_org_links → workers.id), never trusting a caller-supplied path.
//
// Request body (one of):
//   { type:'document', doc_key:'vca' }            → most recent file for that key
//   { type:'contract', assignment_id:'<uuid>' }   → the assignment's contract PDF
//   { type:'vault_doc', vault_doc_id:'<uuid>' }   → a worker-owned vault document

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const BUCKET       = 'tmc-documents'
const SIGNED_TTL   = 120  // seconds — short-lived

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } })
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

    // Paywall: only Vault-plan workers may download.
    const { data: acct } = await sb.from('worker_accounts')
      .select('plan, plan_expires').eq('id', uid).maybeSingle()
    const expired = acct?.plan_expires && new Date(acct.plan_expires) < new Date()
    if (!acct || acct.plan !== 'vault' || expired) {
      return json({ error: 'upgrade_required' }, 402)
    }

    // The worker rows this account owns (active links only).
    const { data: links } = await sb.from('worker_org_links')
      .select('worker_row_id').eq('worker_account_id', uid).eq('status', 'active')
    const workerRowIds = (links || []).map(l => l.worker_row_id).filter(Boolean)

    const body = await req.json().catch(() => ({}))
    const type = body?.type

    let filePath: string | null = null
    let fileName = 'document'

    if (type === 'vault_doc') {
      // Worker-owned vault document — scoped strictly to the account.
      const { data: vd } = await sb.from('vault_documents')
        .select('file_path, file_name, worker_account_id, active')
        .eq('id', body.vault_doc_id).maybeSingle()
      if (!vd || vd.worker_account_id !== uid || vd.active === false) {
        return json({ error: 'Not found' }, 404)
      }
      filePath = vd.file_path; fileName = vd.file_name || fileName

    } else if (type === 'document') {
      if (!workerRowIds.length) return json({ error: 'Not found' }, 404)
      // Most recent active file for this doc_key across the worker's org rows.
      const { data: files } = await sb.from('worker_document_files')
        .select('file_path, file_name, name, worker_id, doc_key, active, created_at, superseded')
        .in('worker_id', workerRowIds)
        .eq('doc_key', body.doc_key)
        .eq('active', true)
        .order('created_at', { ascending: false })
      const pick = (files || []).find(f => !f.superseded) || (files || [])[0]
      if (!pick) return json({ error: 'Not found' }, 404)
      filePath = pick.file_path; fileName = pick.file_name || pick.name || fileName

    } else if (type === 'contract') {
      if (!workerRowIds.length) return json({ error: 'Not found' }, 404)
      // Confirm the assignment belongs to one of the worker's rows.
      const { data: asg } = await sb.from('project_assignments')
        .select('id, worker_id').eq('id', body.assignment_id).maybeSingle()
      if (!asg || !workerRowIds.includes(asg.worker_id)) return json({ error: 'Not found' }, 404)
      const { data: cf } = await sb.from('project_assignment_files')
        .select('file_path, file_name, active, created_at')
        .eq('project_assignment_id', asg.id)
        .eq('active', true)
        .order('created_at', { ascending: false })
      const pick = (cf || [])[0]
      if (!pick) return json({ error: 'Not found' }, 404)
      filePath = pick.file_path; fileName = pick.file_name || 'contract'

    } else {
      return json({ error: 'Invalid request type' }, 400)
    }

    if (!filePath) return json({ error: 'No file on record' }, 404)

    const { data: signed, error: sErr } = await sb.storage
      .from(BUCKET)
      .createSignedUrl(filePath, SIGNED_TTL, { download: fileName })
    if (sErr || !signed?.signedUrl) return json({ error: 'Could not generate link' }, 500)

    return json({ url: signed.signedUrl, file_name: fileName })
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error' }, 500)
  }
})
