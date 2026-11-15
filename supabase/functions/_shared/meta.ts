// Shared helpers for the WhatsApp Cloud API (Meta Graph API) and HMAC checks.
export const GRAPH = `https://graph.facebook.com/${Deno.env.get("META_GRAPH_VERSION") ?? "v21.0"}`;

export type GraphError = { message: string; code?: number };

/** Calls the Graph API with a bearer token. Throws { message, code } on an error reply. */
export async function graph(path: string, token: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(`${GRAPH}/${path}`, {
    ...init,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...(init.headers ?? {}) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.error) {
    const err: GraphError = { message: body.error?.message ?? `HTTP ${res.status}`, code: body.error?.code };
    throw err;
  }
  return body;
}

/** Our template "Your vehicle {plate} is ready at {station}." → Meta body with {{1}}, {{2}}. */
export function toMetaBody(template: string): { text: string; names: string[] } {
  const names: string[] = [];
  const text = template.replace(/\{(\w+)\}/g, (_m, name: string) => {
    names.push(name);
    return `{{${names.length}}}`;
  });
  return { text, names };
}

/** Sample values Meta needs to review a template with parameters. */
export const SAMPLES: Record<string, string> = {
  station: "Alpha Service", customer: "Ali Raza", plate: "LEA-1234", slot: "15-02-2027 10:00",
  amount: "9,500", invoice_no: "INV-0042", date: "15-02-2027", job_no: "42",
};

export async function hmacHex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
