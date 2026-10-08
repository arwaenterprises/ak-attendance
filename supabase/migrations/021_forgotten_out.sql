-- ============================================================
-- Migration 021: a forgotten OUT of an earlier day does not block the new day (owner decision, 2026-10-08)
-- ============================================================
-- Until now an IN was refused ("You have logged in for the day") whenever the labor's latest punch was an IN less than
-- open_session_hours (default 20) ago. A day-shift labor who forgot to punch OUT yesterday could therefore not punch IN
-- next morning if that was less than 20 hours after yesterday's IN.
-- Now: an open IN of an EARLIER day counts as a forgotten OUT and the labor may punch IN again, so the new day starts fresh.
--   * the forgotten day keeps only its IN (no OUT, so no hours; the administrator can approve it on the daily report as before)
--   * NOT for night-shift labors: their open IN of the previous day is their running night shift, so a second IN stays refused
--   * a second IN on the SAME day stays refused
-- Everything else in the rules is unchanged (migration 016's text). Safe to run again.
-- ============================================================

create or replace function public._punch_check(p_client uuid, p_labor text, p_type text, p_ts timestamp, p_final_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_min_minutes int := 240;
    v_open_hours int := 20;
    v_prev_type text;
    v_prev_ts timestamp;
    v_prev_date date;
begin
    select nullif(value, '')::int into v_min_minutes from settings where client_id = p_client and key = 'min_session_minutes' and value ~ '^\d+$';
    v_min_minutes := coalesce(v_min_minutes, 240);
    select nullif(value, '')::int into v_open_hours from settings where client_id = p_client and key = 'open_session_hours' and value ~ '^\d+$';
    v_open_hours := coalesce(v_open_hours, 20);

    select type, (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end, date
      into v_prev_type, v_prev_ts, v_prev_date
      from punch_records
     where client_id = p_client and labor_id = p_labor
       and (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end < p_ts
     order by (date + time) + case when is_night_shift_end then interval '1 day' else interval '0' end desc
     limit 1;

    if p_type = 'login' then
        if v_prev_type = 'login' and p_ts - v_prev_ts < make_interval(hours => v_open_hours) then
            -- an open IN of an earlier day of a day-shift labor = a forgotten OUT: the new day may start
            if not (v_prev_date < p_final_date
                    and not exists (select 1 from shifts s where s.id = public.labor_shift_on(p_client, p_labor, v_prev_date) and s.is_night)) then
                return jsonb_build_object('ok', false, 'code', 'ALREADY_IN', 'message', 'You have logged in for the day');
            end if;
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

-- ============================================================
-- Changelog
-- 2026-10-08  021  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 021 applied' as result;
