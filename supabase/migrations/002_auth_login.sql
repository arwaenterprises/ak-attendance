-- ============================================================
-- Migration 002: login through Supabase Auth, one admin per client (ROADMAP S2; tasks 14, 26, 47)
-- ============================================================
-- Run AFTER 001. Tested on local Postgres (tests/db). NOT yet applied to any Supabase project.
--
-- How login works after this:
--   * the app signs in with Supabase Auth using the email  <username>@<company code>.dawam.arwaenterprises.com  and the password
--     (the person still types Company code + Username + Password; the email is built by the app, nothing is ever sent to it)
--   * an Auth account only gets access to data once it is LINKED to a company with  public.link_admin_profile(...)
--     (run by the platform owner in the SQL editor). Nobody can link themselves, so even if public sign-up were left on,
--     a stranger who registers an address would see nothing.
-- ============================================================

-- 1. passwords now live in Supabase Auth, not in our table
alter table public.users alter column password_hash drop not null;

-- 2. a username only has to be unique inside its company (two companies can both have "admin")
alter table public.users drop constraint if exists users_username_key;
alter table public.users add constraint users_client_username_key unique (client_id, username);

-- 3. exactly one ACTIVE admin per company (to replace an admin: set the old one inactive, then add the new one)
--    If this fails on an existing database, that company has several active admins: decide who stays, then re-run.
create unique index if not exists users_one_admin_per_client on public.users (client_id) where role = 'admin' and status = 'active';

-- 4. settings: unique per company + key (was: key alone, so two companies could not both have "night_shift_start")
alter table public.settings alter column client_id set not null;
alter table public.settings drop constraint if exists settings_pkey;
alter table public.settings add primary key (client_id, key);

-- 5. a company that is deactivated or whose subscription ended gets no data access at all (enforced here, not only in the app)
create or replace function public.current_client_id()
returns uuid language sql stable security definer set search_path = public as $$
    select u.client_id
    from public.users u join public.clients c on c.id = u.client_id
    where u.auth_id = auth.uid()
      and u.status = 'active'
      and c.is_active
      and c.subscription_status is distinct from 'expired'
      and (c.subscription_status = 'premium' or c.subscription_end_date is null or c.subscription_end_date >= current_date)
    limit 1
$$;
create or replace function public.current_user_role()
returns text language sql stable security definer set search_path = public as $$
    select u.role
    from public.users u join public.clients c on c.id = u.client_id
    where u.auth_id = auth.uid() and u.status = 'active' and c.is_active
      and c.subscription_status is distinct from 'expired'
      and (c.subscription_status = 'premium' or c.subscription_end_date is null or c.subscription_end_date >= current_date)
    limit 1
$$;

-- 6. platform-owner command: link an Auth account to a company (creates the admin profile, or links an existing one)
--    Usage (SQL editor):  select public.link_admin_profile('TEST', 'admin', 'Test Admin');
--    The Auth account (Authentication > Users > Add user) must exist first, with email  admin@test.dawam.arwaenterprises.com
create or replace function public.link_admin_profile(p_client_code text, p_username text, p_name text default null)
returns text language plpgsql security definer set search_path = public, auth as $$
declare
    v_client uuid;
    v_email  text;
    v_auth   uuid;
    v_user   text := lower(btrim(p_username));
begin
    select id into v_client from public.clients where upper(client_code) = upper(btrim(p_client_code));
    if v_client is null then raise exception 'unknown company code: %', p_client_code; end if;
    v_email := v_user || '@' || lower(btrim(p_client_code)) || '.dawam.arwaenterprises.com';
    select id into v_auth from auth.users where lower(email) = v_email;
    if v_auth is null then raise exception 'create the Auth account first (Authentication > Users > Add user) with email: %', v_email; end if;

    update public.users set auth_id = v_auth, status = 'active' where client_id = v_client and username = v_user;
    if not found then
        insert into public.users (username, name, role, status, client_id, auth_id)
        values (v_user, coalesce(p_name, p_username), 'admin', 'active', v_client, v_auth);
    end if;
    return v_email;
end;
$$;
revoke all on function public.link_admin_profile(text, text, text) from public, anon, authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  002  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================
