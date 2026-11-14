// Phase 5 smoke test against STAGING with the public key: security fix, owner payment by
// bank transfer with a receipt, and (when an admin test account exists) super-admin
// verification that moves the renewal date.
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");
const client = () => createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const login = async (a) => { const c = client(); must(await c.auth.signInWithPassword({ phone: e164(a.mobile), password: a.password })); return c; };
const must = ({ data, error }) => {
  if (error) throw new Error(error.message + (error.details ? ` (${error.details})` : ""));
  return data;
};
const results = [];
const step = async (name, fn) => {
  try { const out = await fn(); results.push(["PASS", name, typeof out === "string" ? out : ""]); return out; }
  catch (e) { results.push(["FAIL", name, e.message]); throw e; }
};
// 1×1 PNG used as a stand-in receipt image.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", "base64");

try {
  const mech = await login(acc.mechanic);
  const owner = await login(acc.owner);
  const ownerId = (await owner.auth.getUser()).data.user.id;
  const station = must(await owner.from("station_members").select("station_id").eq("user_id", ownerId).single()).station_id;

  await step("security fix: a logged-in user cannot call admin_add_member", async () => {
    const r = await mech.rpc("admin_add_member", { p_actor: randomUUID(), p_station: randomUUID(), p_user: randomUUID(), p_full_name: "Probe", p_mobile: "03990000009", p_role: "mechanic" });
    if (!r.error || !/permission denied/i.test(r.error.message)) throw new Error("still callable: " + JSON.stringify(r.error));
    return "permission denied";
  });

  await step("owner cannot use super-admin functions", async () => {
    const r = await owner.rpc("admin_tenants");
    if (r.error?.message !== "FORBIDDEN") throw new Error(JSON.stringify(r.error));
  });

  const quote = await step("quote: Standard yearly = Rs 50,000", async () => {
    const q = must(await owner.rpc("station_subscription_quote", { p_station: station, p_plan: "standard", p_cycle: "yearly" }));
    if (q.renewal_amount !== 5000000) throw new Error(JSON.stringify(q));
    return q;
  });

  const payment = await step("bank transfer with receipt image → waiting for verification", async () => {
    const path = `${station}/receipt-smoke-${Date.now()}.png`;
    must(await owner.storage.from("payment-receipts").upload(path, PNG, { contentType: "image/png" }));
    const other = await login(acc.owner2);
    const peek = await other.storage.from("payment-receipts").download(path);
    if (!peek.error) throw new Error("another station could read the receipt");
    // Clear an earlier unverified test payment, if any, so this run can submit.
    const pending = must(await owner.from("subscription_payments").select("id").eq("station_id", station).eq("status", "pending_verification"));
    if (pending.length) return pending[0].id;
    must(await owner.rpc("station_submit_manual_payment", { p_station: station, p_kind: "renewal", p_plan: "standard", p_cycle: "yearly", p_method: "bank", p_reference: "SMOKE-" + Date.now(), p_receipt_path: path }));
    return must(await owner.from("subscription_payments").select("id").eq("station_id", station).eq("status", "pending_verification").single()).id;
  });

  if (acc.admin) {
    const admin = await login(acc.admin);
    await step("super admin: tenant list shows usage, not station records", async () => {
      const t = must(await admin.rpc("admin_tenants"));
      const mine = t.find((x) => x.station_id === station);
      const rows = must(await admin.from("customers").select("id").eq("station_id", station));
      if (!mine || mine.pending_payments < 1 || rows.length) throw new Error(JSON.stringify({ mine, rows: rows.length }));
      return `${t.length} tenants; this one: ${mine.status}, ${mine.users} users`;
    });
    await step("super admin verifies → plan active, renewal moved one year", async () => {
      must(await admin.rpc("admin_verify_payment", { p_payment: payment, p_approve: true, p_reason: null }));
      const p = must(await owner.from("subscription_payments").select("status, period_from, period_to, receipt_no").eq("id", payment).single());
      const e = must(await owner.from("station_entitlements").select("status, plan_code").eq("station_id", station).single());
      if (p.status !== "succeeded" || e.status !== "active" || e.plan_code !== "standard") throw new Error(JSON.stringify({ p, e }));
      return `paid ${p.period_from} → ${p.period_to}, receipt #${p.receipt_no}`;
    });
  } else {
    results.push(["SKIP", "super-admin verification", "add an \"admin\" account to config/staging-test-accounts.json"]);
  }
} catch (e) {
  if (!results.some((r) => r[0] === "FAIL")) results.push(["FAIL", "setup", e.message]);
}

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
