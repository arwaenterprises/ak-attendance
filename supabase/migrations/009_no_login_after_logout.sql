-- ============================================================
-- Migration 009: no second IN after a completed OUT on the same shift day (decision of the owner, 2026-10-02)
-- ============================================================
-- A labor who has punched OUT for a shift day cannot punch IN again for that same shift day:
--   refused: "You have already logged out for the day"   (code ALREADY_DONE)
-- The shift day follows the night-shift logic: a night shift IN on day D 21:00 and OUT on day D+1 05:30 both belong to day D,
-- so the next evening's IN (day D+1) is accepted.
-- Everything from migration 007 stays (repeat IN, OUT without IN, 4-hour lock, forgotten OUT). Safe to run again.
-- ============================================================

-- which shift day does a punch at this date / time belong to? (the night-shift rule that used to sit inside terminal_record_punch)
create or replace function public._punch_day(p_client uuid, p_labor text, p_date date, p_time time)
returns table (final_date date, is_night_end boolean) language plpgsql stable security definer set search_path = public as $$
declare
    v_night_start int := 20 * 60;
    v_night_end int := 6 * 60 + 30;
    v_val text;
    v_mins int;
begin
    select value into v_val from settings where client_id = p_client and key = 'night_shift_start';
    if v_val ~ '^\d{1,2}:\d{2}' then v_night_start := split_part(v_val, ':', 1)::int * 60 + split_part(v_val, ':', 2)::int; end if;
    select value into v_val from settings where client_id = p_client and key = 'night_shift_end';
    if v_val ~ '^\d{1,2}:\d{2}' then v_night_end := split_part(v_val, ':', 1)::int * 60 + split_part(v_val, ':', 2)::int; end if;

    final_date := p_date; is_night_end := false;
    v_mins := extract(hour from p_time)::int * 60 + extract(minute from p_time)::int;
    if v_mins <= v_night_end then
        if exists (select 1 from punch_records where client_id = p_client and labor_id = p_labor and date = p_date - 1
                   and extract(hour from time)::int * 60 + extract(minute from time)::int >= v_night_start) then
            final_date := p_date - 1; is_night_end := true;
        end if;
    end if;
    return next;
end;
$$;
revoke all on function public._punch_day(uuid, text, date, time) from public, anon, authenticated;

-- (the rule function gets a NEW name, _punch_check, so nothing has to be dropped; the old _punch_check from 007 is simply no longer used)
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
        -- already logged out for this shift day: no second IN
        if exists (select 1 from punch_records where client_id = p_client and labor_id = p_labor and type = 'logout' and date = p_final_date
                      and (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end < p_ts) then
            return jsonb_build_object('ok', false, 'code', 'ALREADY_DONE', 'message', 'You have already logged out for the day');
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

create or replace function public.terminal_check_punch(p_labor_id text, p_type text, p_date date, p_time time)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_client uuid := public.require_terminal();
    v_rule jsonb;
    v_day record;
begin
    if p_type is null or p_type not in ('login', 'logout') then raise exception 'invalid punch type' using errcode = 'P0001'; end if;
    if p_date is null or p_time is null then raise exception 'invalid date or time' using errcode = 'P0001'; end if;
    if not exists (select 1 from laborers where client_id = v_client and labor_id = p_labor_id and status = 'active') then
        raise exception 'unknown or inactive labor' using errcode = 'P0001';
    end if;
    select * into v_day from public._punch_day(v_client, p_labor_id, p_date, p_time);
    v_rule := public._punch_check(v_client, p_labor_id, p_type, p_date + p_time, v_day.final_date);
    return jsonb_build_object('allowed', (v_rule ->> 'ok')::boolean, 'code', v_rule ->> 'code', 'message', v_rule ->> 'message');
end;
$$;
revoke all on function public.terminal_check_punch(text, text, date, time) from public, anon;
grant execute on function public.terminal_check_punch(text, text, date, time) to authenticated;

-- the punch function: migration 007 version using the shared helpers
create or replace function public.terminal_record_punch(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_client uuid := public.require_terminal();
    v_labor_id text := p ->> 'labor_id';
    v_labor record;
    v_date date;
    v_time time;
    v_type text := p ->> 'type';
    v_day record;
    v_final_date date;
    v_is_night_end boolean := false;
    v_location uuid := null;
    v_conf int := null;
    v_photo text := nullif(p ->> 'photo_url', '');
    v_id uuid;
    v_existing uuid;
    v_rule jsonb;
begin
    select * into v_labor from laborers where client_id = v_client and labor_id = v_labor_id and status = 'active';
    if not found then raise exception 'unknown or inactive labor' using errcode = 'P0001'; end if;
    if v_type is null or v_type not in ('login', 'logout') then raise exception 'invalid punch type' using errcode = 'P0001'; end if;
    begin
        v_date := (p ->> 'date')::date;
        v_time := (p ->> 'time')::time;
    exception when others then raise exception 'invalid date or time' using errcode = 'P0001'; end;
    if v_date is null or v_time is null or v_date < current_date - 31 or v_date > current_date + 1 then
        raise exception 'date out of range' using errcode = 'P0001';
    end if;
    if p ->> 'location_id' is not null then
        select id into v_location from punch_locations where id = (p ->> 'location_id')::uuid and client_id = v_client;
    end if;
    if p ->> 'confidence' is not null then v_conf := greatest(0, least(100, (p ->> 'confidence')::int)); end if;
    if v_photo is not null then
        if length(v_photo) > 500 then raise exception 'photo link too long' using errcode = 'P0001'; end if;
        -- a photo path must be inside this company's punches folder (a full web address from an old terminal is kept as it is)
        if v_photo !~ '^https?://' and (storage.foldername(v_photo))[1] is distinct from v_client::text then
            raise exception 'invalid photo path' using errcode = 'P0001';
        end if;
    end if;

    select * into v_day from public._punch_day(v_client, v_labor_id, v_date, v_time);
    v_final_date := v_day.final_date;
    v_is_night_end := v_day.is_night_end;

    select id into v_existing from punch_records where client_id = v_client and labor_id = v_labor_id and date = v_final_date and time = v_time limit 1;
    if v_existing is not null then
        return jsonb_build_object('success', true, 'duplicate', true, 'id', v_existing, 'date', v_final_date);
    end if;

    -- IN / OUT rules (repeat, mismatch, 4-hour lock): a refused punch is NOT stored; the terminal shows the message
    v_rule := public._punch_check(v_client, v_labor_id, v_type, v_date + v_time, v_final_date);
    if not (v_rule ->> 'ok')::boolean then
        return jsonb_build_object('success', false, 'rejected', true, 'code', v_rule ->> 'code', 'message', v_rule ->> 'message');
    end if;

    insert into punch_records (labor_id, department_id, date, time, type, location_id, location_name, confidence, photo_url, client_id, is_night_shift_end)
    values (v_labor_id, v_labor.department_id, v_final_date, v_time, v_type, v_location, left(p ->> 'location_name', 200), v_conf, v_photo, v_client, v_is_night_end)
    returning id into v_id;

    update laborers set last_sync_at = now() where id = v_labor.id;
    perform public._recalc_attendance(v_client, v_labor_id, v_final_date);
    return jsonb_build_object('success', true, 'duplicate', false, 'id', v_id, 'date', v_final_date, 'is_night_shift_end', v_is_night_end);
end;
$$;
revoke all on function public.terminal_record_punch(jsonb) from public, anon;
grant execute on function public.terminal_record_punch(jsonb) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  009  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

-- proof that it ran (the result panel must show this row):
select 'migration 009 applied' as result,
       (select count(*) from pg_proc where proname = '_punch_day') as punch_day_functions,
       (select count(*) from pg_proc where proname = '_punch_check') as punch_check_functions;
