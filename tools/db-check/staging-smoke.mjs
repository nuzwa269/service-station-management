// End-to-end smoke test against the STAGING project, using only the public key
// (exactly what the apps do). Reads config/staging.json + config/staging-test-accounts.json.
//   node staging-smoke.mjs
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");

const results = [];
const step = async (name, fn) => {
  try {
    const out = await fn();
    results.push(["PASS", name, out ?? ""]);
    return out;
  } catch (e) {
    results.push(["FAIL", name, e.message ?? String(e)]);
    throw e;
  }
};
const must = ({ data, error }) => {
  if (error) throw new Error(error.message + (error.details ? ` (${error.details})` : ""));
  return data;
};
const client = () => createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });

const owner = client();
const phone = e164(acc.owner.mobile);

try {
  await step("owner sign-up (sends code)", async () => {
    const r = await owner.auth.signUp({ phone, password: acc.owner.password });
    if (r.error && !/already registered/i.test(r.error.message)) throw r.error;
    return r.error ? "already registered — logging in instead" : "code requested";
  });

  await step("verify code / log in", async () => {
    const v = await owner.auth.verifyOtp({ phone, token: acc.owner.otp, type: "sms" });
    if (!v.error) return "code accepted";
    must(await owner.auth.signInWithPassword({ phone, password: acc.owner.password }));
    return "logged in with password";
  });

  const uid = (await owner.auth.getUser()).data.user.id;

  const stationId = await step("create station (station_signup)", async () => {
    const r = await owner.rpc("station_signup", {
      p_station_name: acc.owner.station, p_city: "Lahore", p_full_name: "Test Owner", p_email: null,
    });
    if (r.error?.message === "ALREADY_REGISTERED") {
      const m = must(await owner.from("station_members").select("station_id").eq("user_id", uid).single());
      return m.station_id;
    }
    return must(r);
  });

  await step("trial entitlements", async () => {
    const e = must(await owner.from("station_entitlements").select().eq("station_id", stationId).single());
    if (!["trial", "grace"].includes(e.status) || e.effective_plan !== "premium") throw new Error(JSON.stringify(e));
    return `${e.status}, ${e.effective_plan}, renews ${e.renews_at.slice(0, 10)}`;
  });

  await step("update profile + tax", async () => {
    must(await owner.rpc("station_update_profile", {
      p_station: stationId, p_name: acc.owner.station, p_address: "Main Boulevard", p_phone: "042-1234567",
      p_ntn: "1234567-8", p_strn: null, p_sales_tax_enabled: true, p_parts_tax_pct: 18, p_services_tax_pct: 16,
      p_logo_path: null,
    }));
    const s = must(await owner.from("stations").select("parts_tax_pct, station_code").eq("id", stationId).single());
    return `parts tax ${s.parts_tax_pct}%, code ${s.station_code}`;
  });

  await step("validation rejects tax 150%", async () => {
    const r = await owner.rpc("station_update_profile", {
      p_station: stationId, p_name: acc.owner.station, p_address: null, p_phone: null, p_ntn: null, p_strn: null,
      p_sales_tax_enabled: true, p_parts_tax_pct: 150, p_services_tax_pct: 0, p_logo_path: null,
    });
    if (r.error?.message !== "VALIDATION") throw new Error("expected VALIDATION, got " + JSON.stringify(r.error));
    return r.error.details;
  });

  await step("audit log records the change", async () => {
    const rows = must(await owner.from("audit_log").select("action, changes").eq("table_name", "stations").eq("action", "update"));
    const hit = rows.find((r) => r.changes.parts_tax_pct);
    if (!hit) throw new Error("no audit row for parts_tax_pct");
    return `parts_tax_pct ${hit.changes.parts_tax_pct.old} → ${hit.changes.parts_tax_pct.new}`;
  });

  await step("add mechanic (invite-member Edge Function)", async () => {
    const { data, error } = await owner.functions.invoke("invite-member", {
      body: { station_id: stationId, full_name: "Test Mechanic", mobile: acc.mechanic.mobile, role: "mechanic", password: acc.mechanic.password },
    });
    if (error) {
      const body = await error.context?.json?.().catch(() => null);
      if (body?.error === "MOBILE_IN_USE") return "mechanic already exists";
      throw new Error(body ? JSON.stringify(body) : error.message);
    }
    return `member ${data.member_id}`;
  });

  await step("mechanic logs in and sees only own membership", async () => {
    const mech = client();
    must(await mech.auth.signInWithPassword({ phone: e164(acc.mechanic.mobile), password: acc.mechanic.password }));
    const mem = must(await mech.from("station_members").select("role"));
    const audit = must(await mech.from("audit_log").select("id"));
    if (mem.length !== 1 || mem[0].role !== "mechanic" || audit.length !== 0) throw new Error(JSON.stringify({ mem, audit }));
    const r = await mech.rpc("station_update_profile", {
      p_station: stationId, p_name: "Hacked", p_address: null, p_phone: null, p_ntn: null, p_strn: null,
      p_sales_tax_enabled: false, p_parts_tax_pct: 0, p_services_tax_pct: 0, p_logo_path: null,
    });
    if (r.error?.message !== "FORBIDDEN") throw new Error("mechanic could edit settings!");
    return "1 membership, no audit access, settings edit FORBIDDEN";
  });

  await step("anonymous visitor sees no stations", async () => {
    const rows = must(await client().from("stations").select("id"));
    if (rows.length) throw new Error(`${rows.length} stations visible`);
    return "0 rows";
  });
} catch {
  // reported below
}

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
