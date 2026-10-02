# Dawam Attendance - Roadmap

Living file. Updated after every change. Nothing here is built yet unless the status says Done.

**Status:** Todo | In progress | Done | Blocked | Needs your answer
**Severity:** Critical (data exposure / money) | High | Medium | Low

Hosting: GitHub Pages (`dawam.arwaenterprises.com`, DNS at Namecheap). Backend: Supabase free tier.
Rule for every task: do not break the existing workflow or architecture; test before and after.

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
| 2a | Export the REAL schema from the current Supabase (tables, policies, functions) with `supabase/export-schema.sql`, then build `supabase/schema.sql` from it. The code alone shows 16 tables and 2 functions but not column types, rules or security policies | High | Waiting for owner to run the export |
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
| 29 | **Login runs in the browser.** The app reads each user's `password_hash` from the `users` table in the browser. For that to work, anyone holding the public anon key (it is in `js/config/supabase.js`, which is normal) can likely read every client's password hashes. Verify RLS on `users`. Fix: move login into a server-side database function / Supabase Auth, never send hashes to the browser | Critical | Todo (verify) |
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
| 2026-10-02 | Added 4-hour lock rule (tasks 20-24a), schema tasks (2a, 2b), `supabase/` folder with export query and schema skeleton. |
