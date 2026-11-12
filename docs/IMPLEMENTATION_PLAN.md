# Implementation Plan — Car Service Station Management SaaS

> State: APPROVED (frozen) | Version: 1.0 (approved from draft v0.2) | Date: 2026-11-13 | Approval: GRANTED by user "ہاں، منظور ہے" (2026-11-13) | Sources: Approved PRD v1.1 (CR-002) + ARCHITECTURE.md v0.2 (DRAFT) + TASKS.md v0.2
> This is a plan only. No code has been written, no test has been run, and no service account has been created.

## Technology decision summary
- **Apps:** Flutter + Dart for the Android Staff app and Customer app (user-required), with `minSdk 26` (Android 8).
- **Web:** Flutter web for the station dashboard and the super admin area (DEC-030, approved).
- **Backend:** Supabase Pro in Mumbai (DEC-032, approved). Postgres with row-level security per station. Business rules live in SQL functions, and Edge Functions handle webhooks, messaging and exports.
- **Offline:** our own sync engine for the staff app at launch, PowerSync in a later version (DEC-031, approved).
- **Providers** (vendors chosen in Phase 0): FCM for push; WhatsApp Cloud API with Embedded Signup (platform as Meta Tech Provider, each station pays Meta, CR-002) plus manual `wa.me` links; a local SMS aggregator for login codes only; a payment aggregator for JazzCash/Easypaisa/cards.

## Implementation principles and guardrails
1. **The PRD is the contract.** Each pull request names its `TASK-###` and `REQ-###`. Scope changes need a change request in `DECISIONS.md`.
2. **Rules live on the server.** Every money, stock, stage, approval or entitlement rule is enforced in a database function, and the UI only mirrors it.
3. **Append-only for money and stock.** Corrections are made by reversal (REQ-042), and no client gets delete rights on ledgers or the audit log.
4. **Isolation tests are mandatory.** Every new table ships with a policy and an isolation test (TASK-011) in the same pull request.
5. **Provider calls stay behind interfaces.** No provider key ever goes into an app.
6. **Phase 0 comes first.** Its verification tasks must finish before the dependent phases start. Results that change cost or scope go back to you as decisions.
7. **Status follows evidence.** No task is marked DONE without evidence: merged code plus passing tests named in `TASKS.md`.

## Phase 0 — Setup and verification (TASK-001…TASK-009)
- **Requirements:** REQ-003, 008, 011, 023, 028, 031, 045, 047, 055, 060 (spikes only)
- **Dependencies:** your approval of this plan
- **Files/components:** repository skeleton, CI config, `supabase/` project config, spike apps in `spikes/` (deleted after use)
- **Outputs:**
  - Cost table filled with verified prices
  - Vendor choices (SMS for OTP, payments, hosting)
  - Spike reports (own sync engine on Android 8 / 2 GB, Flutter web load, printer/scanner)
  - Meta Tech Provider registration started
- **Tests:** CI green on the empty repository; each spike's pass/fail criteria in `TASKS.md`
- **Definition of done:** every Phase 0 task has a written result, and any result that changes cost or scope is brought back to you

## Phase 1 — Foundation: tenancy, roles, entitlements, audit (TASK-010…TASK-019)
- **Requirements:** REQ-001…006, REQ-058 (plus format helpers for REQ-018/036/046)
- **Dependencies:** Phase 0 (TASK-002, TASK-005)
- **Components:** database migrations (stations, members, roles, plans, entitlements, audit triggers); `packages/core`; app shells; sign-up and onboarding
- **Tests:**
  - Database policy tests
  - TEST-001…006 and TEST-058
  - Isolation suite TEST-003 runs in CI on every pull request from now on
- **Definition of done:** a station can sign up on staging, invite users per role and see only its own data, and plan gating blocks a locked feature

## Phase 2 — Inventory, approvals engine, customers (TASK-020…TASK-028)
- **Requirements:** REQ-028…034, REQ-046, REQ-048, REQ-057 (approvals engine is reused later)
- **Tests:** TEST-028…034, TEST-046, TEST-048, TEST-057, including the 1,000-row import file
- **Definition of done:** an owner can import parts, record a supplier purchase (average cost correct), get a low-stock alert and approve a stock adjustment

## Phase 3 — Job cards and staff app with offline (TASK-029…TASK-037)
- **Requirements:** REQ-018…027, REQ-031
- **Tests:**
  - TEST-018…027 and TEST-031
  - Offline test on a real Android 8 / 2 GB phone: 24 h offline, two-phone conflict
- **Definition of done:**
  - A mechanic completes a job offline, and after sync stock and history are correct
  - Conflicts reach the manager
  - Estimate approval and extra-work re-approval block work until approved

## Phase 4 — Billing and payments (TASK-038…TASK-046)
- **Requirements:** REQ-035…045 (and the invoice part of REQ-025)
- **Tests:**
  - TEST-035…045 and TEST-025
  - Money-rule unit tests: tax rounding, discount limit, split payments, credit allocation oldest-first, storage charge days
- **Definition of done:**
  - J1/J2/J4 journeys work on the web up to delivery
  - Day closing balances
  - A Bluetooth receipt prints on 58 and 80 mm printers
- **Milestone M1 — internal alpha (Basic-plan feature set complete).**

## Phase 5 — Subscription and super admin (TASK-047…TASK-052)
- **Requirements:** REQ-007…010, REQ-012, REQ-013
- **Tests:**
  - TEST-007…010, TEST-012, TEST-013, TEST-104
  - Webhook signature and idempotency tests
- **Definition of done:**
  - The trial → grace → read-only → payment → active cycle works on staging with sandbox payments and manual bank verification
  - Deletion after 90 days runs on a test tenant with a shortened clock

## Phase 6 — Booking and customer app (TASK-053…TASK-059)
- **Requirements:** REQ-014…017, REQ-047, REQ-049, plus the customer-side parts of REQ-020/022/048
- **Tests:**
  - TEST-014…017, TEST-047, TEST-049
  - Concurrency test: two customers booking the last free bay
- **Definition of done:** a customer logs in by OTP, sees only linked stations, books, approves an estimate in the app and views the invoice

## Phase 7 — Notifications and WhatsApp (TASK-060…TASK-062)
- **Requirements:** REQ-055, REQ-056, REQ-061, REQ-062
- **Tests:**
  - TEST-055, TEST-056, TEST-061, TEST-062
  - Connected / not connected / payment-problem / disconnected states
- **Definition of done:**
  - A connected Standard station sends every PRD event automatically from its own number
  - Basic and unconnected stations get a working "Messages to send" list with prefilled WhatsApp links
  - Failed automatic sends move to the manual list
- **Milestone M2 — feature-complete beta (Standard-plan feature set).**

## Phase 8 — Reports, dashboard, staff and payroll (TASK-063…TASK-067)
- **Requirements:** REQ-050…054, REQ-059, REQ-060
- **Tests:** TEST-050…054, TEST-059, TEST-060, TEST-105 (payroll example from PRD)
- **Definition of done:** all PRD reports match hand-calculated fixtures, and March payroll from the PRD example gives Rs 28,000

## Phase 9 — Hardening, pilot and release (TASK-068…TASK-075)
- **Requirements:** cross-cutting NFRs (PRD §14), REQ-003, REQ-005, REQ-008, REQ-013, REQ-045
- **Tests:** security review; load test; E2E TEST-101…105; device test TEST-201; restore drill
- **Definition of done:**
  - Pilot with 2–3 real stations for at least 4 weeks (PROPOSED) with owner sign-off
  - No open High security findings
  - Restore drill passed
- **Milestone M3 — public launch (Premium-plan feature set, all 60 REQs).**

## Functional traceability and testing strategy
Full mapping `REQ → TASK → TEST` is in `TRACEABILITY_MATRIX.csv`. All 61 active REQs (REQ-011 deprecated by CR-002) have at least one task and one acceptance test. Summary by phase:

| REQ | Task(s) | Test ID(s) | Release phase |
|---|---|---|---|
| REQ-001…006, 058 | TASK-010…019 | TEST-001…006, 058 | Phase 1 / M1 |
| REQ-028…034, 046, 048, 057 | TASK-020…028 | TEST-028…034, 046, 048, 057 | Phase 2 / M1 |
| REQ-018…027, 031 | TASK-029…037 | TEST-018…027, 031 | Phase 3 / M1 |
| REQ-035…045 | TASK-038…046 | TEST-035…045 | Phase 4 / M1 |
| REQ-007…010, 012, 013 | TASK-047…052 | TEST-007…010, 012, 013, 104 | Phase 5 / M2 |
| REQ-014…017, 047, 049 | TASK-053…059 | TEST-014…017, 047, 049 | Phase 6 / M2 |
| REQ-055, 056, 061, 062 | TASK-060…062 | TEST-055, 056, 061, 062 | Phase 7 / M2 |
| REQ-050…054, 059, 060 | TASK-063…067 | TEST-050…054, 059, 060, 105 | Phase 8 / M3 |
| Cross-cutting | TASK-068…075 | TEST-101…105, 201 | Phase 9 / M3 |

**Test levels:**
| Level | What | Where | Gate |
|---|---|---|---|
| Unit | Dart money/format rules, payroll and tax formulas | `packages/core` tests | every pull request |
| Database | RLS policies, isolation suite, SQL functions (ledgers, numbering, reversals, entitlements) | local Supabase stack in CI | every pull request |
| Widget | Key screens: empty/loading/error/read-only/locked states | each app | every pull request |
| Integration | App ↔ staging backend: sign-up, job flow, payment, sync | staging | merge to main |
| End-to-end | TEST-101…105 scripted journeys | staging | before each milestone |
| Device | TEST-201 on Android 8 / 2 GB + Android 13+, printers, scanner | test fleet | before M1, M2, M3 |
| Security | Threat-model checks (ARCHITECTURE §6), webhook forgery, OTP abuse | staging | before M3 |
| Performance | 3 s screens, 1,000 stations × 50 users | staging-size copy | before M3 |

## Security review and QA gates
- **Pull request gate:** lint, unit, database and isolation tests green, plus one reviewer. Migrations without policies are rejected.
- **Milestone gate:** E2E and device tests pass, there are no open High defects, and the PRD acceptance tests for that milestone's REQs pass.
- **Launch gate:**
  - Security review report done
  - Keystore custody done: 2 offline copies plus a documented owner
  - Restore drill passed
  - Meta Tech Provider status and standard templates approved
  - Payment aggregator live credentials in place
  - Pilot sign-off obtained

## Environment, deployment, release signing, monitoring and rollback
- **Environments:** local / staging / production (ARCHITECTURE §10).
- **Deploys:** CI deploys database migrations and Edge Functions to staging on merge. Production deploys on a tagged release, with manual approval.
- **APK releases:**
  - Signed with the production keystore; version code always increases
  - Uploaded with a manifest
  - Apps prompt for updates, and a forced update applies when the minimum version rises
- **Monitoring:** Sentry for apps and functions, uptime checks, and a daily super-admin health summary (failed messages, failed payments, sync errors).
- **Rollback:**
  - Web: previous build.
  - Functions: previous version.
  - Database: forward fix migrations, and backup restore only for data loss.
  - APK: re-release the previous code with a higher version code.

## Milestones and release acceptance criteria
| Milestone | Content | Acceptance |
|---|---|---|
| M0 | Phase 0 done | Verified cost table, vendors chosen, spikes pass, DEC-028…032 decided |
| M1 internal alpha | Phases 1–4 | Basic-plan journeys (J2, J3, J4) pass on staging and on the device fleet |
| M2 beta | Phases 5–7 | Subscription cycle, booking, customer app, WhatsApp (automatic + manual) pass; J1, J5 pass |
| M3 launch | Phases 8–9 | All 61 active REQs' acceptance tests and TEST-101…105, 201 pass; pilot sign-off |

**Schedule (ASSUMED):** your team size is not known. As an assumption, for 2 full-time Flutter/Supabase developers plus part-time QA: Phase 0 about 2 weeks, Phases 1–4 about 16 weeks (including 3–5 weeks for our own offline sync, DEC-031), Phases 5–7 about 7 weeks, Phases 8–9 about 7 weeks plus a 4-week pilot. That is roughly **9 months to public launch**. Please give your team size so this can be re-estimated.

## Risks, assumptions and cost drivers
**Monthly running cost at launch: ASSUMED estimates to be verified in Phase 0** (prices from public pages and third-party summaries on 2026-11-12/13; US$1 = PKR 280 assumed)
| Item | Estimate (US$/month) | Basis |
|---|---|---|
| Supabase Pro organisation | 25 | supabase.com/pricing [web] |
| Production compute (Small) | ~15 | VERIFY (third-party figures vary) |
| Staging project compute (Micro) | ~0–10 | $10 compute credit may cover one Micro [web] |
| PowerSync | 0 at launch | not used until a later version (DEC-031); about 49 then |
| Web hosting, Sentry, uptime | 0 at launch | free tiers (VERIFY limits) |
| **Fixed total** | **≈ 40–50 (≈ PKR 11,000–14,000)** | about 3 Standard subscriptions to break even on fixed costs |
| WhatsApp messages | 0 for the platform | each connected station pays Meta directly (CR-002) |
| SMS (login codes only) | VERIFY, small | one SMS per sign-up/login; local aggregator quote (TASK-005) |
| Payment aggregator fee | VERIFY (% per transaction) | TASK-006 |
| Optional: point-in-time recovery | ~100 | not proposed at launch |

**Top risks:** see ARCHITECTURE §12. The most important are R5 (correctness of our own offline sync) and R2 (Meta Tech Provider approval; manual WhatsApp covers the gap).

**Assumptions:** team size and schedule; PKR/US$ rate; that most target phones have Google Play services (needed for push); that payment-aggregator and Meta Tech Provider approvals come within Phase 0–2.

**Architecture decisions:** DEC-028…DEC-032 decided by you on 2026-11-13. **Still open:** team size (for the schedule).

## Approval
- Status: APPROVED 2026-11-13 — user "ہاں، منظور ہے" (2026-11-13) — scope: ARCHITECTURE.md v1.0, IMPLEMENTATION_PLAN.md v1.0, TASKS.md v1.0. Changes need a change request in `DECISIONS.md`.
