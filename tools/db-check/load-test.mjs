// TASK-069 — light load test of common screens against STAGING with the public key.
//   node tools/db-check/load-test.mjs [virtualUsers=10] [seconds=20]
// Each virtual user logs in as the staging owner and repeatedly loads what the busiest screens
// load (job board, dashboard figures, customer search, today's collections). Prints p50/p95/max
// per call and the error count. The PRD target is 3 s per screen on 4G; the full launch target
// (1,000 stations × 50 users) needs a paid load-test tool and a production-sized project.
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const vus = Number(process.argv[2] ?? 10);
const seconds = Number(process.argv[3] ?? 20);
const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const acc = JSON.parse(readFileSync(new URL("../../config/staging-test-accounts.json", import.meta.url)));
const e164 = (m) => "+92" + m.replace(/\D/g, "").replace(/^0/, "");
const today = new Date(Date.now() + 5 * 3600e3).toISOString().slice(0, 10);

const login = async () => {
  const c = createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ phone: e164(acc.owner.mobile), password: acc.owner.password });
  if (error) throw new Error(error.message);
  return c;
};

const first = await login();
const uid = (await first.auth.getUser()).data.user.id;
const station = (await first.from("station_members").select("station_id").eq("user_id", uid).single()).data.station_id;

const calls = {
  "job board": (c) => c.from("job_cards").select("id, job_no, stage, vehicle:vehicles(plate), customer:customers(name)")
    .eq("station_id", station).not("stage", "in", "(delivered,cancelled)").order("created_at", { ascending: false }).limit(100),
  "dashboard figures": (c) => c.rpc("station_dashboard_totals", { p_station: station }),
  "customer search": (c) => c.rpc("station_search_customers", { p_station: station, p_query: "03" }),
  "today's collections": (c) => c.rpc("station_day_summary", { p_station: station, p_day: today }),
};
const times = Object.fromEntries(Object.keys(calls).map((k) => [k, []]));
const errors = Object.fromEntries(Object.keys(calls).map((k) => [k, 0]));
const errorText = {};

const clients = [first, ...(await Promise.all(Array.from({ length: Math.max(0, vus - 1) }, login)))];
const end = Date.now() + seconds * 1000;
await Promise.all(clients.map(async (c) => {
  while (Date.now() < end) {
    for (const [name, fn] of Object.entries(calls)) {
      const t = performance.now();
      const { error } = await fn(c);
      const ms = performance.now() - t;
      if (error) { errors[name]++; errorText[name] = error.message; } else times[name].push(ms);
    }
  }
}));

const pct = (a, p) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : NaN; };
console.log(`${vus} virtual users for ${seconds} s against staging`);
for (const name of Object.keys(calls)) {
  const a = times[name];
  console.log(`${name.padEnd(20)} n=${String(a.length).padStart(5)}  p50=${pct(a, 0.5).toFixed(0)} ms  p95=${pct(a, 0.95).toFixed(0)} ms  max=${Math.max(...a, 0).toFixed(0)} ms  errors=${errors[name]}${errorText[name] ? " (" + errorText[name] + ")" : ""}`);
}
