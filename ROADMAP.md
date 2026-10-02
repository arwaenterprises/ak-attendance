# Dawam Attendance - Roadmap

Living file. Updated after every change. Nothing here is built yet unless the status says Done.

**Status:** Todo | In progress | Done | Blocked | Needs your answer
**Severity:** Critical (data exposure / money) | High | Medium | Low

Hosting: GitHub Pages (`dawam.arwaenterprises.com`, DNS at Namecheap). Backend: Supabase free tier.
Rule for every task: do not break the existing workflow or architecture; test before and after.

---

## NOW - your next steps (kept short on purpose)

| Step | What you do | Done? |
|------|-------------|-------|
| 1-5 | NEW Supabase project fully set up (structure, policies, test data, clients policy) | Yes |
| 6 | Reply "go" to start my next block: baseline tests (task 1), then update mechanism + PWA + rename (tasks 4-12) | No |

Only these steps are yours right now. Everything else is mine until I ask.

---

## A. Decisions made so far

| # | Decision |
|---|----------|
| D1 | App name is **Dawam Attendance**, short and simple. "AK" is removed from visible text, cache names, manifest and constants. Database table/column names are NOT renamed. |
| D2 | One Admin user per client; same login may be used on several devices at once. User Management page is removed. |
| D3 | Two shifts: Day and Night. Admin configures them in a new **Shift Management** tab and moves labors between them. |
| D4 | Keep the existing night-shift detection as a safety net. |
| D5 | **Lock rule:** once an IN (login) punch is registered, every later punch is rejected with a clear message ("You have already logged in for the day") until at least **4 hours** have passed. After that the next punch is the OUT. Exact wording of the rule is in tasks 20-23. |
| D8 | Keep a Supabase schema file (`supabase/schema.sql`) in the repo and update it with every database change. New Supabase project is created by the owner first (staging), live project untouched until verified. |
| D6 | Update mechanism + PWA install prompt for all users, all pages. |
| D7 | Test everything before implementing: baseline tests of today's behaviour first. |

---

## B. Task list

### 1. Foundation (do first)

| # | Task | Severity | Status |
|---|------|----------|--------|
| 1 | Write baseline tests of today's behaviour (punch, offline sync, night shift, reports) against a fake Supabase, run them green BEFORE any change | High | Todo |
| 2 | Set up a free second Supabase project (new/staging), so real-database checks never touch live data. Owner creates it; guide in chat | High | In progress (owner creating) |
| 2a | Export the REAL schema and build `supabase/schema.sql` from it | High | Done (export received 2026-10-02; schema.sql written, NOT yet run on any project) |
| 2c | Run `supabase/schema.sql` then `supabase/policies-temporary-open.sql` on the NEW project and report any error. Both ran without errors on a local Postgres 16 (with stand-ins for Supabase's roles/storage); not yet run on real Supabase | High | Todo (owner) |
| 2d | Create staging data on the new project: one client, one admin user, settings keys. File: `supabase/seed-staging.sql` | High | Done (owner ran it successfully) |
| 2e | Staging config: app uses the new project ONLY on localhost / 127.0.0.1 / `staging.*` hosts; every other address (live site included) uses the live project; red STAGING badge; `sw.js` v69. **Tested:** login TEST / admin / Test@1234 on a local copy reaches the dashboard against the new project, contacting only the new project | High | Done |
| 2f | Decide where a shared staging page lives (e.g. a `staging.` address) so you can try it on a phone. Not needed yet; I test locally first | Low | Todo |
| 2b | Keep `supabase/schema.sql` updated with every database change from now on (see D8) | Medium | Todo |
| 3 | Add CI (GitHub Actions) running the tests and static checks on every push | Medium | Todo |

### 2. App update, service worker, PWA

| # | Task | Severity | Status |
|---|------|----------|--------|
| 4 | Service worker becomes network-first (today it is cache-first, so devices can run old code for days) | High | Todo |
| 5 | One version number: `?v=N` on every script tag AND in `sw.js`; static check fails the build if they differ or are not bumped | High | Todo |
| 6 | Update icon + red dot + centred popup ("Update now" / "Later"); never reloads by itself | High | Todo |
| 7 | Register the service worker on every page, not only the punch page; pre-cache all app files | Medium | Todo |
| 8 | Install prompt on the punch terminal (browser prompt where supported; "Add to Home Screen" hint on iPhone) | Medium | Todo |
| 9 | Real PNG app icons (current icon is an inline SVG that some phones may reject; verify on a real device) | Medium | Needs your answer (logo?) |
| 10 | Fix offline-sync registration code in `js/utils/sync-manager.js` (~line 413 uses `window.registration` / `navigator.serviceWorker.sync`, which I believe are not valid; verify in current docs) and the `online` listener inside `sw.js` (a service worker likely never receives it) | Medium | Todo |
| 11 | GitHub Pages cannot set `no-cache` headers (it serves files with a short cache, I believe about 10 minutes; verify). Updates may appear up to that long after deploy. Test on a real device | Low | Todo |

### 3. Rename and single admin

| # | Task | Severity | Status |
|---|------|----------|--------|
| 12 | Rename "AK" to "Dawam Attendance" everywhere visible (30+ files, `AK_CLIENT_ID`, cache name, manifest, session key). Show the client's own name from the database instead of the hard-coded "M.A. Al Abdul Karim & Co" | Low | Todo |
| 13 | Remove User Management (`admin/users.html`, `js/api/user-api.js` use); keep the role/permission checks so nothing else breaks | Medium | Todo |
| 14 | One admin per client; enforce in the database, not just the screen | Medium | Todo |
| 15 | Test same admin login on 2+ devices at once | Medium | Todo |
| 16 | Admin password creation / reset flow (platform owner does it) | High | Needs your answer |

### 4. Shift Management (biggest change)

| # | Task | Severity | Status |
|---|------|----------|--------|
| 17 | New **Shift Management** tab: Day and Night shift definitions (start/end times) | High | Todo |
| 18 | Assign labors to Day or Night, one by one and in bulk, with a **start date**; history is kept so old months never change | High | Todo |
| 19 | Reports, LOP, overtime and views read the labor's shift **on each date** | High | Todo |

### 5. IN / OUT punches and the 4-hour lock

What the code does today (read from `punch/index.html` and `js/api/punch-api.js`): the terminal does NOT ask IN or OUT. It alternates automatically: first punch = `login`, next = `logout`, next = `login`... There is a per-day punch limit setting. Offline, it only looks at punches saved on that device, not the server. There is no minimum gap between punches.

My reading of your rule (please confirm, task 20): after a `login`, ANY punch within 4 hours is rejected with "You have already logged in for the day"; the first punch after 4 hours is the `logout`.

| # | Task | Severity | Status |
|---|------|----------|--------|
| 20 | Confirm the rule wording: lock = 4 hours after the IN; setting `min_shift_hours` per client, default 4; applies to day and night shift alike | High | Needs your answer |
| 21 | Terminal rejects any punch inside the lock with a clear message showing the IN time and when OUT opens | High | Todo |
| 22 | Same rule enforced **in the database** (not only on the screen), so a changed phone or a direct call cannot bypass it | High | Todo |
| 23 | Offline: apply the same lock using punches saved on the device AND the last known server punches; on sync the database re-checks, and a rejected offline punch is flagged for admin review, never silently dropped | High | Todo |
| 24 | Night shift: IN on day D pairs with the OUT next morning using the shift assignment (the existing night detection stays as fallback). Offline and online give the same result (today `savePunch` reads the shift settings from the server at save time) | High | Todo |
| 24a | Decide what a punch after a completed OUT means (new IN for a second session, or reject). Today it starts a new IN | Medium | Needs your answer |

### 6. Platform / SaaS

| # | Task | Severity | Status |
|---|------|----------|--------|
| 25 | Platform Owner page to create clients and their single admin, activate/deactivate, set trial / paid dates. Separate private page or app (recommended) | Medium | Needs your answer |
| 26 | Verify expiry is actually enforced (today only checked at login; an already-open session keeps working) | Medium | Todo |

### 7. Labor monthly attendance on the punch terminal

| # | Task | Severity | Status |
|---|------|----------|--------|
| 27 | Labor sees only their own month after face match + ID/PIN, served by a small database function (not direct table reads) | Medium | Todo, after tasks 29-31 |
| 28 | Check free-tier limits and project pausing on the current Supabase pricing page (as I recall about 500 MB database, 1 GB storage, 5 GB transfer, pause after about a week idle; verify) | Medium | Todo |

---

## C. Security review (read from the code; not yet verified against the live Supabase)

I could only read the code. I have not seen your Supabase row-level security (RLS) rules. Items marked "verify" depend on them.

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 29 | **(CONFIRMED by export, see 43)** **Login runs in the browser.** The app reads each user's `password_hash` from the `users` table in the browser. For that to work, anyone holding the public anon key (it is in `js/config/supabase.js`, which is normal) can likely read every client's password hashes. Verify RLS on `users`. Fix: move login into a server-side database function / Supabase Auth, never send hashes to the browser | Critical | Todo (verify) |
| 30 | **Tenant isolation depends on the browser.** `client_id` comes from localStorage and every query filters on it in JavaScript. If RLS does not enforce it, a user can change `client_id` and read or write another client's data. Verify RLS on every table. Fix: RLS rules tied to the logged-in user | Critical | Todo (verify) |
| 31 | **Role and permissions live in localStorage** (`ak_attendance_session`) and can be edited by the user. Real enforcement must be in the database | Critical | Todo (verify) |
| 32 | **Weak password storage.** Fast SHA-256 with the username as salt is easy to crack if hashes leak. A plaintext-password fallback is still in the login code. Fix: remove the fallback, migrate to a proper password hashing scheme (Supabase Auth) | High | Todo |
| 33 | **Face photos use public URLs** (`getPublicUrl`). Anyone with a link can view a face photo. Fix: private bucket + short-lived signed links. The 15-day cleanup workflow is good and stays | High | Todo (verify bucket setting) |
| 34 | **Punches are trusted from the device**: time, date and location come from the phone's clock and are inserted straight from the browser. A labor with a changed clock can fake a time. Fix: store the server time too and flag differences | High | Todo |
| 35 | **No brute-force protection** on login (unlimited password guesses). Fix: rate limit / lockout | High | Todo |
| 36 | **79 uses of `innerHTML`.** If a labor name or other text contains HTML, it could run in an admin's browser (XSS). Fix: escape text or use `textContent`; check each use | Medium | Todo |
| 37 | **Face recognition and Supabase libraries load from public CDNs / GitHub Pages of a third party** without integrity checks. If those were tampered with, the app would run the changed code. Fix: pin versions with integrity hashes or host copies | Medium | Todo |
| 38 | **Face data (descriptors) stored on the device** in the browser. Confirm what is stored, for how long, and that it is cleared on logout | Medium | Todo (verify) |
| 39 | **Privacy / legal**: biometric data (faces) is sensitive. Confirm consent wording on enrollment and the retention period with your lawyer. I am not a lawyer; verify | Medium | Needs your answer |
| 40 | `service role` key is only used in the GitHub workflow secret (good). Confirm it is never in the repo or browser code | Low | Todo |
| 41 | Subscription messages contain a hard-coded phone number; move to client/platform settings | Low | Todo |
| 42 | Add an audit log review: login, password change, shift change, freeze day all recorded with who/when | Medium | Todo |

### Findings from the real database export (2026-10-02) - these CONFIRM the Critical items above

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 43 | **Every attendance table is open to anyone with the public key.** Row-level security is switched on, but every policy is "allow all" (`true`) for anon. Tables `users`, `clients`, `labor_id_sequence` have security fully OFF. Anyone can read all password hashes, face data, salaries and photos, and change or delete any record of any client. This confirms tasks 29, 30, 31 | Critical | Todo (first real fix; needs login moved server-side) |
| 44 | **`clients` is writable by anyone** (security off). A person could mark their own company as premium / never-expiring, or deactivate another client. Confirms task 26 is a real hole, not just a gap | Critical | Todo |
| 45 | **Storage: anon can list, upload and DELETE every punch photo**, and the bucket is public. Anyone could wipe all photos | High | Todo |
| 46 | **The live project is shared with other apps** (pharmacy tables, an expense tracker, `admin_users`, and a shared `clients` table with `pharmacy_tier`, `subscribed_apps`). Attendance should have its own project, which the new Supabase project gives us. The other apps keep running on the live project | Medium | Decided: attendance-only on the new project |
| 47 | **Multi-client design flaws in the database:** `settings` primary key is `key` alone, so two clients cannot both have a `night_shift_start`; `users.username`, `departments.code`, `laborers.labor_id` and `iqama_number` are unique across ALL clients, so two clients cannot use the same username or department code; labor IDs come from one global counter | High | Todo (migration) |
| 48 | **`update_daily_attendance` uses the earliest and latest punch time of a date** and fixed fallback hours (570 and 240 minutes) instead of your settings. I believe night shifts and the new IN/OUT lock need this rewritten. It runs with elevated rights and anyone can call it for any labor. **Reproduced on a local test database:** a night shift IN 21:00 / OUT 05:00 is stored as first_login 05:00, last_logout 21:00, 16 hours and status P (should be 8 hours). Reports compensate in report-api.js, but the stored daily_attendance row is wrong. Check real data in the live database | High | Todo |
| 49 | The code reads a table `frozen_dates` that does not exist in the database (the app also uses `attendance_freeze`). Find out which one is real | Low | Todo |
| 50 | `punch_records`, `attendance_freeze`, `holidays`, `ot_rates`, `overtime_records` and `enrollment_links` have no link (foreign key) to `clients`, and `punch_records` has no rule stopping duplicate or too-close punches. The 4-hour lock must be added at database level | Medium | Todo |
| 51 | `admin_users` table: attendance code does not use it. Confirm it belongs to another app before leaving it behind | Low | Needs your answer |

---

## D. Feedback and suggestions

1. Do tasks 29-31 (login/RLS) **before** adding more features. A new monthly-view feature (task 27) widens what the public key can reach, so it must not ship until these are verified.
2. Task 2 (staging Supabase) is cheap and removes most of the risk of testing on live data.
3. Rolling out shifts: switch one client's labors first, compare reports with the old logic for a week, then the rest.
4. Keep this file updated at the end of every piece of work. Statuses above change only after tests pass.

---

## E. Open questions for you

1. Confirm the 4-hour lock wording (task 20) and what a punch after OUT should do (task 24a)
2. Logo for app icons, or should I make a neutral placeholder? (task 9)
3. Who creates and resets the single admin password? (task 16)
4. Platform Owner: page inside this app or a separate private app? (task 25)
5. Repeat-punch window: is 5 minutes right for your warehouse? (task 21)
6. Consent and retention rules for face data (task 39)

---

## F. Change log

| Date | Change |
|------|--------|
| 2026-10-02 | Roadmap created from the code review. No application code changed yet. |
| 2026-10-02 | Owner ran schema.sql and policies-temporary-open.sql on the new project successfully. Added `supabase/seed-staging.sql`. |
| 2026-10-02 | Owner applied the clients policy; staging login test passes (dashboard reached on new project). Task 2e done. |
| 2026-10-02 | Environment switch added (staging vs live), sw.js v69. Found by testing: `clients` had no open policy on the new project (login said Invalid client code); fixed in policies-temporary-open.sql, owner to run one line. |
| 2026-10-02 | Owner ran seed-staging.sql successfully. Next: staging app config (task 2e). |
| 2026-10-02 | Real database export received; `supabase/schema.sql` and `policies-temporary-open.sql` written; findings 43-51 added (security is worse than the code review suggested). |
| 2026-10-02 | Added 4-hour lock rule (tasks 20-24a), schema tasks (2a, 2b), `supabase/` folder with export query and schema skeleton. |
