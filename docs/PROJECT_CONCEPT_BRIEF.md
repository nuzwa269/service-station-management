# Project Concept Brief — Car Service Station Management SaaS

> State: APPROVED (frozen) | Version: 1.2 | Date: 2026-11-13 | Approval: v1.0 GRANTED 2026-11-12; v1.1 = + CR-001 (2026-11-12); v1.2 = + CR-002 WhatsApp model, supersedes CR-001 (2026-11-13). See `DECISIONS.md`.
> v0.2 redoes Stage 0 under skill v1.3.3 (A10–A13 packs). v0.1 is kept in `archive/v0.1/`.
> Status tags: `CONFIRMED` = user said or selected it · `ASSUMED` = user was asked and delegated ("you decide") · `PROPOSED` = AI idea, not asked · `OPEN` = asked, user will decide later.

## Vision and problem
- **One-line product idea:** A multi-tenant SaaS that lets independent car service stations in Pakistan run bookings, job cards, parts stock, billing, staff pay and customer history, with an Android staff app, an Android customer app and a web dashboard. — CONFIRMED (Round 1–2)
- **The problem and current alternatives:** Workshops run on paper job cards, registers and spreadsheets. Parts used on a car are not always billed, stock and supplier dues are hard to track, customers cannot see progress, and owners lack daily cash and staff performance figures. — PROPOSED (carried from v0.1; not separately confirmed)
- **Business/user outcome:** Every part and labour item used is billed, cash closes daily, owners see stock value, dues and staff performance, and customers can book and follow their vehicle. — PROPOSED

## Audience and roles
| Role | User need | Allowed capabilities | Source of confirmation |
| --- | --- | --- | --- |
| Platform Super Admin (product owner) | Run the SaaS business | Manage tenants, plans, trials, subscription payments (verify bank/cash payments), usage counts. **No access to tenant customers or bills** except support access granted by the station owner. | CONFIRMED (Round 1 roles; A11.3-Q7) |
| Station Owner | Control the business | Everything in the station: settings, prices, discount limit, approvals, profit, audit log, salaries, reports, data export | CONFIRMED (roles; A11.5-Q3, A11.5-Q4) |
| Station Manager | Run the floor | Job cards, bookings, assignment, quality check, attendance, approvals delegated by owner. Cannot see profit or audit log by default. | CONFIRMED (roles); exact Manager vs Owner permission split PROPOSED |
| Cashier / Service Advisor (staff) | Intake and billing | Create job cards, estimates, invoices, record payments; discount up to owner-set limit | CONFIRMED (roles "staff and mechanics"; A10 discount limit) |
| Mechanic / Technician | Do the work | See assigned jobs, checklist, status updates, record parts used — also offline | CONFIRMED (A11.4-Q6a, A11.4-Q3a) |
| Vehicle Owner / Customer | Book and follow service | Book a free slot, approve estimates and additions, track status, view invoices and history | CONFIRMED (roles; booking; A12-Q2) |

## Core user journeys
1. **Booking → intake:** Customer opens customer app → picks a station they are linked to, a service and a free slot (capacity set by owner) → slot auto-confirmed → reminder sent → car arrives and staff opens a job card from the booking. Walk-ins and phone bookings are entered by staff. — CONFIRMED
2. **Job card lifecycle:** Intake (odometer, fuel, checklist; no photos) → estimate sent to customer → customer approves in app (or staff records phone approval) → mechanic works, records parts used (works offline up to 1 day) → any extra work needs customer re-approval → manager quality check → Ready → payment → Delivered. — Stages ASSUMED (user delegated); re-approval CONFIRMED (A12-Q2)
3. **Billing and handover:** Invoice = parts (selling price) + labour (service list rate, editable) − discount (within limit, more needs approval) + optional sales tax → payment by cash / JazzCash / Easypaisa / bank transfer / card machine, split payments allowed → full payment normally required; partial / credit release only with owner/manager approval → invoice sent via app push and WhatsApp (CR-002). — CONFIRMED
4. **Stock in and out:** Owner/staff records supplier purchase with bill → stock rises, supplier due rises → parts consumed on job cards reduce stock → supplier payments reduce dues → low-stock alert when below minimum. — CONFIRMED
5. **Day and month end:** Cashier closes the day (expected vs counted cash by payment method) → owner sees monthly revenue, stock, dues, mechanic performance and payroll sheet. — CONFIRMED
6. **Station onboarding (SaaS):** Owner self-signs-up → 14-day full trial → imports customers/vehicles/parts from Excel or enters opening stock → picks a plan and pays → on non-payment 7-day grace then read-only. — CONFIRMED

## Modules and must-have features
| Module | Must-have behavior | Priority | Evidence |
| --- | --- | --- | --- |
| MOD-001 Tenant workspace, sign-up & access | Self sign-up, full data isolation per station, role-based access, station logo/name on documents, one branch per station at launch | Must-have | A11.3-Q1, A11.3-Q6, A11.5-Q1a |
| MOD-002 Subscription & platform admin | Three plans by features/modules (no message quota since CR-002), prices in DEC-025/026, 14-day trial, monthly billing with yearly discount, payment by wallet/bank/card/cash, grace & read-only, tenant exit export | Must-have | A11.3-Q2…Q8 |
| MOD-003 Booking & scheduling | Customer self-books free slots; owner sets bays, slot length, working hours, off-days; staff enters walk-ins; no-show blocking | Must-have | Round 2 modules; booking answers; A12-Q6 |
| MOD-004 Job cards & inspection checklist | Intake data, checklist (no photos), estimate & re-approval, mechanic assignment, status stages, offline mechanic work, rework and warranty links | Must-have | Round 2; A11.4-Q2/Q3; A12 |
| MOD-005 Parts, inventory & suppliers | Items by piece/litre/partial drum/kit, cost & selling price, supplier purchases & ledger, consumption on jobs, customer-supplied parts, stock adjustments with approval, low-stock alerts | Must-have | A10 inventory batch |
| MOD-006 Billing, payments & customer credit | Itemised invoice, labour service list, discount limit, optional sales tax with NTN/STRN, split payments, approved credit, refunds/credit notes, daily cash closing | Must-have | A10 billing batch; A12-Q4; A13-Q2/Q3 |
| MOD-007 Customer & vehicle history | One customer account across linked stations; vehicle history per station; next-service reminders | Must-have | Round 2 "booking + history"; customer account answer |
| MOD-008 Staff, attendance, payroll & commission | Daily attendance by manager, fixed monthly salary, commission as % of labour on paid invoices, advance deduction, mechanic performance report | Must-have | A11.5-Q7; payroll answer; commission answer |
| MOD-009 Notifications | App push plus WhatsApp for booking confirmed, estimate, extra-work approval, vehicle ready, invoice, dues, service reminder. WhatsApp either sent by staff from their phone (all plans) or automatically from the station's own connected WhatsApp Business account, billed to the station by Meta (Standard+). No SMS for customer messages | Must-have | A13-Q4a/b, CR-002 |
| MOD-010 Reports, approvals & audit log | Owner approvals (discount over limit, refund/cancel bill, stock adjustment, credit release), owner-only change history, daily/monthly reports, Excel export | Must-have | A11.5-Q3/Q4/Q5 |

## Core records, quantities and money flow
> Business facts only — no database fields (A10).

| Module | What one record is | Unit / quantity | Cost vs selling price | Comes in from | Goes out as | Controls & alerts | Reports needed | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MOD-005 Inventory | One spare part, oil/fluid or kit (barcode/QR scan supported) | Piece; litre; partial use from a drum; set/kit | Purchase price + selling price; selling price editable on job card within discount limit; profit visible to owner only | Supplier purchase with bill; opening stock (manual or Excel); customer-supplied part (labour-only billing, no stock) | Used on a job card; returned unused part on refund goes back to stock; warranty part can be recorded as returned to supplier | Minimum level + low-stock alert; manual stock adjustment needs owner/manager approval; offline usage deducts stock on sync, manager alerted if stock goes negative | Supplier ledger/dues; low stock; stock value on hand; profit per part / per job | CONFIRMED |
| MOD-006 Billing | One invoice per job card | Lines: parts, labour, discount, tax | Labour from fixed service list, editable per job | Job card; counter refunds as credit notes | Payment(s): cash, JazzCash, Easypaisa, bank transfer, card machine; split across methods; advance; approved credit | Discount above owner-set limit (default 5%) needs approval; credit release needs approval; bills never deleted, only reversed with reason | Daily cash closing; monthly revenue; customer dues | CONFIRMED |
| MOD-004 Job cards | One vehicle visit | Status stages; parts and labour lines | — | Booking or walk-in | Delivered, cancelled, or linked rework/warranty job | Extra work needs customer re-approval; offline conflicts: last change wins, kept in history, manager notified | Jobs per mechanic; rework count per mechanic | CONFIRMED (stage list ASSUMED) |
| MOD-003 Booking | One slot booking for one vehicle | Slots per bay | — | Customer app or staff entry | Arrived → job card; no-show; cancelled | Capacity by bays × slot length × hours; repeated no-shows block app booking (owner sets limit, default 3; manager can unblock) | No-show list | CONFIRMED (limit ASSUMED) |
| MOD-008 Staff pay | One staff member's month | Days present; labour amount on paid invoices | — | Attendance, paid invoices, advances | Monthly payroll sheet | Commission % per mechanic set by owner; counts only paid invoices; advances deducted | Payroll sheet; mechanic performance | CONFIRMED |
| MOD-002 Subscription | One station's plan period | Monthly or yearly | Basic 2,500 / Standard 5,000 / Premium 8,000 PKR per month; yearly = 10 months' price (DEC-025/026) | Trial start; payment (wallet/bank/card/cash) | Renewal; grace; read-only; exit | Bank/cash payments verified by super admin | Tenants, MRR, expiring trials | CONFIRMED |

## Archetype-specific requirements
- **SaaS pack (A11.3):**
  - [A11.3-Q1] Self sign-up by station owner — CONFIRMED
  - [A11.3-Q2a] Free trial: yes — CONFIRMED
  - [A11.3-Q2b] 14 days, all features — CONFIRMED
  - [A11.3-Q3] Plans differ by features/modules at launch (message quota of CR-001 removed by CR-002); branch-count tiers later when multi-branch arrives — CONFIRMED
  - [A11.3-Q4a] Monthly billing; yearly = 2 months free — CONFIRMED (DEC-026)
  - [A11.3-Q4b] PKR; stations pay via JazzCash/Easypaisa, bank transfer, debit/credit card, cash (manual activation) — CONFIRMED
  - [A11.3-Q5] 7-day grace with full use and reminders, then read-only (no new entries) — CONFIRMED
  - [A11.3-Q6] Station logo and name on invoices and customer messages; no white-label/custom domain — CONFIRMED
  - [A11.3-Q7] Super admin sees account and usage counts only; tenant data only with owner-granted support access — CONFIRMED
  - [A11.3-Q8a] Leaving tenant gets Excel export — CONFIRMED
  - [A11.3-Q8b] Data kept 90 days, then permanently deleted — CONFIRMED
- **Mobile app pack (A11.4):**
  - [A11.4-Q1] Android via direct APK only; no Play Store at launch. iOS deferred to a later release — CONFIRMED
  - [A11.4-Q2] Push notifications, barcode/QR scan, Bluetooth printer; camera not used (no inspection photos) — CONFIRMED
  - [A11.4-Q3a] Offline: mechanic work — view job card, checklist, status, parts used. Billing online only — CONFIRMED
  - [A11.4-Q3b] Up to 1 day offline before sync — CONFIRMED
  - [A11.4-Q4] Conflict: last change wins, older value kept in history, manager notified — CONFIRMED
  - [A11.4-Q5] Low-cost Android phones (≈2 GB RAM), Android 8+; iOS 15+ when iOS ships — CONFIRMED
  - [A11.4-Q6a] App users: mechanics/staff, vehicle owners, station owner/manager — CONFIRMED
  - [A11.4-Q6b] Two apps: Staff app (role-based for owner, manager, cashier, mechanic) and Customer app — ASSUMED (asked, user delegated)
  - [A11.4-Q7] Companion web dashboard exists (web app selected as platform) — CONFIRMED (user-stated)
- **Management system pack (A11.5):**
  - [A11.5-Q1a] One branch per station at launch — CONFIRMED
  - [A11.5-Q1b] No transfers or consolidated branch reports at launch — CONFIRMED (follows from Q1a)
  - [A11.5-Q2a] Excel import, manual/opening-stock entry, or fresh start — CONFIRMED
  - [A11.5-Q2b] A few hundred to a few thousand records per station — CONFIRMED (stated in selected option)
  - [A11.5-Q3] Approvals: discount above limit, refund/bill cancellation, manual stock adjustment, vehicle release on credit — CONFIRMED
  - [A11.5-Q4a] Full change history (who, what, when) — CONFIRMED
  - [A11.5-Q4b] Visible to owner only — CONFIRMED
  - [A11.5-Q5] Daily cash closing and monthly reports; no period locking — CONFIRMED
  - [A11.5-Q6a] Printed document: invoice/receipt (Bluetooth or normal printer). Estimate and job card are digital only — CONFIRMED
  - [A11.5-Q6b] Station logo and name on invoice; no fixed letterhead — CONFIRMED
  - [A11.5-Q7] Attendance, fixed salary, commission, advances, mechanic performance report — CONFIRMED
  - [A11.5-Q8] No integrations at launch (Excel export only); FBR e-invoicing later — CONFIRMED

Pack coverage: asked A11.3-Q1, A11.3-Q2a, A11.3-Q2b, A11.3-Q3, A11.3-Q4a, A11.3-Q4b, A11.3-Q5, A11.3-Q6, A11.3-Q7, A11.3-Q8a, A11.3-Q8b, A11.4-Q1, A11.4-Q2, A11.4-Q3a, A11.4-Q3b, A11.4-Q4, A11.4-Q5, A11.4-Q6a, A11.4-Q6b, A11.5-Q1a, A11.5-Q1b, A11.5-Q2a, A11.5-Q2b, A11.5-Q3, A11.5-Q4a, A11.5-Q4b, A11.5-Q5, A11.5-Q6a, A11.5-Q6b, A11.5-Q7, A11.5-Q8, A12-Q1…Q7, A13-Q1…Q7; user-stated A11.4-Q7; not applicable A11.1 (no public website), A11.2 (not a plugin); not yet asked: none

## Exceptions and failure paths
| Workflow | Exception | Expected handling | Status |
| --- | --- | --- | --- |
| Job card | [A12-Q1] Customer cancels or rejects estimate | Charge inspection fee (owner-set) plus work already done and parts used | CONFIRMED |
| Job card | [A12-Q2] Extra work found after approval | Addition sent to customer for re-approval before work | CONFIRMED |
| Job card | [A12-Q3] Comeback / rework | New job linked to the original, labour free; owner decides on new parts; counted in mechanic report | CONFIRMED |
| Billing | [A12-Q4] Refund / return | Full or partial with approval, as cash or customer credit; unused parts back to stock; bill reversed by credit note, never deleted | CONFIRMED |
| Billing | [A12-Q5] Warranty / complaint | Warranty days per part/service; claim linked to original invoice; free labour inside warranty; part can be returned to supplier | CONFIRMED |
| Booking | [A12-Q6] Customer no-show | Repeated no-shows block app booking (limit set by owner, default 3; manager can unblock) | CONFIRMED (limit ASSUMED) |
| Handover | [A12-Q6] Car ready but not collected / not paid | Reminders; optional daily storage charge after owner-set days; no handover without payment or approved credit | CONFIRMED |
| All records | [A12-Q7] Wrong entry | No deletion; reversing entry with a reason by owner/manager; logged in audit trail | CONFIRMED |
| Mobile offline | Two offline edits on one job card | Last change wins, history kept, manager notified | CONFIRMED |
| Subscription | Station does not pay | 7-day grace, then read-only | CONFIRMED |
| Inventory | Offline parts use makes stock negative | Allowed; manager alerted on sync | PROPOSED |

## Local context, payments and communication
- **Country / currency:** Pakistan, PKR only — CONFIRMED (A13-Q1, Round 1)
- **Tax and invoice requirements:** Sales tax optional per station; owner sets separate rates for parts and services and enters NTN/STRN for the invoice; untaxed for unregistered stations; FBR e-invoicing later — CONFIRMED (A13-Q2)
- **Payment methods (customers at station):** Cash, JazzCash, Easypaisa, bank transfer (IBFT/RAAST), card machine; recorded by staff, no online customer payment in-app — CONFIRMED (A13-Q3)
- **Payment methods (stations → platform):** JazzCash/Easypaisa, bank transfer, card, cash — CONFIRMED (A11.3-Q4b)
- **Customer communication channels and events:** App push and WhatsApp for booking confirmed, estimate, extra-work approval, vehicle ready, invoice, dues, next-service reminder. WhatsApp is either sent by staff from their own WhatsApp (all plans) or automatically from the station's own connected WhatsApp Business account at the station's cost (Standard+). No SMS for customer messages; SMS is used only for login codes — CONFIRMED (A13-Q4a/b as changed by CR-002)
- **Date / number / phone formats:** DD/MM/YYYY; Rs with thousands separators; phone 03XX-XXXXXXX; Pakistani number plates (e.g. LEA-1234) — CONFIRMED (A13-Q5)
- **UI and document languages:** English only for apps, web, invoices and messages; no Urdu/RTL at launch — CONFIRMED (A13-Q6)
- **After-launch support, training, backups, maintenance:** Platform owner's team gives WhatsApp support and video guides; station owners train their staff; weekly backups; owner can export to Excel anytime; platform owner's in-house team maintains the system — CONFIRMED (A13-Q7)

## Inputs and trusted source material
- Staff entries: customers, vehicles, job cards, checklists, odometer/fuel, parts used, payments, attendance.
- Customer app: bookings, estimate approvals.
- Excel import of customers, vehicles and parts at onboarding; manual opening stock.
- Barcode/QR scans of parts.

## Expected outputs, reporting and exports
- Printed/shared invoice with station logo; digital estimate and job card.
- Reports: daily cash closing, monthly revenue, stock value, low stock, supplier ledger, customer dues, profit per part/job (owner only), mechanic performance, payroll sheet, no-show list.
- Excel export of station data; super-admin tenant and subscription overview.

## UX, target devices, language, offline
- Web dashboard (browser) for owner, manager, cashier; Android Staff app; Android Customer app (direct APK). iOS later.
- Low-cost Android 8+ phones; Bluetooth receipt printers; barcode/QR scanning.
- English UI; Pakistani formats.
- Offline: mechanic work up to 1 day; billing online only.

## User-stated technology preferences (Informational for Stage 2)
- **Stated preferences:** Flutter and Dart (mobile apps), Supabase (backend, database, auth, storage).
- **Classification:** `User-required technical constraint` (stated in the initial request, 2026-11-11).
- **Stage 2 note:** Suitability is checked in Stage 2 (`ARCHITECTURE.md`), including: offline sync for 1 day on Android 8+, multi-tenant data isolation, direct-APK updates, WhatsApp connection model (CR-002), and backup frequency.

## Identity, privacy, retention
- Strict isolation: one station never sees another station's data.
- Customer has one login (phone number) and sees only stations where their vehicle was serviced; a customer links to a station when staff registers them or via the station's link/code.
- Super admin: no tenant data access without owner-granted support access.
- Profit and audit log visible to owner only.
- Tenant exit: Excel export, deletion after 90 days.

## MVP and exclusions
- **MVP:** MOD-001 to MOD-010, one branch per station, Android + web, English.
- **Later options:** iOS app; multi-branch with transfers and branch-based plans; FBR e-invoicing; Urdu UI; Play Store listing; accounting integrations; inspection photos.
- **Explicit non-goals (launch):** Full accounting/general ledger; customer online payment in-app; marketplace or station search for customers; white-label/custom domains; dealership sales.

## Success / acceptance example
- Given a mechanic records 4 litres of oil from a drum and one filter on a job card while offline, When the phone syncs and the cashier bills the job, Then stock drops by 4 L and 1 piece, the invoice shows both at selling price plus the oil-change labour rate, and the owner's report shows the profit on that job.

## Confirmed decisions
- See `DECISIONS.md` DEC-001 to DEC-024.

## Proposals awaiting approval
- Offline parts use may push stock below zero, with a manager alert (PROPOSED).
- Role split between Manager and Cashier beyond the confirmed approvals (refined in PRD).

## Open high-impact questions and assumptions
- **Resolved after approval:** plan prices, plan modules and yearly discount (DEC-025/026). Message quota added via CR-001, then removed via CR-002: stations connect their own WhatsApp or send manually.
- **ASSUMED (delegated):** Two Android apps (Staff, Customer); job card stages; no-show limit default 3.
- **Risk:** Customer app via direct APK only — customers may hesitate to install outside Play Store. Confirmed choice; revisit if adoption is low.
- **Risk:** Weekly backups mean up to 7 days of data could be lost. Confirmed choice; Stage 2 will show the trade-off.
- **Risk:** iOS deferred, so iPhone customers have no app at launch.

## Reference files / sources
- User initial request (2026-11-11); Stage 0 discovery answers (2026-11-12, this session).
- `archive/v0.1/PROJECT_CONCEPT_BRIEF.md` (superseded draft).
- Skill `product-blueprint-architect` v1.3.3.
