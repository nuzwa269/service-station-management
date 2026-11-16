// TASK-015 · REQ-002 — the owner adds a staff login (manager, cashier, mechanic) with mobile +
// password. The file was left empty in Phase 1; this is the implementation.
// Body: {station_id, full_name, mobile, role, password}. Requires the owner's login (verify_jwt on).
// Steps: owner check as the caller → create (or reuse) the auth user with a confirmed phone →
// admin_add_member with the service role (writes profile + membership, audited as the owner).
// Self-contained so it can be pasted into the dashboard's function editor.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...cors } });

/** 0300-1234567 / 923001234567 / +923001234567 → 923001234567, else null. */
function e164(raw: string): string | null {
  let d = String(raw ?? "").replace(/\D/g, "");
  if (/^03\d{9}$/.test(d)) d = "92" + d.slice(1);
  if (/^3\d{9}$/.test(d)) d = "92" + d;
  return /^923\d{9}$/.test(d) ? d : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });

  let b: { station_id?: string; full_name?: string; mobile?: string; role?: string; password?: string };
  try { b = await req.json(); } catch { return json(400, { error: "VALIDATION", message: "Bad request" }); }
  const phone = e164(b.mobile ?? "");
  const role = b.role ?? "";
  if (!b.station_id || !phone) return json(400, { error: "VALIDATION", message: "Mobile must be like 0300-1234567" });
  if (!["manager", "cashier", "mechanic"].includes(role)) return json(400, { error: "VALIDATION", message: "Pick manager, cashier or mechanic" });
  if ((b.full_name ?? "").trim().length < 2) return json(400, { error: "VALIDATION", message: "Name is required" });
  if ((b.password ?? "").length < 8) return json(400, { error: "VALIDATION", message: "Password must be at least 8 characters" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  // Who is calling: the user's access token, checked by Auth with the service client.
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: me, error: ue } = await admin.auth.getUser(token);
  if (!me?.user) return json(401, { error: "FORBIDDEN", message: "Please log in again" + (ue ? ` (${ue.message})` : "") });
  // Only an active owner of this station may add users (REQ-002).
  const { data: own } = await admin.from("station_members").select("id")
    .eq("station_id", b.station_id).eq("user_id", me.user.id).eq("role", "owner").eq("active", true).maybeSingle();
  if (!own) return json(403, { error: "FORBIDDEN", message: "Only the owner can add users" });
  // Reuse an existing login with this phone (e.g. someone moving between stations).
  let userId: string | null = null;
  const created = await admin.auth.admin.createUser({ phone, password: b.password, phone_confirm: true });
  if (created.data?.user) {
    userId = created.data.user.id;
  } else {
    for (let page = 1; page <= 20 && !userId; page++) {
      const { data } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
      const hit = data?.users?.find((u) => u.phone === phone);
      if (hit) userId = hit.id;
      if (!data || data.users.length < 1000) break;
    }
    if (!userId) return json(400, { error: "VALIDATION", message: created.error?.message ?? "Could not create the login" });
  }

  const { error } = await admin.rpc("admin_add_member", {
    p_actor: me.user.id, p_station: b.station_id, p_user: userId,
    p_full_name: b.full_name!.trim(), p_mobile: phone, p_role: role,
  });
  if (error) return json(400, { error: error.message, message: error.details ?? error.message });
  return json(200, { ok: true, user_id: userId });
});
