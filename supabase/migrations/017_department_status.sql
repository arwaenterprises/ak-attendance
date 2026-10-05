-- ============================================================
-- Migration 017: department Active / Inactive that really means something; moving labors between departments (owner decisions, 2026-10-05)
-- ============================================================
-- * deactivate_department(): administrator only. Makes the department inactive AND every active labor in it inactive, with the
--   labor's last working day = the chosen date (the day the department is switched off). Inactive labors cannot punch (the terminal only
--   knows active, enrolled labors) and the reports stop showing them after that day.
--   The page asks the administrator twice before it calls this.
-- * move_labors_to_department(): administrator only. Moves labors to another ACTIVE department of the same company.
--   (Past attendance and punches stay as they are; reports follow the labor, not the department the day was recorded under.)
-- * a guard on laborers: an ACTIVE labor cannot be put into an inactive department (insert, move, or switching the labor on).
--   Labors that already sit active in an inactive department keep working until someone moves them; editing one of them then asks for a move.
-- * reactivating a department does NOT reactivate its labors (switch them on one by one, or move labors back).
-- Safe to run again.
-- ============================================================

-- 1. guard
create or replace function public.laborers_department_guard()
returns trigger language plpgsql as $$
begin
    if new.status = 'active' and exists (select 1 from public.departments d where d.id = new.department_id and d.status = 'inactive') then
        raise exception 'This department is inactive. Move the labor to an active department first.' using errcode = 'P0001';
    end if;
    return new;
end;
$$;
drop trigger if exists laborers_department_guard on public.laborers;
create trigger laborers_department_guard before insert or update of department_id, status on public.laborers
    for each row execute function public.laborers_department_guard();

-- 2. switch a department off, with its labors
create or replace function public.deactivate_department(p_dept uuid, p_date date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_client uuid := public.current_client_id();
    v_date date := coalesce(p_date, current_date);
    v_n int;
begin
    if v_client is null or public.current_user_role() not in ('admin', 'super_admin') then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    -- the administrator's own date may be a day away from the database date (time zones)
    if v_date < current_date - 2 or v_date > current_date + 2 then raise exception 'date out of range' using errcode = 'P0001'; end if;
    if not exists (select 1 from departments where id = p_dept and client_id = v_client and status = 'active') then
        raise exception 'department not found or already inactive' using errcode = 'P0001';
    end if;

    update laborers set status = 'inactive', last_working_date = v_date
     where client_id = v_client and department_id = p_dept and status = 'active';
    get diagnostics v_n = row_count;
    update departments set status = 'inactive' where id = p_dept and client_id = v_client;

    return jsonb_build_object('labors_deactivated', v_n, 'last_working_date', v_date);
end;
$$;
revoke all on function public.deactivate_department(uuid, date) from public, anon;
grant execute on function public.deactivate_department(uuid, date) to authenticated;

-- 3. move labors to another department
create or replace function public.move_labors_to_department(p_labor_ids text[], p_dept uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_client uuid := public.current_client_id();
    v_found int;
    v_n int;
begin
    if v_client is null or public.current_user_role() not in ('admin', 'super_admin') then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    if p_labor_ids is null or coalesce(array_length(p_labor_ids, 1), 0) = 0 then raise exception 'no labors chosen' using errcode = 'P0001'; end if;
    if array_length(p_labor_ids, 1) > 1000 then raise exception 'too many labors at once' using errcode = 'P0001'; end if;
    if not exists (select 1 from departments where id = p_dept and client_id = v_client and status = 'active') then
        raise exception 'unknown or inactive department' using errcode = 'P0001';
    end if;
    select count(*) into v_found from laborers where client_id = v_client and labor_id = any (p_labor_ids);
    if v_found <> (select count(distinct x) from unnest(p_labor_ids) x) then raise exception 'unknown labor in the list' using errcode = 'P0001'; end if;

    update laborers set department_id = p_dept
     where client_id = v_client and labor_id = any (p_labor_ids) and department_id is distinct from p_dept;
    get diagnostics v_n = row_count;
    return jsonb_build_object('moved', v_n);
end;
$$;
revoke all on function public.move_labors_to_department(text[], uuid) from public, anon;
grant execute on function public.move_labors_to_department(text[], uuid) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-05  017  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 017 applied' as result,
       (select count(*) from public.departments where status = 'inactive') as inactive_departments,
       (select count(*) from public.laborers l join public.departments d on d.id = l.department_id
         where l.status = 'active' and d.status = 'inactive') as active_labors_in_inactive_departments;
