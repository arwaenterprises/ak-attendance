-- ============================================================
-- LIVE 000: prepare the LIVE project for the attendance-only security rules (ROADMAP S5)
-- ============================================================
-- Run ONLY on the LIVE project (address contains kyktwzwiraipwyglkhva), as the first part of live-cutover-bundle.sql, in the planned window.
-- Written from the real structure of the live project (export of 2026-10-02). Tested on a local copy that imitates it (tests/db/live-like.*).
-- NOTHING IS DELETED by this file:
--   * the pharmacy, expense and admin tables are MOVED to a separate schema "archive_other_apps" (not reachable through the app's public API).
--     To restore one:  alter table archive_other_apps.<name> set schema public;
--     To delete them for good (only when you are sure):  drop schema archive_other_apps cascade;
--   * the old "allow everything" rules are removed (the new rules replace them),
--   * the supervisors are set to inactive (kept for history; they have no new login, so they cannot sign in).
-- ============================================================

-- 0. safety: this must look like the live attendance project
do $$ begin
    if to_regclass('public.laborers') is null or to_regclass('public.punch_records') is null or to_regclass('public.clients') is null then
        raise exception 'This does not look like the attendance database (laborers / punch_records / clients missing). Stopping.';
    end if;
end $$;

-- 1. other apps: move their tables out of the public API
create schema if not exists archive_other_apps;
do $$
declare t text;
begin
    foreach t in array array['medicines','stock','stock_invoices','stock_invoice_items','sales','sale_items','suppliers','payments','admin_users',
                             'exp_app_settings','exp_budgets','exp_categories','exp_currencies','exp_expenses']
    loop
        if to_regclass('public.' || t) is not null then
            execute format('alter table public.%I set schema archive_other_apps', t);
        end if;
    end loop;
end $$;
revoke all on schema archive_other_apps from public, anon, authenticated;

-- 2. remove EVERY old rule (live has permissive "Allow all ..." rules under other names than the staging ones)
do $$
declare r record;
begin
    for r in select schemaname, tablename, policyname from pg_policies where schemaname = 'public' loop
        execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
    end loop;
    for r in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' loop
        execute format('drop policy %I on storage.objects', r.policyname);
    end loop;
end $$;

-- 3. one admin per company: supervisors are retired (kept, inactive, no login). Their old status is saved so the rollback can restore it.
create table if not exists archive_other_apps.supervisor_status_backup (id uuid primary key, status text, saved_at timestamptz default now());
insert into archive_other_apps.supervisor_status_backup (id, status) select id, status from public.users where role = 'supervisor' on conflict (id) do nothing;
update public.users set status = 'inactive' where role = 'supervisor';
