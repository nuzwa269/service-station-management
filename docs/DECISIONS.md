# Decisions and Approvals — Car Service Station Management SaaS

> Brief version tracked: `PROJECT_CONCEPT_BRIEF.md` v1.2 (APPROVED; v1.1 = + CR-001, v1.2 = + CR-002). PRD tracked: `PRD.md` v1.1 (v1.0 + CR-002). Further changes need a change request below. v0.1 files archived in `archive/v0.1/`.

## Confirmed decisions
| Decision ID | Date | Decision | Evidence / user statement | Related REQs / Modules |
|---|---|---|---|---|
| DEC-001 | 2026-11-11 | Product is a Car Service Station Management SaaS | Initial request | All |
| DEC-002 | 2026-11-11 | User-required technology: Flutter + Dart for mobile (Stage 2 input) | Initial request "flutter, dart mobile app" | Mobile apps |
| DEC-003 | 2026-11-11 | User-required technology: Supabase backend (Stage 2 input) | Initial request "supabace" | Backend |
| DEC-004 | 2026-11-12 | Multi-tenant SaaS for independent stations | Round 1 selection | MOD-001 |
| DEC-005 | 2026-11-12 | Launch platforms: web app + Android; iOS deferred | Round 1 (web, Android, iOS) then iOS distribution answer "iOS later" | All clients |
| DEC-006 | 2026-11-12 | Users: super admin, station owner/manager, staff/mechanics, customers | Round 1 selection | MOD-001 |
| DEC-007 | 2026-11-12 | Country Pakistan, currency PKR only | Round 1 (A13-Q1) | MOD-002, MOD-006 |
| DEC-008 | 2026-11-12 | MVP modules: job cards + inspection, inventory, billing + payments, booking + history | Round 2 selection | MOD-003…MOD-007 |
| DEC-009 | 2026-11-12 | Self sign-up; 14-day full trial | A11.3-Q1, A11.3-Q2 | MOD-002 |
| DEC-010 | 2026-11-12 | Plans differ by features at launch; branch tiers later | A11.3-Q3 + clarification | MOD-002 |
| DEC-011 | 2026-11-12 | Monthly billing with yearly discount; stations pay via wallet, bank, card, cash | A11.3-Q4a/b | MOD-002 |
| DEC-012 | 2026-11-12 | 7-day grace, then read-only | A11.3-Q5 | MOD-002 |
| DEC-013 | 2026-11-12 | Station logo/name on documents; super admin sees usage only; exit = Excel export + delete after 90 days | A11.3-Q6/Q7/Q8 | MOD-001, MOD-002 |
| DEC-014 | 2026-11-12 | Android direct APK only; Android 8+ low-cost phones; push, barcode/QR, Bluetooth printer; no camera/photos | A11.4-Q1/Q2/Q5 + camera clarification | MOD-004, MOD-005 |
| DEC-015 | 2026-11-12 | Mechanic work offline up to 1 day incl. parts used; billing online; last change wins + manager notified | A11.4-Q3/Q4 + offline parts answer | MOD-004 |
| DEC-016 | 2026-11-12 | One branch per station at launch; Excel import / opening stock | A11.5-Q1, A11.5-Q2 | MOD-001, MOD-005 |
| DEC-017 | 2026-11-12 | Approvals for over-limit discount, refund/cancel, stock adjustment, credit release; audit log owner-only | A11.5-Q3/Q4 | MOD-010 |
| DEC-018 | 2026-11-12 | Daily cash closing + monthly reports; invoice is the only printed document; no integrations at launch | A11.5-Q5/Q6/Q8 | MOD-006, MOD-010 |
| DEC-019 | 2026-11-12 | Staff module: attendance, fixed salary, commission % of labour on paid invoices, advance deduction, performance report | A11.5-Q7 + payroll/commission answers | MOD-008 |
| DEC-020 | 2026-11-12 | Inventory: piece/litre/partial drum/kit; cost + selling price, profit owner-only; supplier ledger; customer-supplied parts | A10 inventory batch | MOD-005 |
| DEC-021 | 2026-11-12 | Billing: labour service list (editable), owner-set discount limit, full payment normally, credit only with approval, split payments | A10 billing batch + clarification | MOD-006 |
| DEC-022 | 2026-11-12 | Booking: customer auto-books free slots; capacity by bays and hours set by owner; repeated no-shows blocked | Booking + capacity answers, A12-Q6 | MOD-003 |
| DEC-023 | 2026-11-12 | Exceptions A12-Q1…Q7 as recorded in the brief | A12 batches | MOD-003…MOD-006 |
| DEC-025 | 2026-11-12 | Three plans (monthly, PKR): Basic 2,500 = job cards, billing/payments/credit, basic stock + low-stock alert, customer & vehicle history, daily cash closing, monthly report. Standard 5,000 = Basic + booking & customer app, WhatsApp/SMS/push, supplier ledger, approvals & audit log. Premium 8,000 = Standard + staff attendance/payroll/commission + profit reports. Sign-up, access, Excel export and trial in all plans; trial unlocks Premium features. | AI proposal accepted by user: "ٹھیک ہے۔ اور پیغامات کی حد کے لیے بھی چینج ریکویسٹ بنا دیں" | MOD-002 |
| DEC-026 | 2026-11-12 | Yearly plan = 2 months free (pay 10 months): Basic 25,000, Standard 50,000, Premium 80,000 PKR | Same user statement | MOD-002 |
| DEC-027 | 2026-11-12 | All rules tagged PROPOSED in PRD v0.1 accepted into the baseline (e.g. Basic-plan owner-only controls, weighted average cost, salary proration, equal commission split, 30-min no-show, 1-h cancel cut-off, trial quota 100) | User: "سب منظور" | All MODs |
| DEC-028 | 2026-11-13 | WhatsApp cost model: each station connects its own WhatsApp Business account (Meta bills the station) for automatic messages on Standard/Premium; manual WhatsApp from staff phones on all plans; no SMS for customer messages; no platform message quota (CR-002) | User: "jo whatsapp use krna chahta ha wo conect krwa lay" → clarified "دونوں طریقے"; "whatsapp kay sath sms ki zarorat nahi" | MOD-002, MOD-009 |
| DEC-029 | 2026-11-13 | Backups: Supabase daily backups (7-day retention) + weekly off-site copy | User selected "روزانہ + ہفتہ وار الگ کاپی (Recommended)" | Platform |
| DEC-030 | 2026-11-13 | Web dashboard and super admin in Flutter web | User selected "Flutter web (Recommended)" | All web screens |
| DEC-031 | 2026-11-13 | Offline mechanic work at launch with our own sync engine; PowerSync considered in a later version | User: "in next version" → clarified "لانچ پر آف لائن، PowerSync بعد میں" | MOD-004, REQ-023 |
| DEC-032 | 2026-11-13 | Hosting region Mumbai (ap-south-1) | User selected "ممبئی (Recommended)" | Platform |
| DEC-024 | 2026-11-12 | Local context: optional sales tax with NTN/STRN; customer payments cash/wallets/bank/card machine; WhatsApp + SMS + push; Pakistani formats; English only; owner's team supports and maintains; weekly backups; one customer login across linked stations | A13-Q2…Q7 + customer account answer | MOD-006, MOD-007, MOD-009 |

### Delegated (ASSUMED) items
| Item | Recommended default used | Asked in |
|---|---|---|
| Mobile app split (A11.4-Q6b) | Two apps: Staff app (role-based) + Customer app | Round 2 |
| Job card stages | Intake → estimate approval → in progress → quality check → ready → paid → delivered | Booking/job batch |
| No-show block limit | Owner-set, default 3, manager can unblock | Pricing batch |

### Pre-approval pivots (v0.1 → v0.2)
| Date | Change | Reason |
|---|---|---|
| 2026-11-12 | Stage 0 redone under skill v1.3.3; brief bumped to v0.2 | v0.1 predated A10–A13 packs and failed the validator |
| 2026-11-12 | iOS moved from launch to later | User chose direct APK and "iOS later" |
| 2026-11-12 | Inspection photos removed (v0.1 had photo capture) | User answered "no photos" |
| 2026-11-12 | Staff attendance/payroll/commission added (MOD-008) | A11.5-Q7 |
| 2026-11-12 | Booking module and super-admin subscription module added | Round 2, SaaS pack |

## Pending decisions
| Question | Options and tradeoffs | Affected artifacts | Blocking? |
|---|---|---|---|
| Team size for schedule estimate | ~8 months assumes 2 developers + part-time QA | IMPLEMENTATION_PLAN.md | No |
| SMS for login one-time codes (the only SMS use left after CR-002) | Approved with Stage 2 as default (SMS OTP); can switch to WhatsApp authentication template by change request | ARCHITECTURE.md §6 | No |

## Stage approval ledger
| Stage | Artifact and version | Status | Explicit approval evidence | Date |
|---|---|---|---|---|
| 0 Concept | PROJECT_CONCEPT_BRIEF.md v1.2 (CR-002) | APPROVED | User answers on 2026-11-13 (see CR-002) | 2026-11-13 |
| 0 Concept | PROJECT_CONCEPT_BRIEF.md v1.1 (CR-001) | APPROVED (superseded by v1.2) | User: "ٹھیک ہے۔ اور پیغامات کی حد کے لیے بھی چینج ریکویسٹ بنا دیں" | 2026-11-12 |
| 0 Concept | PROJECT_CONCEPT_BRIEF.md v1.0 (from draft v0.2) | APPROVED (superseded by v1.1) | User in chat: "ہاں، منظور ہے" — scope: whole brief, open items (plan prices, yearly discount) stay OPEN | 2026-11-12 |
| 1 PRD | PRD.md v1.1 (CR-002: REQ-011 deprecated, REQ-055 changed, REQ-061/062 added) | APPROVED | User answers on 2026-11-13 (see CR-002) | 2026-11-13 |
| 1 PRD | PRD.md v1.0 + TRACEABILITY_MATRIX.csv (60 REQs) | APPROVED (superseded by v1.1) | User in chat: "سب منظور" — scope: whole PRD incl. all PROPOSED rules | 2026-11-12 |
| 2 Implementation | ARCHITECTURE.md v1.0 + IMPLEMENTATION_PLAN.md v1.0 + TASKS.md v1.0 (75 tasks, all NOT_STARTED) | APPROVED | User in chat: "ہاں، منظور ہے" (2026-11-13) — scope: stack, architecture, plan and tasks; SMS used for login codes as the stated default | 2026-11-13 |
| 3 Blueprint | BLUEPRINT.md v1.0 + blueprint_data.json + PROJECT_BLUEPRINT.html/.pdf | APPROVED | User in chat: "ہاں، منظور ہے" (2026-11-13) — scope: whole blueprint as development handoff | 2026-11-13 |

> Approval rule: status stays PENDING until the user explicitly approves the stage. Individual answers do not approve the brief.

## Change requests (Post-Approval Revisions)
| Change ID | Requested change | Impact | Approved? | New artifact version |
|---|---|---|---|---|
| CR-002 | WhatsApp model replaces the message quota: (1) manual WhatsApp from staff phone with prefilled text on all plans; (2) automatic WhatsApp from the station's own connected WhatsApp Business account on Standard/Premium, billed by Meta to the station; (3) no SMS for customer messages; (4) no platform message quota or top-up packs (CR-001 superseded). | Brief: MOD-002, MOD-009, A11.3-Q3, A13-Q4. PRD: REQ-011 deprecated; REQ-055, REQ-007, REQ-012, REQ-020, REQ-040, REQ-049, REQ-060, plan matrix, SCR-019/023 changed; REQ-061, REQ-062 added. Stage 2: Meta Tech Provider + Embedded Signup, no message cost for the platform. | YES — user: "jo whatsapp use krna chahta ha wo conect krwa lay" → clarified "دونوں طریقے"; "whatsapp kay sath sms ki zarorat nahi" (2026-11-13) | Brief v1.1 → v1.2; PRD v1.0 → v1.1 |
| CR-001 | (SUPERSEDED by CR-002) Add a monthly WhatsApp+SMS message quota per plan (Basic 0 — no WhatsApp/SMS module; Standard 500; Premium 1,500). Messages beyond the quota need a purchased top-up pack. Push notifications unlimited. Plans now differ by features **and** message quota (previously features only, A11.3-Q3). | Brief: MOD-002, MOD-009, A11.3-Q3, core records row MOD-002. PRD: quota counter, warning near limit, behaviour at limit, top-up purchase. Stage 2: per-tenant message metering. Reason: each WhatsApp/SMS message has a real cost to the platform owner. | YES — user: "ٹھیک ہے۔ اور پیغامات کی حد کے لیے بھی چینج ریکویسٹ بنا دیں" (2026-11-12) | v1.0 → v1.1 |
