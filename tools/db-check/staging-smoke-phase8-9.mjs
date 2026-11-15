// Phase 8 + 9 smoke test against STAGING with the public key (read-only except nothing is
// written): reports and dashboard totals as the owner, payroll gated by plan, role checks,
// app_versions readable before login, service-role and admin functions closed.
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");
const client = () => createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const login = async (a) => { const c = client(); must(await c.auth.signInWithPassword({ phone: e164(a.mobile), password: a.password })); return c; };
const must = ({ data, error }) => { if (error) throw new Error(error.message + (error.details ? ` (${error.details})` : "")); return data; };
const results = [];
const step = async (name, fn) => {
  try { const out = await fn(); results.push(["PASS", name, typeof out === "string" ? out : ""]); }
  catch (e) { results.push(["FAIL", name, e.message]); }
};
const day = (o) => new Date(Date.now() + 5 * 3600e3 + o * 86400e3).toISOString().slice(0, 10);

try {
  const owner = await login(acc.owner);
  const uid = (await owner.auth.getUser()).data.user.id;
  const station = must(await owner.from("station_members").select("station_id").eq("user_id", uid).single()).station_id;
  const plan = must(await owner.from("station_entitlements").select("effective_plan, features").eq("station_id", station).single());
  const mech = await login(acc.mechanic);
  const other = await login(acc.owner2);

  await step(`plan on staging: ${plan.effective_plan}`, async () => plan.features.join(", "));

  await step("dashboard totals (REQ-060)", async () => {
    const t = must(await owner.rpc("station_dashboard_totals", { p_station: station }));
    return `dues Rs ${Math.round(t.dues_paisa / 100)}, low stock ${t.low_stock}, WhatsApp to send ${t.messages_to_send}, stages ${JSON.stringify(t.jobs_by_stage)}`;
  });

  await step("revenue report for the last 30 days (REQ-059)", async () => {
    const [r] = must(await owner.rpc("report_revenue", { p_station: station, p_from: day(-30), p_to: day(0) }));
    if (r.net_paisa !== r.parts_paisa + r.labour_paisa - r.discount_paisa) throw new Error("net does not add up");
    return `${r.invoices} invoices, net Rs ${Math.round(r.net_paisa / 100)}`;
  });

  await step("other reports run: collections, stock value, messages", async () => {
    const c = must(await owner.rpc("report_collections", { p_station: station, p_from: day(-30), p_to: day(0) }));
    const s = must(await owner.rpc("report_stock_value", { p_station: station }));
    const m = must(await owner.rpc("report_messages", { p_station: station, p_from: day(-30), p_to: day(0) }));
    if (m.length !== 10) throw new Error("message rows " + m.length);
    return `${c.length} collection rows, ${s.length} items, ${m.length} message events`;
  });

  await step("payroll and profit reports follow the plan", async () => {
    const premium = plan.features.includes("payroll");
    const r = await owner.rpc("payroll_generate", { p_station: station, p_month: day(0) });
    const p = await owner.rpc("report_job_profit", { p_station: station, p_from: day(-30), p_to: day(0) });
    if (premium) {
      if (r.error || p.error) throw new Error(JSON.stringify({ payroll: r.error, profit: p.error }));
      return "Premium: payroll drafted, profit report ran";
    }
    if (r.error?.message !== "FEATURE_LOCKED" || p.error?.message !== "FEATURE_LOCKED") throw new Error(JSON.stringify({ payroll: r.error, profit: p.error }));
    return "not Premium: both FEATURE_LOCKED as expected";
  });

  await step("mechanic and another station's owner are refused", async () => {
    const a = await mech.rpc("report_revenue", { p_station: station, p_from: day(-1), p_to: day(0) });
    const b = await other.rpc("report_revenue", { p_station: station, p_from: day(-1), p_to: day(0) });
    const c = await mech.from("payroll_lines").select("id");
    if (a.error?.message !== "FORBIDDEN" || b.error?.message !== "FORBIDDEN" || (c.data ?? []).length) throw new Error(JSON.stringify({ a: a.error, b: b.error }));
  });

  await step("app_versions readable before login; publishing needs the super admin", async () => {
    must(await client().from("app_versions").select("app, build"));
    const r = await owner.rpc("admin_publish_app_version", { p_app: "staff", p_build: 999, p_version: "x", p_apk_url: "https://x.test/a.apk" });
    if (r.error?.message !== "FORBIDDEN") throw new Error(JSON.stringify(r.error));
  });
} catch (e) {
  results.push(["FAIL", "setup", e.message]);
}
for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
