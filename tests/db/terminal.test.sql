-- Tests for migration 004 (terminal role). Runs after the other test files (their companies and helpers exist).
-- Company TRI (33333333-...) gets a terminal; company A has an admin (a1111111-...).
insert into auth.users (id, email) values
  ('71111111-0000-0000-0000-000000000011', 'terminal@tri.dawam.arwaenterprises.com'),
  ('72222222-0000-0000-0000-000000000012', 'terminal@aaa.dawam.arwaenterprises.com'),
  ('73333333-0000-0000-0000-000000000013', 'terminal@exp.dawam.arwaenterprises.com');
select public.link_terminal_profile('TRI');
select public.link_terminal_profile('AAA');
select public.link_terminal_profile('EXP');

-- data for the TRI company: department, two labors (one enrolled), location, settings
insert into departments (id, name, code, client_id) values ('d7000000-0000-0000-0000-000000000007', 'TRI Dept', 'TRDX', '33333333-0000-0000-0000-000000000009');
insert into iqama_registry (iqama_number, labor_id, client_id) values ('5000000001', 'LT1', '33333333-0000-0000-0000-000000000009'), ('5000000002', 'LT2', '33333333-0000-0000-0000-000000000009');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor, monthly_salary) values
  ('LT1', '5000000001', 'Tri One', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]', 4321),
  ('LT2', '5000000002', 'Tri Two', 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', false, null, 1000);
insert into punch_locations (id, name, department_id, latitude, longitude, client_id) values ('10c00000-0000-0000-0000-000000000001', 'Gate', 'd7000000-0000-0000-0000-000000000007', 1, 1, '33333333-0000-0000-0000-000000000009');
insert into settings (key, value, client_id) values ('max_punches_per_day', '3', '33333333-0000-0000-0000-000000000009'), ('confidence_threshold', '70', '33333333-0000-0000-0000-000000000009');

-- the terminal cannot touch any table directly
do $$ declare t text; begin
  foreach t in array array['clients_X','users_X','departments','laborers','punch_locations','punch_records','daily_attendance','lop_requests','audit_log','settings','attendance_freeze','holidays','ot_rates','overtime_records','iqama_registry','enrollment_links'] loop
    if t like '%\_X' then continue; end if;
    perform public.t_login('71111111-0000-0000-0000-000000000011');
    perform public.t_log('terminal sees no rows of ' || t, public.t_count('select 1 from public.' || t) = 0, '');
    perform public.t_login('71111111-0000-0000-0000-000000000011');
    perform public.t_denied('insert into public.' || t || ' default values', 'terminal cannot add rows to ' || t);
  end loop;
  reset role;
end $$;
do $$ begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_denied($q$select password_hash from public.users$q$, 'terminal cannot read password hashes');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_denied($q$select public.register_iqama('9990000001')$q$, 'terminal cannot register ID numbers');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_denied($q$select public.get_next_labor_id()$q$, 'terminal cannot take labor ids');
  reset role;
end $$;

-- staff still work; staff cannot use terminal functions
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('admin still sees its own laborers (policy now also checks the role)', public.t_count('select 1 from public.laborers') >= 1, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.terminal_bootstrap()$q$, 'an admin cannot call terminal_bootstrap');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.terminal_record_punch('{"labor_id":"LA1","type":"login","date":"2020-01-01","time":"09:00"}')$q$, 'an admin cannot call terminal_record_punch');
  perform public.t_anon();
  perform public.t_denied($q$select public.terminal_bootstrap()$q$, 'the public key cannot call terminal_bootstrap');
  perform public.t_anon();
  perform public.t_denied($q$select public.terminal_record_punch('{}')$q$, 'the public key cannot call terminal_record_punch');
  perform public.t_login('73333333-0000-0000-0000-000000000013');
  perform public.t_denied($q$select public.terminal_bootstrap()$q$, 'a terminal of an EXPIRED company is refused');
  reset role;
end $$;

-- bootstrap: only what a terminal needs
do $$ declare b jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  b := public.terminal_bootstrap();
  reset role;
  perform public.t_log('bootstrap: company', b #>> '{client,client_code}' = 'TRI', b #>> '{client,client_code}');
  perform public.t_log('bootstrap: only enrolled labors (1 of 2)', jsonb_array_length(b -> 'laborers') = 1 and b #>> '{laborers,0,labor_id}' = 'LT1', '');
  perform public.t_log('bootstrap: face data included', (b #> '{laborers,0,face_descriptor}')::text = '[0.1, 0.2]', (b #> '{laborers,0,face_descriptor}')::text);
  perform public.t_log('bootstrap: NO salary, ID number or other staff data',
    not (b #> '{laborers,0}' ? 'monthly_salary') and not (b #> '{laborers,0}' ? 'iqama_number') and not (b #> '{laborers,0}' ? 'nationality'), (b #> '{laborers,0}')::text);
  perform public.t_log('bootstrap: settings and locations', b #>> '{settings,max_punches_per_day}' = '3' and jsonb_array_length(b -> 'locations') = 1, '');
  perform public.t_log('bootstrap: nothing of other companies', not (b::text like '%Company A%'), '');
end $$;

-- recording punches
do $$ declare r jsonb; r2 jsonb; n int; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','login','date',current_date::text,'time','09:00:00','location_id','10c00000-0000-0000-0000-000000000001','location_name','Gate','confidence',92));
  r2 := public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','login','date',current_date::text,'time','09:00:00'));
  perform public.t_log('a punch is recorded', (r ->> 'success')::boolean and not (r ->> 'duplicate')::boolean, r::text);
  perform public.t_log('the same punch sent again (offline upload twice) is ignored', (r2 ->> 'duplicate')::boolean and r2 ->> 'id' = r ->> 'id', r2::text);
  perform public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','logout','date',current_date::text,'time','18:30:00'));
  reset role;
  select count(*) into n from punch_records where labor_id = 'LT1' and client_id = '33333333-0000-0000-0000-000000000009';
  perform public.t_log('exactly 2 punch rows stored', n = 2, n::text);
  perform public.t_log('attendance was recalculated (9.5 hours, P)', (select total_hours from daily_attendance where labor_id = 'LT1' and date = current_date) = 9.5 and (select auto_status from daily_attendance where labor_id = 'LT1' and date = current_date) = 'P', '');
  perform public.t_log('labor last sync time was set', (select last_sync_at from laborers where labor_id = 'LT1') is not null, '');
end $$;
do $$ declare r jsonb; begin
  -- night shift: evening punch, then a 05:00 punch next morning belongs to the evening's date
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','login','date',(current_date - 6)::text,'time','21:00:00'));
  r := public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','logout','date',(current_date - 5)::text,'time','05:00:00'));
  reset role;
  perform public.t_log('night shift: 05:00 after a 21:00 punch is stored on the evening date and flagged', r ->> 'date' = (current_date - 6)::text and (r ->> 'is_night_shift_end')::boolean, r::text);
end $$;
do $$ declare r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','login','date',(current_date - 10)::text,'time','05:00:00'));
  reset role;
  perform public.t_log('a 05:00 punch with no evening punch before keeps its own date', r ->> 'date' = (current_date - 10)::text and not (r ->> 'is_night_shift_end')::boolean, r::text);
end $$;

-- refusals
do $$ declare m text; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.terminal_record_punch(jsonb_build_object('labor_id','LA1','type','login','date',current_date::text,'time','09:00')); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a punch for a labor of ANOTHER company is refused', m = 'unknown or inactive labor', m);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','hack','date',current_date::text,'time','09:00')); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an invalid punch type is refused', m = 'invalid punch type', m);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.terminal_record_punch('{"labor_id":"LT1","type":"login","date":"not-a-date","time":"09:00"}'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an invalid date is refused', m = 'invalid date or time', m);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','login','date',(current_date + 30)::text,'time','09:00')); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a punch dated far in the future is refused', m = 'date out of range', m);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.terminal_record_punch(jsonb_build_object('labor_id','LT1','type','login','date',(current_date - 40)::text,'time','09:00')); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a punch older than 31 days is refused', m = 'date out of range', m);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.terminal_record_punch(jsonb_build_object('labor_id','LT2','type','login','date',current_date::text,'time','09:00')); m := 'allowed'; exception when others then m := 'refused'; end;
  perform public.t_log('a not-enrolled labor can still be punched by ID (same as before)', m = 'allowed', m);
  reset role;
end $$;

-- state, today list, low confidence
do $$ declare s jsonb; l jsonb; r jsonb; begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  s := public.terminal_punch_state('LT1', current_date);
  perform public.t_log('punch state: count, limit, last type', (s ->> 'count')::int = 2 and (s ->> 'max')::int = 3 and s ->> 'last_type' = 'logout', s::text);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  s := public.terminal_punch_state('LT2', '2001-01-01');
  perform public.t_log('punch state of a day without punches', (s ->> 'count')::int = 0 and s -> 'last_type' = 'null'::jsonb, s::text);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  l := public.terminal_today_punches('LT1', current_date);
  perform public.t_log('today list has the 2 punches in order', jsonb_array_length(l) = 2 and l #>> '{0,type}' = 'login' and l #>> '{1,type}' = 'logout', l::text);
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_log('today list of another company''s labor is empty', jsonb_array_length(public.terminal_today_punches('LA1', '2020-02-01')) = 0, '');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.terminal_low_confidence('LT1'); perform public.terminal_low_confidence('LT1'); r := public.terminal_low_confidence('LT1');
  perform public.t_log('3 low-confidence matches flag the labor for re-enrollment', (r ->> 'needs_reenrollment')::boolean, r::text);
  reset role;
  perform public.t_log('the flag is stored', (select needs_reenrollment from laborers where labor_id = 'LT1'), '');
end $$;

-- isolation between terminals of different companies
do $$ declare b jsonb; begin
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  b := public.terminal_bootstrap();
  reset role;
  perform public.t_log('terminal of company A sees only company A in bootstrap', b #>> '{client,client_code}' = 'AAA' and not (b::text like '%Tri One%'), '');
end $$;

-- link_terminal_profile
do $$ declare e text; begin
  begin perform public.link_terminal_profile('NOPE'); e := 'allowed'; exception when others then e := sqlerrm; end;
  perform public.t_log('link_terminal_profile refuses an unknown company', e like 'unknown company code%', e);
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.link_terminal_profile('AAA')$q$, 'a logged-in admin cannot run link_terminal_profile');
  reset role;
  perform public.t_log('exactly one terminal profile per company', (select count(*) from users where client_id = '33333333-0000-0000-0000-000000000009' and role = 'terminal') = 1, '');
end $$;
