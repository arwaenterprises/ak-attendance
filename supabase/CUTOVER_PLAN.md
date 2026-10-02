# Live cutover plan (ROADMAP step S5)

Status: PLAN ONLY. Nothing on the live site or the live database has been changed for S5.

## What the read-only inventory of the live database showed (counts and codes only, no names or personal data)
- **The live Supabase project is shared with other apps**: pharmacy tables, an expense tracker, "logigate" (client AE3 only uses logigate), and one shared `clients` table.
- **3 companies**: AE1 (attendance + logigate), AE2 (attendance + pharmacy), AE3 (logigate only, no attendance data).
- **Attendance data is almost all AE1**: 89 laborers, 5 punch locations, 12 settings, 3 departments, 3 holidays. AE2 has 1 laborer, 2 departments, 1 location (looks like a test company). No LOP requests exist at all.
- **Punch records**: over 14,000; about 3,100 of them have a photo.
- **Users**: 3 admins (one per company) and **4 supervisors, all in AE1 (3 active, 1 inactive)**.

## The problem this found
My security migrations (001-006) were written for an attendance-only database. Migration 001 removes the public key's access to **every** table in the `public` schema and changes the shared `clients` table. Run on the shared live project, it would **break the pharmacy, expense and logigate apps**. So the plan is NOT to run them on the shared project.

## Recommended approach: attendance gets its own database (the staging project, promoted)
The staging Supabase project already has every security rule applied and tested. Instead of changing the shared project, move attendance there:

1. **Prepare** (no effect on live): clean the staging test data, create the real admin login for AE1 (and AE2 if kept) in the new project, create one terminal login (key) per company, add two GitHub secrets (old and new service keys) for the data copy.
2. **Copy the data** with a GitHub workflow (manual start; data goes from your old project to your new project inside GitHub's runner, it never passes through me): laborers (with face data), departments, punch locations, settings, holidays, OT rates, punch records, daily attendance, LOP requests (none), freeze dates. A first copy can run days before the switch; a short final copy picks up the newest punches.
3. **Rehearse** on the new project: log in as the real admin, open every page, check numbers against the old system (laborer count, punch count, one day's report).
4. **Switch** in a short maintenance window (my estimate: 30-60 minutes; to be confirmed by the rehearsal): pause terminals, final copy, one-line change in `js/config/supabase.js` (live address -> new project + new login), merge, wait for the deploy, give each terminal its link with the key.
5. **Afterwards**: old photos stay readable at their old addresses until the 15-day cleanup removes them; the cleanup job is pointed at the new project; the old project keeps running the other apps untouched; the attendance tables there are left read-only for a safety period, then removed on your say-so.

## Rollback
Until the final step nothing changes for users. After the switch: revert the one-line change (and bump the version) and the live site is back on the old project with the old login within minutes. Punches taken in the new project during that time would need a copy back (small).

## What changes for people
- Admin: same company code, username; **new password step** (set once).  One admin per company.
- Supervisors (AE1 has 3 active): **would lose access** under the one-admin rule. Needs your decision (see below).
- Terminals: each needs its terminal link once (`punch/?client=AE1#key=...`), then works as today. Punches waiting offline on a terminal are uploaded after it signs in.
- Photos: private, shown through short-lived links.

## Decisions needed from the owner
1. Approve "attendance gets its own database" (recommended) instead of changing the shared project.
2. The 3 active supervisors in AE1: remove (one-admin rule), or keep a "supervisor" login (more work: department access rules)?
3. AE2 (1 laborer, 2 departments): migrate or leave behind?
4. How many terminals (tablets) does AE1 use?
5. A good time for the maintenance window (a quiet period).

## Free-tier note (verify on the Supabase pricing page)
A free account allows a limited number of active projects (I believe 2). The old shared project + the new attendance project use both; a separate staging project afterwards would need a paid plan or testing in the new project with the TEST company. Tests only touch the TEST company's rows.
