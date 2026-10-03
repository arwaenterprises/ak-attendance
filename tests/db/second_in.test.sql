-- Tests for migration 016: a second IN after an OUT on the same day is allowed; hours = first IN to last OUT (company TRI, terminal 71111111-...).
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('5600000001', 'LQ1', '33333333-0000-0000-0000-000000000009'), ('5600000002', 'LQ2', '33333333-0000-0000-0000-000000000009'),
  ('5600000003', 'LQ3', '33333333-0000-0000-0000-000000000009'), ('5600000004', 'LQ4', '33333333-0000-0000-0000-000000000009'),
  ('5600000005', 'LQ5', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('LQ1', '5600000001', 'Second One', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LQ2', '5600000002', 'Second Two', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LQ3', '5600000003', 'Second Three', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LQ4', '5600000004', 'Second Four', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LQ5', '5600000005', 'Second Five', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');

-- A. IN, OUT, IN, OUT on one day: all accepted; hours = first IN to last OUT
do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LQ1', 'login', 3, '06:00:00');
  r := public.t_punch('LQ1', 'logout', 3, '11:00:00');
  r := public.t_punch('LQ1', 'login', 3, '12:00:00');
  perform public.t_log('A: a second IN after the OUT the same day is accepted', (r ->> 'success')::boolean, r::text);
  r := public.terminal_check_punch('LQ1', 'logout', current_date - 3, '16:30');
  perform public.t_log('A: the check for the second OUT is allowed', (r ->> 'allowed')::boolean, r::text);
  r := public.t_punch('LQ1', 'logout', 3, '16:30:00');
  perform public.t_log('A: the second OUT (more than 4 hours after the second IN) is accepted', (r ->> 'success')::boolean, r::text);
  reset role;
  select * into d from daily_attendance where labor_id = 'LQ1' and date = current_date - 3;
  perform public.t_log('A: first login 06:00, last logout 16:30, 10.5 hours, present', d.first_login = '06:00' and d.last_logout = '16:30' and d.total_hours = 10.5 and d.final_status = 'P',
    row(d.first_login, d.last_logout, d.total_hours, d.final_status)::text);
end $$;

-- B. IN, OUT, IN (second OUT missing): hours = first IN to the first OUT
do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LQ2', 'login', 3, '06:00:00');
  r := public.t_punch('LQ2', 'logout', 3, '11:00:00');
  r := public.t_punch('LQ2', 'login', 3, '12:00:00');
  reset role;
  select * into d from daily_attendance where labor_id = 'LQ2' and date = current_date - 3;
  perform public.t_log('B: with the second OUT missing, hours run from the first IN to the first OUT (5 h, last logout 11:00)', d.first_login = '06:00' and d.last_logout = '11:00' and d.total_hours = 5, row(d.first_login, d.last_logout, d.total_hours)::text);
end $$;

-- C. the 4-hour rule is NOT changed: an OUT less than 4 hours after the second IN is refused; a repeated IN while IN is still refused
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LQ3', 'login', 3, '06:00:00');
  r := public.t_punch('LQ3', 'logout', 3, '11:00:00');
  r := public.t_punch('LQ3', 'login', 3, '12:00:00');
  r := public.t_punch('LQ3', 'logout', 3, '13:00:00');
  perform public.t_log('C: an OUT one hour after the second IN is refused (4-hour rule untouched)', r ->> 'code' = 'TOO_EARLY', r::text);
  r := public.t_punch('LQ3', 'login', 3, '13:30:00');
  perform public.t_log('C: an IN while an IN is open is still refused', r ->> 'code' = 'ALREADY_IN', r::text);
  reset role;
end $$;

-- D. "Leaving early?" counts from the FIRST IN of the day
do $$ declare r jsonb; c jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LQ4', 'login', 3, '06:00:00');
  r := public.t_punch('LQ4', 'logout', 3, '10:30:00');
  r := public.t_punch('LQ4', 'login', 3, '10:40:00');
  c := public.terminal_check_punch('LQ4', 'logout', current_date - 3, '14:50');
  perform public.t_log('D: second OUT at 14:50: allowed, early, 530 minutes worked since the FIRST IN (not 250)',
    (c ->> 'allowed')::boolean and (c ->> 'early')::boolean and (c ->> 'worked_minutes')::int = 530 and (c ->> 'required_minutes')::int = 570, c::text);
  c := public.terminal_check_punch('LQ4', 'logout', current_date - 3, '15:40');
  perform public.t_log('D: second OUT at 15:40: 580 minutes since the first IN, not early', (c ->> 'allowed')::boolean and not (c ->> 'early')::boolean, c::text);
  reset role;
end $$;

-- E. night shift: IN 21:00, OUT 05:30 next morning, then a new IN: accepted; the open IN does not change the night hours
do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LQ5', 'login', 6, '21:00:00');
  r := public.t_punch('LQ5', 'logout', 5, '05:30:00');
  r := public.t_punch('LQ5', 'login', 5, '05:45:00');
  perform public.t_log('E: an IN right after a night OUT is accepted', (r ->> 'success')::boolean, r::text);
  reset role;
  select * into d from daily_attendance where labor_id = 'LQ5' and date = current_date - 6;
  perform public.t_log('E: night hours stay 8.5 (21:00 to 05:30), the open IN is not counted', d.total_hours = 8.5, row(d.first_login, d.last_logout, d.total_hours)::text);
end $$;
