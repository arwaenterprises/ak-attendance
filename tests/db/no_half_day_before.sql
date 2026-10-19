-- Runs BEFORE migration 022: days stored with the old half-day rule (company TRI), so the test after 022 can check how they were converted.
-- NH1 = punched 07:00-12:00 (5 h, half day by the old rule), NH2 = no punches, approved by the administrator as half day,
-- NH1 on another day = approved as Present, then a later punch turned it back to Absent (finding 64).
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('6100000001', 'NH1', '33333333-0000-0000-0000-000000000009'), ('6100000002', 'NH2', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor) values
  ('NH1', '6100000001', 'Half one', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'),
  ('NH2', '6100000002', 'Half two', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]');
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('NH1', 'login', 12, '07:00:00');
  r := public.t_punch('NH1', 'logout', 12, '12:00:00');
  reset role;
end $$;
insert into daily_attendance (labor_id, department_id, date, total_hours, auto_status, final_status, approved_by, approved_at, client_id)
values ('NH2', 'd7000000-0000-0000-0000-000000000007', current_date - 12, 0, 'A', 'H', 'Admin', now(), '33333333-0000-0000-0000-000000000009');
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('NH1', 'login', 11, '07:00:00');
  reset role;
  update daily_attendance set final_status = 'P', approved_by = 'Admin' where labor_id = 'NH1' and date = current_date - 11;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('NH1', 'logout', 11, '12:00:00');
  reset role;
  perform public.t_log('before 022: the later punch overwrote the approval (old behaviour)', (select final_status from daily_attendance where labor_id = 'NH1' and date = current_date - 11) = 'H', '');
end $$;
do $$ begin
  perform public.t_log('before 022: the old rule stored 5 h as half day', (select final_status from daily_attendance where labor_id = 'NH1' and date = current_date - 12) = 'H', '');
end $$;
