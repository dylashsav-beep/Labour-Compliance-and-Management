import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const DROPBOX_SIGN_API_KEY = Deno.env.get('DROPBOX_SIGN_API_KEY')!
const SUPABASE_URL          = Deno.env.get('SUPABASE_URL')!
const SUPABASE_KEY          = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// Dropbox Sign requires this exact response body to acknowledge receipt.
const ACK = new Response('Hello API Event Received', {
  status:  200,
  headers: { 'Content-Type': 'text/plain' },
})

async function verifySignature(payloadStr: string, headerSig: string): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(DROPBOX_SIGN_API_KEY),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
    )
    const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payloadStr))
    const hex = Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('')
    return hex === headerSig
  } catch {
    return false
  }
}

Deno.serve(async (req) => {
  try {
    const rawBody = await req.text()
    const params  = new URLSearchParams(rawBody)
    // Dropbox Sign sends real events as form-encoded POST with field name 'json'
    const payloadStr = params.get('json')

    if (!payloadStr) return ACK

    // Require HMAC signature — reject any call that lacks it or has a bad one.
    // An attacker posting directly to this endpoint has no API key so cannot
    // produce a valid signature. Skipping this check would let anyone forge
    // a 'signed' event and write arbitrary files into any org's storage path.
    const headerSig = req.headers.get('X-HelloSign-Signature') || ''
    if (!headerSig || !(await verifySignature(payloadStr, headerSig))) {
      console.warn('[dropbox-sign-webhook] Missing or invalid signature — rejecting event')
      return ACK
    }

    const payload   = JSON.parse(payloadStr)
    const eventType = payload?.event?.event_type as string
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
    if (eventType === 'signature_request_signed') {
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
        // Store signed PDF in org-scoped path alongside the original
        const signedPath = `${org_id}/assignments/${reference_id}/signed_contract_${timestamp}.pdf`
        const { error: uploadErr } = await sb.storage
          .from('tmc-documents')
          .upload(signedPath, pdfBytes, { contentType: 'application/pdf', upsert: false })

        if (uploadErr) {
          console.error('[dropbox-sign-webhook] Upload failed:', uploadErr.message)
          return ACK
        }

        // Insert as a new file entry so it sits alongside the original contract
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
