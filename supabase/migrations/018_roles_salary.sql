-- ============================================================
-- Migration 018: roles (managed list) and salary history (owner decisions, 2026-10-05)
-- ============================================================
-- * roles: every company has its own list (name, default monthly salary, overtime rate per hour, one default role).
--   A company that does not only deal in "labors" defines its own roles (Driver, Cashier ...).
-- * laborers.role_id points at a role; the old text column laborers.role is kept in step with the role name (older screens keep working).
-- * labor_salaries: the salary history of each labor, "from this date on". The salary on any day = the latest entry up to that day.
--   Reports, the monthly billing and the exports read this history, so one change reaches every place, and old months keep old salaries.
-- * A new labor gets the salary typed at creation; if none is typed, the default salary of its role.
-- * Everyone that exists today keeps exactly their current salary (a starting entry dated 2000-01-01), so no past month changes.
-- * Overtime rates move into the role (roles.ot_rate_per_hour); the old ot_rates table is left in place, not used any more.
-- * Salaries are for administrators only: the salary history table cannot be read by supervisors or the terminal.
-- Safe to run again.
-- ============================================================

-- 1. tables
create table if not exists public.roles (
    id                     uuid primary key default gen_random_uuid(),
    client_id              uuid not null references public.clients (id),
    name                   text not null check (length(btrim(name)) between 1 and 60),
    default_monthly_salary numeric not null default 0 check (default_monthly_salary >= 0 and default_monthly_salary <= 10000000),
    ot_rate_per_hour       numeric not null default 0 check (ot_rate_per_hour >= 0 and ot_rate_per_hour <= 100000),
    is_default             boolean not null default false,
    status                 text not null default 'active' check (status in ('active', 'inactive')),
    created_at             timestamptz not null default now(),
    updated_at             timestamptz not null default now()
);
create unique index if not exists roles_name_unique on public.roles (client_id, lower(btrim(name)));
create unique index if not exists roles_one_default on public.roles (client_id) where is_default;
drop trigger if exists update_roles_updated_at on public.roles;
create trigger update_roles_updated_at before update on public.roles for each row execute function public.update_updated_at();

create table if not exists public.labor_salaries (
    id             uuid primary key default gen_random_uuid(),
    client_id      uuid not null references public.clients (id),
    labor_id       text not null,
    from_date      date not null,
    monthly_salary numeric not null check (monthly_salary >= 0 and monthly_salary <= 10000000),
    created_at     timestamptz not null default now(),
    unique (client_id, labor_id, from_date)
);
create index if not exists idx_labor_salaries_labor on public.labor_salaries (client_id, labor_id, from_date);

alter table public.laborers add column if not exists role_id uuid references public.roles (id);
create index if not exists idx_laborers_role on public.laborers (role_id);
-- the old fixed default of 3000: a new labor without a typed salary now takes the default of its role
alter table public.laborers alter column monthly_salary drop default;

-- 2. who may touch what
alter table public.roles enable row level security;
alter table public.labor_salaries enable row level security;
drop policy if exists "tenant roles read" on public.roles;
drop policy if exists "tenant roles write" on public.roles;
drop policy if exists "tenant roles" on public.roles;
create policy "tenant roles read" on public.roles for select to authenticated
    using (client_id = (select public.current_client_id()) and (select public.is_staff()));
create policy "tenant roles write" on public.roles for all to authenticated
    using (client_id = (select public.current_client_id()) and (select public.current_user_role()) in ('admin', 'super_admin'))
    with check (client_id = (select public.current_client_id()) and (select public.current_user_role()) in ('admin', 'super_admin'));
drop policy if exists "tenant labor_salaries" on public.labor_salaries;
create policy "tenant labor_salaries" on public.labor_salaries for all to authenticated
    using (client_id = (select public.current_client_id()) and (select public.current_user_role()) in ('admin', 'super_admin'))
    with check (client_id = (select public.current_client_id()) and (select public.current_user_role()) in ('admin', 'super_admin'));
revoke all on public.roles, public.labor_salaries from public, anon;
grant select, insert, update, delete on public.roles, public.labor_salaries to authenticated;

-- 3. every company gets one default role
create or replace function public.ensure_default_roles(p_client uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
    if not exists (select 1 from roles where client_id = p_client) then
        insert into roles (client_id, name, default_monthly_salary, ot_rate_per_hour, is_default) values (p_client, 'Labor', 3000, 15, true);
    end if;
end;
$$;
revoke all on function public.ensure_default_roles(uuid) from public, anon, authenticated;

create or replace function public.clients_default_roles() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.ensure_default_roles(new.id); return new; end;
$$;
drop trigger if exists clients_default_roles on public.clients;
create trigger clients_default_roles after insert on public.clients for each row execute function public.clients_default_roles();

-- 4. move what exists today into the new structure (keeps every current salary)
-- 4a. roles from the role names in use (one per name, ignoring capitals and spaces), salary = the most common current salary in that role,
--     overtime rate = the company's ot_rates entry for that role name, else its 'labor' entry, else 15
insert into public.roles (client_id, name, default_monthly_salary, ot_rate_per_hour)
select g.client_id, g.name, g.salary,
       coalesce((select o.rate_per_hour from public.ot_rates o where o.client_id = g.client_id and lower(btrim(o.role)) = g.key limit 1),
                (select o.rate_per_hour from public.ot_rates o where o.client_id = g.client_id and lower(btrim(o.role)) = 'labor' limit 1), 15)
  from (select l.client_id,
               lower(btrim(coalesce(nullif(btrim(l.role), ''), 'Labor'))) as key,
               min(btrim(coalesce(nullif(btrim(l.role), ''), 'Labor'))) as name,
               coalesce(mode() within group (order by coalesce(l.monthly_salary, 3000)), 3000) as salary
          from public.laborers l group by 1, 2) g
on conflict do nothing;
-- 4b. roles that only exist as overtime rates
insert into public.roles (client_id, name, default_monthly_salary, ot_rate_per_hour)
select o.client_id, btrim(o.role), 3000, o.rate_per_hour from public.ot_rates o
 where exists (select 1 from public.clients c where c.id = o.client_id) and length(btrim(o.role)) between 1 and 60
on conflict do nothing;
-- 4c. companies without any role
select public.ensure_default_roles(id) from public.clients;
-- 4d. one default role per company: the one called Labor, else the one with most labors
update public.roles r set is_default = true
 where not exists (select 1 from public.roles x where x.client_id = r.client_id and x.is_default)
   and r.id = (select y.id from public.roles y where y.client_id = r.client_id
                order by (lower(btrim(y.name)) = 'labor') desc,
                         (select count(*) from public.laborers l where l.client_id = y.client_id and lower(btrim(coalesce(l.role, 'Labor'))) = lower(btrim(y.name))) desc,
                         y.created_at limit 1);
-- 4e. labors point at their role (by name), the rest at the default role
update public.laborers l set role_id = r.id
  from public.roles r
 where l.role_id is null and r.client_id = l.client_id and lower(btrim(r.name)) = lower(btrim(coalesce(nullif(btrim(l.role), ''), 'Labor')));
update public.laborers l set role_id = r.id from public.roles r where l.role_id is null and r.client_id = l.client_id and r.is_default;
update public.laborers l set role = r.name from public.roles r where r.id = l.role_id and l.role is distinct from r.name;
-- 4f. salary history: everybody starts with the salary they have now
insert into public.labor_salaries (client_id, labor_id, from_date, monthly_salary)
select l.client_id, l.labor_id, date '2000-01-01', coalesce(l.monthly_salary, 3000) from public.laborers l
on conflict (client_id, labor_id, from_date) do nothing;
update public.laborers set monthly_salary = 3000 where monthly_salary is null;

-- 5. a labor always has a role, and its salary starts from the typed salary or the role default
create or replace function public.laborers_role_sync() returns trigger language plpgsql security definer set search_path = public as $$
declare v roles%rowtype;
begin
    if new.role_id is not null then
        select * into v from roles where id = new.role_id;
        if not found or v.client_id <> new.client_id then raise exception 'Unknown role' using errcode = 'P0001'; end if;
    else
        select * into v from roles where client_id = new.client_id and lower(btrim(name)) = lower(btrim(coalesce(new.role, ''))) limit 1;
        if not found then select * into v from roles where client_id = new.client_id and is_default limit 1; end if;
    end if;
    if v.id is not null then
        new.role_id := v.id;
        new.role := v.name;
        if tg_op = 'INSERT' and new.monthly_salary is null then new.monthly_salary := v.default_monthly_salary; end if;
    end if;
    return new;
end;
$$;
drop trigger if exists laborers_role_sync on public.laborers;
create trigger laborers_role_sync before insert or update of role_id, role on public.laborers for each row execute function public.laborers_role_sync();

create or replace function public.laborers_salary_start() returns trigger language plpgsql security definer set search_path = public as $$
begin
    insert into labor_salaries (client_id, labor_id, from_date, monthly_salary)
    values (new.client_id, new.labor_id, date '2000-01-01', coalesce(new.monthly_salary, 0))
    on conflict (client_id, labor_id, from_date) do nothing;
    return new;
end;
$$;
drop trigger if exists laborers_salary_start on public.laborers;
create trigger laborers_salary_start after insert on public.laborers for each row execute function public.laborers_salary_start();

-- a role renamed: the labors' text column follows
create or replace function public.roles_name_follow() returns trigger language plpgsql security definer set search_path = public as $$
begin
    if new.name is distinct from old.name then update laborers set role = new.name where role_id = new.id; end if;
    return new;
end;
$$;
drop trigger if exists roles_name_follow on public.roles;
create trigger roles_name_follow after update of name on public.roles for each row execute function public.roles_name_follow();

-- 6. the salary of a labor on a date: latest entry up to that date
create or replace function public.labor_salary_on(p_client uuid, p_labor text, p_date date)
returns numeric language sql stable security definer set search_path = public as $$
    select coalesce(
        (select s.monthly_salary from labor_salaries s where s.client_id = p_client and s.labor_id = p_labor and s.from_date <= p_date order by s.from_date desc limit 1),
        (select l.monthly_salary from laborers l where l.client_id = p_client and l.labor_id = p_labor limit 1),
        0)
$$;
revoke all on function public.labor_salary_on(uuid, text, date) from public, anon, authenticated;

-- 7. change the salary of labors from a date (administrator only)
create or replace function public.set_labor_salary(p_labor_ids text[], p_amount numeric, p_from date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_client uuid := public.current_client_id();
    v_found int;
    v_n int;
begin
    if v_client is null or public.current_user_role() not in ('admin', 'super_admin') then raise exception 'not allowed' using errcode = '42501'; end if;
    if p_labor_ids is null or coalesce(array_length(p_labor_ids, 1), 0) = 0 then raise exception 'no labors chosen' using errcode = 'P0001'; end if;
    if array_length(p_labor_ids, 1) > 1000 then raise exception 'too many labors at once' using errcode = 'P0001'; end if;
    if p_amount is null or p_amount < 0 or p_amount > 10000000 then raise exception 'invalid salary' using errcode = 'P0001'; end if;
    if p_from is null or p_from < current_date - 800 or p_from > current_date + 400 then raise exception 'date out of range' using errcode = 'P0001'; end if;
    select count(*) into v_found from laborers where client_id = v_client and labor_id = any (p_labor_ids);
    if v_found <> (select count(distinct x) from unnest(p_labor_ids) x) then raise exception 'unknown labor in the list' using errcode = 'P0001'; end if;

    insert into labor_salaries (client_id, labor_id, from_date, monthly_salary)
    select v_client, x, p_from, p_amount from (select distinct unnest(p_labor_ids) x) q
    on conflict (client_id, labor_id, from_date) do update set monthly_salary = excluded.monthly_salary, created_at = now();
    get diagnostics v_n = row_count;
    update laborers l set monthly_salary = public.labor_salary_on(v_client, l.labor_id, current_date)
     where l.client_id = v_client and l.labor_id = any (p_labor_ids);
    return jsonb_build_object('changed', v_n, 'from', p_from);
end;
$$;
revoke all on function public.set_labor_salary(text[], numeric, date) from public, anon;
grant execute on function public.set_labor_salary(text[], numeric, date) to authenticated;

-- 8. change the default salary of a role from a date; optionally also for the labors that are on that default (not the personal exceptions)
create or replace function public.change_role_salary(p_role uuid, p_amount numeric, p_from date, p_apply boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_client uuid := public.current_client_id();
    v_old numeric;
    v_n int := 0;
begin
    if v_client is null or public.current_user_role() not in ('admin', 'super_admin') then raise exception 'not allowed' using errcode = '42501'; end if;
    if p_amount is null or p_amount < 0 or p_amount > 10000000 then raise exception 'invalid salary' using errcode = 'P0001'; end if;
    if p_from is null or p_from < current_date - 800 or p_from > current_date + 400 then raise exception 'date out of range' using errcode = 'P0001'; end if;
    select default_monthly_salary into v_old from roles where id = p_role and client_id = v_client;
    if not found then raise exception 'unknown role' using errcode = 'P0001'; end if;

    if p_apply then
        insert into labor_salaries (client_id, labor_id, from_date, monthly_salary)
        select v_client, l.labor_id, p_from, p_amount from laborers l
         where l.client_id = v_client and l.role_id = p_role and l.status = 'active'
           and public.labor_salary_on(v_client, l.labor_id, p_from) = v_old
        on conflict (client_id, labor_id, from_date) do update set monthly_salary = excluded.monthly_salary, created_at = now();
        get diagnostics v_n = row_count;
        update laborers l set monthly_salary = public.labor_salary_on(v_client, l.labor_id, current_date) where l.client_id = v_client and l.role_id = p_role;
    end if;
    update roles set default_monthly_salary = p_amount where id = p_role and client_id = v_client;
    return jsonb_build_object('labors_updated', v_n, 'from', p_from);
end;
$$;
revoke all on function public.change_role_salary(uuid, numeric, date, boolean) from public, anon;
grant execute on function public.change_role_salary(uuid, numeric, date, boolean) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-05  018  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 018 applied' as result,
       (select count(*) from public.roles) as roles,
       (select count(*) from public.laborers where role_id is null) as labors_without_role,
       (select count(*) from public.laborers l where not exists (select 1 from public.labor_salaries s where s.client_id = l.client_id and s.labor_id = l.labor_id)) as labors_without_salary_entry,
       (select string_agg(distinct r.name || ' ' || r.default_monthly_salary::text, ', ') from public.roles r) as roles_created;
