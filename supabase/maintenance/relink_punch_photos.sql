-- ============================================================
-- One-off repair: link punch photos to the punches that lost them (ROADMAP 2026-10-03, bug fixed in v93)
-- ============================================================
-- Between v90 and v93 the terminal uploaded each punch photo but saved the punch WITHOUT the photo path (punch_records.photo_url = null).
-- The files are still in Storage as  <company id>/punches/L<labor number>_<milliseconds>.jpg .
-- A photo is matched to a punch only when ALL of these hold:
--   * same labor, the punch has no photo yet, the punch date is the photo's local date or one day either side
--   * the photo's local clock time is within 10 seconds of the punch time (the terminal stamps both within a second or two)
--   * the match is one-to-one (that punch has exactly one candidate photo, and that photo has exactly one candidate punch)
-- Anything unclear stays unlinked. It only fills empty photo_url values; it never changes a punch that already has a photo.
-- Local time zone of the punch clock: Asia/Riyadh (UTC+3), checked on 3 punches that had photos.
--
-- HOW TO RUN (Supabase SQL Editor, LIVE project):
--   1. Run STEP 1 (preview) first and look at the rows. 2. If they look right, run STEP 2 (the update). Safe to run twice.
-- ============================================================

-- STEP 1: preview (changes nothing)
with photos as (
    select o.name,
           split_part(split_part(o.name, '/', 3), '_', 1) as labor_id,
           (to_timestamp(split_part(split_part(split_part(o.name, '/', 3), '_', 2), '.', 1)::bigint / 1000.0) at time zone 'Asia/Riyadh') as local_ts
      from storage.objects o
     where o.bucket_id = 'punch-photos'
       and o.name ~ '^[0-9a-f-]{36}/punches/L[0-9]+_[0-9]{13}\.jpg$'
       and o.name not in (select photo_url from punch_records where photo_url is not null)
),
cand as (
    select p.id as punch_id, p.labor_id, p.date, p.time, ph.name, ph.local_ts,
           abs(extract(epoch from (ph.local_ts::time - p.time))) as secs
      from punch_records p
      join photos ph on ph.labor_id = p.labor_id
       and p.photo_url is null
       and p.date between ph.local_ts::date - 1 and ph.local_ts::date + 1
       and p.client_id::text = split_part(ph.name, '/', 1)
       and abs(extract(epoch from (ph.local_ts::time - p.time))) <= 10
)
select c.labor_id, c.date, c.time, c.name as photo, round(c.secs::numeric, 1) as seconds_apart
  from cand c
 where (select count(*) from cand x where x.punch_id = c.punch_id) = 1
   and (select count(*) from cand x where x.name = c.name) = 1
 order by c.date desc, c.time desc;

-- STEP 2: the update (same rules; reports how many punches were linked)
with photos as (
    select o.name,
           split_part(split_part(o.name, '/', 3), '_', 1) as labor_id,
           (to_timestamp(split_part(split_part(split_part(o.name, '/', 3), '_', 2), '.', 1)::bigint / 1000.0) at time zone 'Asia/Riyadh') as local_ts
      from storage.objects o
     where o.bucket_id = 'punch-photos'
       and o.name ~ '^[0-9a-f-]{36}/punches/L[0-9]+_[0-9]{13}\.jpg$'
       and o.name not in (select photo_url from punch_records where photo_url is not null)
),
cand as (
    select p.id as punch_id, ph.name
      from punch_records p
      join photos ph on ph.labor_id = p.labor_id
       and p.photo_url is null
       and p.date between ph.local_ts::date - 1 and ph.local_ts::date + 1
       and p.client_id::text = split_part(ph.name, '/', 1)
       and abs(extract(epoch from (ph.local_ts::time - p.time))) <= 10
),
safe as (
    select c.punch_id, c.name from cand c
     where (select count(*) from cand x where x.punch_id = c.punch_id) = 1
       and (select count(*) from cand x where x.name = c.name) = 1
),
done as (
    update punch_records p set photo_url = s.name
      from safe s where p.id = s.punch_id and p.photo_url is null
    returning p.id
)
select count(*) as punches_linked from done;
