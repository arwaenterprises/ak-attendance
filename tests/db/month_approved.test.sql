-- Tests for migration 019: the month screen data says which days were approved by the administrator (company TRI, terminal 71111111-..., labor LM1).
-- LM1 already has rows from month.test.sql: day 3 of the month is auto 'A' with final 'P' (an approval written without approved_by).
insert into daily_attendance (labor_id, department_id, date, first_login, last_logout, total_hours, auto_status, final_status, approved_by, client_id) values
  ('LM1', 'd7000000-0000-0000-0000-000000000007', (date_trunc('month', current_date) + interval '6 day')::date, null, null, 0, 'A', 'P', 'Admin Name', '33333333-0000-0000-0000-000000000009'),
  ('LM1', 'd7000000-0000-0000-0000-000000000007', (date_trunc('month', current_date) + interval '7 day')::date, '06:00', '16:30', 10.5, 'P', 'P', null, '33333333-0000-0000-0000-000000000009');
do $$ declare r jsonb; d jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_month_attendance('LM1', current_date);
  select e into d from jsonb_array_elements(r -> 'days') e where (e ->> 'date')::date = (date_trunc('month', current_date) + interval '6 day')::date;
  perform public.t_log('an approved day without punches is reported as approved Present', d ->> 'status' = 'P' and (d ->> 'approved')::boolean, d::text);
  select e into d from jsonb_array_elements(r -> 'days') e where (e ->> 'date')::date = (date_trunc('month', current_date) + interval '7 day')::date;
  perform public.t_log('a day that was really worked is not marked approved', d ->> 'status' = 'P' and not (d ->> 'approved')::boolean, d::text);
  perform public.t_log('every day carries the approved flag', (select count(*) = 0 from jsonb_array_elements(r -> 'days') e where not (e ? 'approved')), '');
  perform public.t_log('the totals and the rest of the answer are unchanged (present counts both days)', (r ->> 'present')::int >= 2 and r ? 'holidays' and r ? 'hours', r::text);
  perform public.t_log('no salary, ID number or overtime amount in the answer', r::text !~* 'salary|iqama|overtime|ot_', '');
  reset role;
end $$;
