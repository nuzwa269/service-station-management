// TASK-052 · REQ-013 — removes files of deleted stations through the Storage API
// (Supabase does not allow deleting storage.objects with SQL). Run daily by a scheduler
// with the service role: POST /functions/v1/storage-cleanup with the service-role key.
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (req.headers.get("authorization") !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: "FORBIDDEN" }), { status: 403 });
  }
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey, { auth: { persistSession: false } });
  const { data: jobs, error } = await admin.from("storage_cleanup_queue").select("*").is("done_at", null).limit(50);
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  let removed = 0;
  for (const job of jobs ?? []) {
    // List everything under the station folder (one level; our paths are <station>/<file>).
    const folder = job.prefix.replace(/\/$/, "");
    for (;;) {
      const { data: files, error: listErr } = await admin.storage.from(job.bucket_id).list(folder, { limit: 100 });
      if (listErr) break;
      if (!files || files.length === 0) break;
      const { error: rmErr } = await admin.storage.from(job.bucket_id).remove(files.map((f) => `${folder}/${f.name}`));
      if (rmErr) break;
      removed += files.length;
    }
    await admin.from("storage_cleanup_queue").update({ done_at: new Date().toISOString() }).eq("id", job.id);
  }
  return new Response(JSON.stringify({ jobs: jobs?.length ?? 0, removed }), { headers: { "content-type": "application/json" } });
});
