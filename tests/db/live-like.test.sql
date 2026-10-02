-- After cutover bundle: assertions. Then rollback: assertions.
do $$ declare n int; begin
  select count(*) into n from information_schema.tables where table_schema='archive_other_apps' and table_name in ('medicines','exp_expenses');
  if n=2 then raise notice 'PASS other apps moved to archive'; else raise notice 'FAIL other apps not archived (%)', n; end if;
  select count(*) into n from archive_other_apps.medicines;
  if n=2 then raise notice 'PASS archived data intact'; else raise notice 'FAIL archived data lost'; end if;
  select count(*) into n from pg_policies where schemaname='public' and (policyname ilike 'allow all%');
  if n=0 then raise notice 'PASS no old open policies remain'; else raise notice 'FAIL % old open policies', n; end if;
  select count(*) into n from public.users where role='supervisor';
  if n=0 then raise notice 'PASS unreferenced supervisors removed'; else raise notice 'FAIL supervisors remain (%)', n; end if;
  select count(*) into n from public.clients where client_code in ('AE2','AE3');
  if n=0 then raise notice 'PASS AE2 and AE3 deleted'; else raise notice 'FAIL AE2/AE3 remain'; end if;
  select count(*) into n from public.departments where code='OP2';
  if n=0 then raise notice 'PASS AE2 data deleted'; else raise notice 'FAIL AE2 data remains'; end if;
  select count(*) into n from public.punch_locations where status='active' and name in ('Kaden Warehouse','Sulay');
  if n=2 then raise notice 'PASS Kaden Warehouse and Sulay kept active'; else raise notice 'FAIL kept locations (%)', n; end if;
  select count(*) into n from public.punch_locations where name='Murabba Site';
  if n=0 then raise notice 'PASS unused location deleted'; else raise notice 'FAIL unused location remains'; end if;
  select count(*) into n from public.punch_locations where name='Home' and status='inactive';
  if n=1 then raise notice 'PASS location with punches kept but inactive'; else raise notice 'FAIL Home handling'; end if;
  if has_table_privilege('anon','public.laborers','select') then raise notice 'FAIL anon can read laborers'; else raise notice 'PASS anon locked out'; end if;
  select count(*) into n from public.clients where business_name='Arwa Enterprises';
  if n=1 then raise notice 'PASS company data preserved'; else raise notice 'FAIL company data lost'; end if;
end $$;
