-- ============================================================
-- Dawam Attendance - Supabase schema (baseline v0)
-- ============================================================
-- Built from the export of the CURRENT live project (2026-10-02), attendance tables only.
-- The live project ALSO holds other apps' tables (pharmacy: medicines, stock, sales, suppliers,
-- payments, stock_invoices, stock_invoice_items, admin_users; expenses: exp_*). Those are NOT here.
--
-- This file is a faithful copy of today's structure, so the existing app works unchanged on a
-- new project. It is NOT the final design. Known problems are listed in ROADMAP.md (section C)
-- and will be fixed in later numbered files under supabase/migrations/ (not created yet).
--
-- Run order on a NEW project:  1) this file   2) supabase/policies-temporary-open.sql
-- Do not run on the live project.
--
-- Not included (data, not structure): rows in clients, users, settings, departments, laborers.
-- The app needs at least one clients row, one users row (role admin) and the settings keys.
--
-- Maintenance rule: every database change is added here (or as a migration) in the same commit
-- as the app change that needs it. Changelog at the bottom.
-- ============================================================

-- ---------- helper functions ----------
create or replace function public.update_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

-- ---------- tables ----------
create table public.clients (
    id                    uuid primary key default gen_random_uuid(),
    business_name         varchar not null,
    business_name_ar      varchar,
    owner_name            varchar,
    email                 varchar unique,
    phone                 varchar,
    logo_url              text,
    plan                  varchar default 'trial',
    trial_ends_at         timestamptz default (now() + interval '14 days'),
    subscription_ends_at  timestamptz,
    is_active             boolean default true,
    created_at            timestamptz default now(),
    updated_at            timestamptz default now(),
    client_code           varchar unique,
    subscribed_apps       text[] default '{}',
    subscription_status   varchar default 'trial',
    subscription_end_date date,
    contact_email         varchar,
    contact_phone         varchar,
    address               text,
    onboarded_at          timestamptz default now(),
    subscription_tier     varchar default 'basic',
    pharmacy_tier         varchar default 'basic'   -- belongs to the pharmacy app; kept for now (shared clients table)
);
create index idx_clients_client_code on public.clients (client_code);

create table public.departments (
    id                 uuid primary key default gen_random_uuid(),
    name               text not null,
    code               text not null unique,
    status             text default 'active' check (status = any (array['active','inactive'])),
    created_at         timestamptz default now(),
    updated_at         timestamptz default now(),
    client_id          uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id),
    min_hours_full_day time default '09:30:00'
);
create index idx_departments_client_id on public.departments (client_id);

create table public.users (
    id            uuid primary key default gen_random_uuid(),
    username      text not null unique,
    password_hash text not null,
    name          text not null,
    role          text not null check (role = any (array['super_admin','admin','supervisor'])),
    department_id uuid references public.departments(id) on delete set null,
    status        text default 'active' check (status = any (array['active','inactive'])),
    created_at    timestamptz default now(),
    updated_at    timestamptz default now(),
    client_id     uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id),
    permissions   jsonb default '{}'::jsonb
);
create index idx_users_client_id on public.users (client_id);

create table public.iqama_registry (
    iqama_number text primary key,
    labor_id     text not null unique,
    created_at   timestamptz default now(),
    client_id    uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id)
);

create table public.laborers (
    id                       uuid primary key default gen_random_uuid(),
    labor_id                 text not null unique,
    iqama_number             text not null unique references public.iqama_registry(iqama_number),
    name                     text not null,
    nationality              text not null,
    date_of_joining          date not null,
    department_id            uuid not null references public.departments(id) on delete restrict,
    status                   text default 'active' check (status = any (array['active','inactive'])),
    face_enrolled            boolean default false,
    face_descriptor          jsonb,
    enrollment_date          timestamptz,
    needs_reenrollment       boolean default false,
    low_confidence_count     integer default 0,
    last_low_confidence_date date,
    created_at               timestamptz default now(),
    updated_at               timestamptz default now(),
    fcm_token                text,
    last_sync_at             timestamp,
    client_id                uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id),
    last_working_date        date,
    role                     text default 'labor',
    monthly_salary           numeric default 3000,
    face_photo_url           text
);
create index idx_laborers_department on public.laborers (department_id);
create index idx_laborers_iqama      on public.laborers (iqama_number);
create index idx_laborers_labor_id   on public.laborers (labor_id);
create index idx_laborers_status     on public.laborers (status);
create index idx_laborers_client_id  on public.laborers (client_id);

create table public.punch_locations (
    id            uuid primary key default gen_random_uuid(),
    name          text not null,
    department_id uuid not null references public.departments(id) on delete restrict,
    latitude      numeric not null,
    longitude     numeric not null,
    radius        integer default 100,
    status        text default 'active' check (status = any (array['active','inactive'])),
    created_at    timestamptz default now(),
    updated_at    timestamptz default now(),
    client_id     uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id)
);
create index idx_punch_locations_department on public.punch_locations (department_id);
create index idx_punch_locations_client_id  on public.punch_locations (client_id);

create table public.punch_records (
    id                 uuid primary key default gen_random_uuid(),
    labor_id           text not null,
    department_id      uuid not null references public.departments(id),
    date               date not null,
    time               time not null,
    type               text not null,
    location_id        uuid references public.punch_locations(id),
    location_name      text,
    confidence         integer,
    photo_url          text,
    created_at         timestamptz default now(),
    client_id          uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id),
    is_night_shift_end boolean default false
);
create index idx_punch_records_labor      on public.punch_records (labor_id);
create index idx_punch_records_date       on public.punch_records (date);
create index idx_punch_records_department on public.punch_records (department_id);
create index idx_punch_records_labor_date on public.punch_records (labor_id, date);
create index idx_punch_records_client_id  on public.punch_records (client_id);

create table public.daily_attendance (
    id             uuid primary key default gen_random_uuid(),
    labor_id       text not null references public.laborers(labor_id),
    department_id  uuid not null references public.departments(id),
    date           date not null,
    first_login    time,
    last_logout    time,
    total_hours    numeric default 0,
    auto_status    text check (auto_status = any (array['P','H','A'])),
    final_status   text check (final_status = any (array['P','H','A'])),
    lop_request_id uuid,
    created_at     timestamptz default now(),
    updated_at     timestamptz default now(),
    client_id      uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id),
    approved_by    text,
    approved_at    timestamptz,
    lop_reason     text,
    unique (labor_id, date)
);
create index idx_daily_attendance_labor      on public.daily_attendance (labor_id);
create index idx_daily_attendance_date       on public.daily_attendance (date);
create index idx_daily_attendance_department on public.daily_attendance (department_id);
create index idx_daily_attendance_labor_date on public.daily_attendance (labor_id, date);
create index idx_daily_attendance_client_id  on public.daily_attendance (client_id);

create table public.lop_requests (
    id               uuid primary key default gen_random_uuid(),
    labor_id         text not null,
    department_id    uuid not null references public.departments(id),
    date             date not null,
    auto_status      text not null check (auto_status = any (array['H','A'])),
    requested_status text not null check (requested_status = any (array['P','H'])),
    remarks          text,
    requested_by     uuid references public.users(id),
    approved_by      uuid references public.users(id),
    approval_status  text default 'pending' check (approval_status = any (array['draft','pending','approved','rejected'])),
    rejection_reason text,
    approved_at      timestamptz,
    created_at       timestamptz default now(),
    updated_at       timestamptz default now(),
    client_id        uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id),
    unique (labor_id, date)
);
create index idx_lop_requests_labor      on public.lop_requests (labor_id);
create index idx_lop_requests_date       on public.lop_requests (date);
create index idx_lop_requests_department on public.lop_requests (department_id);
create index idx_lop_requests_status     on public.lop_requests (approval_status);
create index idx_lop_requests_client_id  on public.lop_requests (client_id);

create table public.audit_log (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid references public.users(id),
    user_name   text,
    action      text not null,
    table_name  text not null,
    record_id   text,
    old_value   jsonb,
    new_value   jsonb,
    ip_address  text,
    created_at  timestamptz default now(),
    client_id   uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id)
);
create index idx_audit_log_user  on public.audit_log (user_id);
create index idx_audit_log_table on public.audit_log (table_name);
create index idx_audit_log_date  on public.audit_log (created_at);

-- NOTE: primary key is (key) alone, so two clients cannot have the same setting key. See ROADMAP task 47.
create table public.settings (
    key         text primary key,
    value       text not null,
    description text,
    updated_at  timestamptz default now(),
    client_id   uuid default '00000000-0000-0000-0000-000000000001' references public.clients(id),
    constraint settings_client_key_unique unique (client_id, key)
);
create index idx_settings_client_id on public.settings (client_id);

create table public.labor_id_sequence (
    id         integer primary key default 1 check (id = 1),
    next_value integer default 1
);
insert into public.labor_id_sequence (id, next_value) values (1, 1) on conflict do nothing;

create table public.attendance_freeze (
    id         uuid primary key default gen_random_uuid(),
    client_id  uuid not null,
    date       date not null,
    frozen_by  varchar,
    frozen_at  timestamptz default now(),
    unique (client_id, date)
);

create table public.holidays (
    id         uuid primary key default gen_random_uuid(),
    client_id  uuid not null,
    date       date not null,
    name       varchar not null,
    created_at timestamptz default now(),
    is_active  boolean default true,
    unique (client_id, date)
);

create table public.ot_rates (
    id            uuid primary key default gen_random_uuid(),
    client_id     uuid not null,
    role          varchar not null,
    rate_per_hour numeric not null default 15.00,
    created_at    timestamptz default now(),
    unique (client_id, role)
);

create table public.overtime_records (
    id           uuid primary key default gen_random_uuid(),
    client_id    uuid not null,
    labor_id     varchar not null,
    from_date    date not null,
    to_date      date not null,
    ot_hours     numeric not null,
    ot_amount    numeric not null,
    submitted_by varchar,
    submitted_at timestamptz default now(),
    notes        text
);

create table public.enrollment_links (
    id              uuid primary key default gen_random_uuid(),
    token           varchar not null unique,
    labor_id        varchar not null,
    client_id       uuid not null,
    created_by      varchar,
    created_at      timestamptz default now(),
    expires_at      timestamptz default (now() + interval '1 hour'),
    status          varchar default 'pending',
    face_descriptor text,
    photo_url       text,
    submitted_at    timestamptz,
    labor_name      varchar
);

-- ---------- functions ----------
create or replace function public.get_next_labor_id()
returns text language plpgsql as $$
declare
    next_id integer;
begin
    update labor_id_sequence
    set next_value = next_value + 1
    where id = 1
    returning next_value - 1 into next_id;

    return 'L' || next_id::text;
end;
$$;

create or replace function public.register_iqama(p_iqama text)
returns text language plpgsql as $$
declare
    existing_labor_id text;
    new_labor_id text;
begin
    select labor_id into existing_labor_id from iqama_registry where iqama_number = p_iqama;
    if existing_labor_id is not null then
        return existing_labor_id;
    end if;

    new_labor_id := get_next_labor_id();
    insert into iqama_registry (iqama_number, labor_id) values (p_iqama, new_labor_id);
    return new_labor_id;
end;
$$;

create or replace function public.calculate_attendance_status(hours numeric)
returns text language plpgsql as $$
declare
    min_present decimal;
    min_half decimal;
begin
    select value::decimal into min_present from settings where key = 'min_hours_present';
    select value::decimal into min_half from settings where key = 'min_hours_half_day';

    if hours >= min_present then
        return 'P';
    elsif hours >= min_half then
        return 'H';
    else
        return 'A';
    end if;
end;
$$;

create or replace function public.update_daily_attendance(p_labor_id text, p_date date)
returns void language plpgsql security definer as $$
declare
    v_client_id uuid;
    v_department_id uuid;
    v_first_login time;
    v_last_logout time;
    v_total_hours numeric;
    v_total_minutes integer;
    v_auto_status text;
    v_min_present_minutes integer := 570;
    v_min_half_minutes integer := 240;
    v_dept_min_hours text;
begin
    select client_id, department_id
    into v_client_id, v_department_id
    from laborers
    where labor_id = p_labor_id
    limit 1;

    if v_client_id is null then return; end if;

    select min(time), max(time)
    into v_first_login, v_last_logout
    from punch_records
    where labor_id = p_labor_id
      and date = p_date
      and client_id = v_client_id;

    if v_first_login is null then return; end if;

    select min_hours_full_day
    into v_dept_min_hours
    from departments
    where id = v_department_id
    limit 1;

    if v_dept_min_hours is not null then
        v_min_present_minutes :=
            extract(hour from v_dept_min_hours::time) * 60 +
            extract(minute from v_dept_min_hours::time);
    end if;

    v_total_minutes := extract(epoch from (v_last_logout - v_first_login)) / 60;
    v_total_hours   := v_total_minutes / 60.0;

    if v_total_minutes >= v_min_present_minutes then
        v_auto_status := 'P';
    elsif v_total_minutes >= v_min_half_minutes then
        v_auto_status := 'H';
    else
        v_auto_status := 'A';
    end if;

    insert into daily_attendance (
        labor_id, department_id, date,
        first_login, last_logout, total_hours,
        auto_status, final_status, client_id, updated_at
    ) values (
        p_labor_id, v_department_id, p_date,
        v_first_login, v_last_logout, v_total_hours,
        v_auto_status, v_auto_status, v_client_id, now()
    )
    on conflict (labor_id, date)
    do update set
        first_login  = excluded.first_login,
        last_logout  = excluded.last_logout,
        total_hours  = excluded.total_hours,
        auto_status  = excluded.auto_status,
        final_status = case
            when daily_attendance.final_status in ('LP','LH','LA')
            then daily_attendance.final_status
            else excluded.auto_status
        end,
        updated_at = now();
end;
$$;

-- ---------- triggers ----------
create trigger update_departments_updated_at     before update on public.departments     for each row execute function update_updated_at();
create trigger update_users_updated_at           before update on public.users           for each row execute function update_updated_at();
create trigger update_laborers_updated_at        before update on public.laborers        for each row execute function update_updated_at();
create trigger update_punch_locations_updated_at before update on public.punch_locations for each row execute function update_updated_at();
create trigger update_daily_attendance_updated_at before update on public.daily_attendance for each row execute function update_updated_at();
create trigger update_lop_requests_updated_at    before update on public.lop_requests    for each row execute function update_updated_at();

-- ============================================================
-- Changelog
-- 2026-10-02  v0  Baseline from live export. Not yet run on any project.
--                 Hand-converted from the export: not tested. Run on the NEW project first and tell me any error.
-- ============================================================
