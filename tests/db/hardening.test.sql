-- Tests for migration 005 (runs after the terminal tests; their data is still there).
do $$ begin
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_log('a terminal cannot read the company row', public.t_count('select 1 from public.clients') = 0, '');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_log('a terminal can still read its own user row only', public.t_count('select 1 from public.users') = 1, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('an admin can still read its company row', public.t_count('select 1 from public.clients') = 1, '');
  reset role;
end $$;
