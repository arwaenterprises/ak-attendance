-- ============================================================
-- Migration 023: a self-enrollment link can try again after a failed submit (owner report 2026-10-20: "Failed to submit. Please try again.")
-- ============================================================
-- The self-enrollment page uploads the photo with "overwrite" (upsert) to <company id>/enrollment/<token>.jpg, then calls enrollment_submit.
-- Supabase Storage needs SELECT and UPDATE (besides INSERT) to overwrite a file that is already there (Supabase docs, Storage access control).
-- Migration 006 gave the link INSERT and UPDATE but not SELECT, so once a first attempt had uploaded the photo (and the submit then failed,
-- for example a weak connection, or the labor pressed Retake), every further attempt on that link was refused and the link was useless.
-- Now the link may also SEE its own one photo, under the same condition as before: the link is pending and not expired. Nothing else changes.
-- Run AFTER 022. Safe to run again.
-- ============================================================

drop policy if exists "enrollment link sees its photo" on storage.objects;
create policy "enrollment link sees its photo" on storage.objects for select to anon
    using (bucket_id = 'punch-photos' and public.enrollment_upload_allowed(name));

-- ============================================================
-- Changelog
-- 2026-10-20  023  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 023 applied' as result,
       (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'enrollment link sees its photo') as policy;
