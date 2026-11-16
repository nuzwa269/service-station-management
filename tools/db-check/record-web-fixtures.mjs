// Fetches, as the demo owner, the exact server answers the web layout audit asked for
// (apps/web/test/fixtures/web_misses.json) and adds them to web_demo.json. Run after each audit
// pass until no misses are left.   node tools/db-check/record-web-fixtures.mjs
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const root = new URL("../../", import.meta.url);
const cfg = JSON.parse(readFileSync(new URL("config/staging.json", root)));
const acc = JSON.parse(readFileSync(new URL("config/staging-test-accounts.json", root)));
const fxFile = new URL("apps/web/test/fixtures/web_demo.json", root);
const missFile = new URL("apps/web/test/fixtures/web_misses.json", root);
const ZERO = "00000000-0000-0000-0000-000000000000";

const c = createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const { data: s, error } = await c.auth.signInWithPassword({ phone: "+92" + acc.owner2.mobile.replace(/\D/g, "").replace(/^0/, ""), password: acc.owner2.password });
if (error) throw new Error(error.message);
const station = (await c.from("station_members").select("station_id").eq("user_id", s.user.id).eq("role", "owner").single()).data.station_id;

const fx = existsSync(fxFile) ? JSON.parse(readFileSync(fxFile, "utf8")) : { answers: {} };
fx.station_id = station;
const misses = existsSync(missFile) ? JSON.parse(readFileSync(missFile, "utf8")) : {};
let added = 0, failed = 0;
for (const [key, m] of Object.entries(misses)) {
  const sub = (t) => t.split(ZERO).join(station);
  const k = sub(key);
  if (fx.answers[k] !== undefined) continue;
  const u = new URL(sub(m.url));
  const res = await fetch(cfg.SUPABASE_URL.replace(/\/+$/, "") + u.pathname + u.search, {
    method: m.method,
    headers: {
      apikey: cfg.SUPABASE_PUBLISHABLE_KEY, authorization: `Bearer ${s.session.access_token}`,
      "content-type": "application/json", accept: m.accept || "application/json",
    },
    body: m.method === "GET" || m.method === "HEAD" ? undefined : sub(m.body || "{}"),
  });
  const text = await res.text();
  if (!res.ok) { failed++; console.log(`✗ ${res.status} ${k.slice(0, 110)} — ${text.slice(0, 120)}`); continue; }
  fx.answers[k] = text ? JSON.parse(text) : null;
  added++;
}
writeFileSync(fxFile, JSON.stringify(fx, null, 1));
console.log(`station ${station.slice(0, 8)}…  added ${added}, failed ${failed}, total answers ${Object.keys(fx.answers).length}`);
