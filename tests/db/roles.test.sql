-- Tests for migration 018: roles, salary history, default salary at creation, changing salaries from a date.
-- Company A (admin a1111111-...), company B (admin b2222222-...), terminal of company TRI (71111111-...). Department of company A: de000000-...a2.

-- what the migration did with the data that already existed
do $$ declare n int; begin
  select count(*) into n from clients c where exists (select 1 from roles r where r.client_id = c.id) and (select count(*) from roles r where r.client_id = c.id and r.is_default) <> 1;
  perform public.t_log('every company that has roles has exactly ONE default role', n = 0, n::text);
  select count(*) into n from clients c where not exists (select 1 from roles r where r.client_id = c.id);
  perform public.t_log('every company has at least one role', n = 0, n::text);
  select count(*) into n from laborers where role_id is null;
  perform public.t_log('every existing labor points at a role', n = 0, n::text);
  select count(*) into n from laborers l where not exists (select 1 from labor_salaries s where s.client_id = l.client_id and s.labor_id = l.labor_id and s.from_date = date '2000-01-01');
  perform public.t_log('every existing labor has a starting salary entry (2000-01-01)', n = 0, n::text);
  select count(*) into n from laborers l join labor_salaries s on s.client_id = l.client_id and s.labor_id = l.labor_id and s.from_date = date '2000-01-01' where s.monthly_salary is distinct from l.monthly_salary;
  perform public.t_log('the starting entries equal the salary the labors had (nothing changes in past months)', n = 0, n::text);
  select count(*) into n from laborers l join roles r on r.id = l.role_id where l.role is distinct from r.name;
  perform public.t_log('the old text column follows the role name', n = 0, n::text);
  perform public.t_log('the overtime rate of the migrated role comes from the old ot_rates entry (company A: 1)', (select ot_rate_per_hour from roles where client_id = 'aaaaaaaa-0000-0000-0000-000000000001' and lower(name) = 'labor') = 1, '');
end $$;

-- a role for company A, a labor created with and without a salary
insert into roles (id, client_id, name, default_monthly_salary, ot_rate_per_hour) values
  ('f0000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 'Driver', 2500, 20);
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('5800000001', 'LRS1', 'aaaaaaaa-0000-0000-0000-000000000001'), ('5800000002', 'LRS2', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('5800000003', 'LRS3', 'aaaaaaaa-0000-0000-0000-000000000001'), ('5800000004', 'LRS4', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('5800000005', 'LRSB', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, role_id, monthly_salary) values
  ('LRS1', '5800000001', 'Role Labor 1', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-0000000000a1', null),
  ('LRS2', '5800000002', 'Role Labor 2', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-0000000000a1', 2800);
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, role, monthly_salary) values
  ('LRS3', '5800000003', 'Role Labor 3 (text role)', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', 'driver', null);
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, role, monthly_salary) values
  ('LRS4', '5800000004', 'Role Labor 4 (no role)', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', null, null);

do $$ declare r jsonb; begin
  perform public.t_log('LRS1 (role Driver, no salary typed) takes the role default 2500', (select monthly_salary = 2500 and role = 'Driver' from laborers where labor_id = 'LRS1'), '');
  perform public.t_log('LRS2 keeps the salary typed at creation (2800)', (select monthly_salary = 2800 from laborers where labor_id = 'LRS2'), '');
  perform public.t_log('a role given only as text (any capitals) finds its role: LRS3 is a Driver with 2500', (select role_id = 'f0000000-0000-0000-0000-0000000000a1' and role = 'Driver' and monthly_salary = 2500 from laborers where labor_id = 'LRS3'), '');
  perform public.t_log('a labor without any role gets the default role of its company', (select r.is_default from laborers l join roles r on r.id = l.role_id where l.labor_id = 'LRS4'), '');
  perform public.t_log('every new labor got its starting salary entry', (select count(*) = 4 from labor_salaries where labor_id in ('LRS1', 'LRS2', 'LRS3', 'LRS4') and from_date = date '2000-01-01'), '');
  perform public.t_log('LRS2 starting entry is 2800, LRS1 is 2500', (select monthly_salary from labor_salaries where labor_id = 'LRS2') = 2800 and (select monthly_salary from labor_salaries where labor_id = 'LRS1') = 2500, '');
end $$;

-- who may see and change what
do $$ declare m text; n int; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('admin A sees only the roles of company A', public.t_count('select 1 from public.roles') >= 2 and public.t_count($q$select 1 from public.roles where client_id <> 'aaaaaaaa-0000-0000-0000-000000000001'$q$) = 0, '');
  perform public.t_log('admin A sees the salary history of company A only', public.t_count('select 1 from public.labor_salaries') >= 4 and public.t_count($q$select 1 from public.labor_salaries where client_id <> 'aaaaaaaa-0000-0000-0000-000000000001'$q$) = 0, '');
  perform public.t_log('admin A can add a role', public.t_rows_changed($q$insert into public.roles (client_id, name, default_monthly_salary) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Cashier', 1800)$q$) = 1, '');
  begin insert into public.roles (client_id, name) values ('aaaaaaaa-0000-0000-0000-000000000001', 'cashier'); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('a role name is unique in the company, capitals ignored', m = '23505', m);
  begin insert into public.roles (client_id, name, is_default) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Second default', true); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('a company cannot have two default roles', m = '23505', m);
  begin insert into public.roles (client_id, name) values ('bbbbbbbb-0000-0000-0000-000000000002', 'Intruder'); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('admin A cannot add a role to company B', m = '42501', m);
  reset role;
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  perform public.t_log('admin B cannot see roles or salaries of company A', public.t_count($q$select 1 from public.roles where client_id = 'aaaaaaaa-0000-0000-0000-000000000001'$q$) = 0 and public.t_count($q$select 1 from public.labor_salaries where client_id = 'aaaaaaaa-0000-0000-0000-000000000001'$q$) = 0, '');
  begin perform public.set_labor_salary(array['LRS1'], 9999, current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('admin B cannot change the salary of a labor of company A', m = 'unknown labor in the list', m);
  begin perform public.change_role_salary('f0000000-0000-0000-0000-0000000000a1', 1, current_date, true); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('admin B cannot change a role of company A', m = 'unknown role', m);
  reset role;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_log('the terminal cannot read roles or salaries', public.t_count('select 1 from public.roles') = 0 and public.t_count('select 1 from public.labor_salaries') = 0, '');
  begin perform public.set_labor_salary(array['LRS1'], 1, current_date); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('the terminal cannot change salaries', m = '42501', m);
  reset role;
  perform public.t_anon();
  perform public.t_denied('select 1 from public.labor_salaries', 'the public key cannot read salaries');
  perform public.t_denied('select 1 from public.roles', 'the public key cannot read roles');
  reset role;
end $$;

-- changing a salary from a date
do $$ declare r jsonb; m text; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r := public.set_labor_salary(array['LRS2'], 3200, current_date - 10);
  perform public.t_log('admin A changes LRS2 to 3200 from 10 days ago', (r ->> 'changed')::int = 1, r::text);
  reset role;
  perform public.t_log('before that date the old salary applies (2800)', public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS2', current_date - 11) = 2800, '');
  perform public.t_log('on that day and after, the new salary applies (3200)', public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS2', current_date - 10) = 3200 and public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS2', current_date) = 3200, '');
  perform public.t_log('the labor row shows the current salary (3200)', (select monthly_salary = 3200 from laborers where labor_id = 'LRS2'), '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r := public.set_labor_salary(array['LRS2'], 3500, current_date + 20);
  reset role;
  perform public.t_log('a change dated in the future does not touch today (still 3200)', public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS2', current_date) = 3200 and public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS2', current_date + 20) = 3500, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  begin perform public.set_labor_salary(array['LRS2'], -5, current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a negative salary is refused', m = 'invalid salary', m);
  begin perform public.set_labor_salary(array['LRS2'], 100, current_date - 2000); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a date far in the past is refused', m = 'date out of range', m);
  reset role;
end $$;

-- changing the default salary of a role, with and without the labors that follow it
do $$ declare r jsonb; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r := public.change_role_salary('f0000000-0000-0000-0000-0000000000a1', 2700, current_date, true);
  reset role;
  perform public.t_log('Driver default changes to 2700 and the labors ON the default follow (LRS1, LRS3)', (r ->> 'labors_updated')::int = 2 and (select default_monthly_salary = 2700 from roles where id = 'f0000000-0000-0000-0000-0000000000a1'), r::text);
  perform public.t_log('LRS1 and LRS3 now earn 2700 from today, and 2500 before', public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS1', current_date) = 2700 and public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS3', current_date - 1) = 2500, '');
  perform public.t_log('LRS2 (personal salary) is not touched', public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS2', current_date) = 3200, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r := public.change_role_salary('f0000000-0000-0000-0000-0000000000a1', 2900, current_date, false);
  reset role;
  perform public.t_log('without "apply to labors" only the role default changes', (r ->> 'labors_updated')::int = 0 and public.labor_salary_on('aaaaaaaa-0000-0000-0000-000000000001', 'LRS1', current_date) = 2700 and (select default_monthly_salary = 2900 from roles where id = 'f0000000-0000-0000-0000-0000000000a1'), r::text);
end $$;

-- renaming a role
do $$ begin
  update roles set name = 'Truck Driver' where id = 'f0000000-0000-0000-0000-0000000000a1';
  perform public.t_log('renaming a role renames it for its labors', (select count(*) = 3 from laborers where role = 'Truck Driver' and role_id = 'f0000000-0000-0000-0000-0000000000a1'), '');
  begin delete from roles where id = 'f0000000-0000-0000-0000-0000000000a1'; perform public.t_log('a role with labors cannot be deleted', false, 'deleted'); exception when foreign_key_violation then perform public.t_log('a role with labors cannot be deleted', true, ''); end;
  insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, role_id) values ('LRSB', '5800000005', 'Other company', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000002', null);
  perform public.t_log('a labor of company B never gets a role of company A', (select r.client_id = 'bbbbbbbb-0000-0000-0000-000000000002' from laborers l join roles r on r.id = l.role_id where l.labor_id = 'LRSB'), '');
  begin update laborers set role_id = 'f0000000-0000-0000-0000-0000000000a1' where labor_id = 'LRSB'; perform public.t_log('a labor cannot be given a role of another company', false, 'allowed'); exception when others then perform public.t_log('a labor cannot be given a role of another company', sqlerrm = 'Unknown role', sqlerrm); end;
end $$;
