// Phase 7 smoke test against STAGING with the public key: event switches, a booking that lands
// in "Messages to send" with the right text, staff marking it sent, the customer's phone token
// turning on push, staff notifications, and that service-role functions stay closed.
// The customer is the owner2 test account (any verified phone can be a customer).
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
const slotLabel = (iso) => {
  const t = new Date(new Date(iso).getTime() + 5 * 3600e3).toISOString();
  return `${t.slice(8, 10)}-${t.slice(5, 7)}-${t.slice(0, 4)} ${t.slice(11, 16)}`;
};

const created = [];
let owner, station;
try {
  owner = await login(acc.owner);
  const ownerId = (await owner.auth.getUser()).data.user.id;
  station = must(await owner.from("station_members").select("station_id").eq("user_id", ownerId).single()).station_id;
  const stationName = must(await owner.from("stations").select("name").eq("id", station).single()).name;
  const cust = await login(acc.owner2);

  await step("standard message set and per-event switches (owner)", async () => {
    const events = must(await owner.from("message_events").select("code"));
    if (events.length !== 10) throw new Error(`${events.length} events`);
    must(await owner.rpc("station_set_message_events", { p_station: station, p_events: { storage_started: false } }));
    const s = must(await owner.from("message_event_settings").select("event, enabled").eq("station_id", station));
    if (!s.some((x) => x.event === "storage_started" && x.enabled === false)) throw new Error(JSON.stringify(s));
    must(await owner.rpc("station_set_message_events", { p_station: station, p_events: { storage_started: true } }));
    return "10 events";
  });

  // Customer record for owner2 with a vehicle.
  const m = local(acc.owner2.mobile);
  const hits = must(await owner.rpc("station_search_customers", { p_station: station, p_query: m }));
  const custId = hits.find((h) => h.mobile === m)?.customer_id
    ?? must(await owner.rpc("station_save_customer", { p_station: station, p_id: null, p_name: "Smoke Customer A", p_mobile: m }));
  const car = hits.find((h) => h.mobile === m && h.plate)?.vehicle_id
    ?? must(await owner.rpc("station_save_vehicle", { p_station: station, p_id: null, p_customer: custId, p_plate: "SMK-101" }));
  const plate = must(await owner.from("vehicles").select("plate").eq("id", car).single()).plate;

  const freeSlot = async () => {
    for (let i = 2; i <= 12; i++) {
      const free = must(await owner.rpc("booking_slots", { p_station: station, p_day: pkDay(i) })).filter((s) => s.booked < s.capacity);
      if (free.length) return free[free.length - 1].slot_start;
    }
    throw new Error("no free slot");
  };

  let msgId;
  await step("staff booking → WhatsApp message in 'Messages to send' with the text", async () => {
    const slot = await freeSlot();
    const bk = must(await owner.rpc("station_create_booking", { p_station: station, p_customer: custId, p_vehicle: car, p_service: null, p_slot: slot, p_note: "smoke 7" }));
    created.push(bk);
    const rows = must(await owner.from("message_outbox").select("id, channel, status, body, manual_reason, to_mobile").eq("ref_id", bk));
    const wa = rows.find((r) => r.channel === "whatsapp");
    const want = `Your booking at ${stationName} is confirmed for ${slotLabel(slot)} (${plate}).`;
    if (!wa || wa.status !== "manual" || wa.body !== want || wa.to_mobile !== m) throw new Error(JSON.stringify({ wa, want }));
    msgId = wa.id;
    return `"${wa.body}" · ${wa.manual_reason ?? "manual"}`;
  });

  await step("staff open it in WhatsApp, then mark it sent", async () => {
    must(await owner.rpc("message_mark", { p_message: msgId, p_action: "opened" }));
    must(await owner.rpc("message_mark", { p_message: msgId, p_action: "sent" }));
    const r = await owner.rpc("message_mark", { p_message: msgId, p_action: "skipped" });
    if (r.error?.message !== "VALIDATION") throw new Error("handled message changed again");
    const cr = await cust.rpc("message_mark", { p_message: msgId, p_action: "sent" });
    if (cr.error?.message !== "NOT_FOUND") throw new Error("customer could mark a station message");
    const peek = must(await cust.from("message_outbox").select("id"));
    if (peek.length) throw new Error("customer reads the outbox");
  });

  const token = "smoke-fcm-token-" + Date.now() + "-0000000000";
  await step("customer phone registers for push → next booking also queues a push", async () => {
    must(await cust.rpc("register_device", { p_token: token, p_app: "customer" }));
    const slot = await freeSlot();
    const bk = must(await cust.rpc("customer_book", { p_station: station, p_vehicle: car, p_service: null, p_slot: slot, p_note: "smoke 7 app" }));
    created.push(bk);
    const rows = must(await owner.from("message_outbox").select("channel, status").eq("ref_id", bk));
    if (!rows.some((r) => r.channel === "push" && r.status === "queued")) throw new Error(JSON.stringify(rows));
    return rows.map((r) => `${r.channel}:${r.status}`).join(", ");
  });

  await step("staff notification for the app booking, mark read", async () => {
    const n = must(await owner.from("notifications").select("id, kind, title, read_at").eq("station_id", station).order("created_at", { ascending: false }).limit(5));
    if (!n.some((x) => x.kind === "booking" && x.title === "New app booking")) throw new Error(JSON.stringify(n));
    must(await owner.rpc("notifications_mark_read", { p_station: station }));
    return `${n.length} recent`;
  });

  await step("WhatsApp status: not connected → events go to the manual list", async () => {
    const a = must(await owner.from("whatsapp_accounts").select("status").eq("station_id", station));
    if (a.length && a[0].status === "connected") throw new Error("unexpectedly connected");
    return a.length ? a[0].status : "not_connected (no row)";
  });

  await step("service-role functions are closed to logged-in users", async () => {
    for (const fn of ["svc_outbox_claim", "svc_staff_push_claim"]) {
      const r = await owner.rpc(fn, { p_limit: 1 });
      if (!r.error || !/permission denied/i.test(r.error.message)) throw new Error(`${fn}: ${JSON.stringify(r.error)}`);
    }
    const r = await owner.rpc("svc_whatsapp_set_account", { p_station: station, p_status: "connected" });
    if (!r.error) throw new Error("svc_whatsapp_set_account callable");
  });

  must(await cust.rpc("unregister_device", { p_token: token }));
} catch (e) {
  if (!results.some((r) => r[0] === "FAIL")) results.push(["FAIL", "setup", e.message]);
} finally {
  // Clean up the smoke bookings so the station calendar stays tidy.
  for (const id of created) await owner?.rpc("station_cancel_booking", { p_booking: id, p_reason: "Smoke test cleanup" });
  // …and the smoke messages out of the staff list.
  if (owner && created.length) {
    const left = (await owner.from("message_outbox").select("id").in("ref_id", created).in("status", ["manual", "opened"])).data ?? [];
    for (const r of left) await owner.rpc("message_mark", { p_message: r.id, p_action: "skipped" });
  }
}

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
