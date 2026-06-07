// demo-request — receives a demo request form submission and emails sales@work-force.nl
//
// Required Supabase secrets (set via Dashboard → Settings → Edge Functions → Secrets):
//   RESEND_API_KEY          — your Resend API key
//   DEMO_REQUEST_FROM       — sender address verified in Resend
//                             Use "sales@work-force.nl" once the domain is verified;
//                             fall back to "onboarding@resend.dev" until then.
//   DEMO_REQUEST_TO         — internal recipient (sales@work-force.nl)

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const FROM           = Deno.env.get('DEMO_REQUEST_FROM') || 'Work Force <onboarding@resend.dev>'
const TO             = Deno.env.get('DEMO_REQUEST_TO')   || 'sales@work-force.nl'

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: corsHeaders })
  }

  let body: { name?: string; company?: string; email?: string; workers?: string; message?: string }
  try {
    body = await req.json()
  } catch {
    return new Response('Invalid JSON', { status: 400, headers: corsHeaders })
  }

  const { name = '', company = '', email = '', workers = '', message = '' } = body

  const html = `
    <h2 style="margin:0 0 16px;color:#1a3082;">New Demo Request — Work Force</h2>
    <table style="border-collapse:collapse;font-family:Inter,Arial,sans-serif;font-size:14px;">
      <tr><td style="padding:6px 16px 6px 0;color:#64748b;white-space:nowrap;">Name</td><td style="padding:6px 0;font-weight:600;">${esc(name)}</td></tr>
      <tr><td style="padding:6px 16px 6px 0;color:#64748b;">Company</td><td style="padding:6px 0;font-weight:600;">${esc(company)}</td></tr>
      <tr><td style="padding:6px 16px 6px 0;color:#64748b;">Email</td><td style="padding:6px 0;"><a href="mailto:${esc(email)}">${esc(email)}</a></td></tr>
      <tr><td style="padding:6px 16px 6px 0;color:#64748b;">Workers</td><td style="padding:6px 0;">${esc(workers)}</td></tr>
      <tr><td style="padding:6px 16px 6px 0;color:#64748b;vertical-align:top;">Message</td><td style="padding:6px 0;white-space:pre-wrap;">${esc(message) || '<em style="color:#94a3b8;">—</em>'}</td></tr>
    </table>
  `

  const res = await fetch('https://api.resend.com/emails', {
    method:  'POST',
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from:    FROM,
      to:      [TO],
      subject: `Demo Request — ${company || 'Unknown company'}`,
      html,
    }),
  })

  if (!res.ok) {
    const err = await res.text()
    console.error('[demo-request] Resend error:', err)
    // Still return 200 to the visitor — don't expose internal errors
    return new Response(JSON.stringify({ ok: false }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
})

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}
