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

## Needed from you
Admin username, number of terminals, quiet window, explicit OK.
