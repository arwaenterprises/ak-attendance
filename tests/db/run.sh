#!/usr/bin/env bash
# Database security tests on a throw-away local Postgres database (needs a running Postgres and psql; uses the usual PG* variables).
# Usage: bash tests/db/run.sh        Exit code 0 only if every check passed and no SQL error occurred.
set -uo pipefail
cd "$(dirname "$0")/../.."
DB=dawam_rls_test
FAILED=0
psql -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB" -c "create database $DB" || exit 1
for f in tests/db/stubs.sql supabase/schema.sql supabase/policies-temporary-open.sql supabase/migrations/001_security_foundation.sql tests/db/rls.test.sql supabase/migrations/002_auth_login.sql tests/db/auth.test.sql supabase/migrations/003_lop_labor_fk.sql tests/db/lop.test.sql supabase/migrations/004_terminal.sql tests/db/terminal.test.sql supabase/migrations/005_terminal_least_privilege.sql tests/db/hardening.test.sql supabase/migrations/006_private_photos.sql tests/db/photos.test.sql supabase/migrations/007_punch_rules.sql tests/db/punchrules.test.sql supabase/migrations/008_terminal_month.sql tests/db/month.test.sql supabase/migrations/009_no_login_after_logout.sql tests/db/done.test.sql supabase/migrations/010_shifts.sql tests/db/shifts.test.sql supabase/migrations/011_early_out.sql tests/db/early.test.sql supabase/migrations/012_terminal_link.sql tests/db/terminal_link.test.sql supabase/migrations/013_platform_owner.sql tests/db/platform.test.sql supabase/migrations/014_cleanup_old_rule.sql tests/db/cleanup.test.sql supabase/migrations/015_face_photo_refresh.sql tests/db/refresh.test.sql supabase/migrations/016_second_in.sql tests/db/second_in.test.sql supabase/migrations/017_department_status.sql tests/db/department.test.sql supabase/migrations/018_roles_salary.sql tests/db/roles.test.sql supabase/migrations/019_month_approved.sql tests/db/month_approved.test.sql; do
  echo "--- $f"
  out=$(psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); code=$?
  echo "$out" | grep -E "NOTICE:  (PASS|FAIL)|ERROR" | sed -E 's/^psql:[^ ]* NOTICE:  //; s/^psql:[^ ]* //'
  if [ $code -ne 0 ]; then echo "SQL ERROR while running $f"; FAILED=1; fi
  if echo "$out" | grep -q "NOTICE:  FAIL"; then FAILED=1; fi
done
# --- dry run of the exact staging procedure: staging state (schema + open policies + seed) -> Auth user -> ONE bundle file
echo "--- staging dry run (seed-staging.sql, then staging-security-bundle.sql)"
DRY=dawam_staging_dryrun
psql -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $DRY" -c "create database $DRY" || exit 1
out=$(psql -d "$DRY" -v ON_ERROR_STOP=1 -q -f tests/db/stubs.sql -f supabase/schema.sql -f supabase/policies-temporary-open.sql -f supabase/seed-staging.sql \
  -c "insert into auth.users (id, email) values (gen_random_uuid(), 'admin@test.dawam.arwaenterprises.com')" -f supabase/staging-security-bundle.sql \
  -f supabase/migrations/003_lop_labor_fk.sql \
  -c "insert into auth.users (id, email) values (gen_random_uuid(), 'terminal@test.dawam.arwaenterprises.com')" -f supabase/staging-terminal-bundle.sql 2>&1); code=$?
echo "$out" | grep -E "ERROR|linked_login_email|admin@test" | head -5
if [ $code -ne 0 ]; then echo "FAIL staging bundle did not run cleanly"; FAILED=1; fi
check=$(psql -d "$DRY" -At -c "select count(*) from users where username='admin' and role='admin' and auth_id is not null and client_id='00000000-0000-0000-0000-000000000001'")
if [ "$check" = "1" ]; then echo "PASS staging bundle links the test admin to the TEST company"; else echo "FAIL staging bundle did not link the test admin ($check)"; FAILED=1; fi
term=$(psql -d "$DRY" -At -c "select count(*) from users where username='terminal' and role='terminal' and auth_id is not null and client_id='00000000-0000-0000-0000-000000000001'")
if [ "$term" = "1" ]; then echo "PASS terminal bundle links the test terminal to the TEST company"; else echo "FAIL terminal bundle did not link the terminal ($term)"; FAILED=1; fi
open=$(psql -d "$DRY" -At -c "select count(*) from pg_policies where policyname like 'tmp allow all %'")
if [ "$open" = "0" ]; then echo "PASS staging bundle removed every temporary open policy"; else echo "FAIL $open temporary open policies remain"; FAILED=1; fi

# --- rehearsal of the LIVE cutover and its rollback on a live-like copy
echo "--- live-like rehearsal (cutover bundle, then rollback bundle)"
LIVE=dawam_livelike
psql -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $LIVE" -c "create database $LIVE" || exit 1
for f in tests/db/stubs.sql supabase/schema.sql supabase/policies-temporary-open.sql tests/db/live-like.fixture.sql supabase/live/live-cutover-bundle.sql tests/db/live-like.test.sql supabase/live/live-rollback-bundle.sql tests/db/live-like.rollback.test.sql; do
  echo "--- $f"
  out=$(psql -d "$LIVE" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); code=$?
  echo "$out" | grep -E "NOTICE:  (PASS|FAIL)|ERROR" | sed -E 's/^psql:[^ ]* NOTICE:  //; s/^psql:[^ ]* //'
  if [ $code -ne 0 ]; then echo "SQL ERROR while running $f"; FAILED=1; fi
  if echo "$out" | grep -q "NOTICE:  FAIL"; then FAILED=1; fi
done

if [ $FAILED -eq 0 ]; then echo "RESULT: all database security checks passed"; else echo "RESULT: FAILED"; fi
exit $FAILED
