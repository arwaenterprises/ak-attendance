# Live cutover plan (S5) - in place on the live project

Decision (owner): use the same live Supabase project, keep only the attendance app, retire supervisors (one admin per company).

## What the cutover does (and does not)
- MOVES the other apps' tables (medicines, stock, sales, exp_* etc.) to a hidden schema `archive_other_apps`. Nothing is deleted. Restore one: `alter table archive_other_apps.<name> set schema public;` Delete for good later: `drop schema archive_other_apps cascade;` (only when you are sure).
- Removes all old "allow everything" rules, applies migrations 001-006 (tenant isolation, new login, terminal rights, private photos).
- Sets the 3 AE1 supervisors inactive (status saved for rollback).
- Your attendance data (laborers, punches, attendance, LOP) is untouched.
- The pharmacy / expense / logigate apps STOP working after this (by your decision).

## Safety
- Tested on a local copy imitating live: [rehearsal test](https://github.com/arwaenterprises/ak-attendance/blob/claude/cool-cannon-o7cbyn/tests/db/live-like.test.sql), run by [tests/db/run.sh](https://github.com/arwaenterprises/ak-attendance/blob/claude/cool-cannon-o7cbyn/tests/db/run.sh).
- Way back: [rollback SQL](https://github.com/arwaenterprises/ak-attendance/blob/claude/cool-cannon-o7cbyn/supabase/live/live-rollback-bundle.sql) restores old rules, access, photo bucket, other apps and supervisors.

## Steps (window 30-60 minutes; I give them one at a time)
1. Before: you create two Auth users in the live Supabase (Authentication > Users): `<admin>@ae1.dawam.arwaenterprises.com` and `terminal@ae1.dawam.arwaenterprises.com`, with passwords you choose. Signups disabled.
2. Run [live-cutover-bundle.sql](https://github.com/arwaenterprises/ak-attendance/blob/claude/cool-cannon-o7cbyn/supabase/live/live-cutover-bundle.sql) in the SQL editor of the LIVE project.
3. Run the two link statements (I write them with your admin username): `link_admin_profile('AE1','<username>')`, `link_terminal_profile('AE1')`.
4. I merge the app change that turns on the new login for the live host (version bump). Everyone updates through the update popup.
5. Test: admin login, dashboard, punch terminal on the terminal device (open `punch/?client=AE1#key=...`), photo shown.
6. If anything is wrong: run the rollback SQL and I revert the app change.

## Decided with the owner
- AE1 admin: the existing admin `akhtar.ansari@ak.com.sa` becomes username `akhtaransari` (typed as AkhtarAnsari; the login ignores capitals). Same person, same history, new password set in Supabase Auth.
- AE1 supervisors adel, hridoy, prodip (active) are retired; arif was already inactive.
- Downtime accepted: 60-90 minutes.
- Terminals: Kaden Warehouse is the main one (2073 punches in 30 days); Sulay (49) maybe. One terminal link per company, used on every device.
- AE2 (Hadir, 1 laborer) and AE3 (0 laborers) each have one admin whose username is an email, so those two logins will NOT work after the cutover (no Auth accounts). Their data stays. Open question to the owner: give them short usernames too, or leave.

## Exact statements for step 3 (live SQL editor, after the bundle)
```sql
-- rename first (the old username is an email and cannot be used in the new login address)
update public.users set username = 'akhtaransari'
 where username = 'akhtar.ansari@ak.com.sa' and client_id = (select id from public.clients where client_code = 'AE1');
select public.link_admin_profile('AE1', 'akhtaransari');
select public.link_terminal_profile('AE1');
```
Auth users to create first (Authentication > Users > Add user, tick auto-confirm): `akhtaransari@ae1.dawam.arwaenterprises.com` and `terminal@ae1.dawam.arwaenterprises.com`.

## If rolling back
After the rollback SQL also run:
```sql
update public.users set username = 'akhtar.ansari@ak.com.sa'
 where username = 'akhtaransari' and client_id = (select id from public.clients where client_code = 'AE1');
```
(the old login's stored password check depends on the old username, so it must be put back).
