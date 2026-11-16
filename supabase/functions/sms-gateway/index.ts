// TASK-005 — endpoint for the platform's Android SMS-gateway phone.
//   POST {action: "claim", device, info}         → {messages: [{id, phone, body}]}
//   POST {action: "report", id, ok, error?}      → {ok: true}
// The phone sends the shared secret in the "x-gateway-secret" header (GATEWAY_SECRET).
// No user login: verify_jwt is off for this function. Self-contained for the dashboard editor.
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

function sameSecret(a: string, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });
  const secret = Deno.env.get("GATEWAY_SECRET") ?? "";
  if (secret.length < 24) return json(500, { error: "NOT_CONFIGURED" });
  if (!sameSecret(req.headers.get("x-gateway-secret") ?? "", secret)) return json(403, { error: "FORBIDDEN" });

  let b: any;
  try { b = await req.json(); } catch { return json(400, { error: "VALIDATION" }); }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  if (b.action === "claim") {
    const { data, error } = await db.rpc("svc_sms_claim", { p_device: String(b.device ?? "gateway"), p_limit: 10, p_info: b.info ?? {} });
    if (error) return json(500, { error: error.message });
    return json(200, { messages: data ?? [] });
  }
  if (b.action === "report" && Number.isInteger(b.id)) {
    const { error } = await db.rpc("svc_sms_report", { p_id: b.id, p_ok: b.ok === true, p_error: b.error ?? null });
    if (error) return json(500, { error: error.message });
    return json(200, { ok: true });
  }
  return json(400, { error: "VALIDATION" });
});
