-- ============================================================
-- Migration 012: every company's administrator gets the punch terminal link inside the app (SaaS: no key handling by the platform owner)
-- ============================================================
-- * terminal_keys: the key of the company's terminal login, readable ONLY by that company's administrator (never by the terminal, never by the public key).
-- * get_terminal_key(): administrator only. Returns the company's key (and code) so the page can build  .../punch/?client=CODE#key=KEY .
--   The first time (no key yet) a new random key is created and set as the password of the company's terminal login.
-- * get_terminal_key(true): makes a NEW key (all devices must open the new link once). get_terminal_key(false, 'my own key'): sets a key the administrator chose.
-- The terminal login itself (Authentication > Users, linked with link_terminal_profile) is still created once per company by the platform owner
-- (the platform-owner page will do that); this migration only lets the company administrator read and renew its key.
-- Safe to run again.
-- ============================================================

create table if not exists public.terminal_keys (
    client_id  uuid primary key references public.clients (id) on delete cascade,
    key        text not null check (length(key) >= 20),
    rotated_at timestamptz not null default now()
);
alter table public.terminal_keys enable row level security;
drop policy if exists "admin reads own terminal key" on public.terminal_keys;
create policy "admin reads own terminal key" on public.terminal_keys for select to authenticated
    using (client_id = (select public.current_client_id()) and (select public.current_user_role()) in ('admin', 'super_admin'));
revoke all on public.terminal_keys from public, anon, authenticated;
grant select on public.terminal_keys to authenticated;

-- sets the key as the password of the company's terminal login and remembers it
create or replace function public._set_terminal_key(p_client uuid, p_key text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_auth uuid;
begin
    select auth_id into v_auth from public.users where client_id = p_client and role = 'terminal' and status = 'active' and auth_id is not null limit 1;
    if v_auth is null then
        raise exception 'The punch terminal login is not set up for this company yet. Please contact support.' using errcode = 'P0001';
    end if;
    update auth.users set encrypted_password = crypt(p_key, gen_salt('bf')), updated_at = now() where id = v_auth;
    insert into public.terminal_keys (client_id, key, rotated_at) values (p_client, p_key, now())
    on conflict (client_id) do update set key = excluded.key, rotated_at = now();
end;
$$;
revoke all on function public._set_terminal_key(uuid, text) from public, anon, authenticated;

create or replace function public.get_terminal_key(p_new boolean default false, p_set text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
    v_client uuid := public.current_client_id();
    v_key text;
    v_code text;
    v_created boolean := false;
begin
    if v_client is null or public.current_user_role() not in ('admin', 'super_admin') then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    if p_set is not null and p_set !~ '^[A-Za-z0-9_-]{20,64}$' then
        raise exception 'The key must be 20 to 64 letters, digits, - or _' using errcode = 'P0001';
    end if;
    select client_code into v_code from public.clients where id = v_client;
    select key into v_key from public.terminal_keys where client_id = v_client;
    if v_key is null or coalesce(p_new, false) or p_set is not null then
        -- p_set = a key the administrator chose; otherwise 28 random letters and digits (nothing that needs special handling in a web address)
        v_key := coalesce(p_set, left(replace(replace(replace(encode(gen_random_bytes(40), 'base64'), '+', ''), '/', ''), '=', ''), 28));
        perform public._set_terminal_key(v_client, v_key);
        v_created := true;
    end if;
    return jsonb_build_object('client_code', v_code, 'key', v_key, 'created', v_created);
end;
$$;
revoke all on function public.get_terminal_key(boolean, text) from public, anon;
grant execute on function public.get_terminal_key(boolean, text) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  012  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 012 applied' as result,
       (select count(*) from pg_proc where proname = 'get_terminal_key') as function_present,
       (select count(*) from pg_extension where extname = 'pgcrypto') as pgcrypto;
