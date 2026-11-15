// TASK-061 · REQ-061 — finishes Meta Embedded Signup for a station.
// The dashboard opens Meta's sign-up window (Facebook JS SDK, META_APP_ID + config id). Meta
// returns a one-time code plus the chosen WhatsApp Business account (waba_id) and phone number
// (phone_number_id). The owner's browser posts them here with the owner's login.
// Steps: check owner + plan (whatsapp_begin_connect as the user) → swap the code for the
// station's token → subscribe our app to the account → register the number → save the account
// → submit the standard English templates → record their review status.
// Secrets: META_APP_ID, META_APP_SECRET.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { graph, GRAPH, GraphError, json, SAMPLES, toMetaBody } from "../_shared/meta.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return withCors(json(405, { error: "METHOD_NOT_ALLOWED" }));
  const appId = Deno.env.get("META_APP_ID");
  const appSecret = Deno.env.get("META_APP_SECRET");
  if (!appId || !appSecret) return withCors(json(503, { error: "NOT_CONFIGURED", message: "WhatsApp connection is not set up on the platform yet" }));

  let body: { station_id?: string; code?: string; waba_id?: string; phone_number_id?: string };
  try { body = await req.json(); } catch { return withCors(json(400, { error: "VALIDATION" })); }
  const { station_id, code, waba_id, phone_number_id } = body;
  if (!station_id || !code || !waba_id || !phone_number_id) return withCors(json(400, { error: "VALIDATION", message: "Sign-up did not finish" }));

  const url = Deno.env.get("SUPABASE_URL")!;
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false },
  });
  const begin = await asUser.rpc("whatsapp_begin_connect", { p_station: station_id });
  if (begin.error) return withCors(json(403, { error: begin.error.message, message: begin.error.details }));

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const fail = async (reason: string) => {
    await admin.rpc("svc_whatsapp_set_account", { p_station: station_id, p_status: "not_connected", p_reason: reason });
    return withCors(json(502, { error: "META_ERROR", message: reason }));
  };

  try {
    // 1. One-time code → the station's business token.
    const tokenRes = await fetch(`${GRAPH}/oauth/access_token?` + new URLSearchParams({ client_id: appId, client_secret: appSecret, code }));
    const tokenBody = await tokenRes.json();
    if (!tokenRes.ok || !tokenBody.access_token) return await fail(tokenBody.error?.message ?? "Meta did not accept the sign-up");
    const token: string = tokenBody.access_token;

    // 2. The number must belong to the account the token can reach.
    const phone = await graph(`${phone_number_id}?fields=display_phone_number,verified_name`, token);
    await graph(`${waba_id}/subscribed_apps`, token, { method: "POST" });
    const pin = String(Math.floor(100000 + Math.random() * 900000));
    await graph(`${phone_number_id}/register`, token, { method: "POST", body: JSON.stringify({ messaging_product: "whatsapp", pin }) })
      .catch((e: GraphError) => { if (!/already registered/i.test(e.message)) throw e; });

    // 3. Save now, so template webhooks can find the station by its account id.
    const saved = await admin.rpc("svc_whatsapp_set_account", {
      p_station: station_id, p_status: "pending", p_reason: "Templates in review at Meta",
      p_waba: waba_id, p_phone_id: phone_number_id, p_display: phone.display_phone_number ?? null, p_token: token,
    });
    if (saved.error) return await fail(saved.error.message);

    // 4. Standard English templates (utility category), one per event.
    const { data: events } = await admin.from("message_events").select("code, template");
    for (const e of events ?? []) {
      const { text, names } = toMetaBody(e.template);
      await graph(`${waba_id}/message_templates`, token, {
        method: "POST",
        body: JSON.stringify({
          name: `csm_${e.code}`, language: "en", category: "UTILITY",
          components: [{ type: "BODY", text, ...(names.length ? { example: { body_text: [names.map((n) => SAMPLES[n] ?? n)] } } : {}) }],
        }),
      }).catch((err: GraphError) => { if (!/already exists|duplicate/i.test(err.message)) throw err; });
    }

    // 5. Current review status (templates approved earlier connect at once).
    const list = await graph(`${waba_id}/message_templates?fields=name,status,rejected_reason&limit=100`, token);
    for (const t of list.data ?? []) {
      if (!String(t.name).startsWith("csm_")) continue;
      await admin.rpc("svc_whatsapp_template_status", { p_waba: waba_id, p_name: t.name, p_status: t.status, p_reason: t.rejected_reason ?? null });
    }
    const { data: acc } = await admin.from("whatsapp_accounts").select("status, status_reason").eq("station_id", station_id).single();
    return withCors(json(200, acc));
  } catch (e) {
    return await fail((e as GraphError).message ?? String(e));
  }
});

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};
function withCors(res: Response): Response {
  for (const [k, v] of Object.entries(cors)) res.headers.set(k, v);
  return res;
}
