# Planned Tasks — Car Service Station Management SaaS

> State: APPROVED plan (frozen) | Version: 1.0 | Date: 2026-11-13 | Approval: user "ہاں، منظور ہے" (2026-11-13) | Sources: PRD v1.1, ARCHITECTURE.md v0.2
> All tasks are NOT_STARTED. This stage only plans; no code exists yet. Do not mark a task DONE without implementation evidence.

## Tasks

| Task ID | Phase | Task | REQ IDs | Dependencies | Test / proof | Status |
|---|---|---|---|---|---|---|
| TASK-001 | 0 | Create monorepo (apps/staff, apps/customer, apps/web, packages/core, supabase/) with lint and CI skeleton | — | — | CI runs lint + empty test suite green | DONE |
| TASK-002 | 0 | Create Supabase staging + production projects in Mumbai; record plan, compute size and current prices | REQ-003 | TASK-001 | Cost table filled in IMPLEMENTATION_PLAN Costs section | NOT_STARTED |
| TASK-003 | 0 | Choose web hosting + domain/subdomains; HTTPS for web, super admin, APK downloads | REQ-045 | TASK-001 | Staging URL serves a test page over HTTPS | NOT_STARTED |
| TASK-004 | 0 | Register as Meta Tech Provider, set up Embedded Signup test, prepare standard English templates for REQ-055 events | REQ-061, REQ-055 | — | Test station connected; a template message sent from its number | NOT_STARTED |
| TASK-005 | 0 | SMS aggregator selection (login codes only) + Supabase Auth custom SMS hook spike (OTP to a Pakistani number) | REQ-001, REQ-047 | TASK-002 | OTP received on 2 networks; cost per SMS recorded | NOT_STARTED |
| TASK-006 | 0 | Payment aggregator selection, merchant onboarding, sandbox checkout + webhook for JazzCash, Easypaisa, card | REQ-008 | TASK-002 | Sandbox payment reaches webhook with valid signature | NOT_STARTED |
| TASK-007 | 0 | Own sync engine spike: local SQLite + change queue + sync_pull/sync_apply on Android 8 / 2 GB phone, 24 h offline | REQ-023, REQ-031 | TASK-002 | Spike report: memory, sync time, duplicate and conflict handling | NOT_STARTED |
| TASK-008 | 0 | Flutter web spike: measure first-load size and time on 4G for a dashboard shell | REQ-060 | TASK-001 | Report vs 3 s target; confirms DEC-030 | NOT_STARTED |
| TASK-009 | 0 | Bluetooth ESC/POS printer (58/80 mm) + barcode/QR scanning spike on Android 8 | REQ-045, REQ-028 | TASK-001 | Receipt printed; barcode read | NOT_STARTED |
| TASK-010 | 1 | Core schema: stations, profiles, station_members, roles; RLS on every tenant table | REQ-002, REQ-003 | TASK-002 | Database policy tests pass | DONE |
| TASK-011 | 1 | Automated cross-station isolation test suite covering every table and view | REQ-003 | TASK-010 | TEST-003 passes for all tables | DONE |
| TASK-012 | 1 | Shared core package: PKR/date/phone/plate formatting, error codes, validation | REQ-018, REQ-036, REQ-046 | TASK-001 | Unit tests for formats | DONE |
| TASK-013 | 1 | App shells: web (role routes), staff app, customer app with login and session | REQ-002 | TASK-010, TASK-012 | Widget tests; login works on staging | DONE |
| TASK-014 | 1 | Station sign-up with OTP + onboarding wizard (SCR-001, SCR-002) | REQ-001, REQ-004 | TASK-005, TASK-013 | TEST-001 | DONE |
| TASK-015 | 1 | Users and roles management, deactivation with open-job check | REQ-002 | TASK-013 | TEST-002 | DONE |
| TASK-016 | 1 | Station profile, logo upload, tax and NTN/STRN settings | REQ-004 | TASK-014 | TEST-004 | IN_PROGRESS |
| TASK-017 | 1 | Plans, features, station_entitlements view; gating in write functions and locked-feature UI | REQ-006 | TASK-010 | TEST-006 | DONE |
| TASK-018 | 1 | Audit-log triggers on all money/stock/settings tables + owner viewer (SCR-018) | REQ-058 | TASK-010 | TEST-058; no update/delete grants | DONE |
| TASK-019 | 1 | Support access grants (time-limited, read-only, logged) | REQ-005 | TASK-017, TASK-018 | TEST-005 | DONE |
| TASK-020 | 2 | Items, units (piece/litre/kit), bulk containers, kits, prices, min level (SCR-009) | REQ-028 | TASK-017 | TEST-028 | DONE |
| TASK-021 | 2 | Purchases with stock movements and weighted average cost (SCR-010) | REQ-029 | TASK-020 | TEST-029 | DONE |
| TASK-022 | 2 | Suppliers, supplier ledger and payments (Standard+) | REQ-030 | TASK-021 | TEST-030 | DONE |
| TASK-023 | 2 | Approvals engine: requests, approve/reject, inbox web + staff app, Basic owner-only path | REQ-057, REQ-032, REQ-037, REQ-039, REQ-041 | TASK-017, TASK-018 | TEST-057 | DONE |
| TASK-024 | 2 | Stock adjustment requests via approvals (SCR-011) | REQ-032 | TASK-020, TASK-023 | TEST-032 | DONE |
| TASK-025 | 2 | Low-stock and negative-stock alerts | REQ-033, REQ-031 | TASK-020 | TEST-033 | DONE |
| TASK-026 | 2 | Customers and vehicles: records, search, ownership change (SCR-008) | REQ-046 | TASK-010 | TEST-046 | DONE |
| TASK-027 | 2 | Excel templates and import with row-level rejection report (SCR-020) | REQ-034 | TASK-020, TASK-026 | TEST-034 (1,000-row file) | DONE |
| TASK-028 | 2 | Vehicle service history timeline | REQ-048 | TASK-026 | TEST-048 | IN_PROGRESS |
| TASK-029 | 3 | Job card intake from booking or walk-in, odometer check (SCR-005, SCR-006) | REQ-018 | TASK-026 | TEST-018 | DONE |
| TASK-030 | 3 | Station checklist configuration and use, add-to-estimate | REQ-019 | TASK-029 | TEST-019 | DONE |
| TASK-031 | 3 | Estimate, customer/phone approval, extra-work re-approval | REQ-020, REQ-022 | TASK-029 | TEST-020, TEST-022 | DONE |
| TASK-032 | 3 | Stages, mechanic assignment, quality check | REQ-021, REQ-024 | TASK-029 | TEST-021, TEST-024 | DONE |
| TASK-033 | 3 | Parts on job cards incl. customer-supplied lines, stock movements | REQ-031 | TASK-020, TASK-029 | TEST-031 | DONE |
| TASK-034 | 3 | Own sync engine: sync_pull (assigned jobs, items without prices), change queue, sync_apply with idempotency, conflict history + manager alert, SyncEngine interface for a later PowerSync swap | REQ-023 | TASK-007, TASK-032, TASK-033 | TEST-023 + sync test suite (ordering, duplicates, restarts, conflicts) | DONE |
| TASK-035 | 3 | Staff app mechanic screens SCR-031 to SCR-033 with offline badge and 24 h warning | REQ-023, REQ-021 | TASK-034 | TEST-023 on device | IN_PROGRESS |
| TASK-036 | 3 | Cancellation and rejected estimate (fee invoice completed with TASK-039) | REQ-025 | TASK-031 | TEST-025 | DONE |
| TASK-037 | 3 | Rework jobs and warranty claims (incl. return to supplier) | REQ-026, REQ-027 | TASK-029, TASK-022 | TEST-026, TEST-027 | DONE |
| TASK-038 | 4 | Labour/service list with warranty days | REQ-035 | TASK-017 | TEST-035 | IN_PROGRESS |
| TASK-039 | 4 | Invoice from approved lines, sequential numbering, tax per category (SCR-007) | REQ-036 | TASK-031, TASK-038 | TEST-036, TEST-004 | IN_PROGRESS |
| TASK-040 | 4 | Discount limit enforcement with approval/owner path | REQ-037 | TASK-023, TASK-039 | TEST-037 | IN_PROGRESS |
| TASK-041 | 4 | Payments: methods, references, split, advance, change | REQ-038 | TASK-039 | TEST-038 | IN_PROGRESS |
| TASK-042 | 4 | Handover rule, credit release, customer ledger and collections | REQ-039, REQ-040 | TASK-023, TASK-041 | TEST-039, TEST-040 | IN_PROGRESS |
| TASK-043 | 4 | Refunds, credit notes, reversals with reason | REQ-041, REQ-042 | TASK-023, TASK-041 | TEST-041, TEST-042 | IN_PROGRESS |
| TASK-044 | 4 | Storage-charge scheduler job and ready-vehicle reminders | REQ-043 | TASK-039 | TEST-043 | IN_PROGRESS |
| TASK-045 | 4 | Daily cash closing and reopen (SCR-013) | REQ-044 | TASK-041 | TEST-044 | IN_PROGRESS |
| TASK-046 | 4 | Invoice/estimate PDF, A4 web print, Bluetooth receipt, share (SCR-036) | REQ-045 | TASK-009, TASK-039 | TEST-045 | IN_PROGRESS |
| TASK-047 | 5 | Trial lifecycle, reminders, trial extension | REQ-007 | TASK-017 | TEST-007 | NOT_STARTED |
| TASK-048 | 5 | Subscription checkout, webhook activation, bank/cash verification (SCR-019, SCR-022) | REQ-008 | TASK-006, TASK-047 | TEST-008 | NOT_STARTED |
| TASK-049 | 5 | Grace and read-only enforcement in functions, UI banner, offline hold | REQ-009 | TASK-017, TASK-034 | TEST-009, TEST-104 | NOT_STARTED |
| TASK-050 | 5 | Upgrade/downgrade with proration | REQ-010 | TASK-048 | TEST-010 | NOT_STARTED |
| TASK-051 | 5 | Super admin tenants list/detail, plans and packs config (SCR-021 to SCR-023) | REQ-012 | TASK-017 | TEST-012 | NOT_STARTED |
| TASK-052 | 5 | Full Excel export, close account, 90-day deletion job | REQ-013 | TASK-026 | TEST-013 | NOT_STARTED |
| TASK-053 | 6 | Booking settings: bays, slot length, hours, off-days | REQ-014 | TASK-017 | TEST-014 | NOT_STARTED |
| TASK-054 | 6 | Customer app login (OTP) and station links by phone/code | REQ-047 | TASK-005, TASK-013 | TEST-047 | NOT_STARTED |
| TASK-055 | 6 | Customer self-booking with capacity locking (SCR-042) | REQ-015 | TASK-053, TASK-054 | TEST-015 (concurrency) | NOT_STARTED |
| TASK-056 | 6 | Staff bookings calendar, reschedule, cancel rules (SCR-004) | REQ-016 | TASK-053 | TEST-016 | NOT_STARTED |
| TASK-057 | 6 | No-show scheduler job, block and unblock | REQ-017 | TASK-055 | TEST-017 | NOT_STARTED |
| TASK-058 | 6 | Customer job tracking, estimate/extra-work approval, invoices and history (SCR-043, SCR-044) | REQ-020, REQ-022, REQ-048 | TASK-031, TASK-054 | TEST-020, TEST-022, TEST-048 | NOT_STARTED |
| TASK-059 | 6 | Next-service reminders (staff list on Basic) | REQ-049 | TASK-032 | TEST-049 | NOT_STARTED |
| TASK-060 | 7 | Message outbox per station, automatic WhatsApp sends, per-event toggles, retry then manual list | REQ-055 | TASK-004 | TEST-055 | NOT_STARTED |
| TASK-061 | 7 | Connect WhatsApp (Embedded Signup) settings and status, plus manual Messages-to-send list with wa.me links on web and staff app | REQ-061, REQ-062 | TASK-004, TASK-060 | TEST-061, TEST-062 | NOT_STARTED |
| TASK-062 | 7 | Staff push events via FCM (assignment, QC fail, approvals, conflicts, stock, subscription) | REQ-056 | TASK-013 | TEST-056 | NOT_STARTED |
| TASK-063 | 8 | Reports with date range, print and Excel export (SCR-014) | REQ-059 | TASK-041, TASK-022 | TEST-059 | NOT_STARTED |
| TASK-064 | 8 | Owner/manager dashboard (SCR-003, SCR-035) | REQ-060 | TASK-041 | TEST-060 | NOT_STARTED |
| TASK-065 | 8 | Staff records and daily attendance (SCR-015) | REQ-050, REQ-051 | TASK-013 | TEST-050, TEST-051 | NOT_STARTED |
| TASK-066 | 8 | Advances and monthly payroll with commission (SCR-016) | REQ-052, REQ-053 | TASK-065, TASK-041 | TEST-052, TEST-053, TEST-105 | NOT_STARTED |
| TASK-067 | 8 | Mechanic performance report | REQ-054 | TASK-032, TASK-037 | TEST-054 | NOT_STARTED |
| TASK-068 | 9 | Security review: RLS audit, threat-model tests, webhook signature tests, OTP rate limits | REQ-003, REQ-005, REQ-008 | All feature tasks | Review report; no open High findings | NOT_STARTED |
| TASK-069 | 9 | Performance and load test (1,000 stations x 50 users, 3 s screens) | REQ-060, REQ-059 | All feature tasks | Load test report vs targets | NOT_STARTED |
| TASK-070 | 9 | End-to-end scenarios TEST-101 to TEST-105 on staging | REQ-015, REQ-037, REQ-039, REQ-009, REQ-053 | All feature tasks | All E2E scenarios pass | NOT_STARTED |
| TASK-071 | 9 | Device fleet test TEST-201 (Android 8 / 2 GB, printers) | REQ-023, REQ-045 | TASK-035, TASK-046 | TEST-201 passes | NOT_STARTED |
| TASK-072 | 9 | APK signing keystore custody, version manifest, in-app updater, install guide | REQ-045 | TASK-001 | Update flow works from vN to vN+1 | NOT_STARTED |
| TASK-073 | 9 | Backups: confirm daily backups, set up weekly off-site export, first restore drill | REQ-013 | TASK-002 | Restore drill report | NOT_STARTED |
| TASK-074 | 9 | Pilot with 2-3 stations on staging, fix list, support WhatsApp line and video guides | REQ-001, REQ-055 | TASK-070, TASK-071, TASK-072 | Pilot sign-off from owner | NOT_STARTED |
| TASK-075 | 9 | Production launch checklist and go-live | — | TASK-074 | Checklist complete; monitoring live | NOT_STARTED |

Allowed statuses: NOT_STARTED, IN_PROGRESS, BLOCKED, DONE. Do not claim tests passed without actual evidence.

## Progress notes (2026-11-13)
- IN_PROGRESS tasks have code in this repository and local evidence only:
  - `tools/db-check/run.mjs` on embedded Postgres (PGlite): 6 migrations apply; `test_003_isolation.sql` and `test_phase1_rules.sql` (TEST-001, 002, 003, 004, 005, 006, 007, 009, 058) pass. Isolation test was checked to fail when a policy is broken.
  - `packages/core`: 14 unit tests pass. `apps/web`: 5 widget tests pass. `apps/staff`: 3 widget tests pass. `flutter analyze` clean.
- 2026-11-13: migrations applied to staging via dashboard SQL Editor (`supabase/dashboard_setup.sql`); `plans` returns 3 rows. `invite-member` deployed; it rejects a call without login (401 UNAUTHENTICATED).
- 2026-11-13: `tools/db-check/staging-smoke.mjs` passed 10/10 on staging with the public key only: owner sign-up, station + Premium trial, profile/tax save, tax 150% rejected, audit 0 → 18, mechanic added via `invite-member`, mechanic sees only own membership and gets FORBIDDEN on settings, anonymous sees 0 stations.
- 2026-11-13: phone confirmations turned on in staging. With test number 0399-0000003: sign-up gives no session and an unconfirmed phone; creating a station before the code is refused; a wrong code is rejected; the right code confirms and logs in; the station is then created with a Premium trial, and the owner sees exactly 1 station.
- Staging SMS provider is a placeholder (dummy Twilio values), so only test numbers can sign up until TASK-005.
- Not yet done, so none is DONE: database tests not run on the real Supabase stack; CI not run on GitHub; phone OTP not tested with a real SMS.
- 2026-11-13: CI run #3 green on `main` (commit 90fe91b): flutter analyze, core unit tests, web and staff widget tests, database tests on PGlite **and** on the real Supabase stack (CLI 3.1.0). TASK-001, 010–015, 017–019 marked DONE on that evidence plus the staging checks above.
- TASK-016 stays IN_PROGRESS: profile and tax are proven (TEST-004, staging), but the logo upload to the `station-logos` bucket has not been tried yet.
- 2026-11-14 Phase 2 (branch `phase-2-inventory`): migrations 07–10 (items, kits, append-only stock movements with weighted average cost, suppliers and ledger, purchases with reversal, approvals engine with Basic owner-only path, customers and vehicles with search, Excel import). `test_phase2_inventory.sql` passes on PGlite: TEST-028, 029 (avg cost 450), 030 (due 20,000), 031/033 (negative and low stock), 032, 034 (1,000 rows → 997 added, 3 "Name missing"), 046 (search "1234"), 057. TEST-003 now seeds every Phase 2 table in the other station and still finds no leak. Web screens for inventory, purchases/suppliers, approvals, customers and Excel import; 17 core tests and 8 web tests pass.
- Phase 2 tasks stay IN_PROGRESS until CI is green and `supabase/dashboard_phase2.sql` is applied on staging. TASK-028 is partial by design: the vehicle timeline shows ownership now; jobs, parts and invoices join it in Phases 3–4. Low-stock push (REQ-033) arrives with notifications in Phase 7.
- 2026-11-14: CI run #5 green on `main` (1b5aa7c). Phase 2 SQL applied on staging; `tools/db-check/staging-smoke-phase2.mjs` passed 9/9 there (avg cost 450, supplier due, owner adjustment, search, Excel import with "Name missing", mechanic sees no items/prices/customers, other station sees 0 rows). TASK-020…027 marked DONE. TASK-028 stays IN_PROGRESS until jobs and invoices feed the vehicle timeline (Phases 3–4).
- 2026-11-15 Phase 3 (branch `phase-3-jobs`): migrations 11–13 — job cards with sequential numbers, odometer check, station checklist, estimate lines, phone/in-person approval, extra-work re-approval, stages with mechanic limits, QC pass/fail, cancellation with inspection fee, parts with stock (kits by component, negative stock alert), rework and warranty (incl. return to supplier), notifications, and the own sync engine (`sync_pull` without prices, `sync_apply` idempotent by client_change_id, last-change-wins with conflict history and manager alert, read-only changes held). `test_phase3_jobs.sql` passes on PGlite (TEST-018…027, 031, sync suite); TEST-003 seeds a job card in the other station. Web job cards screen; Staff app mechanic screens with SQLite queue (9 tests incl. offline, restart, duplicate, held).
- Phase 3 tasks stay IN_PROGRESS until CI is green and `supabase/dashboard_phase3.sql` runs on staging. TASK-035 also needs the real-device test (Android 8 / 2 GB, 24 h offline). Delivery payment rule (REQ-039), fee invoice (REQ-025) and warranty from invoice lines follow in Phase 4; customer app approval in Phase 6; push in Phase 7.
- 2026-11-15: CI run #8 green on `main` (27a47ee). Phase 3 SQL applied on staging; `tools/db-check/staging-smoke-phase3.mjs` passed 12/12 there (intake, odometer warning, estimate + phone approval with stock, assignment, mechanic sync_pull without prices, offline batch via sync_apply with duplicate detection, QC fail note to mechanic then pass, delivery blocked by pending extra work, rejected estimate → Rs 500 fee, no leak to another station). TASK-029…034, 036, 037 marked DONE. TASK-035 stays IN_PROGRESS until the real Android 8 / 2 GB device test (24 h offline).
- 2026-11-16 Phase 4 (branch `phase-4-billing`): migrations 14–15 — service list, invoices from approved lines (sequential, tax per category, whole rupees, locked after first payment), discount limit with approval / Basic owner-only, append-only payments (split, advance, credit use, reversal), handover rule (paid or credit released) now enforced at delivery, customer dues (oldest first) and credit, refunds as numbered credit notes with parts back to stock, storage charge + uncollected reminders (daily job; pg_cron if enabled), day closing with difference note and owner reopen. `test_phase4_billing.sql` passes on PGlite (TEST-035…044, TEST-102 Rs 9,200); TEST-003 seeds invoices, payments, credit notes and a day closing. Web: invoice panel in the job card, day closing screen, customer dues, billing settings, A4 print / PDF.
- Phase 4 tasks stay IN_PROGRESS until CI is green and `supabase/dashboard_phase4.sql` runs on staging (then `tools/db-check/staging-smoke-phase4.mjs`). TASK-046: Bluetooth 58/80 mm receipt from the Staff app still needs the printer spike (TASK-009) and real printers.
