-- ============================================================
-- Migration 013: platform-owner functions (SaaS client management) - ROADMAP "Client (SaaS) management"
-- ============================================================
-- The platform owner is a login with the role super_admin, belonging to the company PLATFORM. It sees NO company's labor data (the table rules stay
-- per company); it only gets these functions, each checking the role itself:
--   platform_create_client(...)            new company: company row, Day + Night shifts, administrator login, punch terminal login + key
--   platform_list_clients()                every company with its status, subscription and simple counts
--   platform_set_client(...)               switch a company on / off, change subscription status / end date / tier
--   platform_reset_admin_password(...)     set a new password for a company's administrator
--   create_platform_owner(...)             ONE-TIME, run by the owner in the SQL editor: creates the PLATFORM company and the owner login
-- Logins are created straight in Supabase Auth with SQL (no Edge Function needed). Safe to run again.
-- ============================================================

-- internal: a Supabase Auth login with email + password (confirmed, ready to sign in)
create or replace function public._create_auth_user(p_email text, p_password text)
returns uuid language plpgsql security definer set search_path = public, auth, extensions as $$
declare v uuid := gen_random_uuid();
begin
    if exists (select 1 from auth.users where lower(email) = lower(p_email)) then
        raise exception 'That login already exists: %', lower(p_email) using errcode = 'P0001';
    end if;
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
    values ('00000000-0000-0000-0000-000000000000', v, 'authenticated', 'authenticated', lower(p_email), crypt(p_password, gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v, v::text, jsonb_build_object('sub', v::text, 'email', lower(p_email), 'email_verified', true, 'phone_verified', false), 'email', now(), now(), now());
    return v;
end;
$$;
revoke all on function public._create_auth_user(text, text) from public, anon, authenticated;

create or replace function public._require_owner()
returns void language plpgsql stable security definer set search_path = public as $$
begin
    if public.current_user_role() is distinct from 'super_admin' then raise exception 'not allowed' using errcode = '42501'; end if;
end;
$$;
revoke all on function public._require_owner() from public, anon, authenticated;

-- ONE-TIME (SQL editor): the PLATFORM company and the owner login.  select public.create_platform_owner('akhtar', 'a-long-password');
-- The owner then signs in with company code PLATFORM, this username and this password.
create or replace function public.create_platform_owner(p_username text, p_password text, p_name text default 'Platform owner')
returns text language plpgsql security definer set search_path = public, auth, extensions as $$
declare
    v_client uuid;
    v_user text := lower(btrim(p_username));
    v_auth uuid;
begin
    if v_user !~ '^[a-z0-9._-]{3,30}$' then raise exception 'username: 3 to 30 letters, digits, . _ -' using errcode = 'P0001'; end if;
    if length(coalesce(p_password, '')) < 10 then raise exception 'password: at least 10 characters' using errcode = 'P0001'; end if;
    select id into v_client from public.clients where upper(client_code) = 'PLATFORM';
    if v_client is null then
        insert into public.clients (business_name, client_code, plan, subscription_status, subscription_tier, is_active, subscribed_apps)
        values ('Platform (Arwa Enterprises)', 'PLATFORM', 'owner', 'premium', 'basic', true, array['platform']) returning id into v_client;
    end if;
    v_auth := public._create_auth_user(v_user || '@platform.dawam.arwaenterprises.com', p_password);
    insert into public.users (username, name, role, status, client_id, auth_id) values (v_user, p_name, 'super_admin', 'active', v_client, v_auth);
    return v_user || '@platform.dawam.arwaenterprises.com';
end;
$$;
revoke all on function public.create_platform_owner(text, text, text) from public, anon, authenticated;

-- a new company
create or replace function public.platform_create_client(p_name text, p_code text, p_admin_username text, p_admin_password text,
                                                          p_owner_name text default null, p_trial_days integer default 14)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare
    v_code text := upper(btrim(p_code));
    v_user text := lower(btrim(p_admin_username));
    v_client uuid;
    v_admin_auth uuid;
    v_term_auth uuid;
    v_tkey text;
    v_domain constant text := '.dawam.arwaenterprises.com';
begin
    perform public._require_owner();
    if length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'company name is required' using errcode = 'P0001'; end if;
    if v_code !~ '^[A-Z0-9]{2,10}$' or v_code = 'PLATFORM' then raise exception 'company code: 2 to 10 letters or digits' using errcode = 'P0001'; end if;
    if exists (select 1 from public.clients where upper(client_code) = v_code) then raise exception 'That company code is already used' using errcode = 'P0001'; end if;
    if v_user !~ '^[a-z0-9._-]{3,30}$' then raise exception 'administrator username: 3 to 30 letters, digits, . _ -' using errcode = 'P0001'; end if;
    if length(coalesce(p_admin_password, '')) < 10 then raise exception 'administrator password: at least 10 characters' using errcode = 'P0001'; end if;
    if p_trial_days is null or p_trial_days < 0 or p_trial_days > 3650 then raise exception 'trial days out of range' using errcode = 'P0001'; end if;

    insert into public.clients (business_name, client_code, owner_name, plan, subscription_status, subscription_tier, subscription_end_date, is_active, subscribed_apps)
    values (btrim(p_name), v_code, nullif(btrim(coalesce(p_owner_name, '')), ''), 'trial', 'trial', 'basic', current_date + p_trial_days, true, array['attendance'])
    returning id into v_client;
    perform public.ensure_default_shifts(v_client);

    v_admin_auth := public._create_auth_user(v_user || '@' || lower(v_code) || v_domain, p_admin_password);
    insert into public.users (username, name, role, status, client_id, auth_id) values (v_user, coalesce(nullif(btrim(coalesce(p_owner_name, '')), ''), 'Administrator'), 'admin', 'active', v_client, v_admin_auth);

    v_tkey := left(replace(replace(replace(encode(gen_random_bytes(40), 'base64'), '+', ''), '/', ''), '=', ''), 28);
    v_term_auth := public._create_auth_user('terminal@' || lower(v_code) || v_domain, v_tkey);
    insert into public.users (username, name, role, status, client_id, auth_id) values ('terminal', 'Punch Terminal', 'terminal', 'active', v_client, v_term_auth);
    insert into public.terminal_keys (client_id, key) values (v_client, v_tkey);

    return jsonb_build_object('client_id', v_client, 'client_code', v_code, 'admin_username', v_user, 'trial_ends', current_date + p_trial_days);
end;
$$;
revoke all on function public.platform_create_client(text, text, text, text, text, integer) from public, anon;
grant execute on function public.platform_create_client(text, text, text, text, text, integer) to authenticated;

-- every company with simple counts (no labor data)
create or replace function public.platform_list_clients()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
    perform public._require_owner();
    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', c.id, 'client_code', c.client_code, 'business_name', c.business_name, 'owner_name', c.owner_name,
            'subscription_status', c.subscription_status, 'subscription_tier', c.subscription_tier, 'subscription_end_date', c.subscription_end_date,
            'is_active', c.is_active, 'created_at', c.created_at, 'is_platform', upper(c.client_code) = 'PLATFORM',
            'laborers', (select count(*) from public.laborers l where l.client_id = c.id and l.status = 'active'),
            'last_punch', (select max(p.date) from public.punch_records p where p.client_id = c.id),
            'admin_username', (select u.username from public.users u where u.client_id = c.id and u.role = 'admin' and u.status = 'active' limit 1),
            'terminal_ready', exists (select 1 from public.terminal_keys k where k.client_id = c.id)
        ) order by (upper(c.client_code) = 'PLATFORM'), c.created_at desc)
        from public.clients c), '[]'::jsonb);
end;
$$;
revoke all on function public.platform_list_clients() from public, anon;
grant execute on function public.platform_list_clients() to authenticated;

-- switch on / off, subscription. NULL = leave as it is. Status "premium" has no end date.
create or replace function public.platform_set_client(p_client uuid, p_is_active boolean default null, p_status text default null,
                                                       p_end_date date default null, p_tier text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
    perform public._require_owner();
    if not exists (select 1 from public.clients where id = p_client) then raise exception 'unknown company' using errcode = 'P0001'; end if;
    if p_status is not null and p_status not in ('trial', 'active', 'premium', 'expired') then raise exception 'status: trial, active, premium or expired' using errcode = 'P0001'; end if;
    if p_tier is not null and p_tier !~ '^[a-z0-9_-]{1,20}$' then raise exception 'tier: letters, digits, - or _' using errcode = 'P0001'; end if;
    if p_is_active is false and exists (select 1 from public.clients where id = p_client and upper(client_code) = 'PLATFORM') then
        raise exception 'The platform company cannot be switched off' using errcode = 'P0001';
    end if;
    update public.clients set
        is_active = coalesce(p_is_active, is_active),
        subscription_status = coalesce(p_status, subscription_status),
        subscription_end_date = case when p_status = 'premium' then null else coalesce(p_end_date, subscription_end_date) end,
        subscription_tier = coalesce(p_tier, subscription_tier),
        updated_at = now()
    where id = p_client;
end;
$$;
revoke all on function public.platform_set_client(uuid, boolean, text, date, text) from public, anon;
grant execute on function public.platform_set_client(uuid, boolean, text, date, text) to authenticated;

-- a new password for the company's administrator (the owner tells the administrator)
create or replace function public.platform_reset_admin_password(p_client uuid, p_password text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_auth uuid;
begin
    perform public._require_owner();
    if length(coalesce(p_password, '')) < 10 then raise exception 'password: at least 10 characters' using errcode = 'P0001'; end if;
    select auth_id into v_auth from public.users where client_id = p_client and role = 'admin' and status = 'active' and auth_id is not null limit 1;
    if v_auth is null then raise exception 'This company has no administrator login' using errcode = 'P0001'; end if;
    update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = v_auth;
end;
$$;
revoke all on function public.platform_reset_admin_password(uuid, text) from public, anon;
grant execute on function public.platform_reset_admin_password(uuid, text) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  013  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 013 applied' as result, (select count(*) from pg_proc where proname like 'platform\_%') as platform_functions;
