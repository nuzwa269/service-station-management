# Release, install, backups and launch — TASK-071…075

## 1. Building the Android apps (TASK-072)
Release APKs are signed with the station SaaS keystore:
- Keystore: `config/keys/station-release.jks` (alias `station`), created 2026-11-16.
- Passwords: `apps/staff/android/key.properties` and `apps/customer/android/key.properties`.
- Both are **gitignored**. If the keystore is lost, installed apps can never be updated again —
  every phone would have to uninstall and reinstall. **Copy the `.jks` file and one
  `key.properties` to two offline places** (e.g. a USB drive in the office and a private cloud
  folder the owner controls).

Build (PowerShell, from the repository root):
```
$env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=C:\Android\tmp -Djava.io.tmpdir=C:\Android\tmp"
cd apps/staff;    flutter build apk --release --dart-define-from-file=../../config/staging.json
cd ../customer;   flutter build apk --release --dart-define-from-file=../../config/staging.json
```
For production use `config/production.json` (same keys as `config/example.json`). Raise the
`version: x.y.z+N` line in each `pubspec.yaml` before every release; `N` must always go up.
Add `FIREBASE_*` and `META_*` ids to the config file when those accounts exist.

## 2. Publishing an update (in-app updater)
1. Upload the signed APK to a public https link (e.g. a Supabase Storage public bucket `releases`).
2. Web → Platform admin → **App releases** → Publish build: build number `N`, version, link,
   and "oldest allowed" (raise it only when old builds must stop working).
3. On next start each phone shows *Update available* (or *Update required* below the minimum).

## 3. Installing on a phone (install guide for stations)
1. Open the download link on the phone (WhatsApp it to staff).
2. Android asks to allow installs from this source (Chrome / Files / WhatsApp) → **Allow**.
3. Open the file → **Install** → Open.
4. Staff app: log in with mobile + password from the owner. Customer app: mobile + SMS code.
5. Android 8 phones: Settings → Security → *Unknown sources* must be on.

## 4. Device test TEST-201 (TASK-071) — needs a real Android 8 / 2 GB phone
Log in as a mechanic, open 20 assigned jobs, turn on airplane mode for 24 h, add parts on 5 jobs,
reconnect. Pass = all changes synced, no crash, conflicts appear as manager notifications. Repeat
receipt printing on a 58 mm and an 80 mm Bluetooth printer. Done so far: staff app on a TECNO
CI8n (Android 12) — login, dashboard, messages and alerts load from staging.

## 5. Backups and restore drill (TASK-073)
- Daily backups: Supabase Pro keeps 7 days (Dashboard → Database → Backups). Confirm the plan.
- Weekly off-site copy: every Monday run
  `pg_dump "<connection string from Dashboard → Connect>" -Fc -f station-YYYY-MM-DD.dump`
  on the owner's computer and keep 8 weeks in a separate cloud folder. The database password
  never goes into the repository or chat.
- Restore drill each quarter: create a scratch Supabase project, `pg_restore` the latest dump,
  run `DATABASE_URL=<scratch> node tools/db-check/run.mjs isolation` and log in to the web app
  pointed at it. Record date, dump size and time taken here.

## 6. Pilot (TASK-074)
2–3 real stations for at least 4 weeks on staging: one Basic, one Standard with WhatsApp
connected, one Premium using payroll. Weekly call, fix list in TASKS.md, a support WhatsApp
number, and short screen videos: new job card, estimate approval, invoice and payment, day
closing, payroll. Exit = written sign-off from each owner.

## 7. Go-live checklist (TASK-075)
- [ ] Production Supabase project (Mumbai), Pro plan, backups on; all `dashboard_phase*.sql` run in order.
- [ ] Auth: phone provider with the SMS aggregator (TASK-005); rate limits — 5 failed logins → 15 min lock; OTP expiry 300 s.
- [ ] Edge Functions deployed with secrets; webhooks tested signed/unsigned (SEC-03).
- [ ] Vault secrets `project_url`, `dispatch_secret`; pg_cron + pg_net enabled; cron jobs listed in `cron.job`.
- [ ] Meta Tech Provider app live (TASK-004); Firebase project for push.
- [ ] Payment aggregator live keys (TASK-006); subscription renewal tested end to end.
- [ ] Web app built with the production config and hosted on https; custom domain.
- [ ] Signed APKs published through App releases; keystore copies verified (section 1).
- [ ] Monitoring: Sentry DSN in the apps, Supabase log alerts, uptime check on web and API.
- [ ] Restore drill done once on production backups.
