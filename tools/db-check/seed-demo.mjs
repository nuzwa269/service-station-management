// Demo station for client demos: "Demo Auto Care, Lahore" with realistic data through the same
// functions the apps use. Runs once (stops if the station already has customers).
//   node tools/db-check/seed-demo.mjs
// Uses the owner2 test login as the demo owner (Premium trial), the admin login to extend the
// trial, and the invite-member function for demo staff logins (skipped if not deployed).
// Demo staff passwords are written to config/demo-accounts.json (gitignored), never printed.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const demoFile = new URL("../../config/demo-accounts.json", import.meta.url);
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");
const client = () => createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const login = async (a) => { const c = client(); must(await c.auth.signInWithPassword({ phone: e164(a.mobile), password: a.password })); return c; };
const must = ({ data, error }, what = "") => { if (error) throw new Error(`${what} ${error.message}${error.details ? ` (${error.details})` : ""}`); return data; };
const day = (o) => new Date(Date.now() + 5 * 3600e3 + o * 86400e3).toISOString().slice(0, 10);
const slot = (o, h) => new Date(`${day(o)}T${String(h).padStart(2, "0")}:00:00+05:00`).toISOString();
const rs = (n) => n * 100;
const log = (...a) => console.log("•", ...a);

const owner = await login(acc.owner2);
const ownerId = (await owner.auth.getUser()).data.user.id;
const S = must(await owner.from("station_members").select("station_id").eq("user_id", ownerId).eq("role", "owner").single()).station_id;
if ((await owner.from("customers").select("id", { count: "exact", head: true }).eq("station_id", S)).count > 0) {
  console.log("Demo station already has data — nothing to do."); process.exit(0);
}
const rpc = async (fn, params) => must(await owner.rpc(fn, params), fn);

// 1. Station profile, plan time, settings ------------------------------------------------------
await rpc("station_update_profile", { p_station: S, p_name: "Demo Auto Care", p_address: "12-B Main Boulevard, Gulberg III, Lahore",
  p_phone: "0300-0000000", p_ntn: null, p_strn: null, p_sales_tax_enabled: false, p_parts_tax_pct: 0, p_services_tax_pct: 0 });
try {
  const admin = await login(acc.admin);
  must(await admin.rpc("admin_extend_trial", { p_station: S, p_days: 60 }), "extend trial");
  log("Premium trial extended by 60 days");
} catch (e) { log("trial not extended:", e.message); }
await rpc("station_save_checklist_template", { p_station: S, p_names: ["Brakes", "Tyres", "Lights", "Battery", "Engine oil level", "Coolant"] });
await rpc("station_save_booking_settings", { p_station: S, p_bays: 3, p_slot_minutes: 60, p_no_show_limit: 3,
  p_hours: [1, 2, 3, 4, 5, 6].map((d) => ({ weekday: d, opens: "09:00", closes: "19:00" })), p_off_days: [], p_days_ahead: 30 });
log("profile, checklist, booking hours");

// 2. Services, parts, supplier, stock -------------------------------------------------------------
const svc = {};
for (const [k, name, price] of [["oil", "Oil change labour", 500], ["tune", "Engine tuning", 2500], ["brake", "Brake service", 1500],
  ["ac", "AC service", 3500], ["wash", "Wash & polish", 1200]]) {
  svc[k] = await rpc("station_save_service", { p_station: S, p_id: null, p_name: name, p_rate_paisa: rs(price), p_warranty_days: 0 });
}
await rpc("station_set_service_bookable", { p_service: svc.oil, p_bookable: true });
await rpc("station_set_service_bookable", { p_service: svc.ac, p_bookable: true });
await rpc("station_set_service_bookable", { p_service: svc.tune, p_bookable: true });
const item = {};
const items = [
  ["oil", "OIL-5W30", "Engine oil 5W-30 (per litre)", "litre", 1100, 850, 20],
  ["ofil", "FIL-OIL-C", "Oil filter Corolla/City", "piece", 950, 600, 6],
  ["afil", "FIL-AIR-C", "Air filter Corolla", "piece", 1600, 1100, 4],
  ["pads", "BRK-PAD-F", "Brake pads front set", "piece", 4800, 3600, 4],
  ["plug", "SPK-PLG", "Spark plug iridium", "piece", 1400, 950, 8],
  ["cool", "COOL-1L", "Coolant (per litre)", "litre", 900, 650, 6],
  ["bat", "BAT-55AH", "Battery 55Ah", "piece", 21500, 18000, 2],
  ["wipe", "WIP-22", "Wiper blade 22 inch", "piece", 1300, 800, 4],
];
for (const [k, code, name, unit, sell, , min] of items) {
  item[k] = await rpc("station_save_item", { p_station: S, p_item: { code, name, unit, selling_price_paisa: rs(sell), min_stock: min, warranty_days: k === "bat" ? 365 : 0 } });
}
const sup = await rpc("station_save_supplier", { p_station: S, p_id: null, p_name: "Al-Madina Auto Parts", p_phone: "0300-0000001" });
await rpc("station_post_purchase", { p_station: S, p_supplier_id: sup, p_supplier_name: null, p_bill_no: "AMP-1043", p_bill_date: day(-6),
  p_lines: items.map(([k, , , , , cost]) => ({ item_id: item[k], qty: k === "oil" ? 40 : k === "bat" ? 3 : 12, unit_cost_paisa: rs(cost) })), p_paid_now_paisa: rs(100000) });
log("5 services, 8 parts, purchase from supplier");

// 3. Customers and vehicles (fictitious numbers; Ali uses the customer-app test login) -----------
const people = [
  ["Ali Raza", acc.owner.mobile, "LEA-1234", "Toyota", "Corolla"],
  ["Sara Khan", "0311-0000102", "LEB-5521", "Honda", "City"],
  ["Bilal Ahmed", "0311-0000103", "LHR-8890", "Suzuki", "Cultus"],
  ["Ayesha Malik", "0311-0000104", "LEC-3307", "Honda", "Civic"],
  ["Usman Tariq", "0311-0000105", "LED-7712", "Toyota", "Hilux"],
  ["Hina Shah", "0311-0000106", "LEE-2290", "Suzuki", "Alto"],
  ["Kamran Iqbal", "0311-0000107", "LEF-6643", "Kia", "Sportage"],
  ["Zainab Ali", "0311-0000108", "LEG-1180", "Toyota", "Yaris"],
];
const cust = {}, car = {};
for (const [name, mobile, plate, make, model] of people) {
  cust[plate] = await rpc("station_save_customer", { p_station: S, p_id: null, p_name: name, p_mobile: mobile });
  car[plate] = await rpc("station_save_vehicle", { p_station: S, p_id: null, p_customer: cust[plate], p_plate: plate, p_make: make, p_model: model });
}
log(`${people.length} customers with vehicles`);

// 4. Staff logins (if invite-member is deployed) and staff records ---------------------------------
const demo = existsSync(demoFile) ? JSON.parse(readFileSync(demoFile, "utf8")) : {};
const pw = () => "Demo-" + randomBytes(6).toString("base64url");
const staffLogins = [["manager", "Imran Manager", "0399-0000111"], ["cashier", "Nadia Cashier", "0399-0000112"], ["mechanic", "Bilal Mechanic", "0399-0000113"], ["mechanic", "Asif Mechanic", "0399-0000114"]];
const memberIds = {};
for (const [role, name, mobile] of staffLogins) {
  const key = name.split(" ")[0].toLowerCase();
  demo[key] ??= { role, name, mobile, password: pw() };
  const r = await owner.functions.invoke("invite-member", { body: { station_id: S, full_name: name, mobile, role, password: demo[key].password } });
  if (r.error) { log(`login for ${name} not created (${r.error.message}) — deploy invite-member and run again for logins`); delete demo[key]; continue; }
  memberIds[key] = r.data.user_id;
}
demo.owner = { role: "owner", name: "Demo owner", mobile: acc.owner2.mobile, password: "(same as owner2 in staging-test-accounts.json)" };
demo.customer_app = { mobile: acc.owner.mobile, otp: "(fixed test code of 'owner' in staging-test-accounts.json)" };
writeFileSync(demoFile, JSON.stringify(demo, null, 2));
const staffIds = {};
for (const [key, name, role, salary, pct] of [["imran", "Imran Manager", "manager", 60000, 0], ["nadia", "Nadia Cashier", "cashier", 40000, 0],
  ["bilal", "Bilal Mechanic", "mechanic", 45000, 10], ["asif", "Asif Mechanic", "mechanic", 38000, 8], ["javed", "Javed Helper", "helper", 25000, 0]]) {
  staffIds[key] = await rpc("station_save_staff", { p_station: S, p: { name, role, salary_paisa: rs(salary), commission_pct: pct, user_id: memberIds[key] ?? null, joined_on: day(-200) } });
}
await rpc("station_set_attendance", { p_staff: staffIds.javed, p_day: day(0), p_status: "absent", p_note: "Sick" });
await rpc("station_set_attendance", { p_staff: staffIds.asif, p_day: day(0), p_status: "half_day", p_note: null });
await rpc("station_add_advance", { p_staff: staffIds.bilal, p_amount_paisa: rs(5000), p_method: "cash", p_given_on: day(0), p_months: 1, p_note: "Family need" });
log(`5 staff records, ${Object.keys(memberIds).length} app logins, attendance, an advance`);

// 5. Job cards in every stage ----------------------------------------------------------------------
const checklistOk = async (job) => {
  for (const c of must(await owner.from("job_checklist_items").select("id").eq("job_id", job))) {
    await rpc("job_set_check", { p_check: c.id, p_status: "ok", p_note: null });
  }
};
const mechs = [memberIds.bilal, memberIds.asif].filter(Boolean);
const newJob = async (plate, km, complaint, lines, { approve = true, assign = 0 } = {}) => {
  const job = await rpc("station_create_job", { p_station: S, p_customer: cust[plate], p_vehicle: car[plate], p_odometer: km, p_fuel: "H", p_complaints: complaint });
  for (const l of lines) {
    if (l.service) await rpc("job_add_service", { p_job: job, p_service: l.service, p_qty: 1, p_price_paisa: null });
    else await rpc("job_add_line", { p_job: job, p_kind: "part", p_item: item[l.item], p_description: null, p_qty: l.qty ?? 1, p_price_paisa: null });
  }
  if (approve) await rpc("job_record_approval", { p_job: job, p_approve: true, p_via: "phone", p_by_name: "Customer" });
  if (mechs.length && assign) await rpc("job_assign", { p_job: job, p_mechanics: [mechs[(assign - 1) % mechs.length]] });
  return job;
};
const finish = async (job) => {
  await rpc("job_set_stage", { p_job: job, p_stage: "in_progress", p_note: null });
  await checklistOk(job);
  await rpc("job_set_stage", { p_job: job, p_stage: "quality_check", p_note: null });
  await rpc("job_quality_check", { p_job: job, p_pass: true, p_note: null });
};
const service = [{ item: "oil", qty: 3.5 }, { item: "ofil" }, { service: svc.oil }];
// Delivered and paid
for (const [plate, km, method, ref] of [["LEB-5521", 61200, "cash", null], ["LEC-3307", 43850, "jazzcash", "JC-7781"], ["LEF-6643", 88200, "card", "POS-2231"]]) {
  const j = await newJob(plate, km, "Periodic service", plate === "LEF-6643" ? [...service, { item: "afil" }, { service: svc.tune }] : service, { assign: 1 });
  await finish(j);
  const inv = await rpc("station_create_invoice", { p_job: j });
  const total = must(await owner.from("invoices").select("total_paisa").eq("id", inv).single()).total_paisa;
  await rpc("invoice_record_payment", { p_invoice: inv, p_amount_paisa: total, p_method: method, p_reference: ref });
  await rpc("job_set_stage", { p_job: j, p_stage: "delivered", p_note: null });
  await rpc("job_set_next_service", { p_job: j, p_date: day(90), p_km: km + 5000 });
}
// Ready, invoiced, waiting for payment
{ const j = await newJob("LHR-8890", 120400, "Brakes squeaking", [{ item: "pads" }, { service: svc.brake }], { assign: 2 });
  await finish(j); await rpc("station_create_invoice", { p_job: j }); }
// Quality check
{ const j = await newJob("LED-7712", 152000, "AC not cooling", [{ service: svc.ac }, { item: "cool", qty: 2 }], { assign: 1 });
  await rpc("job_set_stage", { p_job: j, p_stage: "in_progress", p_note: null }); await checklistOk(j);
  await rpc("job_set_stage", { p_job: j, p_stage: "quality_check", p_note: null }); }
// In progress
{ const j = await newJob("LEE-2290", 70500, "Engine misfiring", [{ item: "plug", qty: 4 }, { service: svc.tune }], { assign: 2 });
  await rpc("job_set_stage", { p_job: j, p_stage: "in_progress", p_note: null }); }
// Waiting for the customer's approval (Ali sees it in the customer app)
{ const j = await newJob("LEA-1234", 84200, "Service due, battery weak", [...service, { item: "bat" }], { approve: false });
  await rpc("job_send_estimate", { p_job: j }); }
// Just arrived (intake)
await newJob("LEG-1180", 39800, "Wash and wiper change", [{ service: svc.wash }, { item: "wipe", qty: 2 }], { approve: false });
log("8 job cards: 3 delivered & paid, 1 ready to pay, 1 QC, 1 in progress, 1 waiting approval, 1 intake");

// 6. Bookings, payroll draft ---------------------------------------------------------------------------
for (const [plate, o, h, s] of [["LEA-1234", 1, 10, svc.oil], ["LEC-3307", 1, 12, svc.ac], ["LEG-1180", 2, 11, svc.tune], ["LEB-5521", 3, 15, svc.oil]]) {
  await rpc("station_create_booking", { p_station: S, p_customer: cust[plate], p_vehicle: car[plate], p_service: s, p_slot: slot(o, h), p_note: null, p_overbook: false });
}
await rpc("payroll_generate", { p_station: S, p_month: day(0) });
log("4 bookings, payroll draft for this month");
console.log("\nDemo station ready. Logins: config/demo-accounts.json (gitignored).");
