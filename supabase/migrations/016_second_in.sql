-- ============================================================
-- Migration 016: a second IN after an OUT on the same day is allowed (owner decision, 2026-10-03)
-- ============================================================
-- * Migration 009 refused an IN after an OUT on the same shift day ("You have already logged out for the day"). That refusal is removed.
--   A labor can now go IN, OUT, IN, OUT ... on one shift day.
-- * Daily hours = the first IN to the LAST OUT of the shift day (the break in between counts).
--   If the last punch is an IN (second session still open) the last OUT is the earlier OUT: first IN to that OUT.
--   A day with only an IN stays as before (logout time = login time, 0 hours).
-- * "Leaving early?" compares the time since the FIRST IN of the shift day with the required hours (not only the latest session).
-- * NOT changed on purpose (owner: decide later): the 4-hour rule (an OUT is refused less than 4 hours after the latest IN), the rule against
--   a repeated IN while an IN is open, and OUT without an IN.
-- Safe to run again.
-- ============================================================

-- 1. rule check: migration 011's text without the ALREADY_DONE refusal
create or replace function public._punch_check(p_client uuid, p_labor text, p_type text, p_ts timestamp, p_final_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_min_minutes int := 240;
    v_open_hours int := 20;
    v_prev_type text;
    v_prev_ts timestamp;
begin
    select nullif(value, '')::int into v_min_minutes from settings where client_id = p_client and key = 'min_session_minutes' and value ~ '^\d+$';
    v_min_minutes := coalesce(v_min_minutes, 240);
    select nullif(value, '')::int into v_open_hours from settings where client_id = p_client and key = 'open_session_hours' and value ~ '^\d+$';
    v_open_hours := coalesce(v_open_hours, 20);

    select type, (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end
      into v_prev_type, v_prev_ts
      from punch_records
     where client_id = p_client and labor_id = p_labor
       and (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end < p_ts
     order by (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end desc
     limit 1;

    if p_type = 'login' then
        if v_prev_type = 'login' and p_ts - v_prev_ts < make_interval(hours => v_open_hours) then
            return jsonb_build_object('ok', false, 'code', 'ALREADY_IN', 'message', 'You have logged in for the day');
        end if;
    else
        if v_prev_type is distinct from 'login' or p_ts - v_prev_ts >= make_interval(hours => v_open_hours) then
            return jsonb_build_object('ok', false, 'code', 'NO_OPEN_IN', 'message', 'Please punch IN first');
        end if;
        if p_ts - v_prev_ts < make_interval(mins => v_min_minutes) then
            return jsonb_build_object('ok', false, 'code', 'TOO_EARLY', 'message', 'You have logged in for the day');
        end if;
    end if;
    return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public._punch_check(uuid, text, text, timestamp, date) from public, anon, authenticated;

-- 2. early OUT: worked time since the first IN of the shift day
create or replace function public._early_out_info(p_client uuid, p_labor text, p_ts timestamp, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_in timestamp;
    v_worked int;
    v_req int;
begin
    select min((date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end) into v_in
      from punch_records
     where client_id = p_client and labor_id = p_labor and type = 'login' and date = p_date
       and (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end < p_ts;
    if v_in is null then
        -- no IN stored on that shift day (should not happen): fall back to the latest earlier IN
        select (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end into v_in
          from punch_records
         where client_id = p_client and labor_id = p_labor and type = 'login'
           and (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end < p_ts
         order by (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end desc limit 1;
    end if;
    if v_in is null then return jsonb_build_object('early', false); end if;
    v_worked := floor(extract(epoch from (p_ts - v_in)) / 60);
    v_req := public._required_minutes(p_client, p_labor, p_date);
    return jsonb_build_object('early', v_worked < v_req, 'worked_minutes', v_worked, 'required_minutes', v_req, 'remaining_minutes', greatest(v_req - v_worked, 0));
end;
$$;
revoke all on function public._early_out_info(uuid, text, timestamp, date) from public, anon, authenticated;

-- 3. daily hours: first punch to the last OUT (migration 010's text; the last OUT counts only punches of type logout)
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
    select min(ts), max(ts) filter (where type = 'logout') into v_first_ts, v_last_ts
      from (select type, (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end as ts
              from punch_records where labor_id = p_labor_id and date = p_date and client_id = p_client) q;
    if v_first_ts is null then return; end if;
    if v_last_ts is null or v_last_ts < v_first_ts then v_last_ts := v_first_ts; end if;   -- only an IN so far: as before (0 hours)
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
-- 2026-10-03  016  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 016 applied' as result;
