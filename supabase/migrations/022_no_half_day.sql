-- ============================================================
-- Migration 022: no more half day; one rule for Present (owner decisions, 2026-10-19; ROADMAP section G, findings 64-67)
-- ============================================================
-- * A day is Present (P) only when the labor worked the full required hours, otherwise Absent (A). Half day (H) is gone everywhere.
--   Required hours = the shift's required hours if set, else the department's "Min Hours (Full Day)", else the setting
--   min_hours_present, else 9.5 h (the same rule the early-leave warning already uses, _required_minutes from migration 011).
-- * Worked time = first IN to the last OUT (before: the first punch of ANY kind, so an OUT could start the day).
-- * An administrator's approval is kept when the labor punches again that day (before: the next punch replaced it, finding 64).
-- * Existing data: days approved as half day become Present (owner: "Present, fully paid"), and so do approved days that a later
--   punch had turned back to Absent (finding 64); every day with punches is
--   recalculated with the new rule (all months, owner decision); no H is left, and the database refuses H from now on.
-- * The month screen of the terminal also gets the days around the month and the sandwich-rule settings, so it can show
--   Fridays and holidays the same way as the reports, and the punches of a day in time order.
-- Run AFTER 021. Safe to run again.
-- ============================================================

-- 1. attendance maths
create or replace function public._recalc_attendance(p_client uuid, p_labor_id text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare
    v_department_id uuid;
    v_first_ts timestamp;
    v_any_ts timestamp;
    v_last_ts timestamp;
    v_total_minutes integer;
    v_auto_status text;
    v_shift uuid;
begin
    select department_id into v_department_id from laborers where labor_id = p_labor_id and client_id = p_client limit 1;
    if v_department_id is null then return; end if;

    -- an OUT that ended a night shift is stored on the IN date: add one day to get its real time
    select min(ts) filter (where type = 'login'), min(ts), max(ts) filter (where type = 'logout')
      into v_first_ts, v_any_ts, v_last_ts
      from (select type, (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end as ts
              from punch_records where labor_id = p_labor_id and date = p_date and client_id = p_client) q;
    if v_any_ts is null then return; end if;
    if v_first_ts is null then v_first_ts := v_any_ts; end if;                               -- only OUT punches that day
    if v_last_ts is null or v_last_ts < v_first_ts then v_last_ts := v_first_ts; end if;    -- no OUT after the first IN: 0 hours

    v_total_minutes := floor(extract(epoch from (v_last_ts - v_first_ts)) / 60);
    v_auto_status := case when v_total_minutes >= public._required_minutes(p_client, p_labor_id, p_date) then 'P' else 'A' end;
    v_shift := public.labor_shift_on(p_client, p_labor_id, p_date);

    insert into daily_attendance (labor_id, department_id, date, first_login, last_logout, total_hours, auto_status, final_status, client_id, shift_id, updated_at)
    values (p_labor_id, v_department_id, p_date, v_first_ts::time, v_last_ts::time, v_total_minutes / 60.0, v_auto_status, v_auto_status, p_client, v_shift, now())
    on conflict (labor_id, date) do update set
        first_login = excluded.first_login, last_logout = excluded.last_logout, total_hours = excluded.total_hours,
        auto_status = excluded.auto_status, shift_id = excluded.shift_id,
        -- an administrator's approval stays
        final_status = case when nullif(btrim(daily_attendance.approved_by), '') is not null then daily_attendance.final_status else excluded.auto_status end,
        updated_at = now();
end;
$$;
revoke all on function public._recalc_attendance(uuid, text, date) from public, anon, authenticated;

-- 2. existing data
alter table public.daily_attendance drop constraint if exists daily_attendance_auto_status_check;
alter table public.daily_attendance drop constraint if exists daily_attendance_final_status_check;

-- an approval only ever wrote P or H, so an approved day that now says A or H was overwritten by a later punch (finding 64): back to P
update public.daily_attendance set final_status = 'P' where final_status in ('H', 'A') and nullif(btrim(approved_by), '') is not null;
update public.daily_attendance set final_status = 'A' where final_status = 'H';

do $$
declare r record;
begin
    for r in select distinct client_id, labor_id, date from public.punch_records where client_id is not null loop
        perform public._recalc_attendance(r.client_id, r.labor_id, r.date);
    end loop;
end $$;

update public.daily_attendance set auto_status = 'A' where auto_status = 'H';     -- days without punches (approved earlier)
update public.daily_attendance set final_status = auto_status where final_status is null and auto_status is not null;

alter table public.daily_attendance add constraint daily_attendance_auto_status_check check (auto_status = any (array['P', 'A']));
alter table public.daily_attendance add constraint daily_attendance_final_status_check check (final_status = any (array['P', 'A']));

-- LOP requests still waiting: a half day can no longer be asked for
update public.lop_requests set requested_status = 'P' where requested_status = 'H' and approval_status in ('draft', 'pending');
update public.lop_requests set auto_status = 'A' where auto_status = 'H' and approval_status in ('draft', 'pending');

-- 3. month screen of the terminal: days from 14 days before to 14 days after the month (for the sandwich rule), the
--    sandwich settings and the joining date. Still only the current and the previous month; no salary / ID / overtime.
create or replace function public.terminal_month_attendance(p_labor_id text, p_month date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_client uuid := public.require_terminal();
    v_start date;
    v_from date;
    v_to date;
    v_ref date := current_date + 1;      -- the terminal's clock may be ahead of the server's (Saudi time is UTC+3)
    v_doj date;
    v_days jsonb;
    v_hol jsonb;
begin
    if p_month is null then raise exception 'invalid month' using errcode = 'P0001'; end if;
    v_start := date_trunc('month', p_month)::date;
    if v_start > date_trunc('month', v_ref)::date or v_start < (date_trunc('month', v_ref) - interval '1 month')::date then
        raise exception 'month not available' using errcode = 'P0001';
    end if;
    select date_of_joining into v_doj from laborers where client_id = v_client and labor_id = p_labor_id and status = 'active';
    if not found then raise exception 'unknown or inactive labor' using errcode = 'P0001'; end if;
    v_from := v_start - 14;
    v_to := (v_start + interval '1 month')::date + 13;

    select coalesce(jsonb_agg(jsonb_build_object('date', d.date, 'status', coalesce(d.final_status, d.auto_status), 'first_in', d.first_login,
                                                 'last_out', d.last_logout, 'hours', coalesce(d.total_hours, 0),
                                                 'approved', (d.approved_by is not null and btrim(d.approved_by) <> '')) order by d.date), '[]'::jsonb)
      into v_days
      from daily_attendance d
     where d.client_id = v_client and d.labor_id = p_labor_id and d.date between v_from and v_to;

    select coalesce(jsonb_agg(jsonb_build_object('date', h.date, 'name', h.name) order by h.date), '[]'::jsonb)
      into v_hol
      from holidays h
     where h.client_id = v_client and coalesce(h.is_active, true) and h.date between v_from and v_to;

    return jsonb_build_object(
        'month', v_start,
        'days', v_days,
        'holidays', v_hol,
        'date_of_joining', v_doj,
        'sandwich_friday', coalesce((select value from settings where client_id = v_client and key = 'sandwich_rule_friday'), 'true') <> 'false',
        'sandwich_nh', coalesce((select value from settings where client_id = v_client and key = 'sandwich_rule_nh'), 'true') <> 'false',
        'present', (select count(*) from jsonb_array_elements(v_days) e where e ->> 'status' = 'P' and (e ->> 'date')::date >= v_start and (e ->> 'date')::date < (v_start + interval '1 month')::date),
        'absent', (select count(*) from jsonb_array_elements(v_days) e where e ->> 'status' = 'A' and (e ->> 'date')::date >= v_start and (e ->> 'date')::date < (v_start + interval '1 month')::date)
    );
end;
$$;
revoke all on function public.terminal_month_attendance(text, date) from public, anon;
grant execute on function public.terminal_month_attendance(text, date) to authenticated;

-- 4. the punches of one day on the month screen in time order (an OUT after midnight that ended a night shift comes last),
--    not in the order they reached the database (an offline punch uploaded late was listed out of order). Same fields as migration 004.
create or replace function public.terminal_today_punches(p_labor_id text, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v uuid := public.require_terminal();
begin
    return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'type', r.type, 'time', r.time, 'date', r.date,
                    'location_name', r.location_name, 'photo_url', r.photo_url, 'created_at', r.created_at)
                    order by (r.date + r.time) + case when r.is_night_shift_end then interval '1 day' else interval '0' end, r.created_at)
                    from punch_records r where r.client_id = v and r.labor_id = p_labor_id and r.date = p_date), '[]'::jsonb);
end;
$$;
revoke all on function public.terminal_today_punches(text, date) from public, anon;
grant execute on function public.terminal_today_punches(text, date) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-19  022  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 022 applied' as result,
       (select count(*) from public.daily_attendance where final_status not in ('P', 'A') or auto_status not in ('P', 'A')) as rows_not_p_or_a;
