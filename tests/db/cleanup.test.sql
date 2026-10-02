-- Tests for migration 014: the old _punch_rule is gone and the rules still work (labor LD1 of the 009 tests: logged in and out on day -3).
do $$ declare r jsonb; begin
  perform public.t_log('the old _punch_rule function no longer exists', not exists (select 1 from pg_proc where proname = '_punch_rule'), '');
  perform public.t_log('the current _punch_check exists', exists (select 1 from pg_proc where proname = '_punch_check'), '');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_punch('LD1', 'login', 3, '13:30:00');
  perform public.t_log('the rules still work after the clean-up: a second IN after the OUT is refused', r ->> 'code' = 'ALREADY_DONE', r::text);
  r := public.terminal_check_punch('LD1', 'logout', current_date - 3, '14:00');
  perform public.t_log('the check function still works', not (r ->> 'allowed')::boolean and r ->> 'code' = 'NO_OPEN_IN', r::text);
  reset role;
end $$;
