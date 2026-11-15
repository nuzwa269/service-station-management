# Security review — TASK-068 (2026-11-16)

Scope: database (RLS, functions, grants), Edge Functions, apps' handling of keys, login.
Method: automated threat-model checks in `supabase/tests/test_phase9_security.sql` (run in CI on
every change) plus a manual read of the code paths below.

## Automated checks (all pass)
| ID | Rule | Test |
|---|---|---|
| T1 | Every `SECURITY DEFINER` function pins `search_path` | catalog scan of `public` and `private` |
| T2 | App roles (`anon`, `authenticated`) have no INSERT/UPDATE/DELETE/TRUNCATE on any table or view | catalog scan |
| T3 | Nothing in `public` is callable without login | catalog scan |
| T4 | `private` tables (Meta tokens, counters) are not readable by app roles | catalog scan |
| T5 | Money and stock ledgers are append-only (stock_movements, payments, credit_notes, job_history, salary_advances, audit_log) | trigger check |
| T6 | Super admin sees no station data without a support grant (REQ-005) | role test |
| TEST-003 | No cross-station rows for owner, mechanic, other owner or customer in every table and view | `test_003_isolation.sql` |
| svc_* | Service-role functions (dispatcher, webhooks) are not callable by users | `test_phase7_messages.sql` |

## Findings
| ID | Severity | Finding | Status |
|---|---|---|---|
| SEC-01 | Medium | Supabase default grants left `TRUNCATE` on every table, and INSERT/UPDATE/DELETE on views, for `anon`/`authenticated`. Not reachable through the REST API (PostgREST never sends TRUNCATE; views are not auto-updatable through revoked base tables), but TRUNCATE ignores RLS. | **Fixed** in migration 22; T2 now fails CI if it comes back. |
| SEC-02 | Low | Login lockout (5 failed attempts → 15 min) and OTP validity (5 min) are Supabase Auth settings, not code. | **Open — config**: set in Supabase dashboard → Authentication → Rate limits / Phone (see checklist). |
| SEC-03 | Low | Edge Functions (`notify-dispatch`, `whatsapp-connect`, `whatsapp-webhook`, `payment-webhook`) were not type-checked or run here (no Deno locally). Signature checks are HMAC-SHA256 with constant-time compare. | **Open**: deploy to staging and send a signed and an unsigned request to each webhook before go-live. |
| SEC-04 | Info | The Meta access token per station is stored in `private.whatsapp_tokens` (not exposed by the API, unreadable by app roles — T4). Vault encryption would add at-rest protection. | Accepted for launch; revisit with TASK-004. |
| SEC-05 | Info | Release keystore and its password are on the build computer only (`config/keys/`, `apps/*/android/key.properties`, both gitignored). | **Action for owner**: copy both to two offline places (see RELEASE_GUIDE.md). |

No open High findings.

## Manual review notes
- Apps hold only the publishable key; the service-role key is used only inside Edge Functions.
- Every write is a function that checks role → plan/read-only → validation → write → audit.
- Webhooks: payment re-queries the provider before confirming; WhatsApp webhook checks
  `X-Hub-Signature-256`; dispatcher requires `DISPATCH_SECRET` or the service-role key.
- Customer app reads only through `customer_*` functions matched to the verified phone.
- Payroll pay columns are hidden from managers by column privileges on top of RLS.
