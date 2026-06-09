import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const DROPBOX_SIGN_API_KEY = Deno.env.get('DROPBOX_SIGN_API_KEY')!
const SUPABASE_URL          = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY          = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
// Set DROPBOX_SIGN_TEST_MODE=0 in Supabase secrets when ready for production.
// In test_mode=1 requests are free and don't count against quota but emails
// are still sent to real signers. Switch to 0 for live client signing.
const TEST_MODE = Deno.env.get('DROPBOX_SIGN_TEST_MODE') ?? '1'

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })

  try {
    // ── Verify caller JWT ──────────────────────────────────────────────────
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!jwt) return json({ error: 'Unauthorized' }, 401)

    const sb = createClient(SUPABASE_URL, SUPABASE_KEY)

    const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
    if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)

    // Derive org from profile — never trust a caller-supplied org_id
    const { data: profile } = await sb.from('profiles').select('org_id, role')
      .eq('id', user.id).maybeSingle()
    if (!profile?.org_id) return json({ error: 'No organisation' }, 403)
    const orgId = profile.org_id

    // ── Parse body ─────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}))
    const { type, reference_id, file_path, file_name, worker_id } = body

    if (!type || !reference_id || !file_path || !worker_id) {
      return json({ error: 'type, reference_id, file_path, worker_id required' }, 400)
    }
    if (!['assignment', 'issued_doc'].includes(type)) {
      return json({ error: "type must be 'assignment' or 'issued_doc'" }, 400)
    }

    // ── Verify reference belongs to this org (cross-org guard) ─────────────
    if (type === 'assignment') {
      const { data: asgn } = await sb.from('project_assignments')
        .select('id').eq('id', reference_id).eq('org_id', orgId).maybeSingle()
      if (!asgn) return json({ error: 'Assignment not found' }, 404)
    } else {
      const { data: idoc } = await sb.from('issued_documents')
        .select('id').eq('id', reference_id).eq('org_id', orgId).maybeSingle()
      if (!idoc) return json({ error: 'Issued document not found' }, 404)
    }

    // ── Fetch worker ───────────────────────────────────────────────────────
    const { data: worker } = await sb.from('workers')
      .select('id, full_name, email')
      .eq('id', worker_id).eq('org_id', orgId).eq('active', true).maybeSingle()
    if (!worker)       return json({ error: 'Worker not found' }, 404)
    if (!worker.email) return json({ error: 'Worker has no email address on file' }, 400)

    // ── Org name for email context ─────────────────────────────────────────
    const { data: org } = await sb.from('organisations').select('name').eq('id', orgId).maybeSingle()
    const orgName = org?.name || 'Your company'

    // ── Generate a short-lived signed URL for the file ─────────────────────
    // Dropbox Sign fetches the document from this URL (10-minute window).
    const { data: signedUrlData, error: urlErr } = await sb.storage
      .from('tmc-documents').createSignedUrl(file_path, 600)
    if (urlErr || !signedUrlData?.signedUrl) {
      console.error('[send-for-signature] signed URL error:', urlErr)
      return json({ error: 'Could not create download URL for the file' }, 500)
    }

    // ── Send signature request to Dropbox Sign ─────────────────────────────
    const formData = new FormData()
    formData.append('title',                   file_name || 'Document for Signature')
    formData.append('subject',                 `${orgName}: Please sign your document`)
    formData.append('message',                 `${orgName} has sent you a document to review and sign. Please follow the link to complete your signature.`)
    formData.append('signers[0][email_address]', worker.email)
    formData.append('signers[0][name]',          worker.full_name || worker.email)
    formData.append('file_urls[0]',              signedUrlData.signedUrl)
    // Parse embedded text tags in the PDF (e.g. [sig|req|signer1], [date|req|signer1]).
    // Safe for all PDFs — if no tags found, Dropbox Sign falls back to drag-to-place UI.
    // hide_text_tags=1 makes the tag strings invisible in the final signed document.
    formData.append('use_text_tags',  '1')
    formData.append('hide_text_tags', '1')
    // Metadata is echoed back in webhook — used to route the signed PDF
    formData.append('metadata[type]',         type)
    formData.append('metadata[reference_id]', reference_id)
    formData.append('metadata[org_id]',       orgId)
    formData.append('metadata[worker_id]',    worker_id)
    formData.append('test_mode',              TEST_MODE)

    const dsRes = await fetch('https://api.hellosign.com/v3/signature_request/send', {
      method:  'POST',
      headers: { 'Authorization': 'Basic ' + btoa(DROPBOX_SIGN_API_KEY + ':') },
      body:    formData,
    })

    if (!dsRes.ok) {
      const errText = await dsRes.text()
      console.error('[send-for-signature] Dropbox Sign error:', dsRes.status, errText)
      return json({ error: `Dropbox Sign error ${dsRes.status}: ${errText}` }, 502)
    }

    const dsData = await dsRes.json()
    const sigRequestId = dsData.signature_request?.signature_request_id
    if (!sigRequestId) return json({ error: 'No signature_request_id in Dropbox Sign response' }, 502)

    // ── Store request ID and set status to pending ─────────────────────────
    if (type === 'assignment') {
      await sb.from('project_assignments')
        .update({ signature_status: 'pending', signature_request_id: sigRequestId })
        .eq('id', reference_id).eq('org_id', orgId)
    } else {
      await sb.from('issued_documents')
        .update({ signature_request_id: sigRequestId })
        .eq('id', reference_id).eq('org_id', orgId)
    }

    return json({ sent: true, signature_request_id: sigRequestId, to: worker.email })

  } catch (err: any) {
    console.error('[send-for-signature]', err)
    return json({ error: err.message }, 500)
  }
})
