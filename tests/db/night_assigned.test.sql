-- Tests for migration 020: a night-shift labor's OUT belongs to the day of the IN, whatever the clock says (company TRI, terminal 71111111-...).
-- LNA = assigned to the Night shift, LNB = day shift (no assignment), LNC = night labor who forgot the OUT.
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('5900000001', 'LNA', '33333333-0000-0000-0000-000000000009'), ('5900000002', 'LNB', '33333333-0000-0000-0000-000000000009'), ('5900000003', 'LNC', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('LNA', '5900000001', 'Night A', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LNB', '5900000002', 'Day B', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LNC', '5900000003', 'Night C', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');
insert into shift_assignments (client_id, labor_id, shift_id, from_date)
select '33333333-0000-0000-0000-000000000009', x, (select id from shifts where client_id = '33333333-0000-0000-0000-000000000009' and code = 'NIGHT'), date '2000-01-01'
  from unnest(array['LNA', 'LNC']) x;

do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  -- night worker: IN at 18:30 (before the old 20:00 clock rule), OUT next morning at 07:10 (after the old 06:30 end)
  r := public.t_punch('LNA', 'login', 6, '18:30:00');
  perform public.t_log('LNA IN 18:30 is stored on its own day', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 6, r::text);
  r := public.terminal_check_punch('LNA', 'logout', current_date - 5, '07:10');
  perform public.t_log('the check for the OUT at 07:10 next morning allows it and counts from the IN (early info follows the IN)', (r ->> 'allowed')::boolean and (r ->> 'worked_minutes')::int = 760, r::text);
  r := public.t_punch('LNA', 'logout', 5, '07:10:00');
  perform public.t_log('LNA OUT 07:10 next morning is stored on the day of the IN as the end of a night shift', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 6 and (r ->> 'is_night_shift_end')::boolean, r::text);
  reset role;
  select * into d from daily_attendance where labor_id = 'LNA' and date = current_date - 6;
  perform public.t_log('that day counts 12 h 40 m (18:30 to 07:10), not 0', d.total_hours is not null and round(d.total_hours, 2) = 12.67, row(d.first_login, d.last_logout, d.total_hours)::text);
  perform public.t_log('nothing is stored on the next day', (select count(*) = 0 from punch_records where labor_id = 'LNA' and date = current_date - 5), '');
end $$;

-- day worker: nothing changes (IN 14:00, OUT 03:03 next morning is still stored on the next day)
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LNB', 'login', 6, '14:00:00');
  r := public.t_punch('LNB', 'logout', 5, '03:03:00');
  perform public.t_log('a day-shift labor is not changed: the OUT after midnight keeps the date it was punched', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 5 and not (r ->> 'is_night_shift_end')::boolean, r::text);
  reset role;
end $$;

-- night worker who forgot the OUT: the IN is older than 20 hours, so the next evening's IN starts a new day
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LNC', 'login', 4, '18:30:00');
  r := public.t_punch('LNC', 'login', 3, '18:30:00');
  perform public.t_log('a forgotten OUT does not swallow the next evening: the new IN is stored on its own day', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 3 and not (r ->> 'is_night_shift_end')::boolean, r::text);
  reset role;
end $$;

-- the labor's own shift is checked on the previous day: a night worker moved to Day after the IN day is not affected
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LNA', 'login', 2, '18:30:00');
  r := public.t_punch('LNA', 'logout', 1, '05:55:00');
  perform public.t_log('a second night: IN 18:30, OUT 05:55 next morning stays with the IN day', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 2 and (r ->> 'is_night_shift_end')::boolean, r::text);
  reset role;
end $$;
