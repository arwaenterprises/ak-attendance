-- ============================================================
-- Migration 020: a night-shift labor's OUT after midnight belongs to the day of the IN (owner decision, 2026-10-08)
-- ============================================================
-- Until now the system decided "this punch ends a night shift" from the clock only: the settings night_shift_start (default 20:00) and
-- night_shift_end (default 06:30). A night worker whose IN was at 18:30, or whose OUT was after 06:30, was split over two days.
-- Now the labor's ASSIGNED shift decides first:
--   if the labor's shift on the previous day is a Night shift and his latest punch is an IN of the previous day that is still open
--   (less than open_session_hours, default 20, ago), then this punch belongs to the day of that IN (stored on the IN's date, flagged as the end
--   of a night shift), at any time of day.
-- Everything else stays as before, including the old clock rule as a safety net (roadmap decision D4). Day-shift labors are not changed.
-- Safe to run again.
-- ============================================================

create or replace function public._punch_day(p_client uuid, p_labor text, p_date date, p_time time)
returns table (final_date date, is_night_end boolean) language plpgsql stable security definer set search_path = public as $$
declare
    v_night_start int := 20 * 60;
    v_night_end int := 6 * 60 + 30;
    v_open_hours int := 20;
    v_val text;
    v_mins int;
    v_prev_type text;
    v_prev_date date;
    v_prev_ts timestamp;
    v_prev_flag boolean;
    v_ts timestamp := p_date + p_time;
begin
    select value into v_val from settings where client_id = p_client and key = 'night_shift_start';
    if v_val ~ '^\d{1,2}:\d{2}' then v_night_start := split_part(v_val, ':', 1)::int * 60 + split_part(v_val, ':', 2)::int; end if;
    select value into v_val from settings where client_id = p_client and key = 'night_shift_end';
    if v_val ~ '^\d{1,2}:\d{2}' then v_night_end := split_part(v_val, ':', 1)::int * 60 + split_part(v_val, ':', 2)::int; end if;
    select nullif(value, '')::int into v_open_hours from settings where client_id = p_client and key = 'open_session_hours' and value ~ '^\d+$';
    v_open_hours := coalesce(v_open_hours, 20);

    final_date := p_date; is_night_end := false;

    -- 1. the labor's assigned shift: a night worker with an open IN from the previous day
    select r.type, r.date, (r.date + r.time) + case when r.is_night_shift_end then interval '1 day' else interval '0' end, r.is_night_shift_end
      into v_prev_type, v_prev_date, v_prev_ts, v_prev_flag
      from punch_records r
     where r.client_id = p_client and r.labor_id = p_labor
       and (r.date + r.time) + case when r.is_night_shift_end then interval '1 day' else interval '0' end < v_ts
     order by (r.date + r.time) + case when r.is_night_shift_end then interval '1 day' else interval '0' end desc
     limit 1;
    if v_prev_type = 'login' and v_prev_date = p_date - 1 and not coalesce(v_prev_flag, false)
       and v_ts - v_prev_ts < make_interval(hours => v_open_hours)
       and exists (select 1 from shifts s where s.id = public.labor_shift_on(p_client, p_labor, p_date - 1) and s.is_night) then
        final_date := p_date - 1; is_night_end := true;
        return next; return;
    end if;

    -- 2. the old clock rule (safety net, unchanged)
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

-- ============================================================
-- Changelog
-- 2026-10-08  020  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 020 applied' as result;
