-- ============================================================
-- Migration 008: monthly attendance on the punch terminal (ROADMAP "labor monthly attendance")
-- ============================================================
-- terminal_month_attendance(labor, any date in the month): one row per day that has attendance, plus holidays and month totals.
-- Only the CURRENT and the PREVIOUS month can be read. No salary, ID number or overtime amount is returned.
-- The terminal already identifies the labor by face before it asks (same as "today's punches").
-- Safe to run again.
-- ============================================================

create or replace function public.terminal_month_attendance(p_labor_id text, p_month date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    v_client uuid := public.require_terminal();
    v_start date;
    v_ref date := current_date + 1;      -- the terminal's clock may be ahead of the server's (Saudi time is UTC+3)
    v_days jsonb;
    v_hol jsonb;
begin
    if p_month is null then raise exception 'invalid month' using errcode = 'P0001'; end if;
    v_start := date_trunc('month', p_month)::date;
    if v_start > date_trunc('month', v_ref)::date or v_start < (date_trunc('month', v_ref) - interval '1 month')::date then
        raise exception 'month not available' using errcode = 'P0001';
    end if;
    if not exists (select 1 from laborers where client_id = v_client and labor_id = p_labor_id and status = 'active') then
        raise exception 'unknown or inactive labor' using errcode = 'P0001';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object('date', d.date, 'status', coalesce(d.final_status, d.auto_status), 'first_in', d.first_login,
                                                 'last_out', d.last_logout, 'hours', coalesce(d.total_hours, 0)) order by d.date), '[]'::jsonb)
      into v_days
      from daily_attendance d
     where d.client_id = v_client and d.labor_id = p_labor_id and d.date >= v_start and d.date < (v_start + interval '1 month')::date;

    select coalesce(jsonb_agg(jsonb_build_object('date', h.date, 'name', h.name) order by h.date), '[]'::jsonb)
      into v_hol
      from holidays h
     where h.client_id = v_client and coalesce(h.is_active, true) and h.date >= v_start and h.date < (v_start + interval '1 month')::date;

    return jsonb_build_object(
        'month', v_start,
        'days', v_days,
        'holidays', v_hol,
        'present', (select count(*) from jsonb_array_elements(v_days) e where e ->> 'status' = 'P'),
        'half', (select count(*) from jsonb_array_elements(v_days) e where e ->> 'status' = 'H'),
        'absent', (select count(*) from jsonb_array_elements(v_days) e where e ->> 'status' = 'A'),
        'hours', (select coalesce(sum((e ->> 'hours')::numeric), 0) from jsonb_array_elements(v_days) e)
    );
end;
$$;
revoke all on function public.terminal_month_attendance(text, date) from public, anon;
grant execute on function public.terminal_month_attendance(text, date) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  008  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================
