// Phase 6 smoke test against STAGING with the public key: booking settings, two customers
// confirming the last free bay at the same moment, arrival → job card, estimate approved in
// the customer app, next service, and isolation between customers.
// Customers here are the owner2 and admin test accounts (any verified phone can be a customer).
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const digits = (m) => m.replace(/\D/g, "");
const e164 = (m) => "+92" + digits(m).replace(/^0/, "");
const local = (m) => "0" + digits(m).replace(/^0/, "").replace(/^92/, "");
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
const pkDay = (offset) => new Date(Date.now() + 5 * 3600e3 + offset * 86400e3).toISOString().slice(0, 10);

try {
  const owner = await login(acc.owner);
  const ownerId = (await owner.auth.getUser()).data.user.id;
  const station = must(await owner.from("station_members").select("station_id").eq("user_id", ownerId).single()).station_id;
  const custA = await login(acc.owner2);   // customer 1
  const custB = await login(acc.admin);    // customer 2

  await step("owner: booking settings 1 bay, 60 min, 09:00–18:00 every day", async () => {
    const hours = [1, 2, 3, 4, 5, 6, 7].map((d) => ({ weekday: d, opens: "09:00", closes: "18:00" }));
    const n = must(await owner.rpc("station_save_booking_settings", {
      p_station: station, p_bays: 1, p_slot_minutes: 60, p_no_show_limit: 3, p_hours: hours, p_off_days: [], p_days_ahead: 30 }));
    const slots = must(await owner.rpc("booking_slots", { p_station: station, p_day: pkDay(3) }));
    if (slots.length !== 9 || slots.some((s) => s.capacity !== 1)) throw new Error(JSON.stringify(slots.length));
    return `9 slots, ${n} conflicts`;
  });

  // Customer records (by mobile) with a vehicle at the owner's station.
  const ensure = async (a, name, plate) => {
    const m = local(a.mobile);
    const hits = must(await owner.rpc("station_search_customers", { p_station: station, p_query: m }));
    let id = hits.find((h) => h.mobile === m)?.customer_id;
    if (!id) id = must(await owner.rpc("station_save_customer", { p_station: station, p_id: null, p_name: name, p_mobile: m }));
    let car = hits.find((h) => h.mobile === m && h.plate)?.vehicle_id;
    if (!car) car = must(await owner.rpc("station_save_vehicle", { p_station: station, p_id: null, p_customer: id, p_plate: plate }));
    return { id, car };
  };
  const a = await ensure(acc.owner2, "Smoke Customer A", "SMK-101");
  const b = await ensure(acc.admin, "Smoke Customer B", "SMK-202");

  await step("customer app: station linked by mobile, sees only own vehicle", async () => {
    const list = must(await custA.rpc("customer_stations"));
    if (!list.some((s) => s.station_id === station)) throw new Error("station not listed");
    const d = must(await custA.rpc("customer_station_data", { p_station: station }));
    if (d.vehicles.length !== 1 || d.vehicles[0].id !== a.car) throw new Error(JSON.stringify(d.vehicles));
    const direct = must(await custA.from("bookings").select("id").eq("station_id", station));
    if (direct.length) throw new Error("customer read bookings table");
    return `${list.length} station(s)`;
  });

  let slot, winner;
  await step("two customers confirm the last bay at the same moment → one booking", async () => {
    for (let i = 2; i <= 10 && !slot; i++) {
      const free = must(await custA.rpc("booking_slots", { p_station: station, p_day: pkDay(i) }));
      slot = free[0]?.slot_start;
    }
    if (!slot) throw new Error("no free slot in the next days");
    const [ra, rb] = await Promise.all([
      custA.rpc("customer_book", { p_station: station, p_vehicle: a.car, p_service: null, p_slot: slot, p_note: "smoke A" }),
      custB.rpc("customer_book", { p_station: station, p_vehicle: b.car, p_service: null, p_slot: slot, p_note: "smoke B" }),
    ]);
    const ok = [ra, rb].filter((r) => !r.error);
    const lost = [ra, rb].find((r) => r.error);
    if (ok.length !== 1 || lost.error.message !== "SLOT_TAKEN") throw new Error(JSON.stringify({ a: ra.error, b: rb.error }));
    winner = !ra.error ? { c: custA, id: ra.data } : { c: custB, id: rb.data };
    return `loser saw "${lost.error.details}"`;
  });

  await step("customer cancels own booking online (more than 1 hour ahead)", async () => {
    must(await winner.c.rpc("customer_cancel_booking", { p_booking: winner.id }));
    const other = winner.c === custA ? custB : custA;
    const r = await other.rpc("customer_cancel_booking", { p_booking: winner.id });
    if (r.error?.message !== "NOT_FOUND") throw new Error("other customer could touch it: " + JSON.stringify(r.error));
  });

  let job;
  await step("staff booking → arrived → job card from the booking", async () => {
    const bk = must(await owner.rpc("station_create_booking", { p_station: station, p_customer: a.id, p_vehicle: a.car, p_service: null, p_slot: slot, p_note: "smoke staff", p_overbook: false }));
    const odo = 100000 + Math.floor(Date.now() / 1000) % 800000;
    job = must(await owner.rpc("station_mark_arrived", { p_booking: bk, p_odometer: odo, p_fuel: "H", p_complaints: "Smoke arrival", p_confirm_odometer: true }));
    const row = must(await owner.from("bookings").select("status, job_id").eq("id", bk).single());
    if (row.status !== "arrived" || row.job_id !== job) throw new Error(JSON.stringify(row));
  });

  await step("estimate Rs 6,500 sent → customer approves in the app", async () => {
    must(await owner.rpc("job_add_line", { p_job: job, p_kind: "labour", p_item: null, p_description: "Smoke oil change", p_qty: 1, p_price_paisa: 650000 }));
    must(await owner.rpc("job_send_estimate", { p_job: job }));
    const seen = must(await custA.rpc("customer_job", { p_job: job }));
    if (seen.stage !== "awaiting_approval") throw new Error(seen.stage);
    const peek = await custB.rpc("customer_job", { p_job: job });
    if (peek.error?.message !== "NOT_FOUND") throw new Error("another customer saw the job");
    must(await custA.rpc("customer_decide", { p_job: job, p_approve: true, p_extra: false }));
    const j = must(await owner.from("job_cards").select("stage, approved_via").eq("id", job).single());
    if (j.stage !== "approved" || j.approved_via !== "app") throw new Error(JSON.stringify(j));
    return "Approved by customer in app";
  });

  await step("next service set → shows in the staff 'Due for service' list window", async () => {
    must(await owner.rpc("job_set_next_service", { p_job: job, p_date: pkDay(5), p_km: null }));
    const due = must(await owner.rpc("station_due_for_service", { p_station: station, p_days: 7 }));
    if (!due.some((d) => d.job_id === job)) throw new Error("not listed");
    const r = await custA.rpc("station_due_for_service", { p_station: station, p_days: 7 });
    if (r.error?.message !== "FORBIDDEN") throw new Error("customer could read staff list");
  });

  await step("customer history and inbox", async () => {
    const h = must(await custA.rpc("customer_vehicle_history", { p_vehicle: a.car }));
    const n = must(await custA.rpc("customer_notifications_list"));
    if (!h.some((x) => x.ref_id === job) || !n.some((x) => x.kind === "estimate")) throw new Error(JSON.stringify({ h: h.length, n: n.length }));
    return `${h.length} visit(s), ${n.length} message(s)`;
  });

  // Clean up the smoke job so the station dashboard stays tidy.
  await owner.rpc("job_cancel", { p_job: job, p_reason: "Smoke test cleanup" });
} catch (e) {
  if (!results.some((r) => r[0] === "FAIL")) results.push(["FAIL", "setup", e.message]);
}

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
