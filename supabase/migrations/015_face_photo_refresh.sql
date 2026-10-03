-- ============================================================
-- Migration 015: small labor photo + automatic face refresh from the punch terminal
-- ============================================================
-- 1. laborers.face_thumb       a tiny passport-style photo (JPEG as text, about 2-4 KB) shown in Labor Master.
--                              It lives in the table, so it needs no storage space and is never touched by the 15-day photo clean-up.
-- 2. laborers.face_refreshed_at when the saved face was last refreshed by the terminal.
-- 3. terminal_refresh_face()   called by the punch terminal AFTER a punch was accepted:
--      mode 'thumb' - only the small photo, and only when the labor has none yet (fills the photos by itself over the first punches)
--      mode 'face'  - the face match was accepted but weaker than usual (aging, beard, lighting): the saved face and photo are replaced
--                     by the fresh ones, the "needs re-enrolment" flag and the low-confidence counter are cleared. At most once per day per labor,
--                     and only if the reported confidence is at least the company's "confidence_threshold" setting (so a face that was REFUSED
--                     can never overwrite the saved one).
-- Safe to run again.
-- ============================================================
alter table public.laborers add column if not exists face_thumb text;
alter table public.laborers add column if not exists face_refreshed_at timestamptz;

create or replace function public.terminal_refresh_face(p_labor_id text, p_mode text, p_thumb text, p_descriptor jsonb, p_confidence int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v uuid := public.require_terminal();
    v_labor record;
    v_min int;
begin
    if p_mode not in ('thumb', 'face') then raise exception 'bad mode' using errcode = 'P0001'; end if;
    if p_thumb is null or p_thumb !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$' or length(p_thumb) > 20000 then
        raise exception 'bad photo' using errcode = 'P0001';
    end if;
    select * into v_labor from laborers where client_id = v and labor_id = p_labor_id and status = 'active';
    if not found then raise exception 'unknown or inactive labor' using errcode = 'P0001'; end if;

    if p_mode = 'thumb' then
        if v_labor.face_thumb is not null then return jsonb_build_object('success', true, 'updated', false, 'reason', 'has photo'); end if;
        update laborers set face_thumb = p_thumb where id = v_labor.id;
        return jsonb_build_object('success', true, 'updated', true, 'mode', 'thumb');
    end if;

    -- mode 'face'
    if p_descriptor is null or jsonb_typeof(p_descriptor) <> 'array' or jsonb_array_length(p_descriptor) <> 128 then
        raise exception 'bad face data' using errcode = 'P0001';
    end if;
    select coalesce(nullif((select value from settings where client_id = v and key = 'confidence_threshold'), '')::int, 70) into v_min;
    if p_confidence is null or p_confidence < v_min then
        return jsonb_build_object('success', true, 'updated', false, 'reason', 'confidence too low');
    end if;
    if v_labor.face_refreshed_at is not null and v_labor.face_refreshed_at > now() - interval '1 day' then
        return jsonb_build_object('success', true, 'updated', false, 'reason', 'refreshed today');
    end if;
    update laborers set face_descriptor = p_descriptor, face_thumb = p_thumb, face_refreshed_at = now(),
                        needs_reenrollment = false, low_confidence_count = 0
     where id = v_labor.id;
    return jsonb_build_object('success', true, 'updated', true, 'mode', 'face');
end;
$$;

revoke all on function public.terminal_refresh_face(text, text, text, jsonb, int) from public, anon;
grant execute on function public.terminal_refresh_face(text, text, text, jsonb, int) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-03  015  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 015 applied' as result,
       (select count(*) from information_schema.columns where table_name = 'laborers' and column_name in ('face_thumb', 'face_refreshed_at')) as new_columns,
       (select count(*) from pg_proc where proname = 'terminal_refresh_face') as refresh_function;
