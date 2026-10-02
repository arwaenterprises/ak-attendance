-- ============================================================
-- Migration 011: early leave warning + shift name on the punch (decision of the owner, 2026-10-02: "Stay / Leave now" warning, not a hard block)
-- ============================================================
-- The hours a labor should work come from (first that exists): the shift's required hours, the department's "Min Hours (Full Day)"
-- (set per department, so it differs from client to client), the setting min_hours_present, 9.5 hours.
-- * terminal_check_punch tells the terminal when an OUT is early (worked / required / remaining minutes) so it can ask "Stay or Leave now".
-- * terminal_record_punch stores the flag on the OUT (punch_records.early_out, early_minutes = minutes missing) whatever the terminal did,
--   and returns the shift name for the "Punched IN / OUT" screen.
-- The hidden minimum between IN and OUT (4 hours) and all other rules from 007 / 009 stay as they are. Safe to run again.
-- ============================================================

alter table public.punch_records add column if not exists early_out boolean not null default false;
alter table public.punch_records add column if not exists early_minutes integer;

-- the rule function of migration 009 (re-created here so this file also works on a project that has the earlier text of 009)
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

-- required minutes of a labor on a date
create or replace function public._required_minutes(p_client uuid, p_labor text, p_date date)
returns integer language sql stable security definer set search_path = public as $$
    select coalesce(
        (select round(s.required_hours * 60)::int from shifts s where s.id = public.labor_shift_on(p_client, p_labor, p_date) and s.required_hours is not null),
        (select extract(hour from d.min_hours_full_day)::int * 60 + extract(minute from d.min_hours_full_day)::int
           from laborers l join departments d on d.id = l.department_id
          where l.client_id = p_client and l.labor_id = p_labor and d.min_hours_full_day is not null),
        (select round(value::numeric * 60)::int from settings where client_id = p_client and key = 'min_hours_present' and value ~ '^\d+(\.\d+)?$'),
        570)
$$;
revoke all on function public._required_minutes(uuid, text, date) from public, anon, authenticated;

-- is an OUT at this time early? (worked since the open IN versus the required minutes)
create or replace function public._early_out_info(p_client uuid, p_labor text, p_ts timestamp, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_in timestamp;
    v_worked int;
    v_req int;
begin
    select (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end into v_in
      from punch_records
     where client_id = p_client and labor_id = p_labor and type = 'login'
       and (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end < p_ts
     order by (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end desc limit 1;
    if v_in is null then return jsonb_build_object('early', false); end if;
    v_worked := floor(extract(epoch from (p_ts - v_in)) / 60);
    v_req := public._required_minutes(p_client, p_labor, p_date);
    return jsonb_build_object('early', v_worked < v_req, 'worked_minutes', v_worked, 'required_minutes', v_req, 'remaining_minutes', greatest(v_req - v_worked, 0));
end;
$$;
revoke all on function public._early_out_info(uuid, text, timestamp, date) from public, anon, authenticated;

-- the question the terminal asks before it takes the photo
create or replace function public.terminal_check_punch(p_labor_id text, p_type text, p_date date, p_time time)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_client uuid := public.require_terminal();
    v_rule jsonb;
    v_day record;
    v_early jsonb := jsonb_build_object('early', false);
    v_shift_name text;
begin
    if p_type is null or p_type not in ('login', 'logout') then raise exception 'invalid punch type' using errcode = 'P0001'; end if;
    if p_date is null or p_time is null then raise exception 'invalid date or time' using errcode = 'P0001'; end if;
    if not exists (select 1 from laborers where client_id = v_client and labor_id = p_labor_id and status = 'active') then
        raise exception 'unknown or inactive labor' using errcode = 'P0001';
    end if;
    select * into v_day from public._punch_day(v_client, p_labor_id, p_date, p_time);
    v_rule := public._punch_check(v_client, p_labor_id, p_type, p_date + p_time, v_day.final_date);
    select s.name into v_shift_name from shifts s where s.id = public.labor_shift_on(v_client, p_labor_id, v_day.final_date);
    if (v_rule ->> 'ok')::boolean and p_type = 'logout' then
        v_early := public._early_out_info(v_client, p_labor_id, p_date + p_time, v_day.final_date);
    end if;
    return jsonb_build_object('allowed', (v_rule ->> 'ok')::boolean, 'code', v_rule ->> 'code', 'message', v_rule ->> 'message',
                              'shift_name', v_shift_name, 'early', (v_early ->> 'early')::boolean,
                              'worked_minutes', v_early -> 'worked_minutes', 'required_minutes', v_early -> 'required_minutes', 'remaining_minutes', v_early -> 'remaining_minutes');
end;
$$;
revoke all on function public.terminal_check_punch(text, text, date, time) from public, anon;
grant execute on function public.terminal_check_punch(text, text, date, time) to authenticated;

-- the punch function: 009 version + early flag + shift name
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
    v_early jsonb := jsonb_build_object('early', false);
    v_shift uuid;
    v_shift_name text;
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

    -- early leave: an OUT before the shift's required hours is stored with a flag (the terminal asked the labor first; the database does not trust that)
    if v_type = 'logout' then v_early := public._early_out_info(v_client, v_labor_id, v_date + v_time, v_final_date); end if;
    v_shift := public.labor_shift_on(v_client, v_labor_id, v_final_date);
    select name into v_shift_name from shifts where id = v_shift;

    insert into punch_records (labor_id, department_id, date, time, type, location_id, location_name, confidence, photo_url, client_id, is_night_shift_end, early_out, early_minutes)
    values (v_labor_id, v_labor.department_id, v_final_date, v_time, v_type, v_location, left(p ->> 'location_name', 200), v_conf, v_photo, v_client, v_is_night_end,
            coalesce((v_early ->> 'early')::boolean, false), case when (v_early ->> 'early')::boolean then (v_early ->> 'remaining_minutes')::int end)
    returning id into v_id;

    update laborers set last_sync_at = now() where id = v_labor.id;
    perform public._recalc_attendance(v_client, v_labor_id, v_final_date);
    return jsonb_build_object('success', true, 'duplicate', false, 'id', v_id, 'date', v_final_date, 'is_night_shift_end', v_is_night_end,
                              'shift_name', v_shift_name, 'early_out', coalesce((v_early ->> 'early')::boolean, false));
end;
$$;
revoke all on function public.terminal_record_punch(jsonb) from public, anon;
grant execute on function public.terminal_record_punch(jsonb) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  011  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 011 applied' as result,
       (select count(*) from information_schema.columns where table_name = 'punch_records' and column_name = 'early_out') as early_out_column,
       (select count(*) from pg_proc where proname in ('_required_minutes', '_early_out_info', '_punch_check')) as helper_functions;
