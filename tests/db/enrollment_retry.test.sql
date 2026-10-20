-- Tests for migration 023: a self-enrollment link can see (and so overwrite) its own photo, and nothing else.
insert into enrollment_links (token, labor_id, client_id, status, expires_at) values
  ('tok-retry', 'NH1', '33333333-0000-0000-0000-000000000009', 'pending', now() + interval '1 hour'),
  ('tok-retry-old', 'NH1', '33333333-0000-0000-0000-000000000009', 'pending', now() - interval '1 minute');
insert into storage.objects (bucket_id, name) values
  ('punch-photos', '33333333-0000-0000-0000-000000000009/enrollment/tok-retry.jpg'),
  ('punch-photos', '33333333-0000-0000-0000-000000000009/enrollment/tok-retry-old.jpg'),
  ('punch-photos', '33333333-0000-0000-0000-000000000009/punches/L1_1.jpg');
do $$ declare n int; begin
  perform public.t_anon();
  select count(*) into n from storage.objects where name = '33333333-0000-0000-0000-000000000009/enrollment/tok-retry.jpg';
  perform public.t_log('023: a pending link sees its own photo (needed to overwrite it on a second try)', n = 1, n::text);
  select count(*) into n from storage.objects where name like '33333333-0000-0000-0000-000000000009/%' and name <> '33333333-0000-0000-0000-000000000009/enrollment/tok-retry.jpg';
  perform public.t_log('023: it sees nothing else (expired link photo, punch photos)', n = 0, n::text);
  perform public.t_log('023: it can overwrite its photo', public.t_rows_changed($q$update storage.objects set name = name where name = '33333333-0000-0000-0000-000000000009/enrollment/tok-retry.jpg'$q$) = 1, '');
  reset role;
end $$;
