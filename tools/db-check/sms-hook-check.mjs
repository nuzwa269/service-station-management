// TASK-005 — after deploying send-sms and sms-gateway, check the whole SMS path on STAGING:
//   1. sms-gateway refuses a wrong secret and accepts the right one;
//   2. send-sms refuses an unsigned call and queues a correctly signed one (Standard Webhooks).
// The queued test message is then sent by the gateway phone to TEST_PHONE (a real SMS).
//   node tools/db-check/sms-hook-check.mjs
// Reads config/staging.json and config/sms-gateway.json (both gitignored).
import { readFileSync } from "node:fs";
import { createHmac, randomUUID } from "node:crypto";

const cfg = JSON.parse(readFileSync(new URL("../../config/staging.json", import.meta.url)));
const sms = JSON.parse(readFileSync(new URL("../../config/sms-gateway.json", import.meta.url), "utf8").replace(/^﻿/, ""));
const base = cfg.SUPABASE_URL.replace(/\/+$/, "") + "/functions/v1";
const results = [];
const step = async (name, fn) => {
  try { results.push(["PASS", name, (await fn()) ?? ""]); } catch (e) { results.push(["FAIL", name, e.message]); }
};

await step("sms-gateway: wrong secret refused", async () => {
  const r = await fetch(`${base}/sms-gateway`, { method: "POST", headers: { "x-gateway-secret": "wrong-secret-wrong-secret-0000", "content-type": "application/json" }, body: '{"action":"claim"}' });
  if (r.status !== 403) throw new Error(`status ${r.status}`);
});

await step("sms-gateway: right secret accepted", async () => {
  // A report for a message that does not exist changes nothing but proves the secret works.
  const r = await fetch(`${base}/sms-gateway`, { method: "POST", headers: { "x-gateway-secret": sms.GATEWAY_SECRET, "content-type": "application/json" }, body: '{"action":"report","id":0,"ok":true}' });
  if (r.status !== 200) throw new Error(`status ${r.status}: ${await r.text()}`);
});

const phone = "92" + String(sms.TEST_PHONE).replace(/\D/g, "").replace(/^0/, "");
const body = JSON.stringify({ user: { phone }, sms: { otp: "000000" } });

await step("send-sms: unsigned call refused", async () => {
  const r = await fetch(`${base}/send-sms`, { method: "POST", headers: { "content-type": "application/json" }, body });
  if (r.status !== 401) throw new Error(`status ${r.status}`);
});

await step(`send-sms: signed test code queued for ${sms.TEST_PHONE}`, async () => {
  if (!/^v1,whsec_/.test(sms.SEND_SMS_HOOK_SECRET)) throw new Error("put the hook secret from Supabase into config/sms-gateway.json");
  if (!/^92\d{10}$/.test(phone)) throw new Error("put your test mobile into TEST_PHONE");
  const id = randomUUID();
  const ts = Math.floor(Date.now() / 1000).toString();
  const key = Buffer.from(sms.SEND_SMS_HOOK_SECRET.replace(/^v1,whsec_/, ""), "base64");
  const sig = createHmac("sha256", key).update(`${id}.${ts}.${body}`).digest("base64");
  const r = await fetch(`${base}/send-sms`, {
    method: "POST",
    headers: { "content-type": "application/json", "webhook-id": id, "webhook-timestamp": ts, "webhook-signature": `v1,${sig}` },
    body,
  });
  if (r.status !== 200) throw new Error(`status ${r.status}: ${await r.text()}`);
  return "the gateway phone should send '000000 is your Car Service login code…' within a few seconds";
});

for (const [s, n, o] of results) console.log(`${s}  ${n}${o ? "  — " + o : ""}`);
process.exit(results.some((r) => r[0] === "FAIL") ? 1 : 0);
