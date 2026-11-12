# Phase 0 — what needs the owner's accounts or real devices

Code for TASK-001 is in this repository. The tasks below need accounts, money or phones,
so they are **NOT_STARTED** until you do them (or give access).

| Task | What you do | What to bring back |
|---|---|---|
| TASK-002 | Supabase staging project exists (`scgtziwibylpmphzkwbw`). **Check its region is Mumbai (ap-south-1)** in Project Settings → General. Create a separate production project later. | Region, plan, compute size and current prices for the cost table |
| TASK-002 (apply) | Install Supabase CLI (`npm i -g supabase`) and run `supabase login`, then `supabase link --project-ref scgtziwibylpmphzkwbw` (asks for the database password — type it yourself), then `supabase db push` and `supabase functions deploy invite-member` | Output of `db push` |
| TASK-002 (auth) | Authentication → Providers → Phone: enable phone sign-up. Until an SMS provider is set, add test numbers + codes under "Phone numbers for testing" | — |
| TASK-003 | Choose web hosting and domain (web dashboard, super admin, APK downloads over HTTPS) | Domain name, hosting choice |
| TASK-004 | Register as Meta Tech Provider; create a test WhatsApp Business account | Approval status |
| TASK-005 | Pick a local SMS aggregator for login codes; we connect it via Supabase Auth "Send SMS" hook | Vendor, price per SMS, API docs |
| TASK-006 | Apply for a payment aggregator merchant account (JazzCash, Easypaisa, cards) | Sandbox credentials (kept in Edge Function secrets only) |
| TASK-007 | Lend a real Android 8 / 2 GB phone for the offline-sync spike | — |
| TASK-008 | Nothing — web load-time spike runs after first deploy | — |
| TASK-009 | A 58 mm and an 80 mm Bluetooth ESC/POS printer, and a barcode on a part | — |

Never paste the service-role key or database password into chat or into the apps.
