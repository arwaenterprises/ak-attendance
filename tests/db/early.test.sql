-- Tests for migration 011: early leave warning data, early flag stored, shift name returned (company TRI, terminal 71111111-...).
update departments set min_hours_full_day = '10:00' where id = 'd7000000-0000-0000-0000-000000000007';
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('5500000001', 'LE1', '33333333-0000-0000-0000-000000000009'), ('5500000002', 'LE2', '33333333-0000-0000-0000-000000000009'),
  ('5500000003', 'LE3', '33333333-0000-0000-0000-000000000009'), ('5500000004', 'LE4', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('LE1', '5500000001', 'Early One', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LE2', '5500000002', 'Early Two', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LE3', '5500000003', 'Early Three', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LE4', '5500000004', 'Early Four', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');

do $$ declare r jsonb; c jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LE1', 'login', 3, '06:00:00');
  perform public.t_log('the IN answer carries the shift name', r ->> 'shift_name' = 'Day shift', r::text);
  c := public.terminal_check_punch('LE1', 'login', current_date - 2, '06:00');
  perform public.t_log('the check for an IN also carries the shift name and no early warning', c ->> 'shift_name' = 'Day shift' and not (c ->> 'early')::boolean, c::text);
  c := public.terminal_check_punch('LE1', 'logout', current_date - 3, '11:00');
  perform public.t_log('OUT after 5 hours with a 10 hour department: allowed, early, 300 of 600 worked, 300 remaining',
    (c ->> 'allowed')::boolean and (c ->> 'early')::boolean and (c ->> 'worked_minutes')::int = 300 and (c ->> 'required_minutes')::int = 600 and (c ->> 'remaining_minutes')::int = 300, c::text);
  c := public.terminal_check_punch('LE1', 'logout', current_date - 3, '16:30');
  perform public.t_log('OUT after 10.5 hours: allowed, not early', (c ->> 'allowed')::boolean and not (c ->> 'early')::boolean, c::text);
  c := public.terminal_check_punch('LE1', 'logout', current_date - 3, '08:00');
  perform public.t_log('OUT after 2 hours: still refused by the hidden minimum (no early warning)', not (c ->> 'allowed')::boolean and c ->> 'code' = 'TOO_EARLY' and not (c ->> 'early')::boolean, c::text);
  r := public.t_punch('LE1', 'logout', 3, '11:00:00');
  perform public.t_log('the early OUT is recorded and reported as early', (r ->> 'success')::boolean and (r ->> 'early_out')::boolean, r::text);
  reset role;
  perform public.t_log('the flag and the missing minutes are stored on the OUT row', (select early_out and early_minutes = 300 from punch_records where labor_id = 'LE1' and type = 'logout'), '');
  perform public.t_log('the IN row is not flagged', (select not early_out from punch_records where labor_id = 'LE1' and type = 'login'), '');
end $$;

do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LE2', 'login', 4, '06:00:00');
  r := public.t_punch('LE2', 'logout', 4, '16:00:00');
  reset role;
  perform public.t_log('OUT after exactly the required 10 hours is not early', (r ->> 'success')::boolean and not (r ->> 'early_out')::boolean and (select not early_out from punch_records where labor_id = 'LE2' and type = 'logout'), r::text);
end $$;

-- the shift's own required hours win over the department
update shifts set required_hours = 8 where client_id = '33333333-0000-0000-0000-000000000009' and code = 'DAY';
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LE3', 'login', 5, '06:00:00');
  r := public.t_punch('LE3', 'logout', 5, '14:30:00');
  reset role;
  perform public.t_log('with the shift set to 8 hours, an OUT after 8.5 hours is not early (shift beats department)', (r ->> 'success')::boolean and not (r ->> 'early_out')::boolean, r::text);
end $$;
update shifts set required_hours = null where client_id = '33333333-0000-0000-0000-000000000009' and code = 'DAY';

-- night shift: 21:00 to 05:30 = 8.5 h of 10 h: early, 90 minutes missing
do $$ declare r jsonb; c jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LE4', 'login', 7, '21:00:00');
  c := public.terminal_check_punch('LE4', 'logout', current_date - 6, '05:30');
  perform public.t_log('night: OUT at 05:30 after 8.5 hours: early, 90 minutes remaining', (c ->> 'allowed')::boolean and (c ->> 'early')::boolean and (c ->> 'remaining_minutes')::int = 90, c::text);
  r := public.t_punch('LE4', 'logout', 6, '05:30:00');
  reset role;
  perform public.t_log('night: stored as early with 90 minutes', (select early_out and early_minutes = 90 from punch_records where labor_id = 'LE4' and type = 'logout'), r::text);
end $$;
update departments set min_hours_full_day = '09:30' where id = 'd7000000-0000-0000-0000-000000000007';
