# deploy/web — the built web dashboard for Vercel

This folder is the output of `flutter build web --release` (apps/web), committed so Vercel can
serve it straight from GitHub without installing Flutter. Vercel project settings:
Root Directory `./` (the repository root): the root `vercel.json` skips install and build and serves `deploy/web` only, so the source code is never published.

Update: rebuild apps/web, copy `apps/web/build/web/*` here, commit and push — Vercel redeploys.
It contains only public values (Supabase URL and publishable key); no secrets.
