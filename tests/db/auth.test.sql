-- Tests for migration 002 (needs rls.test.sql to have run first: it created the helpers and the two test companies).
insert into clients (id, business_name, client_code, subscription_status, subscription_end_date, is_active) values
  ('eeeeeeee-0000-0000-0000-000000000005', 'Expired Co',  'EXP', 'expired', null, true),
  ('ffffffff-0000-0000-0000-000000000006', 'Inactive Co', 'INA', 'trial', null, false),
  ('11111111-0000-0000-0000-000000000007', 'Ended Co',    'END', 'active', current_date - 1, true),
  ('22222222-0000-0000-0000-000000000008', 'Premium Co',  'PRE', 'premium', current_date - 100, true),
  ('33333333-0000-0000-0000-000000000009', 'Trial Co',    'TRI', 'trial', current_date + 10, true);
insert into auth.users (id, email) values
  ('e5555555-0000-0000-0000-000000000005', 'admin@exp.dawam.arwaenterprises.com'),
  ('f6666666-0000-0000-0000-000000000006', 'admin@ina.dawam.arwaenterprises.com'),
  ('17777777-0000-0000-0000-000000000007', 'admin@end.dawam.arwaenterprises.com'),
  ('28888888-0000-0000-0000-000000000008', 'admin@pre.dawam.arwaenterprises.com'),
  ('39999999-0000-0000-0000-000000000009', 'admin@tri.dawam.arwaenterprises.com'),
  ('a1111111-0000-0000-0000-0000000000a1', 'admin@aaa.dawam.arwaenterprises.com');   -- note: separate account used for link tests

do $$ declare r text; begin
  -- link function: creates profiles for the new companies
  perform public.link_admin_profile('EXP', 'Admin', 'Admin EXP');
  perform public.link_admin_profile('INA', 'admin');
  perform public.link_admin_profile('END', 'admin');
  perform public.link_admin_profile('PRE', 'admin');
  perform public.link_admin_profile('TRI', 'admin');
  perform public.t_log('link_admin_profile creates an admin profile (lower-case username, role admin)',
    (select count(*) from users where username = 'admin' and role = 'admin' and auth_id = 'e5555555-0000-0000-0000-000000000005' and client_id = 'eeeeeeee-0000-0000-0000-000000000005') = 1, '');
  -- linking is repeatable and links an existing profile row (company A already has "admin_a"; a second link must not create a second admin)
  r := public.link_admin_profile('TRI', 'ADMIN ');
  perform public.t_log('link_admin_profile is repeatable and returns the email', r = 'admin@tri.dawam.arwaenterprises.com', r);
  perform public.t_log('still one profile for that company', (select count(*) from users where client_id = '33333333-0000-0000-0000-000000000009') = 1, '');
end $$;

do $$ declare msg text; begin
  begin perform public.link_admin_profile('NOPE', 'admin'); msg := 'allowed';
  exception when others then msg := sqlerrm; end;
  perform public.t_log('link_admin_profile refuses an unknown company code', msg like 'unknown company code%', msg);
  begin perform public.link_admin_profile('AAA', 'ghost'); msg := 'allowed';
  exception when others then msg := sqlerrm; end;
  perform public.t_log('link_admin_profile refuses when the Auth account does not exist yet', msg like 'create the Auth account first%', msg);
end $$;

-- nobody but the platform owner can link accounts
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.link_admin_profile('AAA', 'admin_a')$q$, 'a logged-in admin cannot run link_admin_profile');
  perform public.t_anon();
  perform public.t_denied($q$select public.link_admin_profile('AAA', 'admin_a')$q$, 'the public key cannot run link_admin_profile');
  reset role;
end $$;

-- one admin per company, usernames per company, settings per company
do $$ declare e text; begin
  begin insert into users (username, name, role, client_id) values ('second_admin', 'x', 'admin', 'aaaaaaaa-0000-0000-0000-000000000001'); e := 'allowed';
  exception when unique_violation then e := 'refused'; end;
  perform public.t_log('a second ACTIVE admin in the same company is refused', e = 'refused', e);
  begin insert into users (username, name, role, status, client_id) values ('replaced_admin', 'Old', 'admin', 'inactive', 'aaaaaaaa-0000-0000-0000-000000000001'); e := 'allowed';
  exception when unique_violation then e := 'refused'; end;
  perform public.t_log('an inactive (replaced) admin does not count against the rule', e = 'allowed', e);
  begin insert into users (username, name, role, client_id) values ('sup1', 'Supervisor', 'supervisor', 'aaaaaaaa-0000-0000-0000-000000000001'); e := 'allowed';
  exception when unique_violation then e := 'refused'; end;
  perform public.t_log('other roles are not limited by the one-admin rule', e = 'allowed', e);
  begin insert into users (username, name, role, client_id) values ('sup1', 'Dup', 'supervisor', 'aaaaaaaa-0000-0000-0000-000000000001'); e := 'allowed';
  exception when unique_violation then e := 'refused'; end;
  perform public.t_log('the same username twice in one company is refused', e = 'refused', e);
  perform public.t_log('two companies can both have the username "admin"', (select count(*) from users where username = 'admin') >= 2, '');
  begin insert into settings (key, value, client_id) values ('night_shift_start', '20:00', 'aaaaaaaa-0000-0000-0000-000000000001'), ('night_shift_start', '21:00', 'bbbbbbbb-0000-0000-0000-000000000002'); e := 'allowed';
  exception when unique_violation then e := 'refused'; end;
  perform public.t_log('two companies can both have the setting night_shift_start', e = 'allowed', e);
  begin insert into settings (key, value, client_id) values ('night_shift_start', '22:00', 'aaaaaaaa-0000-0000-0000-000000000001'); e := 'allowed';
  exception when unique_violation then e := 'refused'; end;
  perform public.t_log('the same setting twice in one company is refused', e = 'refused', e);
  begin insert into users (username, name, role, client_id, auth_id) values ('nohash', 'No Hash', 'supervisor', 'bbbbbbbb-0000-0000-0000-000000000002', null); e := 'allowed';
  exception when others then e := sqlerrm; end;
  perform public.t_log('a user needs no password hash any more', e = 'allowed', e);
end $$;

-- subscription rules are enforced by the database
do $$ begin
  perform public.t_login('e5555555-0000-0000-0000-000000000005');
  perform public.t_log('company with an EXPIRED subscription: no data access', public.t_count('select 1 from public.departments') = 0 and public.t_count('select 1 from public.clients') = 0, '');
  perform public.t_login('f6666666-0000-0000-0000-000000000006');
  perform public.t_log('INACTIVE company: no data access', public.t_count('select 1 from public.clients') = 0, '');
  perform public.t_login('17777777-0000-0000-0000-000000000007');
  perform public.t_log('company whose end date has passed: no data access', public.t_count('select 1 from public.clients') = 0, '');
  perform public.t_login('28888888-0000-0000-0000-000000000008');
  perform public.t_log('PREMIUM company keeps access (no expiry check)', public.t_count('select 1 from public.clients') = 1, '');
  perform public.t_login('39999999-0000-0000-0000-000000000009');
  perform public.t_log('TRIAL company within its dates has access', public.t_count('select 1 from public.clients') = 1, '');
  perform public.t_login('39999999-0000-0000-0000-000000000009');
  insert into public.departments (name, code) values ('Trial dept', 'TRD');
  perform public.t_log('a linked admin can create data for its own company', (select client_id from public.departments where code = 'TRD') = '33333333-0000-0000-0000-000000000009', '');
  reset role;
end $$;
