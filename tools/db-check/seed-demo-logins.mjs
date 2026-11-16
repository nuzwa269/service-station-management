// Second step of the demo seed: staff app logins through invite-member, linked to the staff
// records, and mechanics put on the open job cards. Safe to run again.
//   node tools/db-check/seed-demo-logins.mjs
// Passwords go to config/demo-accounts.json (gitignored), never printed.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const demoFile = new URL("../../config/demo-accounts.json", import.meta.url);
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");
const must = ({ data, error }, what) => { if (error) throw new Error(`${what}: ${error.message}${error.details ? ` (${error.details})` : ""}`); return data; };

const owner = createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
must(await owner.auth.signInWithPassword({ phone: e164(acc.owner2.mobile), password: acc.owner2.password }), "login");
const ownerId = (await owner.auth.getUser()).data.user.id;
const S = must(await owner.from("station_members").select("station_id").eq("user_id", ownerId).eq("role", "owner").single(), "station").station_id;

const demo = existsSync(demoFile) ? JSON.parse(readFileSync(demoFile, "utf8")) : {};
const pay = Object.fromEntries(must(await owner.rpc("station_staff_pay", { p_station: S }), "pay").map((p) => [p.staff_id, p]));
const staff = must(await owner.from("staff").select("id, name, role, mobile, joined_on, user_id").eq("station_id", S), "staff");

const users = {};
for (const [key, role, name, mobile] of [["imran", "manager", "Imran Manager", "0399-0000111"], ["nadia", "cashier", "Nadia Cashier", "0399-0000112"],
  ["bilal", "mechanic", "Bilal Mechanic", "0399-0000113"], ["asif", "mechanic", "Asif Mechanic", "0399-0000114"]]) {
  demo[key] ??= { role, name, mobile, password: "Demo-" + randomBytes(6).toString("base64url") };
  const r = await owner.functions.invoke("invite-member", { body: { station_id: S, full_name: name, mobile, role, password: demo[key].password } });
  if (r.error) {
    const body = await r.error.context?.text?.().catch(() => "");
    throw new Error(`${name}: ${r.error.message} ${body ?? ""}`);
  }
  users[key] = r.data.user_id;
  const rec = staff.find((s) => s.name === name);
  if (rec && rec.user_id !== users[key]) {
    must(await owner.rpc("station_save_staff", { p_station: S, p: {
      id: rec.id, user_id: users[key], name: rec.name, role: rec.role, mobile: rec.mobile, joined_on: rec.joined_on,
      salary_paisa: pay[rec.id]?.salary_paisa ?? 0, commission_pct: pay[rec.id]?.commission_pct ?? 0 } }), "link staff");
  }
  console.log(`• login ready: ${name} (${role}, ${mobile})`);
}
writeFileSync(demoFile, JSON.stringify(demo, null, 2));

// Mechanics on the open jobs (in progress, quality check, ready).
const open = must(await owner.from("job_cards").select("id, job_no, stage").eq("station_id", S).in("stage", ["approved", "in_progress", "quality_check", "ready"]).order("job_no", { ascending: true }), "jobs");
for (const [i, j] of open.entries()) {
  const r = await owner.rpc("job_assign", { p_job: j.id, p_mechanics: [i % 2 ? users.asif : users.bilal] });
  console.log(`• job ${j.job_no} (${j.stage}) → ${i % 2 ? "Asif" : "Bilal"}${r.error ? " — " + r.error.message : ""}`);
}
console.log("\nPasswords: config/demo-accounts.json (gitignored).");
