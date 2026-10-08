-- Tests for migration 021: a forgotten OUT of an earlier day does not block the new day (company TRI, terminal 71111111-...).
-- LFD = day worker, LFE = day worker (same-day case), LFN = night worker (assigned Night).
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('6000000001', 'LFD', '33333333-0000-0000-0000-000000000009'), ('6000000002', 'LFE', '33333333-0000-0000-0000-000000000009'), ('6000000003', 'LFN', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('LFD', '6000000001', 'Forgot D', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LFE', '6000000002', 'Same day E', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LFN', '6000000003', 'Night N', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');
insert into shift_assignments (client_id, labor_id, shift_id, from_date)
select '33333333-0000-0000-0000-000000000009', 'LFN', (select id from shifts where client_id = '33333333-0000-0000-0000-000000000009' and code = 'NIGHT'), date '2000-01-01';

do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  -- day worker: IN 14:00, forgets the OUT, comes back next morning at 08:00 (18 hours later, inside the 20 hour window)
  r := public.t_punch('LFD', 'login', 5, '14:00:00');
  r := public.terminal_check_punch('LFD', 'login', current_date - 4, '08:00');
  perform public.t_log('LFD: the check says the new IN next morning is allowed', (r ->> 'allowed')::boolean, r::text);
  r := public.t_punch('LFD', 'login', 4, '08:00:00');
  perform public.t_log('LFD: the IN next morning (forgotten OUT yesterday) is accepted on its own day', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 4 and not (r ->> 'is_night_shift_end')::boolean, r::text);
  r := public.t_punch('LFD', 'logout', 4, '17:30:00');
  perform public.t_log('LFD: the OUT that evening pairs with the new IN', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 4, r::text);
  reset role;
  select * into d from daily_attendance where labor_id = 'LFD' and date = current_date - 4;
  perform public.t_log('LFD: the new day counts 9 h 30 m (08:00 to 17:30)', d.total_hours is not null and round(d.total_hours, 2) = 9.5, row(d.first_login, d.last_logout, d.total_hours)::text);
  select * into d from daily_attendance where labor_id = 'LFD' and date = current_date - 5;
  perform public.t_log('LFD: the forgotten day keeps only its IN (no hours, not present)', d.total_hours = 0 and d.auto_status = 'A', row(d.first_login, d.last_logout, d.total_hours, d.auto_status)::text);
end $$;

-- a second IN on the SAME day is still refused
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LFE', 'login', 3, '06:00:00');
  r := public.t_punch('LFE', 'login', 3, '06:30:00');
  perform public.t_log('LFE: a second IN on the same day is still refused', not (r ->> 'success')::boolean and r ->> 'code' = 'ALREADY_IN', r::text);
  reset role;
end $$;

-- a night worker's open IN of the previous day is his running shift: a second IN stays refused
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LFN', 'login', 3, '18:30:00');
  r := public.t_punch('LFN', 'login', 2, '06:00:00');
  perform public.t_log('LFN: a night worker cannot punch IN again while his night shift is open', not (r ->> 'success')::boolean and r ->> 'code' = 'ALREADY_IN', r::text);
  r := public.t_punch('LFN', 'logout', 2, '06:20:00');
  perform public.t_log('LFN: his OUT in the morning still closes the night shift on the day of the IN', (r ->> 'success')::boolean and (r ->> 'date')::date = current_date - 3 and (r ->> 'is_night_shift_end')::boolean, r::text);
  reset role;
end $$;
