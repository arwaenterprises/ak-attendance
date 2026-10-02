create or replace function public.set_config_text(k text, v text) returns void language sql as $$ select set_config(k, v, false) $$;
-- Tests for migration 013: platform owner (super_admin of the company PLATFORM), client creation, list, switch on / off, password reset.
select public.create_platform_owner('theowner', 'owner-password-123');
do $$ declare o uuid; begin
  select u.auth_id into o from public.users u where u.username = 'theowner';
  perform set_config('test.owner', o::text, false);
  perform public.t_log('the owner login and the PLATFORM company exist', o is not null and exists (select 1 from clients where client_code = 'PLATFORM' and subscription_status = 'premium'), '');
  perform public.t_log('the owner login is a confirmed Auth login with the platform email', (select email from auth.users where id = o) = 'theowner@platform.dawam.arwaenterprises.com' and (select email_confirmed_at is not null from auth.users where id = o), '');
end $$;

-- who may call the platform functions
do $$ begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied($q$select public.platform_list_clients()$q$, 'a company administrator cannot list the companies');
  perform public.t_denied($q$select public.platform_create_client('X Co', 'XCO', 'xadmin', 'long-password-1')$q$, 'a company administrator cannot create a company');
  perform public.t_denied($q$select public.platform_set_client('aaaaaaaa-0000-0000-0000-000000000001', false)$q$, 'a company administrator cannot switch a company off');
  perform public.t_denied($q$select public.platform_reset_admin_password('bbbbbbbb-0000-0000-0000-000000000002', 'long-password-1')$q$, 'a company administrator cannot reset another administrator password');
  reset role;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_denied($q$select public.platform_list_clients()$q$, 'a terminal cannot list the companies');
  reset role;
  perform public.t_anon();
  perform public.t_denied($q$select public.platform_list_clients()$q$, 'the public key cannot list the companies');
  perform public.t_denied($q$select public.create_platform_owner('hacker', 'long-password-1')$q$, 'nobody can create a platform owner from the app');
  perform public.t_denied($q$select public._create_auth_user('x@y.z', 'long-password-1')$q$, 'nobody can create raw Auth logins from the app');
  reset role;
end $$;

-- the owner creates a company
do $$ declare o uuid := current_setting('test.owner')::uuid; r jsonb; m text; n int; cid uuid; begin
  perform public.t_login(o);
  r := public.platform_create_client('Gulf Logistics', 'gulf1', 'gulfadmin', 'gulf-admin-pass-1', 'Mr Gulf', 14);
  perform public.t_log('the owner creates a company', r ->> 'client_code' = 'GULF1' and r ->> 'admin_username' = 'gulfadmin', r::text);
  cid := (r ->> 'client_id')::uuid;
  perform public.set_config_text('test.gulf', cid::text);
  begin perform public.platform_create_client('Dup', 'GULF1', 'other1', 'long-password-1'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('the same company code twice is refused', m = 'That company code is already used', m);
  begin perform public.platform_create_client('Bad', 'bad code!', 'other1', 'long-password-1'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a bad company code is refused', m like 'company code:%', m);
  begin perform public.platform_create_client('Bad', 'PLATFORM', 'other1', 'long-password-1'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('the code PLATFORM is reserved', m like 'company code:%', m);
  begin perform public.platform_create_client('Bad', 'BAD2', 'x', 'long-password-1'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a too short administrator username is refused', m like 'administrator username:%', m);
  begin perform public.platform_create_client('Bad', 'BAD3', 'gooduser', 'short'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a short password is refused', m like 'administrator password:%', m);
  reset role;
  perform public.t_log('the company row: trial for 14 days, attendance app, active',
    (select subscription_status = 'trial' and is_active and subscription_end_date = current_date + 14 and subscribed_apps = array['attendance'] from clients where id = cid), '');
  select count(*) into n from shifts where client_id = cid;
  perform public.t_log('the company got its Day and Night shift', n = 2, n::text);
  perform public.t_log('administrator login: Auth user gulfadmin@gulf1... + profile with role admin', (select role from users where client_id = cid and username = 'gulfadmin') = 'admin'
    and exists (select 1 from auth.users where email = 'gulfadmin@gulf1.dawam.arwaenterprises.com'), '');
  perform public.t_log('terminal login: Auth user terminal@gulf1... + profile with role terminal + a key row of 28 characters', (select role from users where client_id = cid and username = 'terminal') = 'terminal'
    and exists (select 1 from auth.users where email = 'terminal@gulf1.dawam.arwaenterprises.com') and (select length(key) from terminal_keys where client_id = cid) = 28, '');
  perform public.t_log('the terminal key is the password of the terminal login (hash matches)',
    (select encrypted_password = extensions.crypt(k.key, encrypted_password) from auth.users a, terminal_keys k where a.email = 'terminal@gulf1.dawam.arwaenterprises.com' and k.client_id = cid), '');
  perform public.t_log('the administrator password is stored as a hash that matches', (select encrypted_password = extensions.crypt('gulf-admin-pass-1', encrypted_password) from auth.users where email = 'gulfadmin@gulf1.dawam.arwaenterprises.com'), '');
end $$;

-- the new administrator really works as that company (sees own company, role admin) and the company admin can fetch the terminal link key
do $$ declare a uuid; r jsonb; begin
  select auth_id into a from users where client_id = current_setting('test.gulf')::uuid and username = 'gulfadmin';
  perform public.t_login(a);
  perform public.t_log('the new administrator is resolved to his own company with the role admin', public.current_client_id() = current_setting('test.gulf')::uuid and public.current_user_role() = 'admin', '');
  r := public.get_terminal_key();
  perform public.t_log('the new administrator can open the terminal link page (key + code)', r ->> 'client_code' = 'GULF1' and length(r ->> 'key') = 28 and not (r ->> 'created')::boolean, r::text);
  perform public.t_log('and sees the 2 shifts of his company only', public.t_count('select 1 from public.shifts') = 2, '');
  reset role;
end $$;

-- list
do $$ declare o uuid := current_setting('test.owner')::uuid; r jsonb; g jsonb; begin
  perform public.t_login(o);
  r := public.platform_list_clients();
  g := (select e from jsonb_array_elements(r) e where e ->> 'client_code' = 'GULF1');
  perform public.t_log('the list has every company (platform last) with status and the administrator name', jsonb_array_length(r) >= 5 and g ->> 'admin_username' = 'gulfadmin' and (g ->> 'terminal_ready')::boolean
    and (r -> (jsonb_array_length(r) - 1)) ->> 'client_code' = 'PLATFORM', r::text);
  perform public.t_log('the list shows counts only (no labor data)', not (r::text ~* 'iqama|salary|face_descriptor'), '');
  perform public.t_log('the owner cannot read any company labor data through the tables', public.t_count('select 1 from public.laborers') = 0 and public.t_count('select 1 from public.punch_records') = 0, '');
  reset role;
end $$;

-- switch off / on, subscription
do $$ declare o uuid := current_setting('test.owner')::uuid; cid uuid := current_setting('test.gulf')::uuid; a uuid; m text; begin
  select auth_id into a from users where client_id = cid and username = 'gulfadmin';
  perform public.t_login(o);
  perform public.platform_set_client(cid, false);
  reset role;
  perform public.t_login(a);
  perform public.t_log('a company that is switched off gets no data access at all', public.current_client_id() is null and public.t_count('select 1 from public.shifts') = 0, '');
  reset role;
  perform public.t_login(o);
  perform public.platform_set_client(cid, true);
  perform public.platform_set_client(cid, null, 'active', current_date + 365, 'pro');
  reset role;
  perform public.t_log('switched on again with a paid year: status active, end date, tier', (select is_active and subscription_status = 'active' and subscription_end_date = current_date + 365 and subscription_tier = 'pro' from clients where id = cid), '');
  perform public.t_login(a);
  perform public.t_log('the administrator has access again', public.current_client_id() = cid, '');
  reset role;
  perform public.t_login(o);
  perform public.platform_set_client(cid, null, 'expired');
  reset role;
  perform public.t_login(a);
  perform public.t_log('an expired subscription closes the data access', public.current_client_id() is null, '');
  reset role;
  perform public.t_login(o);
  perform public.platform_set_client(cid, null, 'premium');
  reset role;
  perform public.t_log('premium has no end date', (select subscription_end_date is null and subscription_status = 'premium' from clients where id = cid), '');
  perform public.t_login(o);
  begin perform public.platform_set_client(cid, null, 'weird'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an unknown status is refused', m like 'status:%', m);
  begin perform public.platform_set_client((select id from clients where client_code = 'PLATFORM'), false); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('the platform company cannot be switched off', m like 'The platform company%', m);
  begin perform public.platform_set_client(gen_random_uuid(), true); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an unknown company is refused', m = 'unknown company', m);
  reset role;
end $$;

-- administrator password reset
do $$ declare o uuid := current_setting('test.owner')::uuid; cid uuid := current_setting('test.gulf')::uuid; m text; h text; begin
  perform public.t_login(o);
  perform public.platform_reset_admin_password(cid, 'brand-new-password-9');
  begin perform public.platform_reset_admin_password(cid, 'short'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a short new password is refused', m like 'password:%', m);
  begin perform public.platform_reset_admin_password((select id from clients where client_code = 'TRI'), 'brand-new-password-9'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a company without an administrator gives a clear message', m = 'This company has no administrator login', m);
  reset role;
  select encrypted_password into h from auth.users where email = 'gulfadmin@gulf1.dawam.arwaenterprises.com';
  perform public.t_log('the administrator password is now the new one and no longer the old one', h = extensions.crypt('brand-new-password-9', h) and h <> extensions.crypt('gulf-admin-pass-1', h), '');
end $$;
