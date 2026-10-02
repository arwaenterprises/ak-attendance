-- ============================================================
-- Migration 003: link LOP requests to laborers (ROADMAP finding 58)
-- ============================================================
-- Bug on the LIVE site today: the LOP lists (attendance/lop.html: pending / approved / rejected / draft) ask the database for
-- "laborers:labor_id(...)" but there is no foreign key lop_requests.labor_id -> laborers.labor_id, so the database answers
-- 400 "Could not find a relationship" and the lists cannot load. Verified against live with a read-only request that returns no rows.
-- Safe on a database with old data: the key is added NOT VALID (checks only new rows), then we try to validate the old rows.
-- ============================================================
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'lop_requests_labor_id_fkey') then
        alter table public.lop_requests
            add constraint lop_requests_labor_id_fkey foreign key (labor_id) references public.laborers (labor_id) not valid;
    end if;
end $$;

do $$
begin
    alter table public.lop_requests validate constraint lop_requests_labor_id_fkey;
exception when foreign_key_violation then
    raise notice 'Some OLD LOP requests point to labor IDs that do not exist. The key stays NOT VALID (new rows are still checked). Find them with: select labor_id from lop_requests where labor_id not in (select labor_id from laborers);';
end $$;
