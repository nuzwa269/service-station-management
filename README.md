# Car Service Station Management SaaS

Bookings, job cards, parts, billing, staff pay and customer history for independent
car service stations in Pakistan. Approved specs are in [docs/](docs/) (PRD v1.1,
ARCHITECTURE v1.0, IMPLEMENTATION_PLAN v1.0, TASKS v1.0). The PRD is the contract:
every change names its `TASK-###` and `REQ-###`.

## Layout
| Path | What |
|---|---|
| `apps/web` | Flutter web — station dashboard and super admin |
| `apps/staff` | Flutter Android (8+) — mechanics (offline from Phase 3), quick dashboard |
| `apps/customer` | Flutter Android (8+) — customers (OTP login; booking from Phase 6) |
| `packages/core` | Pure Dart rules: money (integer paisa), PKR/phone/plate/date formats, roles, plans, error codes, `SyncEngine` interface |
| `packages/app_shared` | Shared Flutter code: Supabase API wrapper, session, login forms, locked/read-only/empty/error states |
| `supabase/migrations` | Schema, RLS, business-rule functions (all writes go through functions) |
| `supabase/tests` | Database tests incl. TEST-003 cross-station isolation over every table |
| `supabase/functions` | Edge Functions (`invite-member`) |
| `tools/db-check` | Runs migrations + database tests on embedded Postgres (no Docker) or a real DB |

## Run
```bash
flutter pub get
```
```bash
cd tools/db-check && npm install && node run.mjs
```
```bash
cd packages/core && dart test
```
```bash
cd apps/web && flutter run -d chrome --dart-define-from-file=../../config/staging.json
```
Copy `config/example.json` to `config/staging.json` and fill the public URL and publishable key.
Only public values go in apps; provider secrets live in Edge Function secrets.

## Status
Phase 0 (repo/CI) and Phase 1 foundation code are written; see `docs/TASKS.md`.
Accounts and device spikes: [docs/phase0/CHECKLIST.md](docs/phase0/CHECKLIST.md).
