-- Imitates the LIVE project before the cutover: our app's data, another app's tables, the old "Allow all" rules, old storage rules.
insert into public.clients (id, business_name) values ('00000000-0000-0000-0000-0000000000a1','Arwa Enterprises') on conflict do nothing;
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
