insert into iqama_registry (iqama_number, labor_id, client_id) values ('5200000001', 'LM1', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor, monthly_salary) values
  ('LM1', '5200000001', 'Month One', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]', 999);
-- Tests for migration 008: monthly attendance on the terminal (company TRI, terminal 71111111-..., labor LM1; company AAA terminal 72222222-...).
insert into daily_attendance (labor_id, department_id, date, first_login, last_logout, total_hours, auto_status, final_status, client_id) values
  ('LM1', 'd7000000-0000-0000-0000-000000000007', date_trunc('month', current_date)::date, '06:00', '16:00', 10, 'P', null, '33333333-0000-0000-0000-000000000009'),
  ('LM1', 'd7000000-0000-0000-0000-000000000007', (date_trunc('month', current_date) + interval '1 day')::date, '06:00', '10:00', 4, 'H', null, '33333333-0000-0000-0000-000000000009'),
  ('LM1', 'd7000000-0000-0000-0000-000000000007', (date_trunc('month', current_date) + interval '2 day')::date, null, null, 0, 'A', 'P', '33333333-0000-0000-0000-000000000009'),
  ('LM1', 'd7000000-0000-0000-0000-000000000007', (date_trunc('month', current_date) - interval '3 day')::date, '06:00', '15:00', 9, 'P', null, '33333333-0000-0000-0000-000000000009'),
  ('LM1', 'd7000000-0000-0000-0000-000000000007', (date_trunc('month', current_date) - interval '70 day')::date, '06:00', '15:00', 9, 'P', null, '33333333-0000-0000-0000-000000000009');
insert into holidays (client_id, date, name) values ('33333333-0000-0000-0000-000000000009', (date_trunc('month', current_date) + interval '4 day')::date, 'Test holiday');

do $$ declare r jsonb; m text; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_month_attendance('LM1', current_date);
  perform public.t_log('this month: 3 days listed, totals present 2 / half 1 / absent 0 (the manual correction counts as present), 14 hours', jsonb_array_length(r -> 'days') = 3 and (r ->> 'present')::int = 2 and (r ->> 'half')::int = 1 and (r ->> 'absent')::int = 0 and (r ->> 'hours')::numeric = 14, r::text);
  perform public.t_log('this month: the holiday is listed', jsonb_array_length(r -> 'holidays') = 1 and r #>> '{holidays,0,name}' = 'Test holiday', r::text);
  perform public.t_log('this month: the day with a correction shows the corrected status (P, not A)', (select e ->> 'status' from jsonb_array_elements(r -> 'days') e where e ->> 'date' = (date_trunc('month', current_date) + interval '2 day')::date::text) = 'P', r::text);
  r := public.terminal_month_attendance('LM1', (current_date - interval '1 month')::date);
  perform public.t_log('previous month is readable and has its own day', jsonb_array_length(r -> 'days') >= 1 and (r ->> 'present')::int >= 1, r::text);
  perform public.t_log('the answer holds no salary, ID number or overtime amount', not (r::text ~* 'salary|iqama|ot_amount'), left(r::text, 120));
  begin perform public.terminal_month_attendance('LM1', (current_date - interval '3 month')::date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('three months back is refused', m = 'month not available', m);
  begin perform public.terminal_month_attendance('LM1', (current_date + interval '2 month')::date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a future month is refused', m = 'month not available', m);
  begin perform public.terminal_month_attendance('NOBODY', current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an unknown labor is refused', m = 'unknown or inactive labor', m);
  reset role;
end $$;
do $$ declare m text; begin
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  begin perform public.terminal_month_attendance('LM1', current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('the terminal of ANOTHER company cannot read this labor', m = 'unknown or inactive labor', m);
  reset role;
end $$;
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.terminal_month_attendance('LM1', current_date)$q$, 'an administrator cannot use terminal_month_attendance');
  reset role;
end $$;
do $$ begin
  perform public.t_anon();
  perform public.t_denied($q$select public.terminal_month_attendance('LM1', current_date)$q$, 'the public key cannot use terminal_month_attendance');
  reset role;
end $$;
