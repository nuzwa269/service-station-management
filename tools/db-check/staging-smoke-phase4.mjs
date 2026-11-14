// Phase 4 smoke test against STAGING with the public key: services, invoice, discount
// approval, split payment, credit release + delivery, refund as credit, reversal, day summary.
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");
const client = () => createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const must = ({ data, error }) => {
  if (error) throw new Error(error.message + (error.details ? ` (${error.details})` : ""));
  return data;
};
const results = [];
const step = async (name, fn) => {
  try { const out = await fn(); results.push(["PASS", name, typeof out === "string" ? out : ""]); return out; }
  catch (e) { results.push(["FAIL", name, e.message]); throw e; }
};
const run = Date.now().toString(36).toUpperCase();
const rs = (p) => "Rs " + (p / 100).toLocaleString("en-US");

const owner = client();
try {
  must(await owner.auth.signInWithPassword({ phone: e164(acc.owner.mobile), password: acc.owner.password }));
  const ownerId = (await owner.auth.getUser()).data.user.id;
  const station = must(await owner.from("station_members").select("station_id").eq("user_id", ownerId).single()).station_id;
  must(await owner.rpc("station_set_billing_rules", { p_station: station, p_discount_limit_pct: 5, p_storage_free_days: 3, p_storage_charge_paisa: 0 }));

  const part = must(await owner.rpc("station_save_item", { p_station: station, p_item: { code: `SH-${run}`, name: "Shock absorber smoke", selling_price_paisa: 800000 } }));
  must(await owner.rpc("station_request_stock_adjustment", { p_station: station, p_item: part, p_qty: 5, p_reason: "count_difference", p_note: null }));
  const svc = await step("service list: Fitting Rs 1,500", async () =>
    must(await owner.rpc("station_save_service", { p_station: station, p_id: null, p_name: `Fitting ${run}`, p_rate_paisa: 150000, p_warranty_days: 30, p_active: true })));
  const mobile = "0399" + String(Date.now()).slice(-7);
  const cust = must(await owner.rpc("station_save_customer", { p_station: station, p_id: null, p_name: "Bill Customer", p_mobile: mobile, p_email: null, p_address: null }));
  const car = must(await owner.rpc("station_save_vehicle", { p_station: station, p_id: null, p_customer: cust, p_plate: `BL ${String(Date.now()).slice(-4)}`, p_make: "Suzuki", p_model: "Cultus", p_year: 2021, p_colour: null }));

  const readyJob = async () => {
    const odo = 10000 + Math.floor(Math.random() * 1000);
    const j = must(await owner.rpc("station_create_job", { p_station: station, p_customer: cust, p_vehicle: car, p_odometer: odo, p_fuel: "H", p_complaints: null, p_expected: null, p_confirm_odometer: true, p_booking: null }));
    must(await owner.rpc("job_add_line", { p_job: j, p_kind: "part", p_item: part, p_description: null, p_qty: 1, p_price_paisa: null }));
    must(await owner.rpc("job_add_service", { p_job: j, p_service: svc, p_qty: 1, p_price_paisa: null }));
    must(await owner.rpc("job_record_approval", { p_job: j, p_approve: true, p_via: "phone", p_by_name: "Bill Customer", p_extra: false }));
    must(await owner.rpc("job_set_stage", { p_job: j, p_stage: "in_progress", p_note: null }));
    must(await owner.rpc("job_set_stage", { p_job: j, p_stage: "quality_check", p_note: null }));
    must(await owner.rpc("job_quality_check", { p_job: j, p_pass: true, p_note: null }));
    return j;
  };

  const job1 = await readyJob();
  const inv1 = await step("invoice from approved lines = Rs 9,500 (tax off)", async () => {
    must(await owner.rpc("station_update_profile", { p_station: station, p_name: acc.owner.station, p_address: "Main Boulevard", p_phone: "042-1234567", p_ntn: "1234567-8", p_strn: null, p_sales_tax_enabled: false, p_parts_tax_pct: 18, p_services_tax_pct: 16, p_logo_path: null }));
    const id = must(await owner.rpc("station_create_invoice", { p_job: job1 }));
    const i = must(await owner.from("invoices").select("total_paisa, invoice_no").eq("id", id).single());
    if (i.total_paisa !== 950000) throw new Error("total " + i.total_paisa);
    return id;
  });

  await step("delivery blocked while unpaid", async () => {
    const r = await owner.rpc("job_set_stage", { p_job: job1, p_stage: "delivered", p_note: null });
    if (r.error?.message !== "PAYMENT_DUE") throw new Error(JSON.stringify(r.error));
    return r.error.details;
  });

  await step("split payment 5,000 cash + 4,500 JazzCash (ref needed)", async () => {
    const noRef = await owner.rpc("invoice_record_payment", { p_invoice: inv1, p_amount_paisa: 450000, p_method: "jazzcash", p_reference: null, p_paid_on: null });
    if (noRef.error?.message !== "VALIDATION") throw new Error("reference not required");
    must(await owner.rpc("invoice_record_payment", { p_invoice: inv1, p_amount_paisa: 500000, p_method: "cash", p_reference: null, p_paid_on: null }));
    must(await owner.rpc("invoice_record_payment", { p_invoice: inv1, p_amount_paisa: 450000, p_method: "jazzcash", p_reference: "7781", p_paid_on: null }));
    const b = must(await owner.from("invoice_balances").select("status").eq("invoice_id", inv1).single());
    if (b.status !== "paid") throw new Error(b.status);
    must(await owner.rpc("job_set_stage", { p_job: job1, p_stage: "delivered", p_note: null }));
    return "paid and delivered";
  });

  await step("owner discount above limit applies directly", async () => {
    const j = await readyJob();
    const inv = must(await owner.rpc("station_create_invoice", { p_job: j }));
    const st = must(await owner.rpc("invoice_set_discount", { p_invoice: inv, p_amount_paisa: 80000, p_reason: "Loyal" }));
    const i = must(await owner.from("invoices").select("total_paisa").eq("id", inv).single());
    if (st !== "applied" || i.total_paisa !== 870000) throw new Error(st + " " + i.total_paisa);
    return "9,500 − 800 = " + rs(i.total_paisa);
  });

  await step("credit release → delivered, customer dues rise", async () => {
    const j = await readyJob();
    const inv = must(await owner.rpc("station_create_invoice", { p_job: j }));
    must(await owner.rpc("invoice_record_payment", { p_invoice: inv, p_amount_paisa: 650000, p_method: "cash", p_reference: null, p_paid_on: null }));
    const st = must(await owner.rpc("invoice_request_credit", { p_invoice: inv, p_reason: "Pays next week" }));
    must(await owner.rpc("job_set_stage", { p_job: j, p_stage: "delivered", p_note: null }));
    const c = must(await owner.from("customer_balances").select("dues_paisa").eq("customer_id", cust).single());
    if (st !== "approved" || c.dues_paisa !== 300000) throw new Error(st + " " + c.dues_paisa);
    must(await owner.rpc("customer_collect_dues", { p_customer: cust, p_amount_paisa: 300000, p_method: "cash", p_reference: null }));
    return "dues Rs 3,000 then collected";
  });

  await step("refund 8,000 as credit; shock absorber back to stock", async () => {
    const before = Number(must(await owner.from("item_stock").select("on_hand").eq("item_id", part).single()).on_hand);
    const line = must(await owner.from("invoice_lines").select("id").eq("invoice_id", inv1).eq("kind", "part").single());
    const st = must(await owner.rpc("invoice_request_refund", { p_invoice: inv1, p_amount_paisa: 800000, p_mode: "credit", p_reason: "Part not fitted", p_returns: [{ invoice_line_id: line.id, qty: 1 }] }));
    const after = Number(must(await owner.from("item_stock").select("on_hand").eq("item_id", part).single()).on_hand);
    const c = must(await owner.from("customer_balances").select("credit_paisa").eq("customer_id", cust).single());
    if (st !== "approved" || after !== before + 1 || c.credit_paisa !== 800000) throw new Error(JSON.stringify({ st, before, after, c }));
    return "credit note issued, stock +1, credit Rs 8,000";
  });

  await step("reversal: 5,000 typed instead of 500", async () => {
    const j = await readyJob();
    const inv = must(await owner.rpc("station_create_invoice", { p_job: j }));
    const pay = must(await owner.rpc("invoice_record_payment", { p_invoice: inv, p_amount_paisa: 500000, p_method: "cash", p_reference: null, p_paid_on: null }));
    must(await owner.rpc("payment_reverse", { p_payment: pay, p_reason: "typing error" }));
    must(await owner.rpc("invoice_record_payment", { p_invoice: inv, p_amount_paisa: 50000, p_method: "cash", p_reference: null, p_paid_on: null }));
    const b = must(await owner.from("invoice_balances").select("paid_paisa").eq("invoice_id", inv).single());
    if (b.paid_paisa !== 50000) throw new Error("paid " + b.paid_paisa);
    return "paid shows Rs 500";
  });

  await step("day summary shows each method", async () => {
    const d = must(await owner.rpc("station_day_summary", { p_station: station, p_day: null }));
    if (!(d.expected.cash > 0) || !(d.expected.jazzcash >= 450000)) throw new Error(JSON.stringify(d.expected));
    return `cash ${rs(d.expected.cash)}, JazzCash ${rs(d.expected.jazzcash)}`;
  });
} catch { /* reported below */ }

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
