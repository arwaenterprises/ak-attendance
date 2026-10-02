-- Dawam Attendance: export the REAL database structure.
-- Run this ONCE in the CURRENT (live) Supabase project:
--   Dashboard > SQL Editor > New query > paste > Run.
-- It returns a single JSON value (no data rows, no passwords, no photos).
-- Copy the result and paste it in the chat. Not yet run by me; if it errors, send the error message.
select jsonb_pretty(jsonb_build_object(
  'columns', (select jsonb_agg(jsonb_build_object('table', table_name, 'column', column_name, 'type', data_type, 'nullable', is_nullable, 'default', column_default) order by table_name, ordinal_position)
              from information_schema.columns where table_schema = 'public'),
  'constraints', (select jsonb_agg(jsonb_build_object('table', conrelid::regclass::text, 'name', conname, 'definition', pg_get_constraintdef(oid)))
              from pg_constraint where connamespace = 'public'::regnamespace),
  'indexes', (select jsonb_agg(indexdef) from pg_indexes where schemaname = 'public'),
  'row_level_security', (select jsonb_agg(jsonb_build_object('table', relname, 'rls_enabled', relrowsecurity))
              from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r'),
  'policies', (select jsonb_agg(to_jsonb(p)) from pg_policies p where schemaname in ('public', 'storage')),
  'functions', (select jsonb_agg(pg_get_functiondef(f.oid)) from pg_proc f where f.pronamespace = 'public'::regnamespace and f.prokind = 'f'),
  'triggers', (select jsonb_agg(pg_get_triggerdef(t.oid)) from pg_trigger t
              where not t.tgisinternal and t.tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace)),
  'storage_buckets', (select jsonb_agg(jsonb_build_object('id', id, 'public', public)) from storage.buckets)
));
