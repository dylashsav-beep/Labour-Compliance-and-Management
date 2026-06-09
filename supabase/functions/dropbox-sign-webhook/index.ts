import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const DROPBOX_SIGN_API_KEY = Deno.env.get('DROPBOX_SIGN_API_KEY')!
const SUPABASE_URL          = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY          = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// Dropbox Sign requires this exact response body to acknowledge receipt.
const ACK = new Response('Hello API Event Received', {
  status:  200,
  headers: { 'Content-Type': 'text/plain' },
})

// Verify using event_hash — the officially supported Dropbox Sign method.
// HMAC-SHA256(key=api_key, message=event_time+event_type) must equal payload.event.event_hash.
// This is inside the payload itself, so no header dependency.
async function verifyEventHash(payload: any): Promise<boolean> {
  try {
    const eventTime = String(payload?.event?.event_time  || '')
    const eventType = String(payload?.event?.event_type  || '')
    const eventHash = String(payload?.event?.event_hash  || '')
    if (!eventTime || !eventType || !eventHash) {
      console.warn('[dropbox-sign-webhook] payload missing event_time/event_type/event_hash')
      return false
    }
    const apiKey    = DROPBOX_SIGN_API_KEY.trim()
    const keyBytes  = new TextEncoder().encode(apiKey)
    const msgBytes  = new TextEncoder().encode(eventTime + eventType)
    const cryptoKey = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
    )
    const sigBuf   = await crypto.subtle.sign('HMAC', cryptoKey, msgBytes)
    const computed = Array.from(new Uint8Array(sigBuf)).map(b => b.toString(16).padStart(2, '0')).join('')
    const match    = computed === eventHash
    console.log('[dropbox-sign-webhook] event_hash verified:', match)
    return match
  } catch (e: any) {
    console.error('[dropbox-sign-webhook] event_hash verify error:', e?.message)
    return false
  }
}

Deno.serve(async (req) => {
  try {
    const contentType = req.headers.get('content-type') || ''

    // Dropbox Sign sends multipart/form-data with the JSON payload in a field
    // called 'json'. URLSearchParams cannot parse multipart — use formData().
    let payloadStr: string | null = null
    if (contentType.includes('multipart/form-data')) {
      const formData = await req.formData()
      payloadStr = formData.get('json') as string | null
    } else {
      // Fallback for url-encoded format (e.g. test pings)
      const rawBody = await req.text()
      const params = new URLSearchParams(rawBody)
      payloadStr = params.get('json') || params.get('payload')
    }

    if (!payloadStr) {
      console.warn('[dropbox-sign-webhook] No payload found in body — ACK and skip')
      return ACK
    }

    const payload = JSON.parse(payloadStr)

    // Verify the event came from Dropbox Sign using the event_hash field.
    // SHA256(event_time + event_type + api_key) — no header dependency.
    if (!(await verifyEventHash(payload))) {
      console.warn('[dropbox-sign-webhook] event_hash verification failed — rejecting event')
      return ACK
    }

    const eventType  = payload?.event?.event_type as string
    const sigRequest = payload?.signature_request

    if (!sigRequest) return ACK

    const metadata    = sigRequest.metadata || {}
    const { type, reference_id, org_id, worker_id } = metadata

    if (!type || !reference_id || !org_id) {
      console.error('[dropbox-sign-webhook] Missing metadata, cannot route event:', metadata)
      return ACK
    }

    const sb = createClient(SUPABASE_URL, SUPABASE_KEY)
    const sigRequestId: string = sigRequest.signature_request_id

    // ── Declined / cancelled ───────────────────────────────────────────────
    if (eventType === 'signature_request_declined' || eventType === 'signature_request_canceled') {
      if (type === 'assignment') {
        await sb.from('project_assignments')
          .update({ signature_status: 'declined' })
          .eq('id', reference_id).eq('org_id', org_id)
      } else {
        // Leave status as pending_signature but clear request so admin can retry
        await sb.from('issued_documents')
          .update({ signature_request_id: null })
          .eq('id', reference_id).eq('org_id', org_id)
      }
      return ACK
    }

    // ── Signed ─────────────────────────────────────────────────────────────
    // signature_request_all_signed fires when every signer is done and the
    // finalised PDF is available. signature_request_signed fires per-signer
    // and the files API returns 409 until all have signed — don't use it.
    if (eventType === 'signature_request_all_signed') {
      // Download the completed signed PDF from Dropbox Sign
      const fileRes = await fetch(
        `https://api.hellosign.com/v3/signature_request/files/${sigRequestId}?file_type=pdf`,
        { headers: { 'Authorization': 'Basic ' + btoa(DROPBOX_SIGN_API_KEY + ':') } }
      )

      if (!fileRes.ok) {
        console.error('[dropbox-sign-webhook] Failed to download signed PDF:', fileRes.status)
        return ACK
      }

      const pdfBytes = await fileRes.arrayBuffer()
      const timestamp = Date.now()

      if (type === 'assignment') {
        // Store signed PDF replacing the original contract
        const signedPath = `${org_id}/assignments/${reference_id}/signed_contract_${timestamp}.pdf`
        const { error: uploadErr } = await sb.storage
          .from('tmc-documents')
          .upload(signedPath, pdfBytes, { contentType: 'application/pdf', upsert: false })

        if (uploadErr) {
          console.error('[dropbox-sign-webhook] Upload failed:', uploadErr.message)
          return ACK
        }

        // Soft-deactivate the original unsigned files (preserves audit trail)
        await sb.from('project_assignment_files')
          .update({ active: false })
          .eq('project_assignment_id', reference_id)
          .eq('org_id', org_id)

        // Insert signed version as the sole active file
        await sb.from('project_assignment_files').insert({
          id:                    crypto.randomUUID(),
          project_assignment_id: reference_id,
          file_name:             `Signed Contract ${new Date().toLocaleDateString('en-GB')}.pdf`,
          file_path:             signedPath,
          mime_type:             'application/pdf',
          size_bytes:            pdfBytes.byteLength,
          active:                true,
          org_id,
        })

        await sb.from('project_assignments')
          .update({ signature_status: 'signed' })
          .eq('id', reference_id).eq('org_id', org_id)

      } else {
        // Issued document — store signed copy, update status
        const signedPath = `${org_id}/workers/${worker_id}/issued-docs/signed_${timestamp}.pdf`
        const { error: uploadErr } = await sb.storage
          .from('tmc-documents')
          .upload(signedPath, pdfBytes, { contentType: 'application/pdf', upsert: false })

        if (uploadErr) {
          console.error('[dropbox-sign-webhook] Upload failed:', uploadErr.message)
          return ACK
        }

        await sb.from('issued_documents')
          .update({ status: 'signed', signed_file_path: signedPath })
          .eq('id', reference_id).eq('org_id', org_id)
      }
    }

    return ACK

  } catch (err: any) {
    // Always ACK — Dropbox Sign will retry on non-200 which could cause duplicates
    console.error('[dropbox-sign-webhook]', err)
    return ACK
  }
})
