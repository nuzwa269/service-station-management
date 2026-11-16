# Go-live setup: SMS gateway, production Supabase, Vercel

## A. SMS gateway phone (TASK-005) — login codes from the platform's own SIM
What you need: a spare Android 8+ phone, a Jazz/Zong/Telenor/Ufone SIM with an SMS bundle,
a charger and Wi-Fi or mobile data.

1. **Database** (staging first): run `supabase/dashboard_sms_gateway.sql` in the SQL Editor.
2. **Edge Functions** (Dashboard → Edge Functions → Deploy a new function → Via editor):
   - name `send-sms`, paste `supabase/functions/send-sms/index.ts`, turn **off** "Verify JWT".
   - name `sms-gateway`, paste `supabase/functions/sms-gateway/index.ts`, turn **off** "Verify JWT".
3. **Secrets** (Edge Functions → Secrets): `GATEWAY_SECRET` = the value in
   `config/sms-gateway.json` (gitignored, created for you).
4. **Auth hook** (Authentication → Hooks → Send SMS hook → HTTPS):
   URL `https://<project>.supabase.co/functions/v1/send-sms` → Generate secret → save. Copy the
   secret (`v1,whsec_…`) into Edge Function secret `SEND_SMS_HOOK_SECRET` and into
   `config/sms-gateway.json`. Make sure Authentication → Sign In / Providers → Phone is enabled.
5. **Gateway phone**: install `dist/sms-gateway-1.0.0.apk`, open it → *Allow sending SMS* →
   server address (filled in) and the gateway secret → **Start**. Keep it on the charger with the
   app open (the screen stays on). Settings → Battery → exclude *SMS Gateway* from battery saving.
6. **Check**: put your mobile in `TEST_PHONE` in `config/sms-gateway.json`, then run
   `node tools/db-check/sms-hook-check.mjs` — the phone should send a `000000` test code to you.
   Platform admin → App releases shows *SMS gateway: online* and today's counts.

Limits: at most 5 codes per number per hour; codes older than 5 minutes are dropped; if the
phone is off, nobody new can log in by code (staff password login still works). When volume
grows, set `SMS_PROVIDER=http`, `SMS_HTTP_URL`, `SMS_HTTP_KEY` for an SMS aggregator — no app change.

## B. Production Supabase project
1. supabase.com → New project → region **South Asia (Mumbai)**, Pro plan (daily backups).
2. SQL Editor → paste `supabase/production_setup.sql` (all migrations 1–23) → Run once.
3. Authentication: enable Phone; Send SMS hook as in A.4; Rate limits: OTP expiry 300 s,
   lock after 5 failed logins (SEC-02). Site URL = the Vercel web address.
4. Make the platform admin: sign up the admin phone in the web app, then in SQL Editor:
   `update public.profiles set is_super_admin = true where mobile = '03xxxxxxxxx';`
5. Deploy all Edge Functions (`notify-dispatch`, `whatsapp-*`, `payment-webhook`,
   `storage-cleanup`, `invite-member`, `send-sms`, `sms-gateway`) with their secrets.
6. Copy Project URL and the **publishable** key into `config/production.json`
   (same shape as `config/example.json`). Never put the service-role key or DB password there.

## C. Web dashboard on Vercel
The web dashboard is a static Flutter web build, so Vercel hosts it as a static site.
1. vercel.com → Add New → Project → *Import* is not needed; create an empty project named
   `station-dashboard` (Framework: Other). Note its Project ID and Team/Org ID (Settings).
2. Create a Vercel token (Account → Tokens).
3. GitHub repository → Settings → Secrets and variables → Actions → add:
   `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `PROD_SUPABASE_URL`,
   `PROD_SUPABASE_PUBLISHABLE_KEY` (and `META_APP_ID`, `META_CONFIG_ID` later).
4. GitHub → Actions → **Deploy web** → Run workflow (production). The workflow builds
   `apps/web` with Flutter 3.47.8 and uploads `build/web`; `web/vercel.json` adds the
   single-page rewrite and security headers.
5. Add your domain in Vercel → Domains, then set Supabase Auth Site URL to it.

## D. Phone apps for production
Build with `--dart-define-from-file=../../config/production.json` (see RELEASE_GUIDE.md §1),
upload the APKs, and publish them in Platform admin → App releases on the production project.
