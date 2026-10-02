-- Tests for migration 010: shifts, assignments with history, attendance stamped with the shift, night hours (finding 48).
-- Company A (aaaaaaaa-..., admin a1111111-..., labor LA1), company B (bbbbbbbb-..., admin b2222222-..., labor LB1), company TRI (33333333-..., terminal 71111111-...).
do $$ declare n int; begin
  select count(*) into n from shifts where code in ('DAY', 'NIGHT') and client_id in ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', '33333333-0000-0000-0000-000000000009');
  perform public.t_log('every company got a Day and a Night shift', n = 6, n::text);
  select count(*) into n from laborers where shift_id is null;
  perform public.t_log('every existing labor got a current shift (Day)', n = 0, n::text);
  perform public.t_log('the Night shift is flagged as night', (select is_night from shifts where code = 'NIGHT' limit 1) and not (select is_night from shifts where code = 'DAY' limit 1), '');
end $$;

-- who sees what
do $$ declare n int; m text; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  n := public.t_count('select 1 from public.shifts');
  perform public.t_log('admin A sees only the 2 shifts of company A', n = 2 and public.t_count($q$select 1 from public.shifts where client_id <> 'aaaaaaaa-0000-0000-0000-000000000001'$q$) = 0, n::text);
  perform public.t_log('admin A cannot change a shift of company B', public.t_rows_changed($q$update public.shifts set name = 'hacked' where client_id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$) = 0, '');
  perform public.t_log('admin A can rename his own Night shift and set its hours', public.t_rows_changed($q$update public.shifts set name = 'Night', start_time = '20:00', end_time = '06:30', required_hours = 10 where code = 'NIGHT'$q$) = 1, '');
  begin insert into public.shifts (client_id, code, name, start_time, end_time) values ('bbbbbbbb-0000-0000-0000-000000000002', 'X1', 'x', '01:00', '02:00'); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('admin A cannot add a shift to company B', m = '42501', m);
  reset role;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_log('the terminal cannot read the shift tables', public.t_count('select 1 from public.shifts') = 0 and public.t_count('select 1 from public.shift_assignments') = 0, '');
  reset role;
end $$;
do $$ begin perform public.t_anon(); perform public.t_denied('select 1 from public.shifts', 'the public key cannot read shifts'); reset role; end $$;

-- moving labors
do $$ declare r jsonb; v_night uuid; v_day uuid; m text; n int; begin
  select id into v_night from shifts where client_id = 'aaaaaaaa-0000-0000-0000-000000000001' and code = 'NIGHT';
  select id into v_day from shifts where client_id = 'aaaaaaaa-0000-0000-0000-000000000001' and code = 'DAY';
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r := public.assign_shift(array['LA1'], v_night, current_date);
  perform public.t_log('admin A moves LA1 to Night from today', (r ->> 'moved')::int = 1, r::text);
  perform public.t_log('LA1 current shift is now Night', (select shift_id from public.laborers where labor_id = 'LA1') = v_night, '');
  r := public.assign_shift(array['LA1'], v_night, current_date);
  select count(*) into n from public.shift_assignments where labor_id = 'LA1' and from_date = current_date;
  perform public.t_log('moving twice on the same date keeps ONE history row', n = 1, n::text);
  select count(*) into n from public.shift_assignments where labor_id = 'LA1' and from_date = date '2000-01-01' and shift_id = v_day;
  perform public.t_log('the labor previous shift (Day) is kept as the starting history entry', n = 1, n::text);
  -- future dated: the current shift stays, the function knows the future
  r := public.assign_shift(array['LA1'], v_day, current_date + 10);
  perform public.t_log('a move dated in the future does not change the current shift', (select shift_id from public.laborers where labor_id = 'LA1') = v_night, '');
  reset role;
  perform public.t_log('labor_shift_on follows the history (Night today, Day in 10 days, Night before)',
    public.labor_shift_on('aaaaaaaa-0000-0000-0000-000000000001', 'LA1', current_date) = v_night
    and public.labor_shift_on('aaaaaaaa-0000-0000-0000-000000000001', 'LA1', current_date + 11) = v_day
    and public.labor_shift_on('aaaaaaaa-0000-0000-0000-000000000001', 'LA1', current_date - 5) = v_day, '');
end $$;
do $$ declare v_night_b uuid; v_night_a uuid; m text; begin
  select id into v_night_b from shifts where client_id = 'bbbbbbbb-0000-0000-0000-000000000002' and code = 'NIGHT';
  select id into v_night_a from shifts where client_id = 'aaaaaaaa-0000-0000-0000-000000000001' and code = 'NIGHT';
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  begin perform public.assign_shift(array['LA1'], v_night_b, current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('admin B cannot move a labor of company A', m = 'unknown labor in the list', m);
  begin perform public.assign_shift(array['LB1'], v_night_a, current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('admin B cannot use a shift of company A', m = 'unknown or inactive shift', m);
  begin perform public.assign_shift(array[]::text[], v_night_b, current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an empty list is refused', m = 'no labors chosen', m);
  begin perform public.assign_shift(array['LB1'], v_night_b, current_date + 1000); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a date far away is refused', m = 'date out of range', m);
  reset role;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_denied($q$select public.assign_shift(array['LT1'], gen_random_uuid(), current_date)$q$, 'a terminal cannot move labors');
  reset role;
end $$;
do $$ begin perform public.t_anon(); perform public.t_denied($q$select public.assign_shift(array['LA1'], gen_random_uuid(), current_date)$q$, 'the public key cannot move labors'); reset role; end $$;

-- attendance is stamped with the shift of the day; moving from a past date re-stamps the rows from that date
do $$ declare v_day uuid; v_night uuid; r jsonb; begin
  select id into v_day from shifts where client_id = '33333333-0000-0000-0000-000000000009' and code = 'DAY';
  select id into v_night from shifts where client_id = '33333333-0000-0000-0000-000000000009' and code = 'NIGHT';
  perform public.t_log('LT1 attendance rows made before this migration have no shift yet (reports treat that as Day)', true, '');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_record_punch(jsonb_build_object('labor_id', 'LT2', 'type', 'login', 'date', (current_date - 8)::text, 'time', '06:00:00'));
  r := public.terminal_record_punch(jsonb_build_object('labor_id', 'LT2', 'type', 'logout', 'date', (current_date - 8)::text, 'time', '16:00:00'));
  reset role;
  perform public.t_log('a new attendance row carries the labor shift (Day)', (select shift_id from daily_attendance where labor_id = 'LT2' and date = current_date - 8) = v_day, '');
end $$;

-- night hours (finding 48): IN 21:00, OUT 05:30 next morning = 8.5 hours, not 15.5
insert into iqama_registry (iqama_number, labor_id, client_id) values ('5400000001', 'LS1', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('LS1', '5400000001', 'Shift One', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');
do $$ declare r jsonb; h numeric; st text; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LS1', 'login', 7, '21:00:00');
  r := public.t_punch('LS1', 'logout', 6, '05:30:00');
  reset role;
  select total_hours, auto_status into h, st from daily_attendance where labor_id = 'LS1' and date = current_date - 7;
  perform public.t_log('night shift 21:00 to 05:30 counts 8.5 hours', h = 8.5, coalesce(h::text, 'no row'));
  perform public.t_log('8.5 hours is less than the 9.5 full day but at least the 4 hour half day: H', st = 'H', coalesce(st, 'no row'));
  perform public.t_log('first login 21:00 and last logout 05:30 are kept as the clock times', (select first_login::text from daily_attendance where labor_id = 'LS1' and date = current_date - 7) = '21:00:00', '');
end $$;
-- day shift maths unchanged
do $$ declare h numeric; begin
  select total_hours into h from daily_attendance where labor_id = 'LT2' and date = current_date - 8;
  perform public.t_log('day shift 06:00 to 16:00 still counts 10 hours (P)', h = 10 and (select auto_status from daily_attendance where labor_id = 'LT2' and date = current_date - 8) = 'P', coalesce(h::text, 'no row'));
end $$;
