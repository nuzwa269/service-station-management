# Planned Tasks — Car Service Station Management SaaS

> State: APPROVED plan (frozen) | Version: 1.0 | Date: 2026-11-13 | Approval: user "ہاں، منظور ہے" (2026-11-13) | Sources: PRD v1.1, ARCHITECTURE.md v0.2
> All tasks are NOT_STARTED. This stage only plans; no code exists yet. Do not mark a task DONE without implementation evidence.

## Tasks

| Task ID | Phase | Task | REQ IDs | Dependencies | Test / proof | Status |
|---|---|---|---|---|---|---|
| TASK-001 | 0 | Create monorepo (apps/staff, apps/customer, apps/web, packages/core, supabase/) with lint and CI skeleton | — | — | CI runs lint + empty test suite green | IN_PROGRESS |
| TASK-002 | 0 | Create Supabase staging + production projects in Mumbai; record plan, compute size and current prices | REQ-003 | TASK-001 | Cost table filled in IMPLEMENTATION_PLAN Costs section | NOT_STARTED |
| TASK-003 | 0 | Choose web hosting + domain/subdomains; HTTPS for web, super admin, APK downloads | REQ-045 | TASK-001 | Staging URL serves a test page over HTTPS | NOT_STARTED |
| TASK-004 | 0 | Register as Meta Tech Provider, set up Embedded Signup test, prepare standard English templates for REQ-055 events | REQ-061, REQ-055 | — | Test station connected; a template message sent from its number | NOT_STARTED |
| TASK-005 | 0 | SMS aggregator selection (login codes only) + Supabase Auth custom SMS hook spike (OTP to a Pakistani number) | REQ-001, REQ-047 | TASK-002 | OTP received on 2 networks; cost per SMS recorded | NOT_STARTED |
| TASK-006 | 0 | Payment aggregator selection, merchant onboarding, sandbox checkout + webhook for JazzCash, Easypaisa, card | REQ-008 | TASK-002 | Sandbox payment reaches webhook with valid signature | NOT_STARTED |
| TASK-007 | 0 | Own sync engine spike: local SQLite + change queue + sync_pull/sync_apply on Android 8 / 2 GB phone, 24 h offline | REQ-023, REQ-031 | TASK-002 | Spike report: memory, sync time, duplicate and conflict handling | NOT_STARTED |
| TASK-008 | 0 | Flutter web spike: measure first-load size and time on 4G for a dashboard shell | REQ-060 | TASK-001 | Report vs 3 s target; confirms DEC-030 | NOT_STARTED |
| TASK-009 | 0 | Bluetooth ESC/POS printer (58/80 mm) + barcode/QR scanning spike on Android 8 | REQ-045, REQ-028 | TASK-001 | Receipt printed; barcode read | NOT_STARTED |
| TASK-010 | 1 | Core schema: stations, profiles, station_members, roles; RLS on every tenant table | REQ-002, REQ-003 | TASK-002 | Database policy tests pass | IN_PROGRESS |
| TASK-011 | 1 | Automated cross-station isolation test suite covering every table and view | REQ-003 | TASK-010 | TEST-003 passes for all tables | IN_PROGRESS |
| TASK-012 | 1 | Shared core package: PKR/date/phone/plate formatting, error codes, validation | REQ-018, REQ-036, REQ-046 | TASK-001 | Unit tests for formats | IN_PROGRESS |
| TASK-013 | 1 | App shells: web (role routes), staff app, customer app with login and session | REQ-002 | TASK-010, TASK-012 | Widget tests; login works on staging | IN_PROGRESS |
| TASK-014 | 1 | Station sign-up with OTP + onboarding wizard (SCR-001, SCR-002) | REQ-001, REQ-004 | TASK-005, TASK-013 | TEST-001 | IN_PROGRESS |
| TASK-015 | 1 | Users and roles management, deactivation with open-job check | REQ-002 | TASK-013 | TEST-002 | IN_PROGRESS |
| TASK-016 | 1 | Station profile, logo upload, tax and NTN/STRN settings | REQ-004 | TASK-014 | TEST-004 | IN_PROGRESS |
| TASK-017 | 1 | Plans, features, station_entitlements view; gating in write functions and locked-feature UI | REQ-006 | TASK-010 | TEST-006 | IN_PROGRESS |
| TASK-018 | 1 | Audit-log triggers on all money/stock/settings tables + owner viewer (SCR-018) | REQ-058 | TASK-010 | TEST-058; no update/delete grants | IN_PROGRESS |
| TASK-019 | 1 | Support access grants (time-limited, read-only, logged) | REQ-005 | TASK-017, TASK-018 | TEST-005 | IN_PROGRESS |
| TASK-020 | 2 | Items, units (piece/litre/kit), bulk containers, kits, prices, min level (SCR-009) | REQ-028 | TASK-017 | TEST-028 | NOT_STARTED |
| TASK-021 | 2 | Purchases with stock movements and weighted average cost (SCR-010) | REQ-029 | TASK-020 | TEST-029 | NOT_STARTED |
| TASK-022 | 2 | Suppliers, supplier ledger and payments (Standard+) | REQ-030 | TASK-021 | TEST-030 | NOT_STARTED |
| TASK-023 | 2 | Approvals engine: requests, approve/reject, inbox web + staff app, Basic owner-only path | REQ-057, REQ-032, REQ-037, REQ-039, REQ-041 | TASK-017, TASK-018 | TEST-057 | NOT_STARTED |
| TASK-024 | 2 | Stock adjustment requests via approvals (SCR-011) | REQ-032 | TASK-020, TASK-023 | TEST-032 | NOT_STARTED |
| TASK-025 | 2 | Low-stock and negative-stock alerts | REQ-033, REQ-031 | TASK-020 | TEST-033 | NOT_STARTED |
| TASK-026 | 2 | Customers and vehicles: records, search, ownership change (SCR-008) | REQ-046 | TASK-010 | TEST-046 | NOT_STARTED |
| TASK-027 | 2 | Excel templates and import with row-level rejection report (SCR-020) | REQ-034 | TASK-020, TASK-026 | TEST-034 (1,000-row file) | NOT_STARTED |
| TASK-028 | 2 | Vehicle service history timeline | REQ-048 | TASK-026 | TEST-048 | NOT_STARTED |
| TASK-029 | 3 | Job card intake from booking or walk-in, odometer check (SCR-005, SCR-006) | REQ-018 | TASK-026 | TEST-018 | NOT_STARTED |
| TASK-030 | 3 | Station checklist configuration and use, add-to-estimate | REQ-019 | TASK-029 | TEST-019 | NOT_STARTED |
| TASK-031 | 3 | Estimate, customer/phone approval, extra-work re-approval | REQ-020, REQ-022 | TASK-029 | TEST-020, TEST-022 | NOT_STARTED |
| TASK-032 | 3 | Stages, mechanic assignment, quality check | REQ-021, REQ-024 | TASK-029 | TEST-021, TEST-024 | NOT_STARTED |
| TASK-033 | 3 | Parts on job cards incl. customer-supplied lines, stock movements | REQ-031 | TASK-020, TASK-029 | TEST-031 | NOT_STARTED |
| TASK-034 | 3 | Own sync engine: sync_pull (assigned jobs, items without prices), change queue, sync_apply with idempotency, conflict history + manager alert, SyncEngine interface for a later PowerSync swap | REQ-023 | TASK-007, TASK-032, TASK-033 | TEST-023 + sync test suite (ordering, duplicates, restarts, conflicts) | NOT_STARTED |
| TASK-035 | 3 | Staff app mechanic screens SCR-031 to SCR-033 with offline badge and 24 h warning | REQ-023, REQ-021 | TASK-034 | TEST-023 on device | NOT_STARTED |
| TASK-036 | 3 | Cancellation and rejected estimate (fee invoice completed with TASK-039) | REQ-025 | TASK-031 | TEST-025 | NOT_STARTED |
| TASK-037 | 3 | Rework jobs and warranty claims (incl. return to supplier) | REQ-026, REQ-027 | TASK-029, TASK-022 | TEST-026, TEST-027 | NOT_STARTED |
| TASK-038 | 4 | Labour/service list with warranty days | REQ-035 | TASK-017 | TEST-035 | NOT_STARTED |
| TASK-039 | 4 | Invoice from approved lines, sequential numbering, tax per category (SCR-007) | REQ-036 | TASK-031, TASK-038 | TEST-036, TEST-004 | NOT_STARTED |
| TASK-040 | 4 | Discount limit enforcement with approval/owner path | REQ-037 | TASK-023, TASK-039 | TEST-037 | NOT_STARTED |
| TASK-041 | 4 | Payments: methods, references, split, advance, change | REQ-038 | TASK-039 | TEST-038 | NOT_STARTED |
| TASK-042 | 4 | Handover rule, credit release, customer ledger and collections | REQ-039, REQ-040 | TASK-023, TASK-041 | TEST-039, TEST-040 | NOT_STARTED |
| TASK-043 | 4 | Refunds, credit notes, reversals with reason | REQ-041, REQ-042 | TASK-023, TASK-041 | TEST-041, TEST-042 | NOT_STARTED |
| TASK-044 | 4 | Storage-charge scheduler job and ready-vehicle reminders | REQ-043 | TASK-039 | TEST-043 | NOT_STARTED |
| TASK-045 | 4 | Daily cash closing and reopen (SCR-013) | REQ-044 | TASK-041 | TEST-044 | NOT_STARTED |
| TASK-046 | 4 | Invoice/estimate PDF, A4 web print, Bluetooth receipt, share (SCR-036) | REQ-045 | TASK-009, TASK-039 | TEST-045 | NOT_STARTED |
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
