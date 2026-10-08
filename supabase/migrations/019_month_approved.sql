-- ============================================================
-- Migration 019: the labor's month screen can tell an APPROVED day from a day that was worked (owner report, 2026-10-08)
-- ============================================================
-- A day is green (P) when its final status is Present. That happens in two ways:
--   * the labor worked at least the department's full-day hours (automatic), or
--   * the administrator pressed Approve on the daily report (this works even for a day without any punch).
-- The month screen used to show both the same way ("green, but no punches"). terminal_month_attendance now also says
-- whether the day was approved by the administrator ('approved': true), so the screen can mark it.
-- Nothing else changes (same rules, same months, no salary / ID / overtime amount). Safe to run again.
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
                                                 'last_out', d.last_logout, 'hours', coalesce(d.total_hours, 0),
                                                 'approved', (d.approved_by is not null and btrim(d.approved_by) <> '')) order by d.date), '[]'::jsonb)
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
-- 2026-10-08  019  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 019 applied' as result;
