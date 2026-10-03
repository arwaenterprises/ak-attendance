-- Tests for migration 015: small photo + automatic face refresh (labors LE2 / LE3 of the 011 tests; company 3333..., terminal 7111...).
do $$ declare r jsonb; d jsonb; thumb text := 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ=='; begin
  select jsonb_agg(0.5) into d from generate_series(1, 128);
  perform public.t_login('71111111-0000-0000-0000-000000000011');

  r := public.terminal_refresh_face('LE2', 'thumb', thumb, null, 80);
  perform public.t_log('thumb mode stores the first small photo', (r ->> 'updated')::boolean, r::text);
  r := public.terminal_refresh_face('LE2', 'thumb', 'data:image/jpeg;base64,AAAA', null, 80);
  perform public.t_log('thumb mode never replaces an existing photo', not (r ->> 'updated')::boolean, r::text);

  r := public.terminal_refresh_face('LE3', 'face', thumb, d, 60);
  perform public.t_log('a face weaker than the company threshold (70) cannot replace the saved face', not (r ->> 'updated')::boolean and r ->> 'reason' = 'confidence too low', r::text);
  begin
    perform public.terminal_refresh_face('LE3', 'face', thumb, '[0.1,0.2]'::jsonb, 80);
    perform public.t_log('face data of the wrong size is refused', false, '');
  exception when others then perform public.t_log('face data of the wrong size is refused', sqlerrm = 'bad face data', sqlerrm); end;
  begin
    perform public.terminal_refresh_face('LE3', 'thumb', 'http://evil/x.jpg', null, 80);
    perform public.t_log('a photo that is not a small JPEG data link is refused', false, '');
  exception when others then perform public.t_log('a photo that is not a small JPEG data link is refused', sqlerrm = 'bad photo', sqlerrm); end;
  begin
    perform public.terminal_refresh_face('NOPE', 'thumb', thumb, null, 80);
    perform public.t_log('an unknown labor is refused', false, '');
  exception when others then perform public.t_log('an unknown labor is refused', sqlerrm = 'unknown or inactive labor', sqlerrm); end;

  reset role;
  update laborers set needs_reenrollment = true, low_confidence_count = 3 where labor_id = 'LE3';
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_refresh_face('LE3', 'face', thumb, d, 78);
  perform public.t_log('a weaker but accepted match refreshes the saved face', (r ->> 'updated')::boolean, r::text);
  reset role;
  perform public.t_log('the new face, photo and date are stored; re-enrol flag and counter cleared',
    (select jsonb_array_length(face_descriptor) = 128 and face_thumb = thumb and face_refreshed_at is not null and not needs_reenrollment and low_confidence_count = 0 from laborers where labor_id = 'LE3'), '');
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.terminal_refresh_face('LE3', 'face', thumb, d, 90);
  perform public.t_log('a second refresh on the same day is skipped', not (r ->> 'updated')::boolean and r ->> 'reason' = 'refreshed today', r::text);
  reset role;

  -- an admin of ANOTHER company / an anonymous caller cannot use it
  perform public.t_log('anonymous callers have no access', not has_function_privilege('anon', 'public.terminal_refresh_face(text,text,text,jsonb,int)', 'execute'), '');
end $$;
