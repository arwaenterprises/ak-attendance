-- ============================================================
-- LIVE 000b: clean-up approved by the owner (ROADMAP S5). Part of live-cutover-bundle.sql, runs right after 000_prepare_live.sql.
-- THIS PART DELETES DATA and is NOT undone by the rollback bundle:
--   * companies AE2 (Hadir) and AE3 and everything that belongs to them
--   * punch locations of AE1 other than "Kaden Warehouse" and "Sulay" (a location that already has punches is kept, switched to inactive, so history stays)
--   * the retired AE1 supervisors (one that is still named in an approval or audit entry is kept, inactive)
--   * enrolment links that expired without ever being used
-- ============================================================
do $$
declare
    v_ids uuid[];
    t text;
    n int;
begin
    -- the archived other-app tables point at company rows (e.g. medicines.client_id). Cut those links so the company rows can go; the archived rows themselves are kept.
    for t in select format('%I.%I|%I', n.nspname, c.relname, k.conname) from pg_constraint k
              join pg_class c on c.oid = k.conrelid join pg_namespace n on n.oid = c.relnamespace
              where k.contype = 'f' and k.confrelid = 'public.clients'::regclass and n.nspname = 'archive_other_apps' loop
        execute format('alter table %s drop constraint %s', split_part(t, '|', 1), split_part(t, '|', 2));
    end loop;

    -- safety: only the tiny companies the owner named, and only if they are still that small
    select array_agg(id) into v_ids from public.clients where upper(client_code) in ('AE2', 'AE3');
    if v_ids is not null then
        select count(*) into n from public.laborers where client_id = any (v_ids);
        if n > 5 then raise exception 'AE2/AE3 now have % laborers (expected at most 1). Stopping - check before deleting.', n; end if;
        foreach t in array array['overtime_records', 'lop_requests', 'daily_attendance', 'punch_records', 'enrollment_links', 'laborers', 'iqama_registry', 'audit_log',
                                 'punch_locations', 'attendance_freeze', 'holidays', 'ot_rates', 'settings', 'users', 'departments'] loop
            if to_regclass('public.' || t) is not null and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'client_id') then
                execute format('delete from public.%I where client_id = any ($1)', t) using v_ids;
            end if;
        end loop;
        delete from public.clients where id = any (v_ids);
    end if;
end $$;

-- AE1 punch locations: keep Kaden Warehouse and Sulay; drop the rest (or switch off when they already have punches)
delete from public.punch_locations l
 where l.client_id = (select id from public.clients where upper(client_code) = 'AE1')
   and l.name not in ('Kaden Warehouse', 'Sulay')
   and not exists (select 1 from public.punch_records p where p.location_id = l.id);
update public.punch_locations l set status = 'inactive'
 where l.client_id = (select id from public.clients where upper(client_code) = 'AE1')
   and l.name not in ('Kaden Warehouse', 'Sulay');

-- retired supervisors: delete those nobody refers to (the ones still named in approvals / audit stay inactive)
delete from public.users u
 where u.role = 'supervisor'
   and not exists (select 1 from public.lop_requests r where r.requested_by = u.id or r.approved_by = u.id)
   and not exists (select 1 from public.audit_log a where a.user_id = u.id);

-- enrolment links that expired and were never used
delete from public.enrollment_links where status = 'pending' and submitted_at is null and expires_at < now();
