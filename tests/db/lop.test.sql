-- Tests for migration 003 (runs after the other test files; their test data is still there).
do $$ declare e text; begin
  perform public.t_log('lop_requests -> laborers key exists (needed by the LOP lists)',
    (select count(*) from pg_constraint where conname = 'lop_requests_labor_id_fkey' and contype = 'f') = 1, '');
  begin insert into lop_requests (labor_id, department_id, date, auto_status, requested_status, client_id)
        values ('NO-SUCH-LABOR', 'da000000-0000-0000-0000-00000000000a', '2020-03-01', 'A', 'P', 'aaaaaaaa-0000-0000-0000-000000000001'); e := 'allowed';
  exception when foreign_key_violation then e := 'refused'; end;
  perform public.t_log('a new LOP request for a labor that does not exist is refused', e = 'refused', e);
  begin insert into lop_requests (labor_id, department_id, date, auto_status, requested_status, client_id)
        values ('LA1', 'da000000-0000-0000-0000-00000000000a', '2020-03-02', 'A', 'P', 'aaaaaaaa-0000-0000-0000-000000000001'); e := 'allowed';
  exception when others then e := sqlerrm; end;
  perform public.t_log('a LOP request for an existing labor is accepted', e = 'allowed', e);
end $$;
