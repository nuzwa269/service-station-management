// TASK-005 — Supabase Auth "Send SMS" hook. Auth calls this with the login code; it is signed
// with the Standard Webhooks scheme (webhook-id / webhook-timestamp / webhook-signature) using the
// secret shown in Dashboard → Authentication → Hooks (format "v1,whsec_<base64>").
//
// SMS_PROVIDER = "gateway" (default): the code goes into the queue that the platform's Android
//                SMS-gateway phone sends from its own SIM.
//              = "http": an SMS aggregator later — POST to SMS_HTTP_URL with JSON
//                {to, text, api_key}; only this branch changes when an aggregator is chosen.
// Secrets: SEND_SMS_HOOK_SECRET, (http) SMS_HTTP_URL, SMS_HTTP_KEY.
// Self-contained so it can be pasted into the dashboard's function editor.
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

function b64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

/** Standard Webhooks check: HMAC-SHA256 over "id.timestamp.body", any "v1,<sig>" may match. */
async function verify(secret: string, headers: Headers, body: string): Promise<boolean> {
  const id = headers.get("webhook-id") ?? "";
  const ts = headers.get("webhook-timestamp") ?? "";
  const sigs = (headers.get("webhook-signature") ?? "").split(" ");
  if (!id || !ts || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", b64ToBytes(secret.replace(/^v1,whsec_/, "")), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${body}`)));
  const expected = btoa(String.fromCharCode(...mac));
  return sigs.some((s) => {
    const v = s.startsWith("v1,") ? s.slice(3) : "";
    if (v.length !== expected.length) return false;
    let diff = 0;
    for (let i = 0; i < v.length; i++) diff |= v.charCodeAt(i) ^ expected.charCodeAt(i);
    return diff === 0;
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });
  const secret = Deno.env.get("SEND_SMS_HOOK_SECRET");
  if (!secret) return json(500, { error: { http_code: 500, message: "SMS hook is not configured" } });
  const raw = await req.text();
  if (!(await verify(secret, req.headers, raw))) return json(401, { error: { http_code: 401, message: "Bad signature" } });

  const payload = JSON.parse(raw);
  const phone: string = payload?.user?.phone ?? payload?.user?.new_phone ?? "";
  const otp: string = payload?.sms?.otp ?? "";
  if (!phone || !otp) return json(400, { error: { http_code: 400, message: "Missing phone or code" } });
  const text = `${otp} is your Car Service login code. It expires in 5 minutes. Do not share it.`;

  if ((Deno.env.get("SMS_PROVIDER") ?? "gateway") === "http") {
    const res = await fetch(Deno.env.get("SMS_HTTP_URL")!, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ to: "+" + phone.replace(/\D/g, ""), text, api_key: Deno.env.get("SMS_HTTP_KEY") }),
    });
    if (!res.ok) return json(502, { error: { http_code: 502, message: "SMS provider refused the message" } });
    return json(200, {});
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await db.rpc("svc_sms_enqueue", { p_phone: phone, p_body: text, p_kind: "otp" });
  if (error) return json(500, { error: { http_code: 500, message: "Could not queue the SMS" } });
  if (data === "dropped") return json(429, { error: { http_code: 429, message: "Too many codes for this number. Try again in an hour." } });
  return json(200, {});
});
