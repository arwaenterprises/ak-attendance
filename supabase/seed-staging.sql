-- ============================================================
-- STAGING TEST DATA ONLY. Never run on the live project.
-- Creates the default client (the app's built-in client id), one admin login, and settings.
-- Login in the app:   Client code: TEST   Username: admin   Password: Test@1234
-- (staging password, change it; hash = sha256("admin:Test@1234") exactly as js/auth/auth.js computes it)
-- Setting values below are test values I chose, not copied from your live data.
-- ============================================================
insert into public.clients (id, business_name, client_code, subscription_status, subscription_tier, is_active)
values ('00000000-0000-0000-0000-000000000001', 'Test Company', 'TEST', 'premium', 'basic', true)
on conflict (id) do nothing;

insert into public.users (username, password_hash, name, role, status, client_id)
values ('admin', '1427598784e04b5788c1d60b5fccd3d0090d4b43e73d6eaff676257b45483acb', 'Test Admin', 'admin', 'active', '00000000-0000-0000-0000-000000000001')
on conflict (username) do nothing;

insert into public.settings (client_id, key, value) values
 ('00000000-0000-0000-0000-000000000001', 'min_hours_present',     '9.5'),
 ('00000000-0000-0000-0000-000000000001', 'min_hours_half_day',    '4'),
 ('00000000-0000-0000-0000-000000000001', 'max_punches_per_day',   '4'),
 ('00000000-0000-0000-0000-000000000001', 'confidence_threshold',  '70'),
 ('00000000-0000-0000-0000-000000000001', 'reenrollment_threshold','60'),
 ('00000000-0000-0000-0000-000000000001', 'reenrollment_attempts', '3'),
 ('00000000-0000-0000-0000-000000000001', 'photo_retention_days',  '15'),
 ('00000000-0000-0000-0000-000000000001', 'night_shift_start',     '20:00'),
 ('00000000-0000-0000-0000-000000000001', 'night_shift_end',       '06:30')
on conflict do nothing;
