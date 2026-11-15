// Checks which Phase 6 objects exist on staging (read-only probes with the owner login).
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const c = createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");
await c.auth.signInWithPassword({ phone: e164(acc.owner.mobile), password: acc.owner.password });
const uuid = "00000000-0000-0000-0000-000000000000";

for (const t of ["booking_settings", "booking_hours", "booking_off_days", "bookings", "no_show_counters", "customer_notifications"]) {
  const r = await c.from(t).select("*", { head: true, count: "exact" });
  console.log(`table ${t}: ${r.error ? "MISSING (" + r.error.message + ")" : "ok"}`);
}
const r1 = await c.from("job_cards").select("next_service_date").limit(1);
console.log(`column job_cards.next_service_date: ${r1.error ? "MISSING" : "ok"}`);
const probes = [
  ["customer_stations", {}],
  ["station_booking_conflicts", { p_station: uuid }],
  ["customer_job", { p_job: uuid }],
  ["customer_vehicle_history", { p_vehicle: uuid }],
  ["station_due_for_service", { p_station: uuid, p_days: 7 }],
];
for (const [fn, args] of probes) {
  const r = await c.rpc(fn, args);
  const missing = r.error && /Could not find the function|does not exist/i.test(r.error.message);
  console.log(`function ${fn}: ${missing ? "MISSING" : "ok"}${r.error && !missing ? " (" + r.error.message + ")" : ""}`);
}
