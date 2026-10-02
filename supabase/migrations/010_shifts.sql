-- ============================================================
-- Migration 010: Shift management (ROADMAP: Day + Night shifts, assign labors, history, reports follow the shift)
-- ============================================================
-- * shifts: each company has a Day and a Night shift (editable: name, start / end time, optional required hours).
-- * shift_assignments: which labor works which shift FROM which date (history is kept; a move can be dated today, in the future or the past).
-- * laborers.shift_id = the labor's CURRENT shift; daily_attendance.shift_id = the shift of that day (reports follow it).
-- * assign_shift(): the one way to move labors (administrator only).
-- * Attendance maths now uses real time stamps, so a night shift (IN 21:00, OUT 05:30 next morning) counts 8.5 hours, not 15.5 (ROADMAP finding 48).
-- The existing night-shift DETECTION (settings night_shift_start / night_shift_end) is unchanged.
-- Safe to run again.
-- ============================================================

-- 1. shifts
create table if not exists public.shifts (
    id             uuid primary key default gen_random_uuid(),
    client_id      uuid not null references public.clients (id),
    code           text not null check (code ~ '^[A-Z0-9_]{1,20}$'),
    name           text not null check (length(btrim(name)) between 1 and 60),
    start_time     time not null,
    end_time       time not null,
    is_night       boolean not null default false,
    required_hours numeric check (required_hours is null or (required_hours > 0 and required_hours <= 24)),
    status         text not null default 'active' check (status in ('active', 'inactive')),
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    unique (client_id, code)
);
create index if not exists idx_shifts_client on public.shifts (client_id);

create table if not exists public.shift_assignments (
    id         uuid primary key default gen_random_uuid(),
    client_id  uuid not null references public.clients (id),
    labor_id   text not null,
    shift_id   uuid not null references public.shifts (id),
    from_date  date not null,
    created_at timestamptz not null default now(),
    unique (client_id, labor_id, from_date)
);
create index if not exists idx_shift_assignments_labor on public.shift_assignments (client_id, labor_id, from_date);

alter table public.laborers         add column if not exists shift_id uuid references public.shifts (id);
alter table public.daily_attendance add column if not exists shift_id uuid references public.shifts (id);

drop trigger if exists update_shifts_updated_at on public.shifts;
create trigger update_shifts_updated_at before update on public.shifts for each row execute function public.update_updated_at();

-- 2. who may touch the tables: staff of the company (same rule as the other company tables); never the terminal, never the public key
alter table public.shifts enable row level security;
alter table public.shift_assignments enable row level security;
do $$
declare t text;
begin
    foreach t in array array['shifts', 'shift_assignments'] loop
        execute format('drop policy if exists %I on public.%I', 'tenant ' || t, t);
        execute format('create policy %I on public.%I for all to authenticated
                        using (client_id = (select public.current_client_id()) and (select public.is_staff()))
                        with check (client_id = (select public.current_client_id()) and (select public.is_staff()))', 'tenant ' || t, t);
        execute format('revoke all on public.%I from public, anon', t);
        execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    end loop;
end $$;

-- 3. every company gets a Day and a Night shift (the administrator edits the times on the Shift Management page)
create or replace function public.ensure_default_shifts(p_client uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
    insert into shifts (client_id, code, name, start_time, end_time, is_night) values
        (p_client, 'DAY', 'Day shift', '06:00', '18:00', false),
        (p_client, 'NIGHT', 'Night shift', '18:00', '06:00', true)
    on conflict (client_id, code) do nothing;
end;
$$;
revoke all on function public.ensure_default_shifts(uuid) from public, anon, authenticated;
select public.ensure_default_shifts(id) from public.clients;
update public.laborers l set shift_id = s.id from public.shifts s where l.shift_id is null and s.client_id = l.client_id and s.code = 'DAY';

-- 4. the shift of a labor on a date: the latest assignment up to that date, else the labor's current shift, else the company's Day shift
create or replace function public.labor_shift_on(p_client uuid, p_labor text, p_date date)
returns uuid language sql stable security definer set search_path = public as $$
    select coalesce(
        (select a.shift_id from shift_assignments a where a.client_id = p_client and a.labor_id = p_labor and a.from_date <= p_date
          order by a.from_date desc limit 1),
        (select l.shift_id from laborers l where l.client_id = p_client and l.labor_id = p_labor limit 1),
        (select s.id from shifts s where s.client_id = p_client and s.code = 'DAY'))
$$;
revoke all on function public.labor_shift_on(uuid, text, date) from public, anon, authenticated;

-- 5. move labors to a shift from a date (administrator only)
create or replace function public.assign_shift(p_labor_ids text[], p_shift_id uuid, p_from date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_client uuid := public.current_client_id();
    v_n int;
    v_found int;
    v_labor text;
begin
    if v_client is null or public.current_user_role() not in ('admin', 'super_admin') then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    if p_labor_ids is null or coalesce(array_length(p_labor_ids, 1), 0) = 0 then raise exception 'no labors chosen' using errcode = 'P0001'; end if;
    if array_length(p_labor_ids, 1) > 500 then raise exception 'too many labors at once' using errcode = 'P0001'; end if;
    if p_from is null or p_from < current_date - 400 or p_from > current_date + 400 then raise exception 'date out of range' using errcode = 'P0001'; end if;
    if not exists (select 1 from shifts where id = p_shift_id and client_id = v_client and status = 'active') then
        raise exception 'unknown or inactive shift' using errcode = 'P0001';
    end if;
    select count(*) into v_found from laborers where client_id = v_client and labor_id = any (p_labor_ids);
    if v_found <> (select count(distinct x) from unnest(p_labor_ids) x) then raise exception 'unknown labor in the list' using errcode = 'P0001'; end if;

    -- a labor moved for the first time: keep his previous shift as the starting entry (2000-01-01), so earlier days keep their shift
    insert into shift_assignments (client_id, labor_id, shift_id, from_date)
    select v_client, l.labor_id, coalesce(l.shift_id, (select s.id from shifts s where s.client_id = v_client and s.code = 'DAY')), date '2000-01-01'
      from laborers l
     where l.client_id = v_client and l.labor_id = any (p_labor_ids)
       and not exists (select 1 from shift_assignments a where a.client_id = v_client and a.labor_id = l.labor_id)
    on conflict (client_id, labor_id, from_date) do nothing;

    insert into shift_assignments (client_id, labor_id, shift_id, from_date)
    select v_client, x, p_shift_id, p_from from (select distinct unnest(p_labor_ids) x) q
    on conflict (client_id, labor_id, from_date) do update set shift_id = excluded.shift_id, created_at = now();
    get diagnostics v_n = row_count;

    -- the labor's CURRENT shift, and the shift stamped on attendance rows from that date on
    update laborers l set shift_id = public.labor_shift_on(v_client, l.labor_id, current_date)
     where l.client_id = v_client and l.labor_id = any (p_labor_ids);
    update daily_attendance d set shift_id = public.labor_shift_on(v_client, d.labor_id, d.date)
     where d.client_id = v_client and d.labor_id = any (p_labor_ids) and d.date >= p_from;
    return jsonb_build_object('moved', v_n, 'from', p_from);
end;
$$;
revoke all on function public.assign_shift(text[], uuid, date) from public, anon;
grant execute on function public.assign_shift(text[], uuid, date) to authenticated;

-- 6. attendance maths: real time stamps (night shift!) and the shift stamped on the day. Everything else is as in migration 004.
create or replace function public._recalc_attendance(p_client uuid, p_labor_id text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare
    v_department_id uuid;
    v_first_ts timestamp;
    v_last_ts timestamp;
    v_first_login time;
    v_last_logout time;
    v_total_hours numeric;
    v_total_minutes integer;
    v_auto_status text;
    v_min_present_minutes integer := 570;
    v_min_half_minutes integer := 240;
    v_dept_min_hours text;
    v_shift uuid;
begin
    select department_id into v_department_id from laborers where labor_id = p_labor_id and client_id = p_client limit 1;
    if v_department_id is null then return; end if;

    -- an OUT that ended a night shift is stored on the IN date: add one day to get its real time
    select min(ts), max(ts) into v_first_ts, v_last_ts
      from (select (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end as ts
              from punch_records where labor_id = p_labor_id and date = p_date and client_id = p_client) q;
    if v_first_ts is null then return; end if;
    v_first_login := v_first_ts::time;
    v_last_logout := v_last_ts::time;

    select min_hours_full_day into v_dept_min_hours from departments where id = v_department_id limit 1;
    if v_dept_min_hours is not null then
        v_min_present_minutes := extract(hour from v_dept_min_hours::time) * 60 + extract(minute from v_dept_min_hours::time);
    end if;

    v_total_minutes := floor(extract(epoch from (v_last_ts - v_first_ts)) / 60);
    v_total_hours   := v_total_minutes / 60.0;
    if v_total_minutes >= v_min_present_minutes then v_auto_status := 'P';
    elsif v_total_minutes >= v_min_half_minutes then v_auto_status := 'H';
    else v_auto_status := 'A'; end if;

    v_shift := public.labor_shift_on(p_client, p_labor_id, p_date);

    insert into daily_attendance (labor_id, department_id, date, first_login, last_logout, total_hours, auto_status, final_status, client_id, shift_id, updated_at)
    values (p_labor_id, v_department_id, p_date, v_first_login, v_last_logout, v_total_hours, v_auto_status, v_auto_status, p_client, v_shift, now())
    on conflict (labor_id, date) do update set
        first_login = excluded.first_login, last_logout = excluded.last_logout, total_hours = excluded.total_hours,
        auto_status = excluded.auto_status, shift_id = excluded.shift_id,
        final_status = case when daily_attendance.final_status in ('LP','LH','LA') then daily_attendance.final_status else excluded.auto_status end,
        updated_at = now();
end;
$$;
revoke all on function public._recalc_attendance(uuid, text, date) from public, anon, authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  010  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 010 applied' as result,
       (select count(*) from public.shifts) as shifts,
       (select count(*) from public.clients) as companies;
