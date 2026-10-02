-- After cutover bundle: assertions. Then rollback: assertions.
do $$ declare n int; begin
  select count(*) into n from information_schema.tables where table_schema='archive_other_apps' and table_name in ('medicines','exp_expenses');
  if n=2 then raise notice 'PASS other apps moved to archive'; else raise notice 'FAIL other apps not archived (%)', n; end if;
  select count(*) into n from archive_other_apps.medicines;
  if n=2 then raise notice 'PASS archived data intact'; else raise notice 'FAIL archived data lost'; end if;
  select count(*) into n from pg_policies where schemaname='public' and (policyname ilike 'allow all%');
  if n=0 then raise notice 'PASS no old open policies remain'; else raise notice 'FAIL % old open policies', n; end if;
  select count(*) into n from public.users where role='supervisor' and status<>'inactive';
  if n=0 then raise notice 'PASS supervisors retired'; else raise notice 'FAIL supervisors active'; end if;
  if has_table_privilege('anon','public.laborers','select') then raise notice 'FAIL anon can read laborers'; else raise notice 'PASS anon locked out'; end if;
  select count(*) into n from public.clients where business_name='Arwa Enterprises';
  if n=1 then raise notice 'PASS company data preserved'; else raise notice 'FAIL company data lost'; end if;
end $$;
