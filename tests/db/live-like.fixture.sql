-- Imitates the LIVE project before the cutover: our app's data, another app's tables, the old "Allow all" rules, old storage rules.
insert into public.clients (id, business_name, client_code) values ('00000000-0000-0000-0000-0000000000a1','Arwa Enterprises','AE1'),
  ('00000000-0000-0000-0000-0000000000a2','Hadir','AE2'),('00000000-0000-0000-0000-0000000000a3','Third','AE3');
insert into public.departments (id, name, code, client_id) values
  ('00000000-0000-0000-0000-00000000d001','Ops','OPS','00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000d002','Ops2','OP2','00000000-0000-0000-0000-0000000000a2');
insert into public.punch_locations (id, name, department_id, latitude, longitude, client_id) values
  ('00000000-0000-0000-0000-00000000f001','Kaden Warehouse','00000000-0000-0000-0000-00000000d001',1,1,'00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000f002','Sulay','00000000-0000-0000-0000-00000000d001',1,1,'00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000f003','Murabba Site','00000000-0000-0000-0000-00000000d001',1,1,'00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000f004','Home','00000000-0000-0000-0000-00000000d001',1,1,'00000000-0000-0000-0000-0000000000a1');
insert into public.punch_records (labor_id, department_id, date, time, type, location_id, client_id) values ('L1','00000000-0000-0000-0000-00000000d001', current_date, '08:00', 'IN', '00000000-0000-0000-0000-00000000f004', '00000000-0000-0000-0000-0000000000a1');
insert into public.users (client_id, username, password_hash, name, role, status) values ('00000000-0000-0000-0000-0000000000a2','hadir@x.com','x','Hadir','admin','active');
create table public.medicines (id serial primary key, name text);
create table public.exp_expenses (id serial primary key, amount numeric);
insert into public.medicines (name) values ('x'), ('y');
insert into public.exp_expenses (amount) values (10);
grant all on public.medicines, public.exp_expenses to anon, authenticated;
alter table public.medicines enable row level security;
create policy "Allow all medicines" on public.medicines for all to anon using (true) with check (true);
do $$ begin
  insert into public.users (client_id, username, password_hash, name, role, status) values
    ('00000000-0000-0000-0000-0000000000a1', 'sup1', 'x', 'Sup One', 'supervisor', 'active');
exception when others then raise notice 'fixture users insert: %', sqlerrm; end $$;
