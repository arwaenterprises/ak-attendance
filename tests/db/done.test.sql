-- Tests for migration 009: no second IN after a completed OUT on the same shift day (company TRI, terminal 71111111-...).
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('5300000001', 'LD1', '33333333-0000-0000-0000-000000000009'), ('5300000002', 'LD2', '33333333-0000-0000-0000-000000000009'), ('5300000003', 'LD3', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('LD1', '5300000001', 'Done One', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LD2', '5300000002', 'Done Two', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LD3', '5300000003', 'Done Three', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');

do $$ declare r jsonb; n int; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  -- day shift
  r := public.t_punch('LD1', 'login', 3, '06:00:00');
  perform public.t_log('day: IN accepted', (r ->> 'success')::boolean, r::text);
  r := public.t_punch('LD1', 'logout', 3, '11:00:00');
  perform public.t_log('day: OUT after 5 hours accepted', (r ->> 'success')::boolean, r::text);
  r := public.t_punch('LD1', 'login', 3, '12:00:00');
  perform public.t_log('day: a second IN the same day is refused: "You have already logged out for the day"', not (r ->> 'success')::boolean and r ->> 'code' = 'ALREADY_DONE' and r ->> 'message' = 'You have already logged out for the day', r::text);
  r := public.terminal_check_punch('LD1', 'login', current_date - 3, '12:30');
  perform public.t_log('day: the check function says the same before the photo is taken', not (r ->> 'allowed')::boolean and r ->> 'code' = 'ALREADY_DONE', r::text);
  r := public.t_punch('LD1', 'logout', 3, '13:00:00');
  perform public.t_log('day: a second OUT is still refused (no open IN)', not (r ->> 'success')::boolean and r ->> 'code' = 'NO_OPEN_IN', r::text);
  r := public.t_punch('LD1', 'login', 2, '06:00:00');
  perform public.t_log('day: the next day IN is accepted', (r ->> 'success')::boolean, r::text);
  r := public.t_punch('LD1', 'logout', 3, '11:00:00');
  perform public.t_log('day: re-sending the stored OUT (offline upload twice) is a harmless duplicate', (r ->> 'success')::boolean and (r ->> 'duplicate')::boolean, r::text);
  reset role;
  select count(*) into n from punch_records where labor_id = 'LD1' and client_id = '33333333-0000-0000-0000-000000000009';
  perform public.t_log('day: refused punches are not stored (3 rows: IN, OUT, next day IN)', n = 3, n::text);
end $$;

-- night shift: IN 21:00, OUT 05:30 next morning, no IN until the evening
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LD2', 'login', 6, '21:00:00');
  r := public.t_punch('LD2', 'logout', 5, '05:30:00');
  perform public.t_log('night: OUT at 05:30 accepted (belongs to the evening before)', (r ->> 'success')::boolean and (r ->> 'is_night_shift_end')::boolean, r::text);
  r := public.t_punch('LD2', 'login', 5, '05:45:00');
  perform public.t_log('night: an IN at 05:45 right after that OUT is refused (same shift day)', not (r ->> 'success')::boolean and r ->> 'code' = 'ALREADY_DONE', r::text);
  r := public.terminal_check_punch('LD2', 'login', current_date - 5, '05:45');
  perform public.t_log('night: the check function agrees', not (r ->> 'allowed')::boolean and r ->> 'code' = 'ALREADY_DONE', r::text);
  r := public.t_punch('LD2', 'login', 5, '21:00:00');
  perform public.t_log('night: the same evening IN (new shift day) is accepted', (r ->> 'success')::boolean, r::text);
  reset role;
end $$;

-- regression: the 007 rules still hold
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LD3', 'logout', 4, '07:00:00');
  perform public.t_log('still: OUT with no IN is refused', r ->> 'code' = 'NO_OPEN_IN', r::text);
  r := public.t_punch('LD3', 'login', 4, '06:00:00');
  r := public.t_punch('LD3', 'login', 4, '06:30:00');
  perform public.t_log('still: a second IN while IN is refused (not ALREADY_DONE)', r ->> 'code' = 'ALREADY_IN', r::text);
  r := public.t_punch('LD3', 'logout', 4, '08:00:00');
  perform public.t_log('still: OUT before 4 hours is refused', r ->> 'code' = 'TOO_EARLY', r::text);
  reset role;
end $$;
