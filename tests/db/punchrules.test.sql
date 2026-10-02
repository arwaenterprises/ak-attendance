-- Tests for migration 007: IN / OUT rules (repeat, mismatch, 4-hour lock, night shift, forgotten OUT, offline duplicates).
-- Company TRI (33333333-...) has a terminal login 71111111-...; test labors are created here.
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('5100000001', 'LR1', '33333333-0000-0000-0000-000000000009'), ('5100000002', 'LR2', '33333333-0000-0000-0000-000000000009'),
  ('5100000003', 'LR3', '33333333-0000-0000-0000-000000000009'), ('5100000004', 'LR4', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('LR1', '5100000001', 'Rule One', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LR2', '5100000002', 'Rule Two', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LR3', '5100000003', 'Rule Three', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('LR4', '5100000004', 'Rule Four', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');

create or replace function public.t_punch(p_labor text, p_type text, p_day int, p_time text) returns jsonb language plpgsql as $$
begin
  return public.terminal_record_punch(jsonb_build_object('labor_id', p_labor, 'type', p_type, 'date', (current_date - p_day)::text, 'time', p_time));
end $$;

do $$ declare r jsonb; n int; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  -- 1. OUT with no IN
  r := public.t_punch('LR1', 'logout', 3, '07:00:00');
  perform public.t_log('OUT with no IN is refused (NO_OPEN_IN, "Please punch IN first")', not (r ->> 'success')::boolean and r ->> 'code' = 'NO_OPEN_IN' and r ->> 'message' = 'Please punch IN first', r::text);
  -- 2. IN
  r := public.t_punch('LR1', 'login', 3, '06:00:00');
  perform public.t_log('IN is accepted', (r ->> 'success')::boolean, r::text);
  -- 3. IN again
  r := public.t_punch('LR1', 'login', 3, '06:30:00');
  perform public.t_log('a second IN is refused: "You have logged in for the day"', not (r ->> 'success')::boolean and r ->> 'code' = 'ALREADY_IN' and r ->> 'message' = 'You have logged in for the day', r::text);
  -- 4. OUT after 2 hours
  r := public.t_punch('LR1', 'logout', 3, '08:00:00');
  perform public.t_log('OUT after 2 hours is refused (4-hour lock): "You have logged in for the day"', not (r ->> 'success')::boolean and r ->> 'code' = 'TOO_EARLY' and r ->> 'message' = 'You have logged in for the day', r::text);
  -- 5. OUT after 3h59m
  r := public.t_punch('LR1', 'logout', 3, '09:59:00');
  perform public.t_log('OUT after 3h59m is still refused', not (r ->> 'success')::boolean and r ->> 'code' = 'TOO_EARLY', r::text);
  -- 6. OUT after exactly 4 hours
  r := public.t_punch('LR1', 'logout', 3, '10:00:00');
  perform public.t_log('OUT after exactly 4 hours is accepted', (r ->> 'success')::boolean, r::text);
  -- 7. new IN after OUT
  r := public.t_punch('LR1', 'login', 3, '10:30:00');
  perform public.t_log('a new IN after a completed OUT is accepted (as before)', (r ->> 'success')::boolean, r::text);
  r := public.t_punch('LR1', 'logout', 3, '12:00:00');
  perform public.t_log('OUT 1.5 hours after the new IN is refused', not (r ->> 'success')::boolean and r ->> 'code' = 'TOO_EARLY', r::text);
  -- 8. refused punches are not stored
  reset role;
  select count(*) into n from punch_records where labor_id = 'LR1' and client_id = '33333333-0000-0000-0000-000000000009';
  perform public.t_log('only the 3 accepted punches are stored (IN, OUT, IN)', n = 3, n::text);
end $$;

-- the same punch uploaded twice (offline) is a harmless duplicate, even though the rule would refuse a new one
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LR1', 'login', 3, '06:00:00');
  perform public.t_log('re-sending an already stored IN returns "duplicate", not a refusal', (r ->> 'success')::boolean and (r ->> 'duplicate')::boolean, r::text);
  reset role;
end $$;

-- check function (used before the photo is taken)
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_check_punch('LR1', 'login', current_date - 3, '11:00');
  perform public.t_log('check: IN while an IN is open is not allowed', not (r ->> 'allowed')::boolean and r ->> 'code' = 'ALREADY_IN', r::text);
  r := public.terminal_check_punch('LR1', 'logout', current_date - 3, '15:00');
  perform public.t_log('check: OUT 4.5 hours after the IN is allowed', (r ->> 'allowed')::boolean, r::text);
  r := public.terminal_check_punch('LR1', 'logout', current_date - 3, '11:00');
  perform public.t_log('check: OUT 30 minutes after the IN is not allowed', not (r ->> 'allowed')::boolean and r ->> 'code' = 'TOO_EARLY', r::text);
  reset role;
end $$;

-- night shift: IN 21:00, OUT 05:30 next morning (stored on the IN date), then IN again that evening
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LR2', 'login', 6, '21:00:00');
  perform public.t_log('night: evening IN accepted', (r ->> 'success')::boolean, r::text);
  r := public.t_punch('LR2', 'login', 5, '05:30:00');
  perform public.t_log('night: an IN at 05:30 while the evening IN is open is refused', not (r ->> 'success')::boolean and r ->> 'code' = 'ALREADY_IN', r::text);
  r := public.t_punch('LR2', 'logout', 5, '05:30:00');
  perform public.t_log('night: OUT at 05:30 next morning accepted and flagged as night end', (r ->> 'success')::boolean and (r ->> 'is_night_shift_end')::boolean, r::text);
  r := public.t_punch('LR2', 'login', 5, '21:00:00');
  perform public.t_log('night: the next evening IN is accepted', (r ->> 'success')::boolean, r::text);
  r := public.t_punch('LR2', 'logout', 5, '22:00:00');
  perform public.t_log('night: OUT one hour after that IN is refused', not (r ->> 'success')::boolean and r ->> 'code' = 'TOO_EARLY', r::text);
  reset role;
end $$;

-- a forgotten OUT: an IN older than the open-session window does not block today's IN
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LR3', 'login', 6, '06:00:00');
  r := public.t_punch('LR3', 'login', 5, '06:30:00');
  perform public.t_log('forgotten OUT: an IN 24 hours after an unclosed IN is accepted', (r ->> 'success')::boolean, r::text);
  r := public.t_punch('LR3', 'logout', 5, '11:00:00');
  perform public.t_log('forgotten OUT: the OUT that follows is accepted', (r ->> 'success')::boolean, r::text);
  reset role;
end $$;

-- per-company setting: minimum session 60 minutes
insert into settings (key, value, client_id) values ('min_session_minutes', '60', '33333333-0000-0000-0000-000000000009');
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LR4', 'login', 4, '06:00:00');
  r := public.t_punch('LR4', 'logout', 4, '06:30:00');
  perform public.t_log('setting: with min_session_minutes = 60, an OUT after 30 minutes is refused', not (r ->> 'success')::boolean and r ->> 'code' = 'TOO_EARLY', r::text);
  r := public.t_punch('LR4', 'logout', 4, '07:15:00');
  perform public.t_log('setting: with min_session_minutes = 60, an OUT after 75 minutes is accepted', (r ->> 'success')::boolean, r::text);
  reset role;
end $$;
delete from settings where key = 'min_session_minutes' and client_id = '33333333-0000-0000-0000-000000000009';

-- who may call what (each check in its own block, so the role stays in force)
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.terminal_check_punch('LR1','login',current_date,'09:00')$q$, 'an administrator cannot use terminal_check_punch');
  reset role;
end $$;
do $$ begin
  perform public.t_anon();
  perform public.t_denied($q$select public.terminal_check_punch('LR1','login',current_date,'09:00')$q$, 'the public key cannot use terminal_check_punch');
  reset role;
end $$;
do $$ begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_denied($q$select public._punch_rule('33333333-0000-0000-0000-000000000009','LR1','login',now()::timestamp)$q$, 'a terminal cannot call the internal rule function directly');
  reset role;
end $$;
do $$ declare m text; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.terminal_check_punch('NOBODY', 'login', current_date, '09:00'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('check for an unknown labor is refused', m = 'unknown or inactive labor', m);
  begin perform public.terminal_check_punch('LT2', 'hack', current_date, '09:00'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('check with an invalid type is refused', m = 'invalid punch type', m);
  reset role;
end $$;
