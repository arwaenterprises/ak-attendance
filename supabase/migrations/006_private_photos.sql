-- ============================================================
-- Migration 006: private punch photos + safe self-enrollment (ROADMAP S4; findings 33, 45)
-- ============================================================
-- Run AFTER 001-005. Tested on local Postgres (tests/db); the storage rules are also tested on the real staging project (tests/photos.test.js).
-- NOT yet applied to any Supabase project.
--
-- Before: the photo bucket was PUBLIC: anyone with a photo link could open it; (staging) anyone with the public key could upload or delete.
-- After:
--   * the bucket is private (+ 5 MB, JPEG only); photos are shown through short-lived signed links
--   * photo files live in a folder per company:   <company id>/punches/...   and   <company id>/enrollment/...
--   * staff (admin/supervisor) and the company's terminal can read their OWN company's photos; staff can delete them
--   * a terminal can add photos only to its own company's  punches  folder
--   * a labor with a valid, unused, unexpired enrollment link can add exactly ONE photo: <company id>/enrollment/<token>.jpg
--   * the self-enrollment page no longer reads or writes tables: it uses enrollment_get / enrollment_submit
-- Photos taken before this change (old paths without a company folder) stay readable by the company that owns them, found through the
-- punch / enrollment record that points at the file. The 15-day photo cleanup removes them; then this lookup is no longer needed.
-- ============================================================

-- 1. who owns a photo file?
create or replace function public.photo_client(p_name text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
    v_first text := (storage.foldername(p_name))[1];
    v uuid;
begin
    if v_first ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
        return v_first::uuid;
    end if;
    -- old path without a company folder: owned by the company whose record points at the file
    select client_id into v from punch_records where photo_url is not null and right(photo_url, length(p_name)) = p_name limit 1;
    if v is null then
        select client_id into v from enrollment_links where photo_url is not null and right(photo_url, length(p_name)) = p_name limit 1;
    end if;
    return v;
end;
$$;

-- 2. may this exact file be uploaded by someone holding an enrollment link?  path = <company id>/enrollment/<token>.jpg
create or replace function public.enrollment_upload_allowed(p_name text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
    f text[] := storage.foldername(p_name);
    v_token text;
begin
    if array_length(f, 1) is distinct from 2 or f[2] <> 'enrollment' then return false; end if;
    if right(p_name, 4) <> '.jpg' then return false; end if;
    v_token := substr(storage.filename(p_name), 1, length(storage.filename(p_name)) - 4);
    return exists (select 1 from enrollment_links l
                   where l.token = v_token and l.client_id::text = f[1] and l.status = 'pending' and l.expires_at > now());
end;
$$;
revoke all on function public.photo_client(text), public.enrollment_upload_allowed(text) from public;
grant execute on function public.photo_client(text) to authenticated;
grant execute on function public.enrollment_upload_allowed(text) to anon, authenticated;

-- 3. the bucket: private, JPEG only, 5 MB
update storage.buckets set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg'] where id = 'punch-photos';

-- 4. storage rules
drop policy if exists "terminal adds punch photos" on storage.objects;
drop policy if exists "tmp punch-photos select" on storage.objects;
drop policy if exists "tmp punch-photos insert" on storage.objects;
drop policy if exists "tmp punch-photos delete" on storage.objects;
drop policy if exists "own company reads photos" on storage.objects;
drop policy if exists "staff delete own company photos" on storage.objects;
drop policy if exists "terminal adds own company photos" on storage.objects;
drop policy if exists "enrollment link adds its photo" on storage.objects;
drop policy if exists "enrollment link retakes its photo" on storage.objects;

create policy "own company reads photos" on storage.objects for select to authenticated
    using (bucket_id = 'punch-photos'
           and public.current_user_role() in ('admin', 'supervisor', 'super_admin', 'terminal')
           and public.photo_client(name) = public.current_client_id());
create policy "staff delete own company photos" on storage.objects for delete to authenticated
    using (bucket_id = 'punch-photos' and public.is_staff() and public.photo_client(name) = public.current_client_id());
create policy "terminal adds own company photos" on storage.objects for insert to authenticated
    with check (bucket_id = 'punch-photos' and public.current_user_role() = 'terminal'
                and (storage.foldername(name))[1] = public.current_client_id()::text and (storage.foldername(name))[2] = 'punches');
create policy "enrollment link adds its photo" on storage.objects for insert to anon
    with check (bucket_id = 'punch-photos' and public.enrollment_upload_allowed(name));
create policy "enrollment link retakes its photo" on storage.objects for update to anon
    using (bucket_id = 'punch-photos' and public.enrollment_upload_allowed(name))
    with check (bucket_id = 'punch-photos' and public.enrollment_upload_allowed(name));

-- 5. self-enrollment without table access
create or replace function public.enrollment_get(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l record;
begin
    select * into l from enrollment_links where token = p_token;
    if not found then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
    if l.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', l.status); end if;     -- submitted / approved / expired / rejected
    if l.expires_at < now() then return jsonb_build_object('ok', false, 'reason', 'expired'); end if;
    return jsonb_build_object('ok', true, 'id', l.id, 'labor_id', l.labor_id, 'client_id', l.client_id, 'expires_at', l.expires_at,
        'labor_name', coalesce(l.labor_name, (select name from laborers where labor_id = l.labor_id and client_id = l.client_id), l.labor_id));
end;
$$;

create or replace function public.enrollment_submit(p_token text, p_descriptor text, p_photo_path text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    l record;
    d jsonb;
begin
    select * into l from enrollment_links where token = p_token for update;
    if not found then raise exception 'Invalid link' using errcode = 'P0001'; end if;
    if l.status <> 'pending' then raise exception 'Link has already been used' using errcode = 'P0001'; end if;
    if l.expires_at < now() then raise exception 'Link has expired' using errcode = 'P0001'; end if;
    if p_photo_path is distinct from (l.client_id::text || '/enrollment/' || p_token || '.jpg') then raise exception 'Invalid photo' using errcode = 'P0001'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'punch-photos' and name = p_photo_path) then raise exception 'Photo was not uploaded' using errcode = 'P0001'; end if;
    begin d := p_descriptor::jsonb; exception when others then raise exception 'Invalid face data' using errcode = 'P0001'; end;
    if jsonb_typeof(d) <> 'array' or jsonb_array_length(d) not between 64 and 512 or length(p_descriptor) > 20000 then raise exception 'Invalid face data' using errcode = 'P0001'; end if;
    update enrollment_links set photo_url = p_photo_path, face_descriptor = p_descriptor, status = 'submitted', submitted_at = now() where id = l.id;
    return jsonb_build_object('success', true);
end;
$$;
revoke all on function public.enrollment_get(text), public.enrollment_submit(text, text, text) from public;
grant execute on function public.enrollment_get(text), public.enrollment_submit(text, text, text) to anon, authenticated;

-- 6. a terminal may only point a punch at a photo inside its own company folder (or keep an old-style link)
create or replace function public.terminal_record_punch(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_client uuid := public.require_terminal();
    v_labor_id text := p ->> 'labor_id';
    v_labor record;
    v_date date;
    v_time time;
    v_type text := p ->> 'type';
    v_night_start int := 20 * 60;
    v_night_end int := 6 * 60 + 30;
    v_val text;
    v_mins int;
    v_prev date;
    v_final_date date;
    v_is_night_end boolean := false;
    v_location uuid := null;
    v_conf int := null;
    v_photo text := nullif(p ->> 'photo_url', '');
    v_id uuid;
    v_existing uuid;
begin
    select * into v_labor from laborers where client_id = v_client and labor_id = v_labor_id and status = 'active';
    if not found then raise exception 'unknown or inactive labor' using errcode = 'P0001'; end if;
    if v_type is null or v_type not in ('login', 'logout') then raise exception 'invalid punch type' using errcode = 'P0001'; end if;
    begin
        v_date := (p ->> 'date')::date;
        v_time := (p ->> 'time')::time;
    exception when others then raise exception 'invalid date or time' using errcode = 'P0001'; end;
    if v_date is null or v_time is null or v_date < current_date - 31 or v_date > current_date + 1 then
        raise exception 'date out of range' using errcode = 'P0001';
    end if;
    if p ->> 'location_id' is not null then
        select id into v_location from punch_locations where id = (p ->> 'location_id')::uuid and client_id = v_client;
    end if;
    if p ->> 'confidence' is not null then v_conf := greatest(0, least(100, (p ->> 'confidence')::int)); end if;
    if v_photo is not null then
        if length(v_photo) > 500 then raise exception 'photo link too long' using errcode = 'P0001'; end if;
        -- a photo path must be inside this company's punches folder (a full web address from an old terminal is kept as it is)
        if v_photo !~ '^https?://' and (storage.foldername(v_photo))[1] is distinct from v_client::text then
            raise exception 'invalid photo path' using errcode = 'P0001';
        end if;
    end if;

    select value into v_val from settings where client_id = v_client and key = 'night_shift_start';
    if v_val ~ '^\d{1,2}:\d{2}' then v_night_start := split_part(v_val, ':', 1)::int * 60 + split_part(v_val, ':', 2)::int; end if;
    select value into v_val from settings where client_id = v_client and key = 'night_shift_end';
    if v_val ~ '^\d{1,2}:\d{2}' then v_night_end := split_part(v_val, ':', 1)::int * 60 + split_part(v_val, ':', 2)::int; end if;

    v_final_date := v_date;
    v_mins := extract(hour from v_time)::int * 60 + extract(minute from v_time)::int;
    if v_mins <= v_night_end then
        v_prev := v_date - 1;
        if exists (select 1 from punch_records where client_id = v_client and labor_id = v_labor_id and date = v_prev
                   and extract(hour from time)::int * 60 + extract(minute from time)::int >= v_night_start) then
            v_final_date := v_prev; v_is_night_end := true;
        end if;
    end if;

    select id into v_existing from punch_records where client_id = v_client and labor_id = v_labor_id and date = v_final_date and time = v_time limit 1;
    if v_existing is not null then
        return jsonb_build_object('success', true, 'duplicate', true, 'id', v_existing, 'date', v_final_date);
    end if;

    insert into punch_records (labor_id, department_id, date, time, type, location_id, location_name, confidence, photo_url, client_id, is_night_shift_end)
    values (v_labor_id, v_labor.department_id, v_final_date, v_time, v_type, v_location, left(p ->> 'location_name', 200), v_conf, v_photo, v_client, v_is_night_end)
    returning id into v_id;

    update laborers set last_sync_at = now() where id = v_labor.id;
    perform public._recalc_attendance(v_client, v_labor_id, v_final_date);
    return jsonb_build_object('success', true, 'duplicate', false, 'id', v_id, 'date', v_final_date, 'is_night_shift_end', v_is_night_end);
end;
$$;
revoke all on function public.terminal_record_punch(jsonb) from public, anon;
grant execute on function public.terminal_record_punch(jsonb) to authenticated;

-- ============================================================
-- Changelog
-- 2026-10-02  006  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================
