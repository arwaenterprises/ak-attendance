# Dawam Attendance

Attendance system for companies with many workers: face recognition, geo-fencing, IN / OUT punches, shifts, departments, roles and salary, reports and billing.
One installation serves many companies (each company only sees its own data).

## What it does

- **Punch terminal** (`punch/`): the labor types the ID, presses IN or OUT, the face is checked in the oval, a photo is kept. Works offline and syncs later. "View my attendance" shows the month (green = worked in full or approved, red = otherwise, today grey).
- **Administrator**: departments (Active / Inactive, move labors), labor master and import, face enrollment (also by a one-hour, single-use link), shifts (Day / Night with history), roles with default salary and overtime rate, salary history ("from which day"), punch locations, holidays, LOP approval, daily / monthly / overtime / 3PL billing reports.
- **Platform owner**: creates and manages companies.

## How it is built

- Front end: plain HTML, CSS and JavaScript (no build step), a service worker (`sw.js`) for the install / offline / update popup. Hosted on GitHub Pages; the site publishes on every push to `main` (`.github/workflows/pages.yml`).
- Back end: one Supabase project (Auth login, Postgres with row-level security, private storage bucket `punch-photos`). All database changes are in `supabase/migrations/` (see `supabase/README.md`).
- Face recognition: face-api.js in the browser.
- Photos are deleted after 15 days or when a month is closed (`.github/workflows/photo-cleanup.yml`).

## Folders

```
index.html, dashboard.html     login and main menu
admin/                         departments, roles, shifts, settings, companies
labor/                         labor master, import, enrollment
attendance/                    punch locations, LOP, overtime, holidays
reports/                       daily, monthly, 3PL billing
punch/                         the punch terminal
js/                            config, auth, api (one file per area), utils, ui
css/, icons/, templates/       styles, icons, the CSV import template
supabase/                      schema and migrations
tests/                         static checks and database security tests
tools/                         bump-version.js (app version), build-site.js (what gets published)
ROADMAP.md                     the living log: decisions, open items, change log
```

## Working on it

- Work goes straight to `main`; test in the browser.
- Change an app file => bump the version: `node tools/bump-version.js` (one number in `sw.js` and in every page).
- Checks: `node tests/static-checks.js` and `bash tests/db/run.sh` (needs a local Postgres and `psql`).
- A database change = a new numbered file in `supabase/migrations/` + a test in `tests/db/`, then the owner pastes it into the Supabase SQL Editor.

## First login

The platform owner creates each company and its administrator. Passwords are never written in this repository.
