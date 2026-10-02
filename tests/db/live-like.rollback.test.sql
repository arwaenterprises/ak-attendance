do $$ declare n int; begin
  select count(*) into n from information_schema.tables where table_schema='public' and table_name in ('medicines','exp_expenses');
  if n=2 then raise notice 'PASS rollback returned other apps'; else raise notice 'FAIL rollback did not return other apps (%)', n; end if;
  if has_table_privilege('anon','public.laborers','select') then raise notice 'PASS rollback restored old access'; else raise notice 'FAIL rollback access not restored'; end if;
  select count(*) into n from public.users where role='supervisor' and status='active';
  if n=1 then raise notice 'PASS rollback restored supervisors'; else raise notice 'FAIL rollback supervisors (%)', n; end if;
  select count(*) into n from public.medicines;
  if n=2 then raise notice 'PASS other-app data intact after rollback'; else raise notice 'FAIL other-app data'; end if;
end $$;
