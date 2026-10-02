-- Tests for migration 006: private photos and safe self-enrollment. Runs after the other test files (their companies, users and links exist).
-- Company A: id aaaaaaaa-...01, admin a1111111-..., terminal 72222222-... ; company B: bbbbbbbb-...02, admin b2222222-...
insert into storage.buckets (id, name, public) values ('punch-photos', 'punch-photos', true) on conflict do nothing;
do $$ begin
  perform public.t_log('the photo bucket is private, 5 MB, JPEG only',
    coalesce((select not public and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg'] from storage.buckets where id = 'punch-photos'), false), '');
end $$;

-- objects uploaded by a terminal
do $$ declare A text := 'aaaaaaaa-0000-0000-0000-000000000001'; B text := 'bbbbbbbb-0000-0000-0000-000000000002'; begin
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  insert into storage.objects (bucket_id, name) values ('punch-photos', A || '/punches/LA1_1.jpg');
  perform public.t_log('a terminal can add a photo to its own company punches folder', true, '');
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, B || '/punches/x.jpg'), 'a terminal cannot add a photo to ANOTHER company folder');
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  perform public.t_denied($q$insert into storage.objects (bucket_id, name) values ('punch-photos', 'punches/x.jpg')$q$, 'a terminal cannot add a photo outside a company folder');
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/enrollment/x.jpg'), 'a terminal cannot write into the enrollment folder');
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  perform public.t_denied($q$insert into storage.objects (bucket_id, name) values ('other-bucket', 'a/punches/x.jpg')$q$, 'a terminal cannot write into another bucket');
  reset role;
end $$;
-- reading
do $$ declare A text := 'aaaaaaaa-0000-0000-0000-000000000001'; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/punches/admin.jpg'), 'an admin cannot upload punch photos (only terminals do)');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('staff of company A can read A photo', public.t_count(format($q$select 1 from storage.objects where name = %L$q$, A || '/punches/LA1_1.jpg')) = 1, '');
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  perform public.t_log('staff of company B cannot see A photo', public.t_count($q$select 1 from storage.objects where name like 'aaaaaaaa%'$q$) = 0, '');
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  perform public.t_log('the terminal of A can read A photo (for its my-punches list)', public.t_count($q$select 1 from storage.objects where name like 'aaaaaaaa%'$q$) = 1, '');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  perform public.t_log('the terminal of another company cannot see A photo', public.t_count($q$select 1 from storage.objects where name like 'aaaaaaaa%'$q$) = 0, '');
  perform public.t_anon();
  perform public.t_log('the public key sees no photos', public.t_count('select 1 from storage.objects') = 0, '');
  perform public.t_anon();
  perform public.t_denied($q$insert into storage.objects (bucket_id, name) values ('punch-photos', 'aaaaaaaa-0000-0000-0000-000000000001/punches/anon.jpg')$q$, 'the public key cannot add punch photos');
  reset role;
end $$;
-- deleting
do $$ begin
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  perform public.t_log('staff of B cannot delete A photo', public.t_rows_changed($q$delete from storage.objects where name like 'aaaaaaaa%'$q$) = 0, '');
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  perform public.t_log('a terminal cannot delete photos', public.t_rows_changed($q$delete from storage.objects where name like 'aaaaaaaa%'$q$) = 0, '');
  perform public.t_anon();
  perform public.t_log('the public key cannot delete photos', public.t_rows_changed($q$delete from storage.objects where true$q$) = 0, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('staff of A can delete A photo (cleanup / enrollment approval)', public.t_rows_changed($q$delete from storage.objects where name like 'aaaaaaaa%'$q$) = 1, '');
  reset role;
end $$;

-- photos from before this change: owned by the company whose record points at the file
do $$ begin
  insert into storage.objects (bucket_id, name) values ('punch-photos', 'punches/LEGACY1_999.jpg');
  insert into punch_records (labor_id, department_id, date, time, type, photo_url, client_id)
    values ('LA1', 'da000000-0000-0000-0000-00000000000a', '2020-05-01', '09:00', 'login', 'https://x.supabase.co/storage/v1/object/public/punch-photos/punches/LEGACY1_999.jpg', 'aaaaaaaa-0000-0000-0000-000000000001');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('an old-style photo is readable by the company whose punch points at it', public.t_count($q$select 1 from storage.objects where name = 'punches/LEGACY1_999.jpg'$q$) = 1, '');
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  perform public.t_log('an old-style photo is NOT readable by another company', public.t_count($q$select 1 from storage.objects where name = 'punches/LEGACY1_999.jpg'$q$) = 0, '');
  perform public.t_anon();
  perform public.t_log('an old-style photo is not readable by the public key', public.t_count($q$select 1 from storage.objects where name = 'punches/LEGACY1_999.jpg'$q$) = 0, '');
  reset role;
end $$;

-- self-enrollment: links
insert into enrollment_links (token, labor_id, client_id, status, expires_at) values
  ('tok-exp',  'LA1', 'aaaaaaaa-0000-0000-0000-000000000001', 'pending',   now() - interval '1 minute'),
  ('tok-used', 'LA1', 'aaaaaaaa-0000-0000-0000-000000000001', 'submitted', now() + interval '1 hour');
do $$ declare r jsonb; A text := 'aaaaaaaa-0000-0000-0000-000000000001'; begin
  perform public.t_anon();
  r := public.enrollment_get('tok-a');
  perform public.t_log('enrollment_get: a valid link returns the labor and company (no table access needed)', (r ->> 'ok')::boolean and r ->> 'labor_id' = 'LA1' and r ->> 'client_id' = A and r ->> 'labor_name' = 'Labor A1', r::text);
  perform public.t_anon(); r := public.enrollment_get('nope');
  perform public.t_log('enrollment_get: an unknown link is reported as invalid', not (r ->> 'ok')::boolean and r ->> 'reason' = 'invalid', r::text);
  perform public.t_anon(); r := public.enrollment_get('tok-used');
  perform public.t_log('enrollment_get: a used link says so', not (r ->> 'ok')::boolean and r ->> 'reason' = 'submitted', r::text);
  perform public.t_anon(); r := public.enrollment_get('tok-exp');
  perform public.t_log('enrollment_get: an expired link says so', not (r ->> 'ok')::boolean and r ->> 'reason' = 'expired', r::text);
  perform public.t_anon();
  perform public.t_denied('select * from public.enrollment_links', 'the public key still cannot read the enrollment table');
  perform public.t_anon();
  perform public.t_denied($q$update public.enrollment_links set status = 'approved'$q$, 'the public key cannot change the enrollment table');
  reset role;
end $$;
-- self-enrollment: photo upload
do $$ declare A text := 'aaaaaaaa-0000-0000-0000-000000000001'; begin
  perform public.t_anon();
  insert into storage.objects (bucket_id, name) values ('punch-photos', A || '/enrollment/tok-a.jpg');
  perform public.t_log('a valid link can upload its one photo', true, '');
  perform public.t_anon();
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/enrollment/tok-b.jpg'), 'a link cannot upload a photo for another link (token belongs to company B)');
  perform public.t_anon();
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/enrollment/tok-exp.jpg'), 'an expired link cannot upload');
  perform public.t_anon();
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/enrollment/tok-used.jpg'), 'a used link cannot upload');
  perform public.t_anon();
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/enrollment/guess123.jpg'), 'a made-up token cannot upload');
  perform public.t_anon();
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/punches/tok-a.jpg'), 'a link cannot upload into the punches folder');
  perform public.t_anon();
  perform public.t_denied($q$insert into storage.objects (bucket_id, name) values ('punch-photos', 'enrollment/tok-a.jpg')$q$, 'a link cannot upload outside a company folder');
  perform public.t_anon();
  perform public.t_denied(format($q$insert into storage.objects (bucket_id, name) values ('punch-photos', %L)$q$, A || '/enrollment/tok-a.png'), 'a link cannot upload a non-jpg path');
  reset role;
end $$;
-- self-enrollment: submit
do $$ declare r jsonb; m text; A text := 'aaaaaaaa-0000-0000-0000-000000000001'; d text := (select jsonb_agg(0.5)::text from generate_series(1, 128)); begin
  perform public.t_anon();
  begin perform public.enrollment_submit('tok-a', d, 'wrong/path.jpg'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('submit with a wrong photo path is refused', m = 'Invalid photo', m);
  perform public.t_anon();
  begin perform public.enrollment_submit('tok-a', 'not json', A || '/enrollment/tok-a.jpg'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('submit with invalid face data is refused', m = 'Invalid face data', m);
  perform public.t_anon();
  begin perform public.enrollment_submit('tok-a', '[1,2,3]', A || '/enrollment/tok-a.jpg'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('submit with a face descriptor of the wrong length is refused', m = 'Invalid face data', m);
  perform public.t_anon();
  begin perform public.enrollment_submit('tok-b', d, 'bbbbbbbb-0000-0000-0000-000000000002/enrollment/tok-b.jpg'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('submit without an uploaded photo is refused', m = 'Photo was not uploaded', m);
  perform public.t_anon();
  begin perform public.enrollment_submit('tok-used', d, A || '/enrollment/tok-used.jpg'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('submit on a used link is refused', m = 'Link has already been used', m);
  perform public.t_anon();
  begin perform public.enrollment_submit('tok-exp', d, A || '/enrollment/tok-exp.jpg'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('submit on an expired link is refused', m = 'Link has expired', m);
  perform public.t_anon();
  r := public.enrollment_submit('tok-a', d, A || '/enrollment/tok-a.jpg');
  perform public.t_log('a valid submit works', (r ->> 'success')::boolean, r::text);
  perform public.t_anon();
  begin perform public.enrollment_submit('tok-a', d, A || '/enrollment/tok-a.jpg'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('the same link cannot be used twice', m = 'Link has already been used', m);
  reset role;
  perform public.t_log('the enrollment waits for approval, photo path stored', (select status || '|' || photo_url from enrollment_links where token = 'tok-a') = 'submitted|' || A || '/enrollment/tok-a.jpg', '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('staff of A can see the submitted photo', public.t_count($q$select 1 from storage.objects where name like '%/enrollment/tok-a.jpg'$q$) = 1, '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  perform public.t_log('staff of A can delete the enrollment photo (approval)', public.t_rows_changed($q$delete from storage.objects where name like '%/enrollment/tok-a.jpg'$q$) = 1, '');
  reset role;
end $$;

-- a terminal records a punch with a photo
do $$ declare m text; r jsonb; A text := 'aaaaaaaa-0000-0000-0000-000000000001'; begin
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  r := public.terminal_record_punch(jsonb_build_object('labor_id', 'LA1', 'type', 'login', 'date', current_date::text, 'time', '10:00:00', 'photo_url', A || '/punches/LA1_5.jpg'));
  perform public.t_log('a punch with a photo path inside the company folder is accepted', (r ->> 'success')::boolean, r::text);
  perform public.t_login('72222222-0000-0000-0000-000000000012');
  begin perform public.terminal_record_punch(jsonb_build_object('labor_id', 'LA1', 'type', 'logout', 'date', current_date::text, 'time', '11:00:00', 'photo_url', 'bbbbbbbb-0000-0000-0000-000000000002/punches/steal.jpg')); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a punch pointing at ANOTHER company photo is refused', m = 'invalid photo path', m);
  reset role;
end $$;
