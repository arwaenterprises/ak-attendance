-- Tests for migration 012: the administrator reads / renews the terminal key. Company A has terminal 72222222-... linked (admin a1111111-...); company B has none (admin b2222222-...).
do $$ declare r jsonb; r2 jsonb; r3 jsonb; h1 text; h2 text; n int; m text; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r := public.get_terminal_key();
  perform public.t_log('admin A: first call creates a key (28 letters / digits) and gives the company code', (r ->> 'created')::boolean and length(r ->> 'key') = 28 and (r ->> 'key') ~ '^[A-Za-z0-9]+$' and r ->> 'client_code' = 'AAA', r::text);
  reset role;
  select encrypted_password into h1 from auth.users where id = '72222222-0000-0000-0000-000000000012';
  perform public.t_log('the key is now the password of the company terminal login (hash matches)', h1 is not null and h1 = extensions.crypt(r ->> 'key', h1), '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r2 := public.get_terminal_key();
  perform public.t_log('second call returns the SAME key and changes nothing', not (r2 ->> 'created')::boolean and r2 ->> 'key' = r ->> 'key', r2::text);
  r3 := public.get_terminal_key(true);
  perform public.t_log('renewing makes a different key', (r3 ->> 'created')::boolean and r3 ->> 'key' <> r ->> 'key', r3::text);
  reset role;
  select encrypted_password into h2 from auth.users where id = '72222222-0000-0000-0000-000000000012';
  perform public.t_log('after renewing, the login password is the new key and no longer the old one', h2 = extensions.crypt(r3 ->> 'key', h2) and h2 <> extensions.crypt(r ->> 'key', h2), '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('admin A can read his own key row, only that one', public.t_count('select 1 from public.terminal_keys') = 1, '');
  begin update public.terminal_keys set key = 'abcdefghijklmnopqrstuvwxyz'; m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('admin A cannot write the key table (only the function does)', m = '42501', m);
  r3 := public.get_terminal_key(false, 'my-own-terminal-key-0123456789');
  perform public.t_log('the administrator can choose his own key', r3 ->> 'key' = 'my-own-terminal-key-0123456789' and (r3 ->> 'created')::boolean, r3::text);
  begin perform public.get_terminal_key(false, 'short'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a key that is too short or has odd characters is refused', m like 'The key must be%', m);
  begin perform public.get_terminal_key(false, 'has spaces and is long enough ok'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a key with spaces is refused', m like 'The key must be%', m);
  reset role;
end $$;
do $$ declare m text; begin
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  begin perform public.get_terminal_key(); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a company without a terminal login gets a clear message', m like 'The punch terminal login is not set up%', m);
  perform public.t_log('admin B sees no key of company A', public.t_count('select 1 from public.terminal_keys') = 0, '');
  reset role;
end $$;
do $$ begin
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  perform public.t_denied($q$select public.get_terminal_key()$q$, 'the terminal cannot ask for the terminal key');
  perform public.t_log('the terminal cannot read the key table', public.t_count('select 1 from public.terminal_keys') = 0, '');
  reset role;
end $$;
do $$ begin perform public.t_anon(); perform public.t_denied($q$select public.get_terminal_key()$q$, 'the public key cannot ask for the terminal key'); reset role; end $$;
do $$ begin perform public.t_anon(); perform public.t_denied('select 1 from public.terminal_keys', 'the public key cannot read the key table'); reset role; end $$;
do $$ begin perform public.t_login('a1111111-0000-0000-0000-000000000001'); perform public.t_denied($q$select public._set_terminal_key('aaaaaaaa-0000-0000-0000-000000000001', 'abcdefghijklmnopqrstuvwxyz')$q$, 'an administrator cannot call the internal key setter directly'); reset role; end $$;
