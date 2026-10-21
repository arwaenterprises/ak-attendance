-- Tests for migration 024: the database checks the punch location itself (company TRI, terminal 71111111-..., department d7..07).
insert into punch_locations (id, name, department_id, latitude, longitude, radius, status, client_id) values
  ('e2400000-0000-0000-0000-000000000001', 'Gate GPS', 'd7000000-0000-0000-0000-000000000007', 24.700000, 46.700000, 100, 'active', '33333333-0000-0000-0000-000000000009');
insert into iqama_registry (iqama_number, labor_id, client_id)
select '62000000' || lpad(n::text, 2, '0'), 'GP' || n, '33333333-0000-0000-0000-000000000009' from generate_series(1, 10) n;
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, face_enrolled, face_descriptor)
select 'GP' || n, '62000000' || lpad(n::text, 2, '0'), 'Gps ' || n, 'X', '2020-01-01', 'd7000000-0000-0000-0000-000000000007', '33333333-0000-0000-0000-000000000009', true, '[0.1,0.2]'
  from generate_series(1, 10) n;

create or replace function public.t_gps_punch(p_labor text, p_gps jsonb) returns jsonb language plpgsql as $$
begin
  return public.terminal_record_punch(jsonb_build_object('labor_id', p_labor, 'type', 'login', 'date', current_date::text, 'time', '08:00:00',
    'location_id', 'e2400000-0000-0000-0000-000000000001', 'location_name', 'claimed by the phone', 'gps', p_gps));
end $$;

do $$ declare r jsonb; begin
  perform public.t_log('024: every existing company gets 3 changeover days', (select value from settings where client_id = '33333333-0000-0000-0000-000000000009' and key = 'gps_required_from') = (current_date + 3)::text, '');
  -- changeover: an old app (no readings) is still accepted
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_gps_punch('GP1', null);
  perform public.t_log('024 changeover: a punch from the old app (no GPS readings) is still accepted', (r ->> 'success')::boolean, r::text);
  reset role;
  update settings set value = (current_date - 1)::text where client_id = '33333333-0000-0000-0000-000000000009' and key = 'gps_required_from';

  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_gps_punch('GP2', null);
  perform public.t_log('024: after the changeover a punch without GPS readings is refused "Location not found"', r ->> 'code' = 'LOCATION_NOT_FOUND' and r ->> 'message' = 'Location not found', r::text);
  r := public.t_gps_punch('GP2', '[{"lat":24.7001,"lng":46.7001,"acc":0}]');
  perform public.t_log('024: a reading claiming 0 m accuracy (fake GPS) is refused "Location not found"', r ->> 'code' = 'LOCATION_NOT_FOUND', r::text);
  r := public.t_gps_punch('GP2', '[{"lat":24.7001,"lng":46.7001,"acc":8},{"lat":24.7001,"lng":46.7001,"acc":8},{"lat":24.7001,"lng":46.7001,"acc":8}]');
  perform public.t_log('024: three readings at exactly the same point with GPS accuracy are refused "Location not found"', r ->> 'code' = 'LOCATION_NOT_FOUND', r::text);
  r := public.t_gps_punch('GP2', '[{"lat":24.7001,"lng":46.7001,"acc":150},{"lat":24.70012,"lng":46.70011,"acc":160}]');
  perform public.t_log('024: a weak signal (best 150 m) is refused "Weak GPS signal"', r ->> 'code' = 'POOR_GPS', r::text);
  r := public.t_gps_punch('GP2', '[{"lat":24.7100,"lng":46.7001,"acc":10},{"lat":24.71002,"lng":46.70011,"acc":12}]');
  perform public.t_log('024: 1 km away is refused "outside the punch area" (the phone''s own claim is not believed)', r ->> 'code' = 'OUTSIDE_AREA', r::text);
  perform public.t_log('024: nothing refused was stored', not exists (select 1 from punch_records where labor_id = 'GP2'), '');

  r := public.t_gps_punch('GP3', '[{"lat":24.70031,"lng":46.70012,"acc":12},{"lat":24.70033,"lng":46.70010,"acc":9},{"lat":24.70030,"lng":46.70014,"acc":11}]');
  perform public.t_log('024: real-looking readings inside the area are accepted', (r ->> 'success')::boolean and r ->> 'location_name' = 'Gate GPS', r::text);
  r := public.t_gps_punch('GP4', '[{"lat":24.7002,"lng":46.7002,"acc":35},{"lat":24.7002,"lng":46.7002,"acc":35},{"lat":24.7002,"lng":46.7002,"acc":35}]');
  perform public.t_log('024: the same point three times with Wi-Fi accuracy (35 m, normal indoors) is accepted', (r ->> 'success')::boolean, r::text);
  reset role;
  perform public.t_log('024: the punch keeps the database''s location and the best reading', exists (select 1 from punch_records where labor_id = 'GP3'
     and location_id = 'e2400000-0000-0000-0000-000000000001' and location_name = 'Gate GPS' and latitude = 24.70033 and gps_accuracy = 9), '');

  insert into settings (client_id, key, value) values ('33333333-0000-0000-0000-000000000009', 'gps_static_check', 'false')
  on conflict (client_id, key) do update set value = excluded.value;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_gps_punch('GP5', '[{"lat":24.7001,"lng":46.7001,"acc":8},{"lat":24.7001,"lng":46.7001,"acc":8},{"lat":24.7001,"lng":46.7001,"acc":8}]');
  perform public.t_log('024: with gps_static_check = false the same point three times is accepted', (r ->> 'success')::boolean, r::text);
  reset role;
  insert into settings (client_id, key, value) values ('33333333-0000-0000-0000-000000000009', 'max_gps_accuracy', '200')
  on conflict (client_id, key) do update set value = excluded.value;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  r := public.t_gps_punch('GP6', '[{"lat":24.7001,"lng":46.7001,"acc":150},{"lat":24.70012,"lng":46.70011,"acc":160}]');
  perform public.t_log('024: max_gps_accuracy = 200 accepts a 150 m reading', (r ->> 'success')::boolean, r::text);
  reset role;
  delete from settings where client_id = '33333333-0000-0000-0000-000000000009' and key in ('gps_static_check', 'max_gps_accuracy');
end $$;
