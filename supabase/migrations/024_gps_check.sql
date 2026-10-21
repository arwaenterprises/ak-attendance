-- ============================================================
-- Migration 024: the server checks the punch location itself (owner decisions 2026-10-21, ROADMAP section H)
-- ============================================================
-- Before: the phone decided "I am inside the punch area" and only sent the NAME of the location; the database believed it.
-- Now the terminal sends its GPS readings (3 readings taken during the face countdown) and the database decides:
--   * no readings                                              -> refused "Location not found"
--   * the best reading claims an accuracy below 1 m (impossible for a phone; typical of fake GPS apps)
--                                                              -> refused "Location not found"
--   * 3 or more readings at EXACTLY the same point with GPS-grade accuracy (20 m or better): real GPS always moves a little,
--     many fake GPS apps do not                                -> refused "Location not found"   (setting gps_static_check, default on)
--   * the best accuracy is worse than max_gps_accuracy (setting, default 100 m)
--                                                              -> refused "Weak GPS signal. Please step outside and try again."
--   * not inside an active punch location of the labor's department (distance <= radius)
--                                                              -> refused "You are outside the authorized punch area"
-- The database also picks the punch location itself (nearest of the labor's department) and keeps the position with the punch.
-- A refused punch is NOT stored (same as the IN / OUT rules). Offline punches are checked the same way when they are uploaded.
-- Changeover: phones still running the old app send no readings. They are accepted (old behaviour) until the date in the setting
-- gps_required_from, set below to 3 days after this migration for every existing company; a company created later has no such
-- setting, so the check applies at once.
-- Everything else in terminal_record_punch is migration 011's text. Run AFTER 023. Safe to run again.
-- ============================================================

alter table public.punch_records add column if not exists latitude numeric;
alter table public.punch_records add column if not exists longitude numeric;
alter table public.punch_records add column if not exists gps_accuracy numeric;

insert into public.settings (client_id, key, value, description)
select c.id, 'gps_required_from', (current_date + 3)::text, 'Until this date a punch from an old app without GPS readings is still accepted (migration 024)'
  from public.clients c
on conflict (client_id, key) do nothing;

-- distance in metres between two points (haversine)
create or replace function public._distance_m(p_lat1 double precision, p_lng1 double precision, p_lat2 double precision, p_lng2 double precision)
returns double precision language sql immutable as $$
    select 2 * 6371000 * asin(sqrt(power(sin(radians(p_lat2 - p_lat1) / 2), 2)
                                  + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lng2 - p_lng1) / 2), 2)))
$$;

-- the GPS check: { ok, code, message } and, when ok, the location the punch belongs to and the position kept with it
create or replace function public._gps_check(p_client uuid, p_department uuid, p_gps jsonb, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_max_acc numeric := 100;
    v_static boolean := true;
    v_from date;
    v_val text;
    v_n int;
    v_best record;
    v_points int;
    v_loc record;
begin
    select value into v_val from settings where client_id = p_client and key = 'max_gps_accuracy';
    if v_val ~ '^\d+(\.\d+)?$' then v_max_acc := v_val::numeric; end if;
    select value into v_val from settings where client_id = p_client and key = 'gps_static_check';
    if v_val = 'false' then v_static := false; end if;
    select value into v_val from settings where client_id = p_client and key = 'gps_required_from';
    if v_val ~ '^\d{4}-\d{2}-\d{2}$' then v_from := v_val::date; end if;

    if p_gps is null or jsonb_typeof(p_gps) <> 'array' or jsonb_array_length(p_gps) = 0 then
        if v_from is not null and p_date < v_from then return jsonb_build_object('ok', true, 'legacy', true); end if;   -- old app, changeover days
        return jsonb_build_object('ok', false, 'code', 'LOCATION_NOT_FOUND', 'message', 'Location not found');
    end if;
    if jsonb_array_length(p_gps) > 20 then return jsonb_build_object('ok', false, 'code', 'LOCATION_NOT_FOUND', 'message', 'Location not found'); end if;

    -- readings that look like a position at all
    with r as (
        select (e ->> 'lat')::double precision as lat, (e ->> 'lng')::double precision as lng, (e ->> 'acc')::double precision as acc
          from jsonb_array_elements(p_gps) e
         where jsonb_typeof(e) = 'object'
           and (e ->> 'lat') ~ '^-?\d+(\.\d+)?$' and (e ->> 'lng') ~ '^-?\d+(\.\d+)?$' and (e ->> 'acc') ~ '^\d+(\.\d+)?$')
    select count(*), count(distinct (lat, lng)) into v_n, v_points from r where abs(lat) <= 90 and abs(lng) <= 180;
    if v_n = 0 then return jsonb_build_object('ok', false, 'code', 'LOCATION_NOT_FOUND', 'message', 'Location not found'); end if;

    select (e ->> 'lat')::double precision as lat, (e ->> 'lng')::double precision as lng, (e ->> 'acc')::double precision as acc
      into v_best
      from jsonb_array_elements(p_gps) e
     where jsonb_typeof(e) = 'object'
       and (e ->> 'lat') ~ '^-?\d+(\.\d+)?$' and (e ->> 'lng') ~ '^-?\d+(\.\d+)?$' and (e ->> 'acc') ~ '^\d+(\.\d+)?$'
       and abs((e ->> 'lat')::double precision) <= 90 and abs((e ->> 'lng')::double precision) <= 180
     order by 3, 1, 2 limit 1;
    if v_best.acc < 1 then return jsonb_build_object('ok', false, 'code', 'LOCATION_NOT_FOUND', 'message', 'Location not found'); end if;
    if v_static and v_n >= 3 and v_points = 1 and v_best.acc <= 20 then
        return jsonb_build_object('ok', false, 'code', 'LOCATION_NOT_FOUND', 'message', 'Location not found');
    end if;
    if v_best.acc > v_max_acc then
        return jsonb_build_object('ok', false, 'code', 'POOR_GPS', 'message', 'Weak GPS signal. Please step outside and try again.');
    end if;

    select l.id, l.name, public._distance_m(v_best.lat, v_best.lng, l.latitude::double precision, l.longitude::double precision) as d
      into v_loc
      from punch_locations l
     where l.client_id = p_client and l.department_id = p_department and l.status = 'active'
       and public._distance_m(v_best.lat, v_best.lng, l.latitude::double precision, l.longitude::double precision) <= coalesce(l.radius, 100)
     order by 3 limit 1;
    if v_loc.id is null then
        return jsonb_build_object('ok', false, 'code', 'OUTSIDE_AREA', 'message', 'You are outside the authorized punch area');
    end if;
    return jsonb_build_object('ok', true, 'location_id', v_loc.id, 'location_name', v_loc.name, 'distance', round(v_loc.d),
                              'lat', v_best.lat, 'lng', v_best.lng, 'acc', v_best.acc);
end;
$$;
revoke all on function public._gps_check(uuid, uuid, jsonb, date) from public, anon, authenticated;

-- the punch function: migration 011's text + the GPS check (the location now comes from the database)
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
    v_location_name text := null;
    v_conf int := null;
    v_photo text := nullif(p ->> 'photo_url', '');
    v_id uuid;
    v_existing uuid;
    v_rule jsonb;
    v_gps jsonb;
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

    -- the GPS check (migration 024): the database decides whether the labor is inside a punch area, and which one
    v_gps := public._gps_check(v_client, v_labor.department_id, p -> 'gps', v_date);
    if not (v_gps ->> 'ok')::boolean then
        return jsonb_build_object('success', false, 'rejected', true, 'code', v_gps ->> 'code', 'message', v_gps ->> 'message');
    end if;
    if coalesce((v_gps ->> 'legacy')::boolean, false) then
        -- old app during the changeover days: as before
        if p ->> 'location_id' is not null then
            select id into v_location from punch_locations where id = (p ->> 'location_id')::uuid and client_id = v_client;
        end if;
        v_location_name := left(p ->> 'location_name', 200);
    else
        v_location := (v_gps ->> 'location_id')::uuid;
        v_location_name := v_gps ->> 'location_name';
    end if;

    -- early leave: an OUT before the shift's required hours is stored with a flag (the terminal asked the labor first; the database does not trust that)
    if v_type = 'logout' then v_early := public._early_out_info(v_client, v_labor_id, v_date + v_time, v_final_date); end if;
    v_shift := public.labor_shift_on(v_client, v_labor_id, v_final_date);
    select name into v_shift_name from shifts where id = v_shift;

    insert into punch_records (labor_id, department_id, date, time, type, location_id, location_name, confidence, photo_url, client_id, is_night_shift_end,
                               early_out, early_minutes, latitude, longitude, gps_accuracy)
    values (v_labor_id, v_labor.department_id, v_final_date, v_time, v_type, v_location, v_location_name, v_conf, v_photo, v_client, v_is_night_end,
            coalesce((v_early ->> 'early')::boolean, false), case when (v_early ->> 'early')::boolean then (v_early ->> 'remaining_minutes')::int end,
            (v_gps ->> 'lat')::numeric, (v_gps ->> 'lng')::numeric, (v_gps ->> 'acc')::numeric)
    returning id into v_id;

    update laborers set last_sync_at = now() where id = v_labor.id;
    perform public._recalc_attendance(v_client, v_labor_id, v_final_date);
    return jsonb_build_object('success', true, 'duplicate', false, 'id', v_id, 'date', v_final_date, 'is_night_shift_end', v_is_night_end,
                              'shift_name', v_shift_name, 'early_out', coalesce((v_early ->> 'early')::boolean, false), 'location_name', v_location_name);
end;
$$;
revoke all on function public.terminal_record_punch(jsonb) from public, anon;
grant execute on function public.terminal_record_punch(jsonb) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-21  024  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 024 applied' as result,
       (select count(*) from public.settings where key = 'gps_required_from') as companies_with_changeover_days;
