-- Tests for migration 022: no half day, one rule for Present, approvals kept, first IN starts the day (company TRI, terminal 71111111-...).
do $$ declare d record; begin
  select * into d from daily_attendance where labor_id = 'NH1' and date = current_date - 12;
  perform public.t_log('022 data: a 5 h day stored as half day is now Absent', d.final_status = 'A' and d.auto_status = 'A', row(d.auto_status, d.final_status)::text);
  select * into d from daily_attendance where labor_id = 'NH2' and date = current_date - 12;
  perform public.t_log('022 data: a day approved as half day is now Present (approval kept)', d.final_status = 'P' and d.approved_by = 'Admin', row(d.auto_status, d.final_status)::text);
  select * into d from daily_attendance where labor_id = 'NH1' and date = current_date - 11;
  perform public.t_log('022 data: an approval overwritten by a later punch is Present again', d.final_status = 'P' and d.approved_by = 'Admin', row(d.auto_status, d.final_status)::text);
  perform public.t_log('022 data: no H left anywhere', not exists (select 1 from daily_attendance where 'H' in (auto_status, final_status)), '');
end $$;

-- the database refuses H from now on
do $$ begin
  begin
    update daily_attendance set final_status = 'H' where labor_id = 'NH1';
    perform public.t_log('022: H can no longer be stored', false, 'update accepted');
  exception when check_violation then
    perform public.t_log('022: H can no longer be stored', true, '');
  end;
end $$;

insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('6100000003', 'NH3', '33333333-0000-0000-0000-000000000009'), ('6100000004', 'NH4', '33333333-0000-0000-0000-000000000009'),
  ('6100000005', 'NH5', '33333333-0000-0000-0000-000000000009'), ('6100000006', 'NH6', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('NH3', '6100000003', 'Short day', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('NH4', '6100000004', 'Eight hours', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('NH5', '6100000005', 'Approved', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('NH6', '6100000006', 'Out first', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');
insert into shifts (client_id, code, name, start_time, end_time, is_night, required_hours)
values ('33333333-0000-0000-0000-000000000009', 'EIGHT', 'Eight hour shift', '08:00', '16:00', false, 8);
insert into shift_assignments (client_id, labor_id, shift_id, from_date)
select '33333333-0000-0000-0000-000000000009', 'NH4', id, date '2000-01-01' from shifts where client_id = '33333333-0000-0000-0000-000000000009' and code = 'EIGHT';

do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  -- department full day 09:30
  r := public.t_punch('NH3', 'login', 9, '07:00:00');
  r := public.t_punch('NH3', 'logout', 9, '11:30:00');
  r := public.t_punch('NH3', 'login', 8, '07:00:00');
  r := public.t_punch('NH3', 'logout', 8, '16:30:00');
  -- the shift asks 8 h
  r := public.t_punch('NH4', 'login', 9, '08:00:00');
  r := public.t_punch('NH4', 'logout', 9, '16:00:00');
  reset role;
  select * into d from daily_attendance where labor_id = 'NH3' and date = current_date - 9;
  perform public.t_log('022: 4 h 30 m is Absent (no half day)', d.final_status = 'A', row(d.total_hours, d.final_status)::text);
  select * into d from daily_attendance where labor_id = 'NH3' and date = current_date - 8;
  perform public.t_log('022: 9 h 30 m is Present', d.final_status = 'P', row(d.total_hours, d.final_status)::text);
  select * into d from daily_attendance where labor_id = 'NH4' and date = current_date - 9;
  perform public.t_log('022: the shift''s required hours decide (8 h shift, 8 h worked = Present)', d.final_status = 'P', row(d.total_hours, d.final_status)::text);
end $$;

-- an administrator's approval survives the next punch of the day
do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('NH5', 'login', 7, '07:00:00');
  reset role;
  update daily_attendance set final_status = 'P', approved_by = 'Admin', approved_at = now() where labor_id = 'NH5' and date = current_date - 7;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('NH5', 'logout', 7, '11:30:00');
  reset role;
  select * into d from daily_attendance where labor_id = 'NH5' and date = current_date - 7;
  perform public.t_log('022: an approval stays when the labor punches OUT later that day', d.final_status = 'P' and d.auto_status = 'A' and d.approved_by = 'Admin', row(d.auto_status, d.final_status, d.total_hours)::text);
end $$;

-- the day starts at the first IN, not at an earlier OUT that closed a forgotten session
do $$ declare r jsonb; d record; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('NH6', 'login', 6, '14:00:00');
  r := public.t_punch('NH6', 'logout', 5, '06:50:00');
  r := public.t_punch('NH6', 'login', 5, '08:00:00');
  r := public.t_punch('NH6', 'logout', 5, '17:00:00');
  reset role;
  select * into d from daily_attendance where labor_id = 'NH6' and date = current_date - 5;
  perform public.t_log('022: hours count from the first IN (08:00 to 17:00 = 9 h, Absent), not from the 06:50 OUT', d.first_login = '08:00' and round(d.total_hours, 2) = 9 and d.final_status = 'A', row(d.first_login, d.last_logout, d.total_hours, d.final_status)::text);
end $$;

-- month screen: days around the month, sandwich settings, joining date
do $$ declare r jsonb; begin
  insert into settings (client_id, key, value) values ('33333333-0000-0000-0000-000000000009', 'sandwich_rule_nh', 'false')
  on conflict (client_id, key) do update set value = excluded.value;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_month_attendance('NH3', current_date);
  perform public.t_log('022 month: sends the sandwich settings (missing = on, false = off) and the joining date',
    (r ->> 'sandwich_friday')::boolean and not (r ->> 'sandwich_nh')::boolean and r ->> 'date_of_joining' = '2020-01-01', r::text);
  perform public.t_log('022 month: no half-day count any more', not (r ? 'half'), '');
  -- the PREVIOUS month also returns the days up to 13 days into this month (and this month the 14 days before it)
  r := public.terminal_month_attendance('NH3', (date_trunc('month', current_date) - interval '1 day')::date);
  perform public.t_log('022 month: days around the month are included (for Thursday / Saturday around a Friday)',
    exists (select 1 from jsonb_array_elements(r -> 'days') e where (e ->> 'date')::date = current_date - 9)
      = (current_date - 9 <= date_trunc('month', current_date)::date + 13), r::text);
  perform public.t_log('022 month: the counts are for the month itself only',
    (r ->> 'present')::int + (r ->> 'absent')::int = (select count(*) from daily_attendance where labor_id = 'NH3'
       and date >= (date_trunc('month', current_date) - interval '1 month')::date and date < date_trunc('month', current_date)::date), r::text);
  reset role;
end $$;

-- the punches of a day come in time order, also when an earlier punch reached the database later (offline upload)
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('NH3', 'login', 4, '07:00:00');
  r := public.t_punch('NH3', 'logout', 4, '17:00:00');
  reset role;
  update punch_records set created_at = now() + interval '1 hour' where labor_id = 'NH3' and date = current_date - 4 and type = 'login';
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_today_punches('NH3', current_date - 4);
  perform public.t_log('022: the day''s punches are listed by time (IN first), not by upload order', r -> 0 ->> 'type' = 'login' and r -> 1 ->> 'type' = 'logout', r::text);
  reset role;
end $$;
