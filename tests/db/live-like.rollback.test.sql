do $$ declare n int; begin
  select count(*) into n from information_schema.tables where table_schema='public' and table_name in ('medicines','exp_expenses');
  if n=2 then raise notice 'PASS rollback returned other apps'; else raise notice 'FAIL rollback did not return other apps (%)', n; end if;
  if has_table_privilege('anon','public.laborers','select') then raise notice 'PASS rollback restored old access'; else raise notice 'FAIL rollback access not restored'; end if;
  select count(*) into n from public.clients where client_code in ('AE2','AE3');
  if n=0 then raise notice 'PASS rollback does not bring deleted companies back (expected)'; else raise notice 'FAIL deleted companies reappeared'; end if;
  select count(*) into n from public.medicines;
  if n=2 then raise notice 'PASS other-app data intact after rollback'; else raise notice 'FAIL other-app data'; end if;
end $$;
