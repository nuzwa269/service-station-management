# Technical Architecture — Car Service Station Management SaaS

> State: APPROVED (frozen) | Version: 1.0 (approved from draft v0.2) | Date: 2026-11-13 | Approval: GRANTED by user "ہاں، منظور ہے" (2026-11-13) | Source: Approved PRD v1.1 (62 REQs, REQ-011 deprecated), Concept Brief v1.2, `DECISIONS.md` up to DEC-032 and CR-002
> Owner: platform owner's in-house team (A13-Q7). Nothing here has been built or tested. Facts marked **[web 2026-11-12]** were checked against public sources on that date (see the source list at the end); everything else marked **VERIFY** needs a check in Phase 0.

## 1. Architecture drivers and constraints (REQ references)
| Driver | Requirement | Architectural consequence |
|---|---|---|
| User-required stack: Flutter + Dart mobile, Supabase backend | DEC-002, DEC-003 | Evaluated in §2; kept |
| Strict station isolation, customer sees only linked stations, super admin blind without grant | REQ-003, REQ-005, REQ-047 | Shared database, a `station_id` column on every tenant table, row-level security enforced in the database (§6) |
| Mechanic offline for 24 h incl. stock use; last write wins + history + manager alert | REQ-023, REQ-031 | Local SQLite on the staff app with our own sync queue at launch; PowerSync in a later version (DEC-031); server-side apply functions write history (§4.3) |
| Money and stock must never be silently changed | REQ-036…REQ-044, REQ-042, REQ-058 | Append-only ledgers for stock, payments and dues; reversals instead of deletes; audit triggers |
| Plan gating, grace, read-only | REQ-006…REQ-010 | Station entitlements stored in the database and checked inside security policies and write functions, not only in the UI |
| Android 8+, 2 GB RAM, direct APK, Bluetooth printer, barcode scan | A11.4-Q1/Q2/Q5, REQ-045 | Flutter Android apps (Flutter minimum is API 21, Android 8 = API 26 [web 2026-11-12]); self-hosted APK + in-app update prompt |
| Push + WhatsApp from the station's own account or sent manually; no SMS for customers; no quota | REQ-055, REQ-061, REQ-062, CR-002 | Platform joins Meta's Tech Provider programme; stations connect via Embedded Signup and Meta bills them [web 2026-11-13]; message outbox per station; `wa.me` prefilled links for manual sending |
| Subscription payments: JazzCash, Easypaisa, card, bank, cash | REQ-008 | Payment aggregator behind an interface; manual verification path for bank/cash |
| Pakistan users | A13-Q1 | Hosting region Mumbai (`ap-south-1`) is offered by Supabase [web 2026-11-12] |
| Backups | DEC-024, DEC-029 | Daily Supabase backups (7-day retention, included) + weekly off-site copy (§8) |
| Scheduled rules (no-show, grace, reminders, deletion) | REQ-009, REQ-013, REQ-017, REQ-043, REQ-049 | Database scheduler jobs plus server functions |

## 2. Stack options and comparison
| Layer | Option A | Option B | Recommendation and rationale |
|---|---|---|---|
| Mobile apps (Staff, Customer) | **Flutter + Dart** (user-required) | Kotlin native | **A.** Meets every mobile requirement: Bluetooth ESC/POS printing, barcode scanning, push and local SQLite all have mature Flutter plugins (versions VERIFY). One codebase serves the later iOS apps. |
| Web dashboard + super admin | **Flutter web** (same language, shared Dart packages) | React/Next.js | **A, with trade-off.** One team, one language: models, validation, money rules and API client are shared with the apps. It is a logged-in dashboard, so SEO doesn't matter. Downsides: larger first load (~2–4 MB, VERIFY) and weaker browser-native tables/printing. Mitigation: A4 invoices are generated as PDF, and heavy tables are paged. Choose B only if the team already knows React well. |
| Backend platform | **Supabase** (Postgres, Auth, Storage, Edge Functions, scheduler) (user-required) | Firebase | **A.** Relational data with money and stock fits Postgres. Row-level security gives database-level tenant isolation. Transactions in SQL functions keep invoices and stock consistent. |
| Offline sync (staff app only) | PowerSync (Supabase partner, about $49/month on Pro [web 2026-11-12]) | **Own sync: local SQLite + change queue + server apply functions** | **B at launch (your decision DEC-031)**: no monthly fee, about 3–5 extra weeks of work (ASSUMED). Built behind a `SyncEngine` interface with the same server functions, so PowerSync can replace it in a later version. The customer app is online-only. |
| Push | **Firebase Cloud Messaging** | OneSignal | **A.** Works for APK-installed apps on phones with Google Play services (most Android phones in Pakistan; VERIFY on target devices). |
| WhatsApp | **Meta Cloud API with Embedded Signup; platform as Meta Tech Provider** (each station owns its account and pays Meta) | BSP-managed accounts billed to the platform | **A (CR-002).** Stations connect their own number and add their own payment method in Meta; the platform pays nothing per message [web 2026-11-13]. Manual `wa.me` prefilled links cover Basic and unconnected stations. Tech Provider onboarding requirements to VERIFY (TASK-004). |
| SMS (login codes only) | Pakistani SMS aggregator with HTTP API | WhatsApp authentication template sent by the platform | **Local aggregator, OTP only** (no customer notifications by SMS, CR-002). Cost is small: one SMS per login/sign-up. VERIFY vendor in TASK-005. |
| Subscription payments | **Pakistani payment aggregator** (one API for JazzCash, Easypaisa, cards) | Direct JazzCash + Easypaisa merchant APIs | **Aggregator** (one integration, one webhook). Merchant onboarding time is outside our control [web 2026-11-12]. Bank/cash stay manual (REQ-008). Vendor chosen in TASK-006. |
| Web hosting | Static hosting with CDN (e.g. Cloudflare Pages) | Supabase Storage as static site | **A** (free tier, CDN). VERIFY in TASK-003. |
| Crash/error reporting | Sentry (Flutter + Edge Functions) | Firebase Crashlytics | **A** (one tool for web + mobile + server). PROPOSED. |

## 3. Chosen stack and verification status
| Component | Choice | Status |
|---|---|---|
| Staff app, Customer app (Android 8+) | Flutter/Dart, separate app builds from one repository | User-required; suitable |
| Web dashboard + super admin | Flutter web, one app with role-based routes; super admin on a separate subdomain | APPROVED by you (DEC-030) |
| Backend | Supabase Pro, region Mumbai `ap-south-1` | User-required; region APPROVED (DEC-032) |
| Offline sync | Own sync engine at launch; PowerSync later | Your decision (DEC-031) |
| Push / WhatsApp / SMS / payments | FCM / Meta Cloud API + Embedded Signup / local SMS aggregator (OTP only) / payment aggregator | Vendors to verify in Phase 0 |
| Versions | Latest stable Flutter, Dart, Supabase CLI and SQLite plugin at the start of Phase 0 | VERIFY — no version numbers are fixed here on purpose |

## 4. System context (editable Mermaid)
```mermaid
flowchart LR
  subgraph Clients
    SA[Staff app<br/>Android, offline SQLite]
    CA[Customer app<br/>Android, online]
    WD[Web dashboard<br/>Flutter web]
    AD[Super admin<br/>Flutter web]
  end
  subgraph Supabase[Supabase - Mumbai]
    AUTH[Auth<br/>phone OTP / password]
    DB[(Postgres<br/>RLS, ledgers, audit)]
    FN[Edge Functions<br/>webhooks, messaging, exports]
    CRON[Scheduler jobs]
    ST[Storage<br/>logos, receipts, PDFs, APKs]
  end
  SY[Sync API<br/>apply + pull functions]
  FCM[Firebase Cloud Messaging]
  WA[WhatsApp Cloud API<br/>station's own account]
  SMS[SMS aggregator<br/>login codes only]
  PAY[Payment aggregator<br/>JazzCash, Easypaisa, cards]

  SA <--> SY <--> DB
  SA --> AUTH
  CA --> AUTH
  WD --> AUTH
  AD --> AUTH
  CA --> DB
  WD --> DB
  AD --> FN
  CRON --> FN
  FN --> DB
  FN --> FCM --> SA
  FCM --> CA
  FN --> WA
  AUTH --> SMS
  SA -. manual wa.me link .-> WAPP[WhatsApp on staff phone]
  WD -. manual wa.me link .-> WAPP
  WD -- start payment --> FN --> PAY
  PAY -- webhook --> FN
  SA --> ST
  WD --> ST
```

### 4.1 Component boundaries and interaction contracts
| Component | Responsibility | Talks to | Contract |
|---|---|---|---|
| Staff app | Mechanic job work (offline), approvals, quick dashboard, Bluetooth print, manual WhatsApp | Local SQLite + Sync API, Supabase RPC (online actions), FCM | Writes go through named server functions, e.g. `job_add_part`, `job_set_stage`. Direct table writes are never allowed. |
| Customer app | Login, linked stations, booking, approvals, invoices | Supabase RPC + read views, FCM | `customer_*` functions; reads limited to own records via RLS |
| Web dashboard | All station operations | Supabase RPC + views, Storage | `station_*` functions grouped per module |
| Super admin | Tenants, plans, payment verification, packs | Edge Functions with service role | `admin_*` functions; sees only `tenant_usage` views unless a support grant is active |
| Postgres functions (RPC) | **All business rules involving money, stock, stages, approvals and entitlements**, each inside one transaction | DB | Each checks: caller role, station entitlement (plan, read-only), validation, then writes ledgers + audit |
| Edge Functions | Things the database can't do alone: payment-provider webhooks, WhatsApp Embedded Signup callback and sending from each station's account, Excel/PDF exports, APK version check | DB, providers | Idempotent handlers keyed by provider event ID |
| Scheduler jobs | No-show marking (every 5 min), grace → read-only (hourly), reminders (daily 09:00 PKT), storage charges (daily), 90-day deletion (daily), message outbox retry (every minute) | DB, Edge Functions | Each job is safe to run twice |

### 4.2 Data flow — posting an invoice payment
1. Cashier taps "Record payment" → `station_record_payment(invoice_id, amount, method, reference)`.
2. Inside one transaction the function: checks the role and that the station is not read-only; checks that the amount ≤ due and that the day is not closed; inserts a row into `payments`; updates the invoice's paid status; writes an audit row.
3. If the invoice is now Paid and the event is enabled, it adds a row to `message_outbox`.
4. The outbox worker sends it from the station's connected WhatsApp account and records the result. If the station is not connected, or the send fails after one retry, the message goes to the manual "Messages to send" list (REQ-062).

### 4.3 Offline flow — mechanic adds a part (own sync engine, DEC-031)
1. **Download (pull):** when online, the staff app calls `sync_pull(since)` and gets changed rows. These are the jobs assigned to that mechanic and the station's item list (name, unit, stock only; prices and costs are never sent to mechanics, REQ-002). The rows are stored in local SQLite.
2. **Local write:** the mechanic adds a part, and the app writes it to SQLite and to a local `change_queue` with a `client_change_id` and `client_time`. The queue survives app restarts.
3. **Upload (push):** when online, the app sends queued changes in order to `sync_apply(changes[])`. Each change maps to the same server function used online (e.g. `job_add_part`). The server applies it idempotently: a repeated `client_change_id` is ignored. It inserts the stock movement (negative stock allowed, REQ-031), recalculates the job lines and writes history.
4. **Conflict rule (REQ-023):** for the same job field, the change with the later `client_time` wins. The losing value is kept in `job_history` and a `conflict` notification goes to managers. Changes rejected by rules (e.g. station read-only) stay in the queue marked "held" (REQ-009).
5. **Status:** the app shows Offline, the pending count, the last sync time and a warning after 24 h.
6. **Later swap to PowerSync:** the app talks to a `SyncEngine` interface, and the server functions stay the same, so PowerSync can replace steps 1 and 3 in a later version without changing business rules.

## 5. Data model / source of truth / migrations / backups
Business-level entities. Exact columns are written in Phase 1 migrations.

| Area | Main tables | Notes |
|---|---|---|
| Platform | `stations`, `plans`, `plan_features`, `subscriptions`, `subscription_payments`, `station_whatsapp_accounts`, `support_grants` | Station entitlement view `station_entitlements` (plan, features, status Trial/Active/Grace/ReadOnly/Suspended/Closed, WhatsApp connected) |
| People | `profiles` (auth user → person), `station_members` (user, station, role, active), `customers` (per station), `customer_accounts` (one per phone, platform-wide), `customer_station_links` | A customer app account links to per-station `customers` rows by verified phone or station code (REQ-047) |
| Vehicles & bookings | `vehicles`, `booking_settings`, `bays`, `bookings`, `no_show_counters` | Capacity check plus row locking prevents double booking (REQ-015) |
| Jobs | `job_cards`, `job_checklist_items`, `job_lines` (part/labour/storage/fee, approval state), `job_approvals`, `job_assignments`, `job_history`, `rework_links`, `warranty_claims` | Stage changes go only through functions |
| Inventory | `items`, `kit_components`, `suppliers`, `purchases`, `purchase_lines`, **`stock_movements`** (append-only), `stock_adjustment_requests` | Stock on hand = sum of movements. Average cost is updated on each purchase (DEC-027) |
| Billing | `services` (labour list), `invoices`, `invoice_lines`, **`payments`** (append-only, reversals as linked rows), `credit_notes`, **`customer_ledger`**, **`supplier_ledger`**, `day_closings` | Sequential numbers per station from a counter table locked inside the transaction |
| Staff | `staff`, `attendance`, `advances`, `payroll_runs`, `payroll_lines` | Payroll lines are frozen when finalised |
| Control | `approval_requests`, **`audit_log`** (append-only, written by triggers), `notifications`, `message_outbox`, `message_log` | `audit_log` has no update/delete rights for anyone |

- **Source of truth:** Postgres. The staff app's SQLite is a cache plus a queue, never the master copy.
- **Money:** stored as whole rupees, or paisa integers if decimals are ever needed (PROPOSED: integer paisa internally, shown as whole rupees on invoices per DEC-027). Never floating-point.
- **Quantities:** fixed decimals (3 places) to cover litres with 2 decimals plus rounding headroom.
- **Migrations:** SQL migration files in the repository, applied by the Supabase CLI. Every policy and function has tests (§10).
- **Backups:** see §8.

## 6. Security: identity, authorization, secrets, privacy and threat model
- **Identity:**
  - Station users log in with mobile + password, and the mobile is verified once by one-time code at sign-up.
  - Customers log in with mobile + one-time code (REQ-047). Codes are sent by the SMS aggregator through Supabase Auth's custom SMS hook (VERIFY hook support, TASK-005).
  - The super admin uses email + password + an authenticator-app second factor (PROPOSED).
- **Authorization layers:**
  1. **Row-level security on every tenant table:** a row is visible only if `station_id` is one of the caller's active memberships, or, for customers, a linked station with the record belonging to their linked customer row.
  2. **Write functions** check role permissions from the PRD §3 matrix, plan features and read-only status.
  3. **Column protection:** purchase cost and profit sit in owner-only views, and mechanics' synced tables exclude prices.
  4. **Super admin:** no RLS bypass from clients. Support access uses a time-limited `support_grants` row that the policies check, and the session is read-only.
- **Secrets:**
  - Provider keys (WhatsApp, SMS, payments, FCM server key) and the Supabase service role live only in Edge Function secrets, never in apps.
  - Apps contain only the public Supabase URL and anon key, which is safe because RLS enforces access.
  - The APK signing keystore is kept offline with two backups (TASK-071).
- **Threat model (main items):**
  | Threat | Mitigation |
  |---|---|
  | Station A reads station B data through a crafted request | RLS on all tables + automated isolation tests (TEST-003) for every table |
  | Cashier gives an unapproved discount via the API | Discount rule enforced in `station_create_invoice`, not only in the UI |
  | Rooted phone edits local SQLite | Local data is only a cache; the server re-validates every uploaded change |
  | Fake payment webhook activates a plan | Verify provider signature, re-query payment status from the provider, idempotency by provider transaction ID |
  | OTP abuse / SMS cost attack | Rate limit per phone and IP (5 per hour, PROPOSED), CAPTCHA-free throttling, daily OTP budget alarm |
  | Tampered APK | Signed releases; downloads only from our domain over HTTPS; the update check compares the signing certificate (VERIFY feasibility) |
  | Insider deletes history | Append-only ledgers and audit; no delete grants; owner sees audit log |
- **Privacy:** personal data is limited to name, phone, optional email/address and vehicles. Exit deletion after 90 days (REQ-013) is done by a scheduler job that deletes all station rows and storage files and writes a deletion record.

## 7. Third-party services and provider abstraction
All providers sit behind small interfaces in Edge Functions, so a vendor can be swapped without app changes:
- `MessageProvider.send(channel, to, template, params)` → WhatsApp first, SMS fallback (REQ-055). Each attempt is logged with the cost unit.
- `PaymentProvider.createCheckout(plan, cycle, method)` / `verifyWebhook(event)`.
- `PushProvider.send(user_ids, payload)` (FCM).
- `OtpSender` (SMS aggregator through the Auth hook).

**WhatsApp model (CR-002, 2026-11-13):**
- **Automatic (Standard, Premium):** the platform registers as a Meta Tech Provider. A station owner connects through Meta's Embedded Signup inside the dashboard. The station keeps ownership of its WhatsApp Business account and must add its own payment method, and Meta bills the station for its messages [web 2026-11-13]. The platform stores the station's account and phone IDs and access token in Edge Function storage (never in apps), creates the standard English templates on that account, and sends event messages from it.
- **Manual (all plans):** for stations that aren't connected, the app builds a `https://wa.me/<number>?text=<prefilled>` link that opens WhatsApp on the staff phone or WhatsApp Web, and staff press Send. No cost, no Meta account needed.
- **No SMS for customer events and no platform message quota.** The earlier cost concern (DEC-028) no longer applies to the platform. SMS remains only for login codes (§6).

## 8. Errors, retries, fallbacks, observability, backups
- **Client errors:** readable messages per the PRD (§6 common states). Write functions return error codes (`READ_ONLY`, `NEEDS_APPROVAL`, `FORBIDDEN`, `VALIDATION:<field>`, `SLOT_FULL`) that the apps translate into the PRD wording.
- **Idempotency:** every client write carries a `client_change_id`. Webhooks are keyed by provider event ID.
- **Retries:** the message outbox retries once after 5 minutes, then moves the message to the manual list (REQ-055, REQ-062). Payment webhooks are retried by the provider, and a reconcile job re-queries pending payments hourly.
- **Offline:** the staff app keeps its queue across app restarts. After 24 h it shows a warning (REQ-023).
- **Observability:** Sentry for apps and functions. Supabase logs. A daily summary job for the super admin (stations with WhatsApp payment problems, failed payments, sync errors). Uptime monitor on the API and web (PROPOSED).
- **Backups (APPROVED, DEC-029):**
  - Supabase Pro takes **daily backups kept for 7 days** at no extra charge [web 2026-11-12]. You chose daily backups plus a weekly separate copy (worst-case loss of 1 day).
  - Add a **weekly off-site export** (database dump + storage files) to a separate storage account, kept for 8 weeks.
  - Point-in-time recovery is a paid add-on (about US$100/month for 7 days, third-party figure, VERIFY) and is not proposed at launch.
  - Restore drill once per quarter (TASK-073).

## 9. Performance, accessibility, localization and device support
- **Targets (PRD §14):** common screens < 3 s on 4G; invoice print < 5 s; sync visible within 1 min; 99.5% monthly availability; 1,000 stations × 50 concurrent users.
- **Means:**
  - Indexes on `(station_id, …)` for every list.
  - Paged lists of 50 rows.
  - Report queries run as SQL functions over date ranges.
  - Heavy exports run in Edge Functions and the file is delivered when ready.
  - Compute sized Small at launch, scaling up with load (VERIFY cost).
- **Devices:** Android 8 (API 26) minimum, set as `minSdk 26` in both apps. This is above Flutter's minimum of API 21 [web 2026-11-12], and some plugins now require API 24, which still works with Android 8. Test fleet: one 2 GB Android 8 phone, one mid-range Android 13+, 58 mm and 80 mm Bluetooth printers (TASK-070).
- **Localization:** English only. Dates DD/MM/YYYY, Rs grouping, phone 03XX-XXXXXXX, all in one shared Dart formatting package. Strings are kept in resource files from day one so Urdu can be added later without a rewrite.
- **Accessibility:** 48 dp touch targets, 4.5:1 contrast, stage chips with text (PRD §13).

## 10. Deployment environments and recovery
| Environment | Backend | Web | Apps | Purpose |
|---|---|---|---|---|
| Local | Supabase CLI local stack | `flutter run -d chrome` | emulator/device | development, migration tests |
| Staging | Separate Supabase project (Mumbai) | staging subdomain | APK flavour "staging" | QA, pilot station |
| Production | Supabase Pro project (Mumbai) | main domain | APK flavour "prod" | live |

- **CI** (e.g. GitHub Actions, PROPOSED): lint, unit tests, database tests (policies and functions), build web + both APKs on every pull request. Deploy to staging on merge. Deploy to production on a tagged release with manual approval.
- **APK release:** signed APK uploaded to Storage plus a version manifest. The apps check the manifest at start and show "Update available", or force the update when the server's minimum version rises. Users must allow "install unknown apps" once, and the app shows a guide with screenshots.
- **Rollback:**
  - Web: redeploy the previous build.
  - Database: forward-fix migrations only, plus restore from backup for data disasters.
  - APK: publish the previous version with a higher version code if needed.

## 11. Architecture decisions (DEC identifiers)
| DEC | Decision | Status |
|---|---|---|
| DEC-002 | Flutter + Dart for mobile — evaluated suitable | CONFIRMED (user) → validated |
| DEC-003 | Supabase backend — evaluated suitable | CONFIRMED (user) → validated |
| DEC-028 | WhatsApp cost: stations connect their own account (Meta bills them) or send manually; no SMS for customers; no quota (CR-002) | APPROVED by you |
| DEC-029 | Backups: daily (included) + weekly off-site export | APPROVED by you |
| DEC-030 | Flutter web for the dashboard and super admin | APPROVED by you |
| DEC-031 | Offline at launch with our own sync engine; PowerSync in a later version | APPROVED by you |
| DEC-032 | Hosting region Mumbai `ap-south-1` | APPROVED by you |
| DEC-033 | Shared database + `station_id` + RLS for multi-tenancy; business rules in database functions | PROPOSED (part of architecture approval) |
| DEC-034 | Vendors for SMS (OTP) and payments chosen in Phase 0 after verification; Meta Tech Provider registration started in Phase 0 | PROPOSED |

## 12. Key risks / unknowns / official-source verification needed
| # | Risk / unknown | Impact | Verification task |
|---|---|---|---|
| R1 | Stations may find Meta sign-up and adding a payment method hard | Few stations use automatic WhatsApp; manual sending still works | Step-by-step guide and video; support helps during onboarding |
| R2 | Meta Tech Provider approval and template approval delays | Automatic WhatsApp not ready at launch; manual sending covers it | TASK-004 starts in week 1 |
| R3 | Payment aggregator merchant approval time | Online subscription payment late; bank/cash manual path still works | TASK-006 |
| R4 | SMS OTP cost and Supabase custom SMS hook with a local provider | Login cost / feasibility | TASK-005 (OTP is the only SMS use) |
| R5 | Own sync engine correctness (ordering, duplicates, conflicts) on 2 GB Android 8 phones | Offline requirement, extra build time | TASK-007 spike + dedicated sync test suite (TASK-034) |
| R6 | Direct-APK installs and updates (customer hesitation, manual updates) | Adoption | Install guide, in-app updater, pilot feedback |
| R7 | Flutter web load time on slow connections | Web usability | TASK-008 measures the first-load size |
| R8 | Single in-house team, ~60 REQs | Schedule | Phased plan; pilot with 2–3 stations before public launch |
| R9 | Exact current pricing of Supabase compute, SMS (OTP), payment aggregator; Meta Tech Provider requirements | Running cost | TASK-002…006, recorded in `IMPLEMENTATION_PLAN.md` §Costs |

### Sources checked on 2026-11-12
- Flutter Android support floor: https://docs.flutter.dev/release/breaking-changes/android-kitkat-deprecation
- Supabase backups: https://supabase.com/docs/guides/platform/backups
- Supabase regions: https://supabase.com/docs/guides/platform/regions
- Supabase pricing: https://supabase.com/pricing
- PowerSync with Supabase: https://docs.powersync.com/integration-guides/supabase-+-powersync ; pricing: https://powersync.com/pricing
- WhatsApp Embedded Signup / Tech Provider billing (checked 2026-11-13): https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/overview/
- WhatsApp pricing: https://developers.facebook.com/docs/whatsapp/pricing ; third-party rate summaries: https://support.wati.io/en/articles/11561662-message-based-pricing-all-you-need-to-know , https://chakrahq.com/article/whatsapp-api-pricing-guide/
- JazzCash/Easypaisa integration landscape (vendor sources only): https://simpaisa-website.pages.dev/blogs/how-to-accept-jazzcash-payments-on-your-website-step-by-step-2026
