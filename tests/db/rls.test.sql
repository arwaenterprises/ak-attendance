-- Security tests for migration 001. Every check records PASS/FAIL in test_results.
create table test_results (name text, ok boolean, detail text);
create or replace function public.t_note(p_name text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  insert into test_results values (p_name, p_ok, p_detail);   -- written as the table owner via t_log below when role is restricted
  raise notice '% %  %', case when p_ok then 'PASS' else 'FAIL' end, p_name, p_detail;
end $$;
-- results are collected through notices + a log table written by a privileged helper
create or replace function public.t_log(p_name text, p_ok boolean, p_detail text) returns void language plpgsql security definer as $$
begin insert into test_results values (p_name, p_ok, p_detail); raise notice '% %  %', case when p_ok then 'PASS' else 'FAIL' end, p_name, p_detail; end $$;

create or replace function public.t_login(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid)::text, true);
  execute 'reset role'; execute 'set local role authenticated';
end $$;
create or replace function public.t_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', true); execute 'reset role'; execute 'set local role anon'; end $$;

-- expects the statement to be refused with "permission denied / row level security" (42501)
create or replace function public.t_denied(p_sql text, p_name text) returns void language plpgsql as $$
declare refused boolean := false;
begin
  begin execute p_sql;
  exception when others then
    if sqlstate = '42501' then refused := true; else perform public.t_log(p_name, false, 'unexpected error ' || sqlstate || ' ' || sqlerrm); return; end if;
  end;
  perform public.t_log(p_name, refused, case when refused then '' else 'was ALLOWED' end);
end $$;
create or replace function public.t_count(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute 'select count(*) from (' || p_sql || ') q' into n; return n; end $$;
create or replace function public.t_rows_changed(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute p_sql; get diagnostics n = row_count; return n; end $$;

-- ---------- test data: two companies, each with an admin; one inactive user; one auth user without profile ----------
insert into clients (id, business_name, client_code, subscribed_apps) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Company A', 'AAA', array['attendance']),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Company B', 'BBB', array['attendance']);
insert into auth.users (id, email) values
  ('a1111111-0000-0000-0000-000000000001', 'admin@aaa.dawam'), ('b2222222-0000-0000-0000-000000000002', 'admin@bbb.dawam'),
  ('c3333333-0000-0000-0000-000000000003', 'old@aaa.dawam'), ('d4444444-0000-0000-0000-000000000004', 'nobody@x.dawam');
insert into users (username, password_hash, name, role, status, client_id, auth_id) values
  ('admin_a', 'x', 'Admin A', 'admin', 'active',   'aaaaaaaa-0000-0000-0000-000000000001', 'a1111111-0000-0000-0000-000000000001'),
  ('admin_b', 'x', 'Admin B', 'admin', 'active',   'bbbbbbbb-0000-0000-0000-000000000002', 'b2222222-0000-0000-0000-000000000002'),
  ('old_a',   'x', 'Old A',   'admin', 'inactive', 'aaaaaaaa-0000-0000-0000-000000000001', 'c3333333-0000-0000-0000-000000000003');
insert into departments (id, name, code, client_id) values
  ('da000000-0000-0000-0000-00000000000a', 'Dept A', 'DA', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('db000000-0000-0000-0000-00000000000b', 'Dept B', 'DB', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('1000000001', 'LA1', 'aaaaaaaa-0000-0000-0000-000000000001'), ('2000000002', 'LB1', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id) values
  ('LA1', '1000000001', 'Labor A1', 'X', '2020-01-01', 'da000000-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('LB1', '2000000002', 'Labor B1', 'X', '2020-01-01', 'db000000-0000-0000-0000-00000000000b', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into punch_records (labor_id, department_id, date, time, type, client_id) values
  ('LA1', 'da000000-0000-0000-0000-00000000000a', '2020-02-01', '09:00', 'login',  'aaaaaaaa-0000-0000-0000-000000000001'),
  ('LA1', 'da000000-0000-0000-0000-00000000000a', '2020-02-01', '18:30', 'logout', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('LB1', 'db000000-0000-0000-0000-00000000000b', '2020-02-01', '09:00', 'login',  'bbbbbbbb-0000-0000-0000-000000000002');
insert into punch_locations (name, department_id, latitude, longitude, client_id) values
  ('Loc A', 'da000000-0000-0000-0000-00000000000a', 1, 1, 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('Loc B', 'db000000-0000-0000-0000-00000000000b', 1, 1, 'bbbbbbbb-0000-0000-0000-000000000002');
insert into daily_attendance (labor_id, department_id, date, client_id) values
  ('LB1', 'db000000-0000-0000-0000-00000000000b', '2020-02-01', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into lop_requests (labor_id, department_id, date, auto_status, requested_status, client_id) values
  ('LA1', 'da000000-0000-0000-0000-00000000000a', '2020-02-02', 'A', 'P', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('LB1', 'db000000-0000-0000-0000-00000000000b', '2020-02-02', 'A', 'P', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into settings (key, value, client_id) values ('k_a', '1', 'aaaaaaaa-0000-0000-0000-000000000001'), ('k_b', '1', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into attendance_freeze (client_id, date) values ('aaaaaaaa-0000-0000-0000-000000000001', '2020-02-01'), ('bbbbbbbb-0000-0000-0000-000000000002', '2020-02-01');
insert into holidays (client_id, date, name) values ('aaaaaaaa-0000-0000-0000-000000000001', '2020-02-03', 'H'), ('bbbbbbbb-0000-0000-0000-000000000002', '2020-02-03', 'H');
insert into ot_rates (client_id, role, rate_per_hour) values ('aaaaaaaa-0000-0000-0000-000000000001', 'labor', 1), ('bbbbbbbb-0000-0000-0000-000000000002', 'labor', 1);
insert into overtime_records (client_id, labor_id, from_date, to_date, ot_hours, ot_amount) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'LA1', '2020-02-01', '2020-02-02', 1, 1), ('bbbbbbbb-0000-0000-0000-000000000002', 'LB1', '2020-02-01', '2020-02-02', 1, 1);
insert into enrollment_links (token, labor_id, client_id) values
  ('tok-a', 'LA1', 'aaaaaaaa-0000-0000-0000-000000000001'), ('tok-b', 'LB1', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into audit_log (action, table_name, client_id) values ('X', 'y', 'aaaaaaaa-0000-0000-0000-000000000001'), ('X', 'y', 'bbbbbbbb-0000-0000-0000-000000000002');

-- ---------- the tests ----------
do $$ begin
  perform public.t_log('temporary "allow all" policies are gone', (select count(*) from pg_policies where policyname like 'tmp allow all %') = 0, '');
  perform public.t_log('every attendance table has row level security ON',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname <> 'test_results' and not relrowsecurity) = 0, '');
end $$;

-- the public (anon) key: nothing at all
do $$ declare t text; begin
  foreach t in array array['clients','users','departments','laborers','punch_locations','punch_records','daily_attendance','lop_requests','audit_log','settings','labor_id_sequence','attendance_freeze','holidays','ot_rates','overtime_records','iqama_registry','enrollment_links'] loop
    perform public.t_anon();
    perform public.t_denied('select * from public.' || t, 'anon key cannot read ' || t);
    perform public.t_denied('delete from public.' || t, 'anon key cannot delete from ' || t);
  end loop;
  reset role;
end $$;
do $$ begin
  perform public.t_anon(); perform public.t_denied($q$select public.update_daily_attendance('LA1', '2020-02-01')$q$, 'anon key cannot run update_daily_attendance');
  perform public.t_anon(); perform public.t_denied($q$select public.register_iqama('3000000003')$q$, 'anon key cannot run register_iqama');
  perform public.t_anon(); perform public.t_denied($q$select public.current_client_id()$q$, 'anon key cannot run current_client_id');
  reset role;
end $$;

-- admin of company A: sees only A, cannot touch B
do $$ declare t text; n bigint; begin
  foreach t in array array['departments','laborers','punch_locations','punch_records','daily_attendance','lop_requests','settings','attendance_freeze','holidays','ot_rates','overtime_records','iqama_registry','enrollment_links','audit_log'] loop
    perform public.t_login('a1111111-0000-0000-0000-000000000001');
    perform public.t_log('A sees no rows of company B in ' || t, public.t_count('select 1 from public.' || t || $q$ where client_id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$) = 0, '');
    if t <> 'daily_attendance' then
      perform public.t_log('A sees its own rows in ' || t, public.t_count('select 1 from public.' || t) >= 1, '');
    end if;
    if t <> 'audit_log' then
      perform public.t_log('A cannot change B rows in ' || t, public.t_rows_changed('update public.' || t || $q$ set client_id = client_id where client_id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$) = 0, '');
      perform public.t_log('A cannot delete B rows in ' || t, public.t_rows_changed('delete from public.' || t || $q$ where client_id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$) = 0, '');
    end if;
  end loop;
  reset role;
end $$;
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$insert into public.departments (name, code, client_id) values ('Evil', 'EVIL', 'bbbbbbbb-0000-0000-0000-000000000002')$q$, 'A cannot create a department for B');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$insert into public.settings (key, value, client_id) values ('evil', '1', 'bbbbbbbb-0000-0000-0000-000000000002')$q$, 'A cannot create a setting for B');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$update public.departments set client_id = 'bbbbbbbb-0000-0000-0000-000000000002' where code = 'DA'$q$, 'A cannot hand its own row over to B');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  insert into public.departments (name, code) values ('New A', 'NEWA');
  perform public.t_log('a row created without client_id belongs to A', (select client_id from public.departments where code = 'NEWA') = 'aaaaaaaa-0000-0000-0000-000000000001', '');
  reset role;
end $$;

-- users and clients tables
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('A sees only its own user row', public.t_count('select 1 from public.users') = 1, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied('select password_hash from public.users', 'A cannot read password hashes');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$update public.users set role = 'super_admin'$q$, 'A cannot change user roles');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$insert into public.users (username, password_hash, name, role) values ('x', 'x', 'x', 'admin')$q$, 'A cannot create users from the app');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('A sees only its own company row', public.t_count('select 1 from public.clients') = 1, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$update public.clients set is_active = false$q$, 'A cannot edit company / subscription data');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$update public.clients set subscription_status = 'premium'$q$, 'A cannot grant itself a premium subscription');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$delete from public.clients$q$, 'A cannot delete companies');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied('select * from public.labor_id_sequence', 'A cannot read the labor id counter directly');
  reset role;
end $$;

-- audit log: add and read, never rewrite
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  insert into public.audit_log (action, table_name) values ('LOGIN', 'users');
  perform public.t_log('A can add audit entries for itself', true, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$insert into public.audit_log (action, table_name, client_id) values ('X', 'y', 'bbbbbbbb-0000-0000-0000-000000000002')$q$, 'A cannot write audit entries for B');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$update public.audit_log set action = 'HIDDEN'$q$, 'audit entries cannot be edited');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$delete from public.audit_log$q$, 'audit entries cannot be deleted');
  reset role;
end $$;

-- functions
do $$ declare id1 text; id2 text; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  id1 := public.register_iqama('3000000003'); id2 := public.register_iqama('3000000003');
  perform public.t_log('register_iqama gives a labor id, same one when repeated', id1 like 'L%' and id1 = id2, id1);
  reset role;
  perform public.t_log('register_iqama stored the row for company A', (select client_id from iqama_registry where iqama_number = '3000000003') = 'aaaaaaaa-0000-0000-0000-000000000001', '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.update_daily_attendance('LA1', '2020-02-01');
  reset role;
  perform public.t_log('update_daily_attendance works for A''s own labor', (select total_hours from daily_attendance where labor_id = 'LA1' and date = '2020-02-01') = 9.5, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.update_daily_attendance('LB1', '2020-02-01')$q$, 'A cannot recalculate attendance of B''s labor');
  reset role;
end $$;

-- users who must see nothing
do $$ begin
  perform public.t_login('c3333333-0000-0000-0000-000000000003');
  perform public.t_log('an inactive user sees nothing', public.t_count('select 1 from public.laborers') = 0 and public.t_count('select 1 from public.punch_records') = 0, '');
  perform public.t_login('c3333333-0000-0000-0000-000000000003');
  perform public.t_denied($q$insert into public.departments (name, code) values ('x', 'XX')$q$, 'an inactive user cannot write');
  perform public.t_login('d4444444-0000-0000-0000-000000000004');
  perform public.t_log('a login without a company profile sees nothing', public.t_count('select 1 from public.laborers') = 0 and public.t_count('select 1 from public.settings') = 0, '');
  reset role;
end $$;

-- company B is isolated the same way
do $$ begin
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  perform public.t_log('B sees none of A''s punches', public.t_count($q$select 1 from public.punch_records where labor_id = 'LA1'$q$) = 0, '');
  perform public.t_log('B sees its own punch', public.t_count($q$select 1 from public.punch_records where labor_id = 'LB1'$q$) = 1, '');
  reset role;
end $$;
