// TASK-072 — upload the split release APKs to the public "releases" bucket as the platform admin,
// publish the arm64 build in app_versions (in-app updater), and print the download links.
//   node tools/db-check/upload-apks.mjs
import { readFileSync, statSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const root = new URL("../../", import.meta.url);
const cfg = JSON.parse(readFileSync(new URL("config/staging.json", root)));
const acc = JSON.parse(readFileSync(new URL("config/staging-test-accounts.json", root)));
const c = createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const { error: le } = await c.auth.signInWithPassword({ phone: "+92" + acc.admin.mobile.replace(/\D/g, "").replace(/^0/, ""), password: acc.admin.password });
if (le) throw new Error("admin login: " + le.message);

const version = (app) => readFileSync(new URL(`apps/${app}/pubspec.yaml`, root), "utf8").match(/^version:\s*([\d.]+)\+(\d+)/m);
const links = {};
for (const [app, name] of [["staff", "station-staff"], ["customer", "my-car-service"]]) {
  const [, ver, build] = version(app);
  for (const [abi, tag] of [["arm64-v8a", "arm64"], ["armeabi-v7a", "armv7"]]) {
    const file = new URL(`apps/${app}/build/app/outputs/flutter-apk/app-${abi}-release.apk`, root);
    const path = `${name}-${tag}-${ver}.apk`;
    const opts = { contentType: "application/vnd.android.package-archive", cacheControl: "300" };
    let { error } = await c.storage.from("releases").upload(path, readFileSync(file), { ...opts, upsert: false });
    if (error && /exists|duplicate/i.test(error.message)) {
      // Same link, new build: try replacing; if the bucket has no select policy, remove then upload.
      ({ error } = await c.storage.from("releases").upload(path, readFileSync(file), { ...opts, upsert: true }));
      if (error) {
        await c.storage.from("releases").remove([path]);
        ({ error } = await c.storage.from("releases").upload(path, readFileSync(file), { ...opts, upsert: false }));
      }
    }
    if (error) throw new Error(`${path}: ${error.message}`);
    links[path] = c.storage.from("releases").getPublicUrl(path).data.publicUrl;
    console.log(`• ${path}  ${(statSync(file).size / 1048576).toFixed(1)} MB  (v${ver}+${build})`);
  }
  const r = await c.rpc("admin_publish_app_version", { p_app: app, p_build: Number(build), p_version: ver,
    p_apk_url: links[`${name}-arm64-${ver}.apk`], p_min_build: 1, p_notes: "New app icon" });
  if (r.error && !/higher than the published/.test(r.error.details ?? r.error.message)) throw new Error(`publish ${app}: ${r.error.message} ${r.error.details ?? ""}`);
}
// Check every link downloads.
for (const [path, url] of Object.entries(links)) {
  const r = await fetch(url, { method: "HEAD" });
  console.log(`${r.ok ? "OK " : "ERR"} ${url}  (${r.headers.get("content-length")} bytes)`);
}
