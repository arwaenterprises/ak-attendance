-- Tests for migration 017: deactivating a department takes its labors with it; moving labors; the inactive-department guard.
-- Company A (admin a1111111-...), company B (admin b2222222-...). Test departments and labors are created here as the table owner.
insert into departments (id, name, code, client_id) values
  ('de000000-0000-0000-0000-0000000000a1', 'Dept One', 'DPO1', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('de000000-0000-0000-0000-0000000000a2', 'Dept Two', 'DPT2', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('de000000-0000-0000-0000-0000000000b1', 'Dept B', 'DPB1', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into iqama_registry (iqama_number, labor_id, client_id) values
  ('5700000001', 'LDP1', 'aaaaaaaa-0000-0000-0000-000000000001'), ('5700000002', 'LDP2', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('5700000003', 'LDP3', 'aaaaaaaa-0000-0000-0000-000000000001'), ('5700000004', 'LDB1', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id, status) values
  ('LDP1', '5700000001', 'Dept Labor 1', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 'active'),
  ('LDP2', '5700000002', 'Dept Labor 2', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 'active'),
  ('LDP3', '5700000003', 'Dept Labor 3 (already inactive)', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 'inactive'),
  ('LDB1', '5700000004', 'Dept Labor B', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000002', 'active');
update laborers set last_working_date = '2026-01-15' where labor_id = 'LDP3';

-- moving labors
do $$ declare r jsonb; m text; begin
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  r := public.move_labors_to_department(array['LDP2'], 'de000000-0000-0000-0000-0000000000a2');
  perform public.t_log('admin A moves a labor to another department of his company', (r ->> 'moved')::int = 1 and (select department_id from public.laborers where labor_id = 'LDP2') = 'de000000-0000-0000-0000-0000000000a2', r::text);
  begin perform public.move_labors_to_department(array['LDP1'], 'de000000-0000-0000-0000-0000000000b1'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('admin A cannot move a labor into a department of company B', m = 'unknown or inactive department', m);
  begin perform public.move_labors_to_department(array['LDB1'], 'de000000-0000-0000-0000-0000000000a1'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('admin A cannot move a labor of company B', m = 'unknown labor in the list', m);
  begin perform public.move_labors_to_department(array[]::text[], 'de000000-0000-0000-0000-0000000000a1'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an empty list is refused', m = 'no labors chosen', m);
  reset role;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.move_labors_to_department(array['LDP1'], 'de000000-0000-0000-0000-0000000000a1'); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('the terminal cannot move labors', m = '42501', m);
  reset role;
  perform public.t_anon();
  begin perform public.move_labors_to_department(array['LDP1'], 'de000000-0000-0000-0000-0000000000a1'); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('the public key cannot move labors', m = '42501', m);
  reset role;
end $$;

-- deactivating a department
do $$ declare r jsonb; m text; n int; begin
  perform public.t_login('b2222222-0000-0000-0000-000000000002');
  begin perform public.deactivate_department('de000000-0000-0000-0000-0000000000a1', current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('admin B cannot deactivate a department of company A', m = 'department not found or already inactive', m);
  reset role;
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  begin perform public.deactivate_department('de000000-0000-0000-0000-0000000000a1', current_date + 10); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a date far from today is refused', m = 'date out of range', m);
  r := public.deactivate_department('de000000-0000-0000-0000-0000000000a1', current_date);
  perform public.t_log('admin A deactivates Dept One: the one active labor is switched off with it', (r ->> 'labors_deactivated')::int = 1, r::text);
  reset role;
  perform public.t_log('the department is inactive', (select status from departments where code = 'DPO1' and client_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 'inactive', '');
  perform public.t_log('LDP1 is inactive and its last working day is the day of the deactivation', (select status = 'inactive' and last_working_date = current_date from laborers where labor_id = 'LDP1'), '');
  perform public.t_log('a labor that was already inactive keeps its own last working day', (select last_working_date = date '2026-01-15' from laborers where labor_id = 'LDP3'), '');
  perform public.t_log('a labor moved earlier to Dept Two is untouched', (select status = 'active' and last_working_date is null from laborers where labor_id = 'LDP2'), '');
  perform public.t_log('company B is untouched', (select status = 'active' from laborers where labor_id = 'LDB1') and (select status = 'active' from departments where code = 'DPB1'), '');
  perform public.t_login('a1111111-0000-0000-0000-000000000001');
  begin perform public.deactivate_department('de000000-0000-0000-0000-0000000000a1', current_date); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('deactivating an inactive department again is refused', m = 'department not found or already inactive', m);
  reset role;
  perform public.t_login('71111111-0000-0000-0000-000000000011');
  begin perform public.deactivate_department('de000000-0000-0000-0000-0000000000a2', current_date); m := 'allowed'; exception when others then m := sqlstate; end;
  perform public.t_log('the terminal cannot deactivate a department', m = '42501', m);
  reset role;
end $$;

-- the guard
do $$ declare m text; begin
  begin update laborers set status = 'active' where labor_id = 'LDP1'; m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a labor cannot be switched on inside an inactive department', m like 'This department is inactive%', m);
  begin update laborers set department_id = 'de000000-0000-0000-0000-0000000000a1' where labor_id = 'LDP2'; m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('an active labor cannot be moved into an inactive department', m like 'This department is inactive%', m);
  begin insert into iqama_registry (iqama_number, labor_id, client_id) values ('5700000009', 'LDP9', 'aaaaaaaa-0000-0000-0000-000000000001');
        insert into laborers (labor_id, iqama_number, name, nationality, date_of_joining, department_id, client_id) values ('LDP9', '5700000009', 'New', 'X', '2020-01-01', 'de000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001'); m := 'allowed'; exception when others then m := sqlerrm; end;
  perform public.t_log('a new active labor cannot be added to an inactive department', m like 'This department is inactive%', m);
  begin update laborers set department_id = 'de000000-0000-0000-0000-0000000000a1' where labor_id = 'LDP3'; m := 'moved'; exception when others then m := sqlerrm; end;
  perform public.t_log('an INACTIVE labor can still be filed under an inactive department (history)', m = 'moved', m);
  update departments set status = 'active' where code = 'DPO1' and client_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  perform public.t_log('reactivating the department does not reactivate its labors', (select status = 'inactive' from laborers where labor_id = 'LDP1'), '');
  begin update laborers set status = 'active', last_working_date = null where labor_id = 'LDP1'; m := 'switched on'; exception when others then m := sqlerrm; end;
  perform public.t_log('after the department is active again a labor can be switched on', m = 'switched on', m);
end $$;
