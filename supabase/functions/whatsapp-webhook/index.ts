// TASK-061 · REQ-061 — Meta webhook for the platform's WhatsApp app.
//   GET  : subscription check (hub.verify_token = WHATSAPP_VERIFY_TOKEN).
//   POST : signed by Meta (X-Hub-Signature-256 = HMAC-SHA256 of the raw body with META_APP_SECRET).
// Handles template review results, account changes (app removed, account disabled) and failed
// message statuses with Meta's payment error 131042. Unknown events are acknowledged and ignored.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { hmacHex, json, timingSafeEqual } from "../_shared/meta.ts";

const OFF_EVENTS = new Set(["PARTNER_REMOVED", "ACCOUNT_DELETED", "DISABLED_UPDATE", "ACCOUNT_VIOLATION"]);

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "GET") {
    const ok = url.searchParams.get("hub.mode") === "subscribe"
      && url.searchParams.get("hub.verify_token") === Deno.env.get("WHATSAPP_VERIFY_TOKEN");
    return ok ? new Response(url.searchParams.get("hub.challenge") ?? "") : json(403, { error: "FORBIDDEN" });
  }
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });

  const secret = Deno.env.get("META_APP_SECRET");
  if (!secret) return json(500, { error: "NOT_CONFIGURED" });
  const raw = await req.text();
  const given = req.headers.get("x-hub-signature-256") ?? "";
  if (!given.startsWith("sha256=") || !timingSafeEqual(given.slice(7), await hmacHex(secret, raw))) {
    return json(401, { error: "BAD_SIGNATURE" });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const stationOf = async (waba: string) =>
    (await db.from("whatsapp_accounts").select("station_id").eq("waba_id", waba).maybeSingle()).data?.station_id as string | undefined;

  const body = JSON.parse(raw);
  for (const entry of body.entry ?? []) {
    const waba = String(entry.id ?? "");
    for (const change of entry.changes ?? []) {
      const v = change.value ?? {};
      if (change.field === "message_template_status_update") {
        await db.rpc("svc_whatsapp_template_status", {
          p_waba: waba, p_name: v.message_template_name, p_status: v.event, p_reason: v.reason ?? null,
        });
      } else if (change.field === "account_update" && OFF_EVENTS.has(v.event)) {
        const station = await stationOf(waba);
        if (station) {
          await db.rpc("svc_whatsapp_set_account", {
            p_station: station, p_status: "disconnected", p_reason: `Meta: ${String(v.event).toLowerCase().replace(/_/g, " ")}`,
          });
        }
      } else if (change.field === "messages") {
        const paymentIssue = (v.statuses ?? []).some((s: any) => s.status === "failed" && (s.errors ?? []).some((e: any) => e.code === 131042));
        const station = paymentIssue ? await stationOf(waba) : undefined;
        if (station) {
          await db.rpc("svc_whatsapp_set_account", {
            p_station: station, p_status: "payment_problem", p_reason: "Meta could not charge the station's payment method",
          });
        }
      }
    }
  }
  return json(200, { ok: true });
});
