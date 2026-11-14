-- HOTFIX (run now in the Supabase SQL Editor). Also included in migration 16.
-- admin_add_member must be callable by the invite-member Edge Function (service role) only.
-- Supabase grants EXECUTE on public functions to "authenticated" by default, which let any
-- logged-in user call it directly.
revoke execute on function public.admin_add_member(uuid, uuid, uuid, text, text, public.member_role) from authenticated;
