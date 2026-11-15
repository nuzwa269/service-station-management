// TASK-060, TASK-062 · REQ-055, REQ-056 — message dispatcher.
// pg_cron calls this every minute through pg_net (private.kick_dispatch) with the shared
// secret DISPATCH_SECRET. It claims due rows with the service role and sends:
//   * WhatsApp template messages from the station's own number (Cloud API),
//   * push to the customer app and to staff phones (Firebase Cloud Messaging HTTP v1).
// Each result is reported back; the database decides retry / manual list (svc_outbox_report).
// Secrets: DISPATCH_SECRET, FCM_SERVICE_ACCOUNT (service-account JSON). Without FCM the
// push rows are marked failed and WhatsApp still works.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { graph, GraphError, json, timingSafeEqual } from "../_shared/meta.ts";

type Claimed = {
  id: number; channel: "whatsapp" | "push"; event: string; to_mobile: string | null; title: string; body: string;
  params: string[]; ref_id: string | null; phone_number_id: string | null; access_token: string | null; tokens: string[] | null;
};

// --- FCM HTTP v1 -------------------------------------------------------------------------
type ServiceAccount = { project_id: string; client_email: string; private_key: string };
let fcmCache: { token: string; until: number } | null = null;

const b64url = (data: ArrayBuffer | string) =>
  btoa(typeof data === "string" ? data : String.fromCharCode(...new Uint8Array(data)))
    .replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

async function fcmAccessToken(sa: ServiceAccount): Promise<string> {
  if (fcmCache && fcmCache.until > Date.now() + 60_000) return fcmCache.token;
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${header}.${claims}.${b64url(sig)}` }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`FCM auth: ${body.error_description ?? res.status}`);
  fcmCache = { token: body.access_token, until: Date.now() + body.expires_in * 1000 };
  return fcmCache.token;
}

/** Sends to each token; returns how many arrived and which tokens are dead. */
async function fcmSend(sa: ServiceAccount, tokens: string[], title: string, body: string, data: Record<string, string>) {
  const access = await fcmAccessToken(sa);
  let ok = 0;
  const dead: string[] = [];
  for (const token of tokens) {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${access}`, "content-type": "application/json" },
      body: JSON.stringify({ message: { token, notification: { title, body }, data, android: { priority: "HIGH" } } }),
    });
    if (res.ok) { ok++; continue; }
    const err = await res.json().catch(() => ({}));
    const code = err.error?.details?.find((d: any) => d.errorCode)?.errorCode ?? err.error?.status;
    if (res.status === 404 || code === "UNREGISTERED" || code === "INVALID_ARGUMENT") dead.push(token);
  }
  return { ok, dead };
}

// --- WhatsApp ----------------------------------------------------------------------------
async function sendWhatsApp(m: Claimed): Promise<string> {
  if (!m.phone_number_id || !m.access_token || !m.to_mobile) throw { message: "Station account or number missing" } as GraphError;
  const to = "92" + m.to_mobile.replace(/^0/, "");
  const res = await graph(`${m.phone_number_id}/messages`, m.access_token, {
    method: "POST",
    body: JSON.stringify({
      messaging_product: "whatsapp", to, type: "template",
      template: {
        name: `csm_${m.event}`, language: { code: "en" },
        components: m.params.length ? [{ type: "body", parameters: m.params.map((text) => ({ type: "text", text })) }] : [],
      },
    }),
  });
  return res.messages?.[0]?.id ?? "";
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("DISPATCH_SECRET");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const given = req.headers.get("x-dispatch-secret") ?? "";
  const byService = req.headers.get("authorization") === `Bearer ${serviceKey}`;
  if (!byService && !(secret && given && timingSafeEqual(given, secret))) return json(403, { error: "FORBIDDEN" });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey, { auth: { persistSession: false } });
  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  const sa: ServiceAccount | null = saRaw ? JSON.parse(saRaw) : null;
  const stats = { whatsapp: 0, push: 0, staff: 0, failed: 0 };

  // Customer messages.
  const { data: rows, error } = await db.rpc("svc_outbox_claim", { p_limit: 50 });
  if (error) return json(500, { error: error.message });
  for (const m of (rows ?? []) as Claimed[]) {
    try {
      if (m.channel === "whatsapp") {
        const id = await sendWhatsApp(m);
        await db.rpc("svc_outbox_report", { p_message: m.id, p_ok: true, p_provider_id: id });
        stats.whatsapp++;
      } else {
        if (!sa) throw { message: "Push is not set up (FCM_SERVICE_ACCOUNT)" };
        const r = await fcmSend(sa, m.tokens ?? [], m.title, m.body, { event: m.event, ref_id: m.ref_id ?? "" });
        for (const t of r.dead) await db.rpc("svc_drop_device_token", { p_token: t });
        if (r.ok === 0) throw { message: "No phone accepted the push" };
        await db.rpc("svc_outbox_report", { p_message: m.id, p_ok: true });
        stats.push++;
      }
    } catch (e) {
      const err = e as GraphError;
      stats.failed++;
      await db.rpc("svc_outbox_report", {
        p_message: m.id, p_ok: false, p_error: String(err.message ?? e), p_error_code: err.code ?? null,
      });
    }
  }

  // Staff push (REQ-056).
  if (sa) {
    const { data: notes } = await db.rpc("svc_staff_push_claim", { p_limit: 100 });
    for (const n of notes ?? []) {
      try {
        const r = await fcmSend(sa, n.tokens, n.title, n.body ?? "", { kind: n.kind, ref_id: n.ref_id ?? "" });
        for (const t of r.dead) await db.rpc("svc_drop_device_token", { p_token: t });
        await db.rpc("svc_staff_push_report", { p_notification: n.id, p_ok: r.ok > 0 });
        stats.staff++;
      } catch {
        await db.rpc("svc_staff_push_report", { p_notification: n.id, p_ok: false });
        stats.failed++;
      }
    }
  }
  return json(200, stats);
});
