// Runs supabase/migrations + supabase/tests on a fresh database per test file.
//   node tools/db-check/run.mjs            -> PGlite in memory (no Docker needed)
//   DATABASE_URL=postgres://... node ...   -> a real (local Supabase) database, each file
//                                             inside a transaction that is rolled back
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const migDir = join(root, "supabase", "migrations");
const testDir = join(root, "supabase", "tests");

const migrations = readdirSync(migDir).filter((f) => f.endsWith(".sql")).sort();
const helpers = readFileSync(join(testDir, "_helpers.sql"), "utf8");
const tests = readdirSync(testDir).filter((f) => f.startsWith("test_") && f.endsWith(".sql")).sort();
const only = process.argv[2];

async function pgliteDb() {
  const { PGlite } = await import("@electric-sql/pglite");
  const { pgcrypto } = await import("@electric-sql/pglite/contrib/pgcrypto");
  const db = new PGlite({ extensions: { pgcrypto } });
  await db.exec(readFileSync(join(here, "supabase_stubs.sql"), "utf8"));
  for (const m of migrations) {
    try {
      await db.exec(readFileSync(join(migDir, m), "utf8"));
    } catch (e) {
      throw new Error(`migration ${m} failed: ${e.message}`);
    }
  }
  return { exec: (sql) => db.exec(sql), close: () => db.close() };
}

async function remoteDb() {
  const pg = (await import("pg")).default;
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  await client.query("begin");
  return {
    exec: (sql) => client.query(sql),
    close: async () => { await client.query("rollback"); await client.end(); },
  };
}

let failed = 0;
for (const t of tests) {
  if (only && !t.includes(only)) continue;
  const db = process.env.DATABASE_URL ? await remoteDb() : await pgliteDb();
  try {
    await db.exec(helpers);
    await db.exec(readFileSync(join(testDir, t), "utf8"));
    console.log(`PASS ${t}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${t}\n     ${e.message}${e.where ? "\n     at " + e.where : ""}`);
  } finally {
    await db.close();
  }
}
console.log(`migrations: ${migrations.length}, test files: ${tests.length}, failed: ${failed}`);
process.exit(failed ? 1 : 0);
