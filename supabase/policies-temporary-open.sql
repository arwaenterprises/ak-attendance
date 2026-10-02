-- ============================================================
-- TEMPORARY - mirrors today's wide-open access so the current app keeps working on the NEW project.
-- INSECURE ON PURPOSE: anyone holding the public anon key can read, change and delete everything.
-- Do NOT use on the live/production project as a "fix". It is replaced by real policies in the
-- security migration (ROADMAP tasks 29-31). Delete this file once that is done.
-- Not tested (hand-converted from the live export).
-- ============================================================

-- storage bucket (live bucket is PUBLIC and anon may select, upload and DELETE any photo)
insert into storage.buckets (id, name, public) values ('punch-photos', 'punch-photos', true) on conflict do nothing;
create policy "tmp punch-photos select" on storage.objects for select to anon using (bucket_id = 'punch-photos');
create policy "tmp punch-photos insert" on storage.objects for insert to anon with check (bucket_id = 'punch-photos');
create policy "tmp punch-photos delete" on storage.objects for delete to anon using (bucket_id = 'punch-photos');

-- tables with RLS enabled + "allow all" policy on live
alter table public.holidays          enable row level security;
alter table public.ot_rates          enable row level security;
alter table public.overtime_records  enable row level security;
alter table public.departments       enable row level security;
alter table public.settings          enable row level security;
alter table public.punch_locations   enable row level security;
alter table public.laborers          enable row level security;
alter table public.punch_records     enable row level security;
alter table public.daily_attendance  enable row level security;
alter table public.iqama_registry    enable row level security;
alter table public.lop_requests      enable row level security;
alter table public.audit_log         enable row level security;
alter table public.enrollment_links  enable row level security;
alter table public.attendance_freeze enable row level security;
-- RLS is OFF on live for: users, clients, labor_id_sequence (so fully open regardless of policy)

do $$
declare t text;
begin
    foreach t in array array['holidays','ot_rates','overtime_records','departments','settings','punch_locations',
                             'laborers','punch_records','daily_attendance','iqama_registry','lop_requests',
                             'audit_log','enrollment_links','attendance_freeze','users','labor_id_sequence']
    loop
        execute format('create policy %I on public.%I for all to anon, authenticated using (true) with check (true)', 'tmp allow all ' || t, t);
    end loop;
end $$;
