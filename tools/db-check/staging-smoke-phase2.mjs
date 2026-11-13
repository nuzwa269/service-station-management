// Phase 2 smoke test against STAGING with the public key (as the apps do).
// Uses the owner + mechanic test accounts from config/staging-test-accounts.json.
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
  try { const out = await fn(); results.push(["PASS", name, out ?? ""]); return out; }
  catch (e) { results.push(["FAIL", name, e.message]); throw e; }
};
const run = Date.now().toString(36).toUpperCase();   // unique codes per run

const owner = client();
try {
  must(await owner.auth.signInWithPassword({ phone: e164(acc.owner.mobile), password: acc.owner.password }));
  const uid = (await owner.auth.getUser()).data.user.id;
  const station = must(await owner.from("station_members").select("station_id").eq("user_id", uid).single()).station_id;

  const filter = await step("save item (piece)", async () =>
    must(await owner.rpc("station_save_item", { p_station: station, p_item: { code: `F-${run}`, name: "Oil filter smoke", unit: "piece", selling_price_paisa: 90000, min_stock: 5 } })));
  const supplier = await step("save supplier", async () =>
    must(await owner.rpc("station_save_supplier", { p_station: station, p_id: null, p_name: `Smoke Supplier ${run}`, p_phone: null })));

  await step("two purchases → average cost 450", async () => {
    for (const cost of [40000, 50000]) {
      must(await owner.rpc("station_post_purchase", {
        p_station: station, p_supplier_id: supplier, p_supplier_name: null, p_bill_no: `B-${cost}`, p_bill_date: null,
        p_lines: [{ item_id: filter, qty: 10, unit_cost_paisa: cost }], p_paid_now_paisa: 0,
      }));
    }
    const s = must(await owner.from("item_stock").select("on_hand").eq("item_id", filter).single());
    const c = must(await owner.from("item_costs").select("avg_cost_paisa").eq("item_id", filter).single());
    if (Number(s.on_hand) !== 20 || c.avg_cost_paisa !== 45000) throw new Error(JSON.stringify({ s, c }));
    return "stock 20, avg Rs 450";
  });

  await step("supplier payment → due", async () => {
    must(await owner.rpc("station_pay_supplier", { p_supplier: supplier, p_amount_paisa: 300000, p_method: "bank", p_reference: "TRX", p_note: null }));
    const b = must(await owner.from("supplier_balances").select("due_paisa").eq("supplier_id", supplier).single());
    if (b.due_paisa !== 600000) throw new Error("due " + b.due_paisa);
    return "purchases 9,000 − paid 3,000 = due Rs 6,000";
  });

  await step("owner stock adjustment applies at once", async () => {
    must(await owner.rpc("station_request_stock_adjustment", { p_station: station, p_item: filter, p_qty: -2, p_reason: "damaged", p_note: null }));
    const s = must(await owner.from("item_stock").select("on_hand").eq("item_id", filter).single());
    if (Number(s.on_hand) !== 18) throw new Error("stock " + s.on_hand);
    return "stock 18";
  });

  await step("customer + vehicle + search '" + run.slice(-4) + "'", async () => {
    const mobile = "0399" + String(Date.now()).slice(-7);
    const cust = must(await owner.rpc("station_save_customer", { p_station: station, p_id: null, p_name: "Smoke Customer", p_mobile: mobile, p_email: null, p_address: null }));
    const digits = String(Date.now()).slice(-4);
    must(await owner.rpc("station_save_vehicle", { p_station: station, p_id: null, p_customer: cust, p_plate: `ZZ ${digits}`, p_make: "Suzuki", p_model: "Alto", p_year: 2020, p_colour: null }));
    const hits = must(await owner.rpc("station_search_customers", { p_station: station, p_query: digits, p_limit: 30 }));
    if (!hits.some((h) => h.plate === `ZZ-${digits}`)) throw new Error("not found");
    return `found ZZ-${digits}`;
  });

  await step("Excel import: 3 rows, 1 rejected", async () => {
    const r = must(await owner.rpc("station_import_items", { p_station: station, p_rows: [
      { row: 2, code: `IMP-${run}-1`, name: "Imported A", unit: "piece", selling_price: "100", opening_qty: "3" },
      { row: 3, code: `IMP-${run}-2`, name: "", unit: "piece" },
      { row: 4, code: `IMP-${run}-3`, name: "Imported C", unit: "litre", opening_qty: "2.5" },
    ] }));
    if (r.added !== 2 || r.rejected !== 1 || r.rejected_rows[0].reason !== "Name missing") throw new Error(JSON.stringify(r));
    return "2 added, row 3 'Name missing'";
  });

  await step("mechanic sees no items, prices or customers", async () => {
    const mech = client();
    must(await mech.auth.signInWithPassword({ phone: e164(acc.mechanic.mobile), password: acc.mechanic.password }));
    const items = must(await mech.from("items").select("id"));
    const costs = must(await mech.from("item_costs").select("item_id"));
    const custs = must(await mech.from("customers").select("id"));
    if (items.length || costs.length || custs.length) throw new Error(JSON.stringify({ items: items.length, costs: costs.length, custs: custs.length }));
    return "0 / 0 / 0";
  });

  await step("second station's owner cannot see this station's items", async () => {
    const other = client();
    must(await other.auth.signInWithPassword({ phone: e164(acc.owner2.mobile), password: acc.owner2.password }));
    const rows = must(await other.from("items").select("id").eq("station_id", station));
    if (rows.length) throw new Error(rows.length + " rows leaked");
    return "0 rows";
  });
} catch { /* reported below */ }

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
