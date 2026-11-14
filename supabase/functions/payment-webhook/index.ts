// TASK-048 · REQ-008 — payment provider webhook (JazzCash / Easypaisa / card aggregator).
// Flow (ARCHITECTURE §6): verify the provider signature, re-query the transaction status
// from the provider (never trust the webhook body alone), then confirm idempotently in the
// database with the service role. The concrete provider is chosen in TASK-006; only the
// PaymentProvider implementation below changes when it is.
import { createClient } from "jsr:@supabase/supabase-js@2";

type WebhookEvent = { paymentId: string; providerTxnId: string; success: boolean };

interface PaymentProvider {
  /** Checks the signature header against the raw body. */
  verifySignature(rawBody: string, headers: Headers): Promise<boolean>;
  /** Extracts our payment id and the provider's transaction id from the body. */
  parse(rawBody: string): WebhookEvent;
  /** Asks the provider for the real status of the transaction. */
  requery(providerTxnId: string): Promise<boolean>;
}

async function hmacHex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Generic HMAC-SHA256 provider used until the real aggregator is chosen (sandbox only). */
class HmacSandboxProvider implements PaymentProvider {
  constructor(private secret: string) {}

  async verifySignature(rawBody: string, headers: Headers): Promise<boolean> {
    const given = headers.get("x-signature") ?? "";
    return given.length > 0 && timingSafeEqual(await hmacHex(this.secret, rawBody), given);
  }

  parse(rawBody: string): WebhookEvent {
    const b = JSON.parse(rawBody);
    if (typeof b.payment_id !== "string" || typeof b.transaction_id !== "string") throw new Error("bad body");
    return { paymentId: b.payment_id, providerTxnId: b.transaction_id, success: b.status === "success" };
  }

  async requery(_providerTxnId: string): Promise<boolean> {
    // Sandbox: the signed body is the source of truth. A real provider MUST call its
    // status API here and return true only for a confirmed, paid transaction.
    return Deno.env.get("PAYMENT_PROVIDER_MODE") === "sandbox";
  }
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });
  const secret = Deno.env.get("PAYMENT_WEBHOOK_SECRET");
  if (!secret) return json(500, { error: "NOT_CONFIGURED" });

  const provider: PaymentProvider = new HmacSandboxProvider(secret);
  const raw = await req.text();
  if (!(await provider.verifySignature(raw, req.headers))) return json(401, { error: "BAD_SIGNATURE" });

  let event: WebhookEvent;
  try {
    event = provider.parse(raw);
  } catch {
    return json(400, { error: "BAD_BODY" });
  }

  const confirmed = event.success && (await provider.requery(event.providerTxnId));
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await admin.rpc("admin_confirm_provider_payment", {
    p_payment: event.paymentId,
    p_provider_txn: event.providerTxnId,
    p_success: confirmed,
  });
  if (error) return json(400, { error: error.message, detail: error.details });
  // 200 for duplicates too, so the provider stops retrying.
  return json(200, { result: data });
});
