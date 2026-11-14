// Phase 3 smoke test against STAGING with the public key: a job from intake to delivery,
// with the mechanic working through sync_pull / sync_apply exactly like the Staff app.
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
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

const owner = client();
const mech = client();
try {
  must(await owner.auth.signInWithPassword({ phone: e164(acc.owner.mobile), password: acc.owner.password }));
  must(await mech.auth.signInWithPassword({ phone: e164(acc.mechanic.mobile), password: acc.mechanic.password }));
  const ownerId = (await owner.auth.getUser()).data.user.id;
  const mechId = (await mech.auth.getUser()).data.user.id;
  const station = must(await owner.from("station_members").select("station_id").eq("user_id", ownerId).single()).station_id;

  await step("checklist template + inspection fee", async () => {
    must(await owner.rpc("station_save_checklist_template", { p_station: station, p_names: ["Brake pads", "Tyres", "Lights"] }));
    must(await owner.rpc("station_set_inspection_fee", { p_station: station, p_fee_paisa: 50000 }));
  });

  const item = must(await owner.rpc("station_save_item", { p_station: station, p_item: { code: `JF-${run}`, name: "Job filter smoke", selling_price_paisa: 90000 } }));
  must(await owner.rpc("station_request_stock_adjustment", { p_station: station, p_item: item, p_qty: 5, p_reason: "count_difference", p_note: null }));
  const mobile = "0399" + String(Date.now()).slice(-7);
  const cust = must(await owner.rpc("station_save_customer", { p_station: station, p_id: null, p_name: "Job Customer", p_mobile: mobile, p_email: null, p_address: null }));
  const car = must(await owner.rpc("station_save_vehicle", { p_station: station, p_id: null, p_customer: cust, p_plate: `JB ${String(Date.now()).slice(-4)}`, p_make: "Honda", p_model: "City", p_year: 2019, p_colour: null }));

  const job = await step("create job card (intake)", async () =>
    must(await owner.rpc("station_create_job", { p_station: station, p_customer: cust, p_vehicle: car, p_odometer: 50000, p_fuel: "H", p_complaints: "Smoke test", p_expected: null, p_confirm_odometer: false, p_booking: null })));

  await step("odometer lower than last visit is caught", async () => {
    const r = await owner.rpc("station_create_job", { p_station: station, p_customer: cust, p_vehicle: car, p_odometer: 40000, p_fuel: "H", p_complaints: null, p_expected: null, p_confirm_odometer: false, p_booking: null });
    if (r.error?.message !== "ODOMETER_LOWER") throw new Error(JSON.stringify(r.error));
    return r.error.details;
  });

  await step("estimate: labour + part, send, record phone approval", async () => {
    must(await owner.rpc("job_add_line", { p_job: job, p_kind: "labour", p_item: null, p_description: "Service labour", p_qty: 1, p_price_paisa: 150000 }));
    must(await owner.rpc("job_add_line", { p_job: job, p_kind: "part", p_item: item, p_description: null, p_qty: 1, p_price_paisa: null }));
    must(await owner.rpc("job_send_estimate", { p_job: job }));
    must(await owner.rpc("job_record_approval", { p_job: job, p_approve: true, p_via: "phone", p_by_name: "Job Customer", p_extra: false }));
    const s = must(await owner.from("item_stock").select("on_hand").eq("item_id", item).single());
    if (Number(s.on_hand) !== 4) throw new Error("stock " + s.on_hand);
    return "approved, stock 5 → 4";
  });

  await step("assign the mechanic", async () => must(await owner.rpc("job_assign", { p_job: job, p_mechanics: [mechId] })));

  const pulled = await step("mechanic sync_pull: job visible, no prices", async () => {
    const p = must(await mech.rpc("sync_pull", { p_station: station, p_since: null }));
    if (!p.jobs.some((j) => j.id === job)) throw new Error("job not in pull");
    if (JSON.stringify(p).includes("price")) throw new Error("prices leaked to mechanic");
    return p;
  });

  await step("mechanic offline batch: start, part, checklist, QC request", async () => {
    const now = Date.now();
    const t = (s) => new Date(now + s * 1000).toISOString();
    const checks = pulled.checklist.filter((c) => c.job_id === job);
    const changes = [
      { client_change_id: randomUUID(), client_time: t(1), op: "stage", args: { job_id: job, stage: "in_progress" } },
      { client_change_id: randomUUID(), client_time: t(2), op: "part_add", args: { line_id: randomUUID(), job_id: job, item_id: item, qty: 1 } },
      ...checks.map((c, i) => ({ client_change_id: randomUUID(), client_time: t(3 + i), op: "check", args: { check_id: c.id, status: "ok", note: null } })),
      { client_change_id: randomUUID(), client_time: t(10), op: "stage", args: { job_id: job, stage: "quality_check" } },
    ];
    const res = must(await mech.rpc("sync_apply", { p_station: station, p_changes: changes }));
    if (!res.every((r) => r.status === "applied")) throw new Error(JSON.stringify(res));
    const again = must(await mech.rpc("sync_apply", { p_station: station, p_changes: changes.slice(0, 1) }));
    if (again[0].status !== "duplicate") throw new Error("duplicate not detected");
    return `${res.length} applied, repeat = duplicate`;
  });

  await step("web sees the mechanic's work (stage, extra part, stock)", async () => {
    const j = must(await owner.from("job_cards").select("stage").eq("id", job).single());
    const lines = must(await owner.from("job_lines").select("status").eq("job_id", job));
    const s = must(await owner.from("item_stock").select("on_hand").eq("item_id", item).single());
    if (j.stage !== "quality_check" || !lines.some((l) => l.status === "extra_pending") || Number(s.on_hand) !== 3) {
      throw new Error(JSON.stringify({ j, lines, s }));
    }
    return "quality_check, 1 extra awaiting approval, stock 3";
  });

  await step("mechanic cannot pass QC; owner fails then passes", async () => {
    const r = await mech.rpc("job_quality_check", { p_job: job, p_pass: true, p_note: null });
    if (!r.error) throw new Error("mechanic passed QC");
    must(await owner.rpc("job_quality_check", { p_job: job, p_pass: false, p_note: "Oil leak" }));
    const n = must(await mech.from("notifications").select("body").eq("kind", "qc_fail").order("created_at", { ascending: false }).limit(1));
    if (n[0]?.body !== "Oil leak") throw new Error("mechanic did not get the note");
    must(await mech.rpc("job_set_stage", { p_job: job, p_stage: "quality_check", p_note: null }));
    must(await owner.rpc("job_quality_check", { p_job: job, p_pass: true, p_note: null }));
    return "fail note reached mechanic; pass → ready";
  });

  await step("delivery blocked until extra work decided, then delivered", async () => {
    const r = await owner.rpc("job_set_stage", { p_job: job, p_stage: "delivered", p_note: null });
    if (r.error?.message !== "VALIDATION") throw new Error("not blocked");
    must(await owner.rpc("job_record_approval", { p_job: job, p_approve: true, p_via: "in_person", p_by_name: "Job Customer", p_extra: true }));
    // Phase 4: delivery needs a paid invoice (REQ-039).
    const inv = must(await owner.rpc("station_create_invoice", { p_job: job }));
    const bal = must(await owner.from("invoice_balances").select("due_paisa").eq("invoice_id", inv).single());
    must(await owner.rpc("invoice_record_payment", { p_invoice: inv, p_amount_paisa: bal.due_paisa, p_method: "cash", p_reference: null, p_paid_on: null }));
    must(await owner.rpc("job_set_stage", { p_job: job, p_stage: "delivered", p_note: null }));
    return "delivered";
  });

  await step("rejected estimate → cancelled with Rs 500 fee", async () => {
    const j2 = must(await owner.rpc("station_create_job", { p_station: station, p_customer: cust, p_vehicle: car, p_odometer: 51000, p_fuel: "F", p_complaints: null, p_expected: null, p_confirm_odometer: false, p_booking: null }));
    must(await owner.rpc("job_add_line", { p_job: j2, p_kind: "labour", p_item: null, p_description: "Diagnosis", p_qty: 1, p_price_paisa: 100000 }));
    must(await owner.rpc("job_record_approval", { p_job: j2, p_approve: false, p_via: "phone", p_by_name: "Job Customer", p_extra: false }));
    const lines = must(await owner.from("job_lines").select("kind, unit_price_paisa, status").eq("job_id", j2).eq("status", "approved"));
    if (lines.length !== 1 || lines[0].kind !== "fee" || lines[0].unit_price_paisa !== 50000) throw new Error(JSON.stringify(lines));
    return "only the inspection fee remains";
  });

  await step("other station's owner sees none of these jobs", async () => {
    const other = client();
    must(await other.auth.signInWithPassword({ phone: e164(acc.owner2.mobile), password: acc.owner2.password }));
    const rows = must(await other.from("job_cards").select("id").eq("station_id", station));
    if (rows.length) throw new Error(rows.length + " leaked");
    return "0 rows";
  });
} catch { /* reported below */ }

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
