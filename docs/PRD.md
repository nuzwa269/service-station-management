# Product Requirements Document — Car Service Station Management SaaS

> State: APPROVED (frozen) | Version: 1.1 (v1.0 + CR-002) | Date: 2026-11-13 | Approval: GRANTED 2026-11-12 by user in chat ("سب منظور") | Source: Approved Concept Brief v1.2 (`PROJECT_CONCEPT_BRIEF.md`, incl. CR-002) and `DECISIONS.md` DEC-001…DEC-026
> Scope: observable product behaviour only. No frameworks, databases or vendors; those belong to Stage 2.
> Tags: requirements without a tag trace to the approved brief. `PROPOSED` marks a rule the AI added. The user accepted **all** PROPOSED rules with this approval (DEC-027), so they are now part of the baseline. The tag is kept to show where each rule came from.
> Verification limits: nothing here has been built or tested. Acceptance tests are specifications.

## 1. Executive summary
A multi-tenant SaaS for independent car service stations in Pakistan (PKR, English UI). Each station (tenant) runs bookings, job cards, parts stock, billing, staff pay and customer history. Their data is fully isolated from other stations. Clients at launch:
- **Web dashboard**: owner, manager and cashier use it in a browser. The platform super admin has a separate admin area.
- **Staff app** (Android, direct APK): mechanics, and owner/manager/cashier on the move. Mechanic work runs offline for up to 24 hours.
- **Customer app** (Android, direct APK): booking, estimate approval, tracking, invoices and history. Standard and Premium plans only.

iOS, multi-branch, Urdu UI, FBR e-invoicing and inspection photos are out of scope for launch.

## 2. Objectives and success metrics
| Objective | Metric (first 6 months after launch) | Source |
|---|---|---|
| Every part and labour item used gets billed | 100% of parts recorded on a job card appear on its invoice (system rule; TEST-031, TEST-036) | Brief vision |
| Daily cash control | Station can close a day in under 5 minutes; every difference has a note | Brief journey 5 |
| Customer trust | ≥ 60% of estimates on Standard/Premium approved in-app or by message (PROPOSED target) | PROPOSED |
| SaaS conversion | ≥ 25% of trials convert to a paid plan (PROPOSED target) | PROPOSED |
| Low-end device support | Staff app usable on Android 8, 2 GB RAM phone (TEST-201) | A11.4-Q5 |

## 3. Users and permissions matrix
Roles: **SA** platform super admin · **OW** station owner · **MG** manager · **CA** cashier/service advisor · **ME** mechanic · **CU** customer.

| Area | View | Create | Edit | Delete / Reverse | Approve |
|---|---|---|---|---|---|
| Tenants, plans, subscription payments | SA; OW (own subscription) | SA (plans); OW (pay) | SA | SA (suspend) | SA (verify bank/cash payments) |
| Station settings, branding, tax, price lists, limits | OW, MG (read) | OW | OW | — | — |
| Users and roles | OW, MG (read) | OW | OW | OW (deactivate) | — |
| Bookings | OW, MG, CA; CU (own) | CA, MG, OW, CU | CA, MG, OW, CU (own, reschedule) | Cancel: CA, MG, OW, CU (own) | — |
| Job cards | OW, MG, CA; ME (assigned only); CU (own) | CA, MG, OW | CA, MG, OW; ME (status, checklist, parts on assigned) | Cancel: MG, OW | CU approves estimate/extra work; MG quality check |
| Inventory items and prices | OW, MG, CA; ME (name/stock only) | OW, MG | OW, MG | — | — |
| Purchase price and profit | OW only | OW, MG (enter purchase price on purchase bill) | OW | — | — |
| Purchases and suppliers | OW, MG | OW, MG | OW, MG | Reverse: OW, MG | — |
| Stock adjustment | OW, MG | MG, CA (request) | — | — | OW, MG |
| Invoices and payments | OW, MG, CA; CU (own) | CA, MG, OW | Before payment: CA, MG, OW | Reverse: OW, MG (with reason) | Discount over limit, refund/cancel, credit release: OW, MG |
| Customers and vehicles | OW, MG, CA; ME (vehicle on assigned job) | CA, MG, OW | CA, MG, OW | — | — |
| Staff, attendance, advances, payroll | OW; MG (attendance) | OW; MG (attendance) | OW; MG (attendance same day) | — | OW finalises payroll |
| Reports | OW all; MG all except profit and payroll | — | — | — | — |
| Audit log | OW only | System only | Never | Never | — |
| Support access to station data | SA only while granted | OW grants | OW revokes | — | — |

- MG gets the approval rights in the table by default. OW can withdraw them per approval type (PROPOSED).
- On the Basic plan the approvals module is not available. Restricted actions (over-limit discount, refund/cancel, stock adjustment, credit release) can then be performed **only by a user logged in as OW** (PROPOSED).

## 4. Product scope (Must / Should / Could / Excluded)
- **Must (MVP):** MOD-001…MOD-010 as specified in section 8, one branch per station, Android + web, English, PKR.
- **Should:** owner dashboard widgets (REQ-060); Excel import of customers/vehicles/parts (REQ-034).
- **Could (PROPOSED, not baseline):** customer feedback rating after delivery; WhatsApp click-to-chat button in customer app.
- **Excluded at launch:** iOS app; multi-branch, stock transfers and branch-based plans; Urdu/RTL UI; FBR e-invoicing; accounting/bank integrations; in-app online payment by customers; inspection photos; marketplace/station search; white-label/custom domain; general ledger; Play Store listing.

### Plan feature matrix (DEC-025, DEC-026, CR-001)
| Capability | Basic | Standard | Premium |
|---|---|---|---|
| Monthly price (PKR) | 2,500 | 5,000 | 8,000 |
| Yearly price (PKR, = 10 months) | 25,000 | 50,000 | 80,000 |
| Sign-up, users/roles, branding, Excel export (MOD-001) | ✓ | ✓ | ✓ |
| Job cards, checklist, staff app incl. offline (MOD-004) | ✓ | ✓ | ✓ |
| Inventory: items, purchases, consumption, adjustments, low-stock alert (MOD-005) | ✓ | ✓ | ✓ |
| Supplier ledger and supplier dues (REQ-029 dues part, REQ-030) | — | ✓ | ✓ |
| Billing, payments, customer credit, refunds, day closing (MOD-006) | ✓ | ✓ | ✓ |
| Customer and vehicle history, staff-side reminders list (MOD-007) | ✓ | ✓ | ✓ |
| Monthly revenue report | ✓ | ✓ | ✓ |
| Booking and customer app (MOD-003, REQ-047) | — | ✓ | ✓ |
| WhatsApp sent by staff from their phone, prefilled message (REQ-062) | ✓ | ✓ | ✓ |
| Automatic WhatsApp from the station's own connected account, billed by Meta to the station (REQ-061) | — | ✓ | ✓ |
| Push notifications | Staff only | Staff + customers | Staff + customers |
| Approvals inbox and audit log view (MOD-010) | — | ✓ | ✓ |
| Staff attendance, advances, payroll, commission, performance (MOD-008) | — | — | ✓ |
| Profit per part / per job reports | — | — | ✓ |
| 14-day trial | All Premium features |||

## 5. Modules and feature inventory
| Module ID | Title | Purpose | Dependencies |
|---|---|---|---|
| MOD-001 | Tenant workspace, sign-up & access | Station sign-up, users, roles, isolation, branding, support access | — |
| MOD-002 | Subscription & platform admin | Plans, trial, payments, grace/read-only, super admin, tenant exit | MOD-001 |
| MOD-003 | Booking & scheduling | Capacity settings, customer self-booking, staff bookings, no-shows | MOD-001, MOD-007 |
| MOD-004 | Job cards & inspection | Intake, checklist, estimate, approvals, stages, offline mechanic work, rework, warranty | MOD-001, MOD-005, MOD-007 |
| MOD-005 | Parts, inventory & suppliers | Items, units, prices, purchases, suppliers, consumption, adjustments, alerts, import | MOD-001 |
| MOD-006 | Billing, payments & customer credit | Labour list, invoices, discounts, tax, payments, credit, refunds, storage charge, day closing, printing | MOD-004, MOD-005 |
| MOD-007 | Customer & vehicle history | Customer/vehicle records, customer app account, history, service reminders | MOD-001 |
| MOD-008 | Staff, attendance, payroll & commission | Staff records, attendance, advances, payroll, performance | MOD-001, MOD-006 |
| MOD-009 | Notifications | Customer push and WhatsApp (manual or station's own account), staff push events | MOD-002, MOD-003, MOD-004, MOD-006 |
| MOD-010 | Reports, approvals & audit log | Approvals inbox, audit trail, reports, dashboard, exports | All |

## 6. Screens and navigation
**Web dashboard (station users)**
| Screen ID | Name | Entry | Main controls | Exit |
|---|---|---|---|---|
| SCR-001 | Sign-up / Login | Public URL | Sign up station, log in, forgot password | SCR-002 (new) or SCR-003 |
| SCR-002 | Onboarding wizard | First login | Station profile, logo, tax, working hours/bays, services list, import or opening stock | SCR-003 |
| SCR-003 | Owner/manager dashboard | Login | Today's jobs by stage, revenue, dues, low stock, approvals count | Any module |
| SCR-004 | Bookings calendar | Menu | Day/week view per bay, new booking, reschedule, cancel, mark arrived, no-show list | SCR-006 |
| SCR-005 | Job card list | Menu | Filter by stage/mechanic/date, search plate/phone, new job card | SCR-006 |
| SCR-006 | Job card detail | SCR-004/005 | Intake, checklist, estimate lines, send estimate, record approval, assign mechanic, stage, extra work, QC, cancel, create invoice | SCR-007 |
| SCR-007 | Invoice & payment | SCR-006 | Lines, discount, tax, payments (split), credit request, print/share, reverse, refund | SCR-006 |
| SCR-008 | Customers & vehicles | Menu | Search, customer profile, vehicles, history, dues, reminders, booking block status | SCR-006 |
| SCR-009 | Inventory items | Menu | Item list, stock, min level, prices, kits, scan, import | SCR-010, SCR-011 |
| SCR-010 | Purchases & suppliers | Menu | Purchase bill entry, supplier list, ledger, supplier payment | SCR-009 |
| SCR-011 | Stock adjustment | SCR-009 | Item, quantity +/−, reason, submit for approval | SCR-009 |
| SCR-012 | Approvals inbox | Menu / badge | Pending requests, approve/reject with note | Source record |
| SCR-013 | Day closing | Menu | Expected vs counted per payment method, note, close day | SCR-014 |
| SCR-014 | Reports | Menu | Report picker, date range, export Excel, print | — |
| SCR-015 | Staff & attendance | Menu | Staff list, roles, commission %, salary, daily attendance grid, advances | SCR-016 |
| SCR-016 | Payroll | SCR-015 | Month sheet, adjust, finalise | SCR-014 |
| SCR-017 | Settings | Menu | Branding, tax, services list, discount limit, inspection fee, storage charge, warranty, no-show limit, booking capacity, checklist, message toggles, users, support access | — |
| SCR-018 | Audit log | Menu (OW) | Filter by user/record/date, view old→new | — |
| SCR-019 | Subscription & billing | Menu (OW) | Plan, renewal date, pay, upgrade, payment history | — |
| SCR-020 | Data import / export / close account | Settings (OW) | Excel templates, import report, full export, close account | — |

**Web super admin area**
| Screen ID | Name | Entry | Main controls | Exit |
|---|---|---|---|---|
| SCR-021 | Tenants list | SA login | Filter by status/plan/trial end, search | SCR-022 |
| SCR-022 | Tenant detail | SCR-021 | Plan, status, usage counts, payments to verify, extend trial, suspend, support session (when granted) | SCR-021 |
| SCR-023 | Plans | SA menu | Plan prices/features, trial settings | — |

**Staff app (Android)**
| Screen ID | Name | Entry | Main controls | Exit |
|---|---|---|---|---|
| SCR-030 | Login | App start | Phone/username + password, station shown | SCR-031 / SCR-035 |
| SCR-031 | My jobs (mechanic) | Login | Assigned jobs, stage, offline badge, sync | SCR-032 |
| SCR-032 | Job work view | SCR-031 | Complaints, checklist, stage buttons, add parts (search/scan), extra-work note, request QC | SCR-031 |
| SCR-033 | Sync status | Header badge | Pending changes, last sync time, conflicts | — |
| SCR-034 | Approvals (OW/MG) | Push / menu | Same as SCR-012 | — |
| SCR-035 | Quick dashboard (OW/MG/CA) | Login | Today summary, job list, find invoice | SCR-036 |
| SCR-036 | Invoice print/share | SCR-035 | Bluetooth print, share PDF | — |

**Customer app (Android, Standard/Premium stations)**
| Screen ID | Name | Entry | Main controls | Exit |
|---|---|---|---|---|
| SCR-040 | Login | App start | Phone number, one-time code | SCR-041 |
| SCR-041 | My vehicles & stations | Login | Linked stations, vehicles, add station by code/link | SCR-042, SCR-043, SCR-044 |
| SCR-042 | Book a slot | SCR-041 | Station, vehicle, service, date, free slots, confirm, cancel/reschedule | SCR-041 |
| SCR-043 | Job tracking & approvals | Push / SCR-041 | Stage timeline, estimate, approve/reject, extra-work approval | SCR-044 |
| SCR-044 | Invoices & history | SCR-041 | Invoice list, PDF, dues, service history, next service | — |
| SCR-045 | Notifications | Bell | Message list | Linked screen |

Common states for every list/detail screen: **loading** indicator; **empty** state with the main action (e.g. "No job cards today — Create job card"); **error** with retry and a readable message; **read-only banner** when subscription is read-only (REQ-009); **locked feature** card with "Upgrade plan" when the plan lacks it (REQ-006).

## 7. User journeys (normal, error, offline)
**J1 — Booking to delivery (Standard plan).** Customer Ali books an oil change for Saturday 10:00 in the customer app (SCR-042). The slot is auto-confirmed and a WhatsApp message goes out from the station's connected WhatsApp account. On Saturday the cashier marks him arrived and a job card opens (SCR-006) with odometer 84,200 km, fuel ½ and checklist. The estimate is sent and Ali approves in the app. The mechanic records 3.5 L oil and 1 filter offline (SCR-032), and the job syncs. The manager passes QC → Ready (message sent). Cashier invoices, Ali pays by JazzCash → Delivered. Next-service reminder is set at 89,200 km / 3 months.
- *Alternate:* Ali rejects the estimate → job is cancelled with inspection fee invoice (REQ-025).
- *Error:* slot taken meanwhile → app shows "Slot just filled, pick another" (REQ-015).
- *Offline:* mechanic phone offline 6 h → changes queue, sync on reconnect; a conflict notifies the manager (REQ-023).

**J2 — Walk-in on Basic plan.** No customer app. Cashier creates the job card from a walk-in, records the customer's phone approval, invoices, prints a Bluetooth receipt. A discount above the limit can only be entered under the owner's login.

**J3 — Stock in.** Manager enters a supplier purchase bill: 20 filters, 1 drum of 208 L oil. Stock rises. On Standard+, the supplier due rises by the unpaid amount. A later supplier payment reduces the due.

**J4 — Credit release.** The fleet customer cannot pay. Cashier requests credit release (SCR-007). The owner approves in the staff app (SCR-034). Vehicle delivered, the due appears in the customer ledger, and reminders are sent weekly (PROPOSED interval).

**J5 — Subscription lapse.** A station's monthly payment is due on 1 March and not paid. 1–7 March: full use with daily reminders. 8 March: read-only (view, print, export only). It pays by bank transfer and uploads a receipt. The super admin verifies it, and full access returns at once.

**J6 — Month end (Premium).** Manager has marked attendance daily. On 1 April the owner opens payroll for March (SCR-016): salary by attendance + commission on labour of invoices paid in March − advances. Owner finalises and the sheet locks.

## 8. Detailed functional requirements
Each requirement lists: priority · source · role/entry · inputs & validation · rules · output · negative/offline · acceptance. `Trace:` gives module | screens | tests.

### MOD-001 Tenant workspace, sign-up & access

### REQ-001 — Station self sign-up
- Priority: Must · Source: A11.3-Q1, A11.3-Q2 · Role: new station owner on SCR-001
- Inputs & validation: owner name, mobile (03XX-XXXXXXX, unique on platform), email (optional, valid format), password (min 8 characters), station name, city. Mobile is verified by one-time code.
- Rules: creates a new isolated station and an OW user; starts a 14-day trial with Premium features; opens onboarding (SCR-002).
- Output: station account, trial end date shown on dashboard.
- Negative: mobile already registered → "This number already has an account — log in or reset password". Wrong code 5 times → wait 15 minutes (PROPOSED).
- Acceptance: Given a new mobile number, When the owner completes sign-up and enters the correct code, Then a station is created with status Trial and end date = today + 14 days.
- Trace: MOD-001 | SCR-001, SCR-002 | TEST-001

### REQ-002 — Users, roles and login
- Priority: Must · Source: brief roles · Role: OW on SCR-017; all users on SCR-001/SCR-030
- Inputs & validation: user name, mobile, role (Manager, Cashier, Mechanic), initial password. Plans have no user-count limit (A11.3-Q3).
- Rules: each role sees only the menus and actions in section 3. Mechanics see only job cards assigned to them. A deactivated user cannot log in, and their history remains.
- Output: user can log in on web and staff app.
- Negative: an action outside the role → hidden; a direct link → "You don't have permission".
- Acceptance: Given a Mechanic user, When they open the job list, Then only job cards assigned to them are listed and no prices are visible.
- Trace: MOD-001 | SCR-017, SCR-030, SCR-001 | TEST-002

### REQ-003 — Data isolation between stations
- Priority: Must · Source: brief identity & privacy, A11.3-Q7 · Role: all
- Rules: no station user can see, search or export another station's records. A customer sees only data from stations they are linked to (REQ-047). The super admin sees only account and usage data unless support access is granted (REQ-005).
- Negative: a request for another station's record returns "not found", with no data leaked.
- Acceptance: Given stations A and B both serve customer phone 0300-1234567, When a cashier of A searches that phone, Then only A's customer record and history appear.
- Trace: MOD-001 | all | TEST-003

### REQ-004 — Station profile, branding and tax settings
- Priority: Must · Source: A11.3-Q6, A11.5-Q6b, A13-Q2 · Role: OW on SCR-002/SCR-017
- Inputs & validation: logo (PNG/JPG, max 2 MB), station name, address, phone, NTN and STRN (optional), sales tax on/off, parts tax % and services tax % (0–100, 2 decimals).
- Rules: logo and name appear on invoices, estimates and customer messages. Tax lines are printed only if tax is on. NTN/STRN are printed when entered.
- Acceptance: Given tax on with parts 18% and services 16%, When an invoice has parts 10,000 and labour 2,000, Then tax shows 1,800 + 320 and total 14,120.
- Trace: MOD-001 | SCR-002, SCR-017 | TEST-004

### REQ-005 — Support access grant
- Priority: Must · Source: A11.3-Q7 · Role: OW on SCR-017; SA on SCR-022
- Rules: OW grants the super admin access for a chosen period (1, 24 or 72 hours — PROPOSED), revocable at any time. While granted, SA can view the station read-only (PROPOSED: no edits). Every grant, view session and revoke is written to the audit log.
- Acceptance: Given no active grant, When SA opens a tenant, Then only plan, status and usage counts are shown; after OW grants 24 h, SA can open job cards read-only.
- Trace: MOD-001 | SCR-017, SCR-022 | TEST-005

### MOD-002 Subscription & platform admin

### REQ-006 — Plans and feature gating
- Priority: Must · Source: DEC-025, A11.3-Q3, CR-001 · Role: system; OW on SCR-019
- Rules: features follow the plan feature matrix (section 4). A locked feature shows a card naming the plan that includes it and an "Upgrade" button. Data created during the trial stays after a downgrade but becomes read-only where the plan lacks the feature (PROPOSED).
- Acceptance: Given a Basic station, When the owner opens Bookings, Then a locked card says "Available on Standard and Premium" and no booking can be created.
- Trace: MOD-002 | SCR-019, all | TEST-006

### REQ-007 — Free trial
- Priority: Must · Source: A11.3-Q2a/b · Role: OW
- Rules: 14 days, all Premium features. Reminders on day 11 and day 13 (PROPOSED). At trial end without payment, the same 7-day grace and read-only rules as REQ-009 apply (PROPOSED). SA can extend a trial (SCR-022).
- Acceptance: Given trial day 14 passes unpaid, When the owner logs in on day 15, Then a grace banner shows 7 days left and all features still work.
- Trace: MOD-002 | SCR-003, SCR-019, SCR-022 | TEST-007

### REQ-008 — Paying the subscription
- Priority: Must · Source: A11.3-Q4a/b, DEC-025/026 · Role: OW on SCR-019; SA on SCR-022
- Inputs: plan, cycle (monthly/yearly), method: JazzCash, Easypaisa, debit/credit card, bank transfer (reference number + receipt image), cash (handed to platform team).
- Rules: wallet and card payments activate the period once the payment is confirmed as successful. Bank and cash payments stay "Pending verification" until SA verifies. Yearly = 10 × monthly price. The period starts from the current renewal date (or today if lapsed). The platform issues a receipt for each payment.
- Negative: wallet/card failure → "Payment not completed", no change. SA rejects a bank receipt → owner notified with reason.
- Acceptance: Given a Standard station pays yearly by bank transfer, When SA verifies the receipt, Then the renewal date moves 12 months ahead and the amount recorded is PKR 50,000.
- Trace: MOD-002 | SCR-019, SCR-022 | TEST-008

### REQ-009 — Grace period and read-only mode
- Priority: Must · Source: A11.3-Q5 · Role: system
- Rules: from the renewal date, 7 days of full use with a daily reminder (in-app + push + message to owner). From day 8: read-only. Users can view, search, print and export. Creating or changing job cards, invoices, payments, stock, bookings and attendance is blocked. Mechanic offline changes not yet synced are kept on the phone, then synced when the plan is active again (PROPOSED). Customer app booking for that station is disabled (PROPOSED). Payment restores full access immediately.
- Acceptance: Given day 8 after an unpaid renewal, When a cashier tries to create an invoice, Then the action is blocked with "Subscription expired — read-only. Ask the owner to renew" and printing old invoices still works.
- Trace: MOD-002 | all | TEST-009

### REQ-010 — Plan upgrade and downgrade
- Priority: Should · Source: PROPOSED (follows A11.3-Q3)
- Rules: upgrade takes effect immediately and the price difference for the remaining days is charged. Downgrade takes effect at the next renewal.
- Acceptance: Given Basic monthly with 15 of 30 days left, When the owner upgrades to Standard, Then PKR 1,250 is charged and Standard features unlock at once.
- Trace: MOD-002 | SCR-019 | TEST-010

### REQ-011 — (DEPRECATED) WhatsApp/SMS message quota and top-up packs
- Status: DEPRECATED by CR-002 (2026-11-13). The platform no longer sends paid WhatsApp/SMS for stations, so there is no quota and no top-up pack. Replaced by REQ-061 and REQ-062. The ID is not reused.
- Trace: MOD-002, MOD-009 | SCR-019 | TEST-011 (withdrawn)

### REQ-012 — Super admin tenant management
- Priority: Must · Source: brief roles, A11.3-Q7 · Role: SA on SCR-021/SCR-022/SCR-023
- Rules: list tenants with plan, status (Trial, Active, Grace, Read-only, Suspended, Closed), renewal/trial end and usage counts (users, job cards this month, WhatsApp connected yes/no). SA can verify payments, extend trials, suspend/unsuspend with reason, and edit plan prices and packs. Price changes apply at each tenant's next renewal (PROPOSED). SA never sees customer, invoice or stock details without a grant.
- Acceptance: Given 3 tenants with trials ending this week, When SA filters "Trial ends in 7 days", Then exactly those 3 are listed.
- Trace: MOD-002 | SCR-021, SCR-022, SCR-023 | TEST-012

### REQ-013 — Tenant exit and data deletion
- Priority: Must · Source: A11.3-Q8a/b · Role: OW on SCR-020
- Rules: OW can download a full Excel export at any time. "Close account" needs a typed confirmation. Data is then kept 90 days (restorable by paying), a reminder is sent on day 80 (PROPOSED), and everything is permanently deleted on day 90.
- Acceptance: Given an account closed on 1 Jan, When 31 March passes, Then the station's data cannot be restored and the tenant shows "Closed — deleted".
- Trace: MOD-002 | SCR-020 | TEST-013

### MOD-003 Booking & scheduling (Standard, Premium)

### REQ-014 — Booking capacity settings
- Priority: Must · Source: booking capacity answer · Role: OW on SCR-017
- Inputs & validation: number of bays (1–50), slot length (30/60/90/120 min), working hours per weekday, off-days and holidays, bookable services.
- Rules: capacity per slot = number of bays. Changing settings does not cancel existing bookings; conflicts are listed for staff (PROPOSED).
- Acceptance: Given 4 bays, 60-minute slots, 09:00–18:00, When a customer views a Tuesday, Then 9 slots are shown, each with capacity 4.
- Trace: MOD-003 | SCR-017 | TEST-014

### REQ-015 — Customer self-booking
- Priority: Must · Source: booking answer "free slots auto-booked" · Role: CU on SCR-042
- Inputs: linked station, own vehicle (or add new: plate, make, model), service, date (today up to 30 days ahead — PROPOSED), free slot, optional note.
- Rules: only slots with free capacity are shown. Booking is confirmed instantly and a confirmation is sent (REQ-055). A customer blocked for no-shows (REQ-017) cannot book in the app and sees "Please call the station".
- Negative: slot filled during confirmation → "Slot just filled, pick another". Station read-only → booking disabled.
- Acceptance: Given a slot with 1 free bay, When two customers confirm it at the same time, Then one booking succeeds and the other sees the "Slot just filled" message.
- Trace: MOD-003 | SCR-041, SCR-042 | TEST-015

### REQ-016 — Staff bookings, reschedule and cancel
- Priority: Must · Source: brief journey 1 · Role: CA/MG/OW on SCR-004; CU on SCR-042
- Rules: staff enter phone and walk-in bookings, and may overbook a full slot with a warning (PROPOSED). Customers can cancel or reschedule their own booking up to 1 hour before the slot (PROPOSED). Each change notifies the other side.
- Acceptance: Given a booking at 10:00, When the customer cancels at 09:30, Then the app refuses with "Too late to cancel online — call the station".
- Trace: MOD-003 | SCR-004, SCR-042 | TEST-016

### REQ-017 — No-shows and booking block
- Priority: Must · Source: A12-Q6, DEC-022 (limit ASSUMED) · Role: system; MG on SCR-008
- Rules: a booking not marked arrived within 30 minutes after slot start becomes No-show and frees the slot (PROPOSED: 30 minutes). When a customer reaches the no-show limit (owner setting, default 3) at a station, app booking at that station is blocked. MG/OW can unblock, which resets the count.
- Acceptance: Given limit 3 and a customer with 2 no-shows, When a third booking becomes No-show, Then their app booking at that station is blocked and the manager can unblock from SCR-008.
- Trace: MOD-003 | SCR-004, SCR-008 | TEST-017

### MOD-004 Job cards & inspection

### REQ-018 — Create job card (intake)
- Priority: Must · Source: brief journeys 1–2 · Role: CA/MG/OW on SCR-006
- Inputs & validation: from a booking or as a walk-in. Customer (search by phone or create), vehicle (plate in Pakistani format such as LEA-1234 or ABC-123, make, model, year 1950–next year), odometer in km (number, not lower than the last recorded value without a confirm warning), fuel level (E, ¼, ½, ¾, F), complaints (text), expected delivery time.
- Rules: job number is sequential per station. Stage = Intake.
- Negative: plate in an unknown format → warning, can still save (PROPOSED). Odometer lower than last visit → "Odometer lower than last visit (85,000) — confirm?"
- Acceptance: Given a vehicle last recorded at 85,000 km, When the cashier enters 84,000, Then a confirmation warning appears before saving.
- Trace: MOD-004 | SCR-004, SCR-005, SCR-006 | TEST-018

### REQ-019 — Inspection checklist
- Priority: Must · Source: brief MOD-004 (no photos, DEC-014) · Role: CA/MG/ME on SCR-006/SCR-032
- Rules: OW maintains the station checklist (e.g. brakes, tyres, lights, battery, fluids). Each item is OK, Needs attention or Not checked, with an optional note. No photo capture. Items marked Needs attention can be turned into estimate lines in one tap.
- Acceptance: Given checklist item "Brake pads" set to Needs attention, When the advisor taps "Add to estimate", Then a brake-pad line is added to the estimate.
- Trace: MOD-004 | SCR-006, SCR-017, SCR-032 | TEST-019

### REQ-020 — Estimate and customer approval
- Priority: Must · Source: brief journey 2, DEC-008 · Role: CA/MG on SCR-006; CU on SCR-043
- Rules: an estimate lists parts (selling price) and labour lines with a total. Sending it moves the stage to Awaiting approval and notifies the customer (app push on Standard/Premium, plus WhatsApp per REQ-055). Staff may instead record a phone or in-person approval, with approver name and time. Approve → stage Approved. Reject → REQ-025. Work cannot start before approval.
- Acceptance: Given an estimate of PKR 6,500 sent to a customer app user, When the customer taps Approve, Then the job card shows "Approved by customer in app" with time, and the mechanic can start.
- Trace: MOD-004 | SCR-006, SCR-043 | TEST-020

### REQ-021 — Mechanic assignment and job stages
- Priority: Must · Source: job card stages (ASSUMED, DEC delegated) · Role: MG/CA assign; ME updates
- Stages: Intake → Awaiting approval → Approved → In progress → Quality check → Ready → Delivered, plus Cancelled. Payment status is shown separately (Unpaid, Partly paid, Paid, On credit).
- Rules: one or more mechanics per job card. Assigned mechanics get a push. ME can move Approved → In progress → Quality check. MG/OW perform QC (REQ-024). Delivered requires REQ-039. Every stage change is time-stamped.
- Acceptance: Given a job in Approved, When the assigned mechanic taps Start, Then the stage becomes In progress with the time and the dashboard count updates.
- Trace: MOD-004 | SCR-005, SCR-006, SCR-031, SCR-032 | TEST-021

### REQ-022 — Extra work after approval
- Priority: Must · Source: A12-Q2 · Role: ME suggests; CA/MG adds; CU approves
- Rules: new lines added after approval form an "Additional work" request that needs customer re-approval (app or recorded phone approval) before they are worked on or invoiced. Rejected additions are kept as rejected and not invoiced.
- Acceptance: Given an approved job, When the advisor adds a PKR 3,000 clutch-plate line, Then that line shows "Awaiting customer approval" and cannot be invoiced until approved.
- Trace: MOD-004 | SCR-006, SCR-032, SCR-043 | TEST-022

### REQ-023 — Mechanic offline work
- Priority: Must · Source: A11.4-Q3a/b, A11.4-Q4, DEC-015 · Role: ME on SCR-031/SCR-032/SCR-033
- Rules: assigned job cards are available offline. Offline, a mechanic can view jobs, update the checklist, change stages (up to Quality check) and add/remove parts used. Changes queue and sync automatically when online. A header badge shows Offline and the number of pending changes. After 24 hours offline the app warns "Connect to sync — changes older than 24 h are at risk" (PROPOSED wording). Conflict on the same field: the last change wins, the overwritten value stays in history, and the manager gets a notification. Billing, estimate sending and approvals need a connection.
- Acceptance: Given the mechanic's phone is offline, When they add 1 oil filter and move the job to Quality check, Then both changes show as pending, and after reconnecting the web shows them within 1 minute (PROPOSED target) with stock reduced.
- Trace: MOD-004, MOD-005 | SCR-031, SCR-032, SCR-033 | TEST-023

### REQ-024 — Quality check
- Priority: Must · Source: brief journey 2 · Role: MG/OW on SCR-006/SCR-034
- Rules: Pass → Ready, and the customer is notified "vehicle ready". Fail → back to In progress with a note to the mechanic.
- Acceptance: Given a job in Quality check, When the manager selects Fail with note "Oil leak", Then the stage returns to In progress and the mechanic gets the note by push.
- Trace: MOD-004 | SCR-006 | TEST-024

### REQ-025 — Cancellation and rejected estimate
- Priority: Must · Source: A12-Q1 · Role: MG/OW
- Rules: on cancel or estimate rejection, an invoice is created for the inspection fee (owner setting, may be 0), plus any labour already done and parts already used. Unused parts return to stock. The job becomes Cancelled with a reason.
- Acceptance: Given inspection fee PKR 500 and no work done, When the customer rejects the estimate, Then a PKR 500 invoice is created and the job is Cancelled.
- Trace: MOD-004, MOD-006 | SCR-006, SCR-007 | TEST-025

### REQ-026 — Rework (comeback) job
- Priority: Must · Source: A12-Q3 · Role: CA/MG
- Rules: a rework job is linked to the original job. Labour is free (price 0). New parts are charged or free per the owner's/manager's choice on that job. Rework counts against the original mechanic in the performance report.
- Acceptance: Given original job #1042 by mechanic Bilal, When a rework job is created from it, Then labour lines show PKR 0 and Bilal's rework count rises by 1.
- Trace: MOD-004, MOD-008 | SCR-006 | TEST-026

### REQ-027 — Warranty claims
- Priority: Must · Source: A12-Q5 · Role: CA/MG
- Rules: each service in the labour list and each item may carry warranty days. A claim is created from the original invoice line. Inside the warranty period, labour is free and the replaced part may be charged 0. The faulty part can be marked "Return to supplier", which reduces the supplier due on Standard+ (PROPOSED). Outside the period, the system says "Warranty expired on <date>" and a normal job is created.
- Acceptance: Given a battery sold 100 days ago with 180 days warranty, When a claim is opened, Then labour is 0, the claim links to the original invoice and the period shows 80 days remaining.
- Trace: MOD-004, MOD-005, MOD-006 | SCR-006, SCR-008 | TEST-027

### MOD-005 Parts, inventory & suppliers

### REQ-028 — Item master
- Priority: Must · Source: A10 inventory · Role: OW/MG on SCR-009
- Inputs & validation: name, code, optional barcode/QR (unique per station), category, unit (piece, litre, kit), "bulk container" flag for drums (allows decimal use), purchase price, selling price (≥ 0; a warning if below purchase price), minimum stock level, warranty days. A kit lists its component items and quantities.
- Rules: quantities in litres allow 2 decimals, pieces and kits are whole numbers. Selling a kit reduces each component's stock (PROPOSED). Purchase price and margin are visible to OW only.
- Acceptance: Given oil is a bulk item in litres, When 3.5 L is added to a job, Then stock drops by 3.50 L.
- Trace: MOD-005 | SCR-009 | TEST-028

### REQ-029 — Purchases from suppliers
- Priority: Must · Source: A10 inflow · Role: OW/MG on SCR-010
- Inputs: supplier (Standard+: from supplier list; Basic: free-text name), bill number, date, lines (item, quantity, purchase price), amount paid now.
- Rules: stock increases per line. The item's purchase price becomes the weighted average cost (PROPOSED). On Standard+, the unpaid amount is added to the supplier's due. A posted purchase can only be reversed with a reason (REQ-042).
- Acceptance: Given 10 filters in stock at cost 400, When 10 more are bought at 500, Then stock is 20 and the cost shown to the owner is 450.
- Trace: MOD-005 | SCR-010 | TEST-029

### REQ-030 — Supplier ledger and payments (Standard, Premium)
- Priority: Must · Source: A10 reports, DEC-020 · Role: OW/MG on SCR-010
- Rules: per supplier: purchases, payments, returns and running due. Payments are recorded with method and reference. The ledger is printable and exportable.
- Acceptance: Given purchases 50,000 and payments 30,000, When the ledger opens, Then the due shows 20,000.
- Trace: MOD-005 | SCR-010, SCR-014 | TEST-030

### REQ-031 — Parts used on job cards
- Priority: Must · Source: A10 outflow · Role: ME/CA/MG on SCR-032/SCR-006
- Rules: parts are added by search or barcode/QR scan. Stock reduces when the line is saved (offline: when synced). Removing the line before invoicing returns the stock. Stock may go below zero when parts are used offline or the stock count is wrong: allowed with a warning, and the manager is notified (PROPOSED). "Customer-supplied part" lines carry no price and no stock effect. Each part line appears on the invoice at the selling price (editable within the discount rule).
- Acceptance: Given filter stock 1, When two mechanics each add 1 filter offline and both sync, Then stock shows −1 and the manager receives a negative-stock alert.
- Trace: MOD-005, MOD-004 | SCR-006, SCR-032 | TEST-031

### REQ-032 — Stock adjustment with approval
- Priority: Must · Source: A11.5-Q3 · Role: CA/MG request on SCR-011; OW/MG approve
- Inputs: item, quantity change (+/−), reason (count difference, damaged, expired, other with note).
- Rules: stock changes only after approval (Basic: OW only, see section 3). The adjustment is logged.
- Acceptance: Given a request for −2 filters "damaged", When the owner rejects it, Then stock is unchanged and the requester sees the rejection note.
- Trace: MOD-005, MOD-010 | SCR-011, SCR-012 | TEST-032

### REQ-033 — Low-stock alert
- Priority: Must · Source: A10 controls · Role: OW/MG
- Rules: when stock reaches or falls below the minimum, the item appears in the dashboard low-stock list and OW/MG get one push per item per day (PROPOSED).
- Acceptance: Given minimum 5 and stock 6, When 1 is used, Then the item appears in the low-stock list.
- Trace: MOD-005 | SCR-003, SCR-009 | TEST-033

### REQ-034 — Opening stock and Excel import
- Priority: Should · Source: A11.5-Q2a/b · Role: OW on SCR-002/SCR-020
- Rules: downloadable Excel templates for items (with opening quantity and prices), customers and vehicles. Import validates each row and shows imported / rejected counts with a reason per rejected row. Re-importing the same code updates rather than duplicates (PROPOSED). Imports of up to 5,000 rows are supported (brief: hundreds to thousands).
- Acceptance: Given a file of 1,000 items where 3 rows have no name, When imported, Then 997 are added and a report lists the 3 rejected rows with "Name missing".
- Trace: MOD-005, MOD-007 | SCR-002, SCR-020 | TEST-034

### MOD-006 Billing, payments & customer credit

### REQ-035 — Labour/service list
- Priority: Must · Source: A10 billing, DEC-021 · Role: OW on SCR-017
- Inputs: service name, standard rate (PKR), warranty days, optional default parts.
- Rules: the rate fills in on the job card and can be edited there within the discount rule (lowering it counts as a discount — PROPOSED).
- Acceptance: Given "Oil change labour" at PKR 500, When added to an estimate, Then the line shows 500 and is editable.
- Trace: MOD-006 | SCR-017, SCR-006 | TEST-035

### REQ-036 — Invoice generation
- Priority: Must · Source: brief journey 3, A13-Q2 · Role: CA/MG/OW on SCR-007
- Rules: an invoice is created from a job card's approved lines only. It shows station branding, sequential invoice number, date (DD/MM/YYYY), customer, vehicle plate, odometer, part lines, labour lines, discount, tax per category (if enabled), total and amount due in "Rs 12,345" format. One job card has one invoice; changes after payment are only possible via reversal or credit note.
- Acceptance: Given approved lines parts 8,000 and labour 1,500 with tax off, When the invoice is created, Then the total is Rs 9,500 and the invoice number is the next in the station's sequence.
- Trace: MOD-006 | SCR-007 | TEST-036

### REQ-037 — Discount limit
- Priority: Must · Source: A11.5-Q3, DEC-021 · Role: CA; OW sets limit on SCR-017
- Rules: the owner sets a maximum discount % without approval (default 5%). A discount within the limit applies at once. Above it, an approval request is created (Standard+) or the owner must enter it under their login (Basic). The invoice cannot be finalised while the request is pending.
- Acceptance: Given limit 5% and an invoice of 10,000, When the cashier enters a discount of 800, Then an approval request is created and the invoice shows "Discount awaiting approval".
- Trace: MOD-006, MOD-010 | SCR-007, SCR-012 | TEST-037

### REQ-038 — Recording payments
- Priority: Must · Source: A13-Q3, A10 money handling · Role: CA/MG/OW on SCR-007
- Inputs: amount, method (Cash, JazzCash, Easypaisa, Bank transfer, Card machine), reference number (required for non-cash), date (today; earlier only before that day is closed).
- Rules: several payments can split one invoice across methods. An advance can be taken on the job card before the invoice and is applied to the invoice. For cash, entering the cash received shows the change to return. Paid amount can't exceed the due (any excess is offered as customer credit — PROPOSED).
- Acceptance: Given an invoice of 9,500, When 5,000 cash and 4,500 JazzCash (ref 7781) are recorded, Then the invoice is Paid and the day-closing totals show each method separately.
- Trace: MOD-006 | SCR-007 | TEST-038

### REQ-039 — Handover rule and credit release
- Priority: Must · Source: DEC-021, A11.5-Q3 · Role: CA requests; OW/MG approve
- Rules: Delivered is allowed only when the invoice is Paid, or a credit release is approved. On approval the remaining amount goes to the customer's dues.
- Negative: marking Delivered with an unpaid balance and no approval → blocked with "Collect Rs X or request credit approval".
- Acceptance: Given an invoice due 3,000, When the cashier requests credit and the owner approves in the staff app, Then the job can be Delivered and the customer's dues rise by 3,000.
- Trace: MOD-006, MOD-010 | SCR-007, SCR-012, SCR-034 | TEST-039

### REQ-040 — Customer dues and collection
- Priority: Must · Source: A10 credit, A13-Q4b · Role: CA/MG/OW on SCR-008
- Rules: per-customer dues ledger (invoices on credit, payments, credit notes). Later payments are allocated to the oldest due first (PROPOSED). A dues reminder message is sent every 7 days while dues remain (PROPOSED; via WhatsApp per REQ-055).
- Acceptance: Given dues of 3,000 + 2,000 on two invoices, When the customer pays 4,000, Then the first invoice is cleared and 1,000 remains on the second.
- Trace: MOD-006 | SCR-008 | TEST-040

### REQ-041 — Refunds and credit notes
- Priority: Must · Source: A12-Q4 · Role: CA requests; OW/MG approve
- Rules: full or partial refund against a paid invoice, with a reason. On approval a credit note is issued (numbered, linked to the invoice). The money goes out as cash/original method or stays as customer credit for future invoices. Returned unused new parts go back to stock. The original invoice is never changed.
- Acceptance: Given a paid invoice with an unused filter of PKR 800, When a partial refund of 800 as credit is approved, Then a credit note of 800 exists, the filter returns to stock and the customer has 800 credit.
- Trace: MOD-006, MOD-005 | SCR-007, SCR-012 | TEST-041

### REQ-042 — Correction by reversal (no deletion)
- Priority: Must · Source: A12-Q7 · Role: OW/MG
- Rules: invoices, payments, purchases, supplier payments and stock entries can't be deleted once saved. A wrong entry is corrected by a reversing entry with a mandatory reason, then a new correct entry. Reversals are logged (REQ-058). Draft (unsaved) items can be discarded freely.
- Acceptance: Given a cash payment entered as 5,000 instead of 500, When the manager reverses it with reason "typing error" and enters 500, Then both the reversed and the new payment are visible and the day total counts 500.
- Trace: MOD-006, MOD-010 | SCR-007, SCR-010 | TEST-042

### REQ-043 — Uncollected vehicle and storage charge
- Priority: Must · Source: A12-Q6 · Role: system; OW sets rules
- Rules: when a vehicle has been Ready for longer than the owner-set free days (default 3 — PROPOSED), a reminder goes out daily (PROPOSED). If the owner has enabled a daily storage charge, it is added to the invoice per extra day as a separate line. The vehicle can't be released until REQ-039 is satisfied.
- Acceptance: Given 3 free days and Rs 300/day, When the vehicle is collected on day 6 after Ready, Then the invoice includes a storage line of Rs 900.
- Trace: MOD-006 | SCR-007, SCR-017 | TEST-043

### REQ-044 — Daily cash closing
- Priority: Must · Source: A11.5-Q5 · Role: CA/MG on SCR-013; OW views
- Rules: closing shows expected amounts per payment method (payments minus cash refunds), the cashier enters the counted cash (and confirms other methods), and the difference is shown and requires a note if not zero. After closing, no new or backdated payment can be dated to that day (PROPOSED). OW can reopen a day with a reason (logged).
- Acceptance: Given expected cash 42,000, When the cashier counts 41,500, Then a difference of −500 is shown and closing requires a note.
- Trace: MOD-006 | SCR-013 | TEST-044

### REQ-045 — Printing and sharing invoices
- Priority: Must · Source: A11.5-Q6a, A11.4-Q2 · Role: CA/MG/OW on SCR-007/SCR-036
- Rules: print on A4 from the web, print on a Bluetooth receipt printer (58/80 mm) from the staff app, share a PDF via WhatsApp or other apps. The estimate and job card are digital only. If no printer is paired, the app offers pairing; a failed print offers a retry or PDF share.
- Acceptance: Given a paired 80 mm printer, When the cashier taps Print, Then a receipt with station logo, lines, total and payment methods prints in English.
- Trace: MOD-006 | SCR-007, SCR-036 | TEST-045

### MOD-007 Customer & vehicle history

### REQ-046 — Customer and vehicle records
- Priority: Must · Source: brief MOD-007 · Role: CA/MG/OW on SCR-008
- Inputs & validation: customer name, mobile (03XX-XXXXXXX, unique per station), optional email/address; vehicles with plate (unique per station), make, model, year, colour. One customer may own many vehicles, and a vehicle can move to another customer (PROPOSED).
- Rules: search by phone, plate or name. The profile shows vehicles, jobs, invoices, dues and booking-block status.
- Acceptance: Given plate LEA-1234 exists, When the cashier searches "1234", Then that vehicle and its owner appear.
- Trace: MOD-007 | SCR-008 | TEST-046

### REQ-047 — Customer app account and station links (Standard, Premium)
- Priority: Must · Source: customer account answer, DEC-024 · Role: CU on SCR-040/SCR-041
- Rules: login by mobile number plus a one-time code. A customer is linked to a station automatically when that station has their mobile on a customer record, or manually by entering the station's code or opening its link. The customer sees, per linked station, only their own vehicles, jobs, estimates, invoices and history there. Stations on Basic don't appear for linking ("This station doesn't offer the app yet").
- Acceptance: Given mobile 0300-1234567 is a customer at stations A (Standard) and B (Standard), When the customer logs in, Then both stations are listed and each shows only its own records.
- Trace: MOD-007 | SCR-040, SCR-041, SCR-044 | TEST-047

### REQ-048 — Vehicle service history
- Priority: Must · Source: brief MOD-007 · Role: staff on SCR-008; CU on SCR-044
- Rules: a timeline per vehicle per station: date, odometer, jobs, parts and services, invoice total, warranty items still valid. Staff see the history of their station only.
- Acceptance: Given 3 past jobs, When the vehicle history opens, Then the 3 jobs show newest first with odometer and invoice totals.
- Trace: MOD-007 | SCR-008, SCR-044 | TEST-048

### REQ-049 — Next-service reminders
- Priority: Must · Source: brief MOD-007, A13-Q4b · Role: CA/MG set on delivery; system sends
- Rules: at delivery the advisor sets the next-service date and/or odometer (defaults from the service — PROPOSED). A reminder is sent 3 days before the date (PROPOSED). On Basic, reminders appear only in a staff "Due for service" list for calling.
- Acceptance: Given next service on 15/02/2027 on a Standard station, When 12/02/2027 arrives, Then the customer receives the reminder by push and by WhatsApp from the station's connected account.
- Trace: MOD-007, MOD-009 | SCR-006, SCR-008 | TEST-049

### MOD-008 Staff, attendance, payroll & commission (Premium)

### REQ-050 — Staff records
- Priority: Must · Source: A11.5-Q7, DEC-019 · Role: OW on SCR-015
- Inputs: name, mobile, role, monthly salary (PKR), commission % on labour (mechanics, 0–100), joining date. Staff records may exist without app login (e.g. helpers — PROPOSED).
- Acceptance: Given a mechanic with salary 40,000 and commission 10%, When saved, Then both appear on the staff profile, visible to OW only.
- Trace: MOD-008 | SCR-015 | TEST-050

### REQ-051 — Daily attendance
- Priority: Must · Source: payroll answer · Role: MG/OW on SCR-015
- Rules: a daily grid per staff member: Present, Absent, Half day, Leave (paid), Off day. MG can edit the same day only, and OW can edit any day with the change logged (PROPOSED).
- Acceptance: Given yesterday's attendance, When the manager tries to edit it, Then it is blocked and the owner can still edit it.
- Trace: MOD-008 | SCR-015 | TEST-051

### REQ-052 — Salary advances
- Priority: Must · Source: payroll answer · Role: OW on SCR-015
- Rules: record an advance (date, amount, method). By default the whole advance is deducted in the next payroll; the owner may split it over months (PROPOSED).
- Acceptance: Given an advance of 5,000 on 10 March, When March payroll is generated, Then 5,000 appears as a deduction.
- Trace: MOD-008 | SCR-015, SCR-016 | TEST-052

### REQ-053 — Monthly payroll sheet
- Priority: Must · Source: payroll + commission answers · Role: OW on SCR-016
- Rules per staff member for the month:
  - Salary earned = monthly salary ÷ days in month × (paid days). Paid days = Present + Leave + Off days + ½ × Half days (PROPOSED formula).
  - Commission = commission % × labour amount (after line discount) on that mechanic's invoices **paid** in that month. Labour on a job shared by several mechanics is split equally (PROPOSED). Rework labour is 0, so it earns nothing.
  - Net = salary earned + commission − advances deducted ± manual adjustment with note.
- OW finalises the sheet, which locks it. Changes after that need a reversal entry in the next month (PROPOSED).
- Acceptance: Given salary 30,000 in a 30-day month with 2 absent days, commission 10% on Rs 50,000 paid labour, and an advance of 5,000, When payroll is generated, Then net = 28,000 + 5,000 − 5,000 = Rs 28,000.
- Trace: MOD-008 | SCR-016 | TEST-053

### REQ-054 — Mechanic performance report
- Priority: Must · Source: A11.5-Q7 · Role: OW/MG on SCR-014
- Rules: per mechanic and period: jobs completed, labour value, rework jobs (from REQ-026), QC fails, average time from In progress to Quality check.
- Acceptance: Given Bilal completed 40 jobs and 2 reworks in March, When the report runs for March, Then it shows 40 jobs and a rework rate of 5%.
- Trace: MOD-008, MOD-010 | SCR-014 | TEST-054

### MOD-009 Notifications

### REQ-055 — Customer messages by event
- Priority: Must · Source: A13-Q4a/b, CR-002 · Role: system; OW toggles on SCR-017
- Events: booking confirmed / changed / cancelled; estimate ready; extra work needs approval; vehicle ready; invoice issued (with PDF link); dues reminder; next-service reminder; storage charge started.
- Rules: English templates with the station name. Each event goes by push to customer-app users (Standard/Premium). For WhatsApp:
  - **Automatic:** if the station has connected its own WhatsApp Business account (REQ-061), the event is sent automatically from that account using approved templates.
  - **Manual:** otherwise, or on Basic, the event is added to a "Messages to send" list where staff tap "Send on WhatsApp" (REQ-062).
  - No SMS is sent for customer events. OW can switch each event on or off.
- Negative: an automatic send that fails is retried once (PROPOSED) and then moved to the manual list with the reason shown.
- Acceptance: Given a Standard station with a connected WhatsApp account and "vehicle ready" on, When QC passes, Then the customer gets a push and a WhatsApp message "Your vehicle LEA-1234 is ready at <station>" sent from the station's own number.
- Trace: MOD-009 | SCR-017, SCR-045 | TEST-055

### REQ-056 — Staff notifications
- Priority: Must · Source: A11.4-Q2, A11.4-Q4 · Role: system
- Events (push, free): new job assigned; QC failed; approval request (to approvers); approval decision (to requester); offline conflict (to manager); low stock and negative stock (to OW/MG); subscription reminders (to OW).
- Acceptance: Given a cashier requests a refund approval, When it is submitted, Then the owner and managers with refund-approval rights receive a push within 1 minute (PROPOSED target).
- Trace: MOD-009 | SCR-034 | TEST-056

### REQ-061 — Connect the station's own WhatsApp Business account (Standard, Premium)
- Priority: Must · Source: CR-002 · Role: OW on SCR-017
- Rules: the owner taps "Connect WhatsApp" and completes Meta's sign-up inside the dashboard, choosing or creating the station's WhatsApp Business account and phone number. The owner must add a payment method in Meta, and Meta bills the station directly for its messages. The platform pays nothing per message. The station's message templates are created from the platform's standard English set and submitted for approval. Settings show the status (Not connected, Pending, Connected, Payment problem, Disconnected) and a Disconnect button. Disconnecting returns all events to manual sending.
- Negative: Meta rejects the sign-up or a template → status shows the reason; events use manual sending meanwhile.
- Acceptance: Given a Standard station that completed Meta sign-up and added a payment method, When its templates are approved, Then the status shows Connected and the next "booking confirmed" event is sent automatically from the station's number.
- Trace: MOD-009, MOD-001 | SCR-017 | TEST-061

### REQ-062 — Manual WhatsApp send from staff phone (all plans)
- Priority: Must · Source: CR-002 · Role: CA/MG/OW on web and staff app
- Rules: for each enabled event without automatic sending, a prefilled English message with the customer's number appears in a "Messages to send" list and on the related job card or invoice. Tapping "Send on WhatsApp" opens WhatsApp (app on the phone, WhatsApp Web on the computer) with the text and the invoice PDF link ready, and staff press Send themselves. The system marks the item as opened, and staff can mark it Sent or Skip. It costs the platform and station nothing.
- Negative: customer has no valid mobile → the item shows "No WhatsApp number" and can be skipped.
- Acceptance: Given a Basic station and an invoice issued, When the cashier taps "Send on WhatsApp", Then WhatsApp opens with the customer's number and the text "Your invoice INV-0042 from <station>: Rs 9,500 …" ready to send.
- Trace: MOD-009 | SCR-007, SCR-035, SCR-003 | TEST-062

### MOD-010 Reports, approvals & audit log

### REQ-057 — Approvals inbox (Standard, Premium)
- Priority: Must · Source: A11.5-Q3 · Role: OW/MG on SCR-012/SCR-034
- Types: discount above limit, refund / bill cancellation, stock adjustment, credit release.
- Rules: each request shows the requester, record, amount and reason. Approve or reject with an optional note. The decision is final and logged, and the requester is notified. Pending requests block only the affected action.
- Acceptance: Given a pending credit-release request, When the manager approves it, Then the job card can be Delivered and the request shows "Approved by <name>, <time>".
- Trace: MOD-010 | SCR-012, SCR-034 | TEST-057

### REQ-058 — Audit log
- Priority: Must · Source: A11.5-Q4a/b · Role: system writes; OW views (Standard+)
- Rules: records who, what record, which field, old value, new value, and when, for invoices, payments, refunds, reversals, stock, prices, discounts, settings, users, attendance edits, day reopen and support access. Nobody can edit or delete entries. Recording happens on all plans; viewing is Standard+ (PROPOSED). Entries are kept for the life of the account.
- Acceptance: Given the owner changed the selling price of a filter from 900 to 950, When the audit log is filtered by that item, Then one entry shows the user, the time and 900 → 950.
- Trace: MOD-010 | SCR-018 | TEST-058

### REQ-059 — Reports and exports
- Priority: Must · Source: brief outputs, A10 reports, A11.5-Q5 · Role: OW/MG per section 3 on SCR-014
- Reports (date-range filter, print, Excel export): daily cash closing; monthly revenue (parts, labour, tax, discounts, refunds); stock on hand and stock value (at cost — OW only); low stock; supplier ledger and dues (Standard+); customer dues; profit per part and per job (Premium, OW only); mechanic performance (Premium); payroll (Premium, OW only); no-show list (Standard+); message usage.
- Acceptance: Given March invoices with parts 300,000, labour 120,000 and discounts 10,000, When the monthly revenue report runs for March, Then it shows those totals and net 410,000.
- Trace: MOD-010 | SCR-014 | TEST-059

### REQ-060 — Owner dashboard
- Priority: Should · Source: brief outcome · Role: OW/MG on SCR-003/SCR-035
- Rules: today's job count per stage, today's collections by method, total customer dues, low-stock count, pending approvals, subscription status and WhatsApp messages waiting to be sent manually.
- Acceptance: Given 5 jobs In progress and 2 Ready, When the owner opens the dashboard, Then it shows 5 and 2 in those stage tiles.
- Trace: MOD-010 | SCR-003, SCR-035 | TEST-060

## 9. Business logic and constraints
| Rule | Value / formula | Owner-editable | Status |
|---|---|---|---|
| Plan prices | Basic 2,500 · Standard 5,000 · Premium 8,000 PKR/month; yearly = 10 × monthly | SA | CONFIRMED (DEC-025/026) |
| Customer messages | Push + WhatsApp (manual all plans; own connected account Standard+); no SMS; no platform quota | — | CONFIRMED (CR-002) |
| Trial | 14 days, Premium features | SA (extend) | CONFIRMED |
| Grace | 7 days full use, then read-only | — | CONFIRMED |
| Data after exit | 90 days then permanent deletion | — | CONFIRMED |
| Discount without approval | ≤ owner limit, default 5% | OW | CONFIRMED (default ASSUMED) |
| Inspection fee on rejection | owner-set PKR, may be 0 | OW | CONFIRMED |
| Storage charge | optional; after X free days (default 3), Rs Y per day | OW | CONFIRMED (defaults PROPOSED) |
| No-show block | after N no-shows (default 3) | OW | CONFIRMED (default ASSUMED) |
| No-show timeout | 30 min after slot start | — | PROPOSED |
| Booking window | today to 30 days ahead | OW | PROPOSED |
| Customer cancel cut-off | 1 hour before slot | OW | PROPOSED |
| Stock cost | weighted average purchase price | — | PROPOSED |
| Profit per line | (selling price − average cost) × qty − line discount share | — | PROPOSED |
| Tax | parts % × taxable parts + services % × taxable labour, rounded to whole rupees per invoice | OW | CONFIRMED (rounding PROPOSED) |
| Commission | % × labour of paid invoices in month, split equally between assigned mechanics | OW (%) | CONFIRMED (split PROPOSED) |
| Salary proration | salary ÷ days in month × paid days | — | PROPOSED |
| Money format | Rs with thousands separators, whole rupees on invoices | — | CONFIRMED / rounding PROPOSED |
| Numbering | job, invoice, credit-note numbers sequential per station, never reused | — | PROPOSED |

## 10. Content and data expectations
- Sources: staff entry, customer app, Excel import, barcode scans. No external data sources at launch.
- Retention: all station records are kept while the account is active. After closing: 90 days, then deleted. Audit log is kept for the life of the account.
- Backups: weekly (DEC-024). Up to 7 days of data could be lost in a disaster. This is a confirmed choice and is flagged as a risk (section 18).
- Owner can export all data to Excel at any time (REQ-013).
- Customer personal data: name, mobile, optional email/address, vehicles. No national ID or payment card numbers are stored by stations.

## 11. AI functionality (only if applicable)
Not applicable — no AI features are in the approved scope.

## 12. Reports, PDF, exports and printing
- Printed: invoice/receipt (A4 web, 58/80 mm Bluetooth from the staff app) and credit note (PROPOSED same layouts). The estimate and job card are digital and shareable as PDF.
- PDF share: invoice, estimate, supplier ledger, reports.
- Excel export: every report in REQ-059 and the full station export (REQ-013).
- All documents are in English, show the station logo and name, use DD/MM/YYYY, and show NTN/STRN when entered.

## 13. UI, accessibility and localization
- English only (A13-Q6). No RTL at launch. Pakistani formats: DD/MM/YYYY, Rs 1,250,000, 03XX-XXXXXXX, plates such as LEA-1234.
- Staff app: large tap targets (≥ 48 dp — PROPOSED), high contrast for workshop light, usable on a 5-inch screen, Android 8+, 2 GB RAM.
- Web dashboard: usable from 1280 px desktop down to tablet width (PROPOSED).
- Accessibility: text contrast ≥ 4.5:1 and no information conveyed by colour alone (stage chips also carry text) (PROPOSED).
- Offline cues: the staff app always shows online/offline status and the pending change count.

## 14. Security and non-functional outcomes
| Outcome | Measurable target | Status |
|---|---|---|
| Station data isolation | 0 cross-station records in isolation tests (TEST-003) | CONFIRMED rule |
| Role permissions | every row in section 3 enforced, verified by tests per role | CONFIRMED rule |
| Login protection | lock 15 minutes after 5 failed attempts; OTP valid 5 minutes | PROPOSED |
| Availability | 99.5% monthly for web and sync (excluding announced maintenance) | PROPOSED |
| Speed | common screens open within 3 seconds on a 4G connection; invoice print within 5 seconds | PROPOSED |
| Offline | mechanic work for 24 hours without connection, no data loss on reconnect | CONFIRMED |
| Backups | weekly, restorable; owner Excel export anytime | CONFIRMED |
| Audit | no editable or deletable audit entries | CONFIRMED |
| Privacy | SA sees no station records without an active grant | CONFIRMED |
| Capacity | up to 1,000 stations and 50 concurrent users per station at launch (PROPOSED) | PROPOSED |

## 15. Edge cases
- Customer rejects only some estimate lines → the approved lines proceed, rejected ones are kept as rejected (PROPOSED).
- The same vehicle is booked twice for the same time → the second booking is refused with "This vehicle already has a booking at 10:00".
- Price changed while a job is open → open estimates keep the old price, new lines use the new price (PROPOSED).
- Mechanic deactivated with open jobs → the owner must reassign before deactivation completes.
- Station goes read-only while mechanics have offline changes → kept on the phone, synced after renewal (REQ-009).
- Invoice paid then a warranty claim arrives → handled through REQ-027 without changing the paid invoice.
- Day closed, then a late payment arrives → it is recorded on today's date.
- Customer changes mobile number → staff update it; the customer app login moves to the new number after verification (PROPOSED).
- Excel import has duplicate plates → rows after the first are rejected with "Duplicate plate".
- Station's WhatsApp account is disconnected or its Meta payment method fails → automatic messages stop, events go to the manual "Messages to send" list, and the owner is notified once.

## 16. Realistic end-to-end acceptance scenarios
- **TEST-101 (J1, Standard):** Booking 10:00 → arrived 10:05 → intake 84,200 km → estimate Rs 6,500 (3.5 L oil @ 1,000, filter 900, labour 500, air filter 1,600) approved in app → mechanic offline adds parts → sync → QC pass → invoice Rs 6,500 → paid 6,500 JazzCash ref 7781 → Delivered. *Expected:* stock oil −3.5 L, filter −1, air filter −1; 4 WhatsApp messages sent from the station's connected account (confirmed, estimate, ready, invoice); day closing shows JazzCash 6,500.
- **TEST-102 (J2, Basic):** Walk-in, phone approval, discount 8% on Rs 10,000. *Expected:* cashier login blocked from finalising; owner login applies it; WhatsApp only as manual prefilled messages; Bluetooth receipt shows Rs 9,200.
- **TEST-103 (J4):** Invoice Rs 15,000, paid 12,000, credit release approved. *Expected:* Delivered; dues 3,000; reminder after 7 days; later payment 3,000 clears dues.
- **TEST-104 (J5):** Renewal 01/03 unpaid. *Expected:* 01–07/03 full use with reminders; 08/03 read-only; bank receipt uploaded 09/03, SA verifies → full access, renewal 01/04.
- **TEST-105 (J6, Premium):** March payroll as in REQ-053 acceptance. *Expected:* net Rs 28,000, sheet locked after finalise.
- **TEST-201 (device):** Staff app on Android 8, 2 GB RAM: log in, open 20 assigned jobs, go offline 24 h, add parts on 5 jobs, reconnect. *Expected:* all changes synced, no crash, conflicts reported to the manager.

## 17. MVP / future roadmap / exclusions
- **MVP:** REQ-001…REQ-062 except deprecated REQ-011 (Must + Should), web + Android staff app + Android customer app, one branch, English, PKR.
- **Next (from brief "later"):** iOS apps; multi-branch with transfers and branch-based plans; FBR e-invoicing; Urdu UI; Play Store listing; inspection photos; accounting integrations.
- **Excluded:** see section 4.

## 18. Risks, proposals and open questions
- **Risk:** direct-APK distribution — customers may not install apps from outside Play Store; app updates must be pushed manually. Confirmed choice.
- **Risk:** weekly backups → up to 7 days of data loss in a disaster. Confirmed choice; Stage 2 will price daily backups for comparison.
- **Risk:** Automatic WhatsApp needs the platform to join Meta's Tech Provider programme, and each station must complete Meta sign-up, add a payment method and use approved templates. Stations that don't connect fall back to manual sending.
- **Risk:** Basic plan has no approvals inbox, so money controls depend on the owner logging in (PROPOSED handling in section 3).
- **PROPOSED items for your review:** every rule tagged PROPOSED in sections 3–15. The most important are the Basic-plan owner-only controls, weighted average cost, the salary proration formula, the commission split between mechanics, the no-show 30-minute timeout and the customer cancel cut-off of 1 hour.

## 19. Traceability appendix
- See `TRACEABILITY_MATRIX.csv` for every `REQ → MOD → SCR → TEST` mapping. Plan tasks and blueprint sections will be filled in Stages 2 and 3.

## Review / approval
- Approval: APPROVED 2026-11-12 — user: "سب منظور" — scope: whole PRD v1.0 including all PROPOSED rules (DEC-027). Further changes need a change request in `DECISIONS.md`.
