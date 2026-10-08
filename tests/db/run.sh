#!/usr/bin/env bash
# Database security tests on a throw-away local Postgres database (needs a running Postgres and psql; uses the usual PG* variables).
# Usage: bash tests/db/run.sh        Exit code 0 only if every check passed and no SQL error occurred.
set -uo pipefail
cd "$(dirname "$0")/../.."
DB=dawam_rls_test
FAILED=0
psql -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB" -c "create database $DB" || exit 1
for f in tests/db/stubs.sql supabase/schema.sql supabase/policies-temporary-open.sql supabase/migrations/001_security_foundation.sql tests/db/rls.test.sql supabase/migrations/002_auth_login.sql tests/db/auth.test.sql supabase/migrations/003_lop_labor_fk.sql tests/db/lop.test.sql supabase/migrations/004_terminal.sql tests/db/terminal.test.sql supabase/migrations/005_terminal_least_privilege.sql tests/db/hardening.test.sql supabase/migrations/006_private_photos.sql tests/db/photos.test.sql supabase/migrations/007_punch_rules.sql tests/db/punchrules.test.sql supabase/migrations/008_terminal_month.sql tests/db/month.test.sql supabase/migrations/009_no_login_after_logout.sql tests/db/done.test.sql supabase/migrations/010_shifts.sql tests/db/shifts.test.sql supabase/migrations/011_early_out.sql tests/db/early.test.sql supabase/migrations/012_terminal_link.sql tests/db/terminal_link.test.sql supabase/migrations/013_platform_owner.sql tests/db/platform.test.sql supabase/migrations/014_cleanup_old_rule.sql tests/db/cleanup.test.sql supabase/migrations/015_face_photo_refresh.sql tests/db/refresh.test.sql supabase/migrations/016_second_in.sql tests/db/second_in.test.sql supabase/migrations/017_department_status.sql tests/db/department.test.sql supabase/migrations/018_roles_salary.sql tests/db/roles.test.sql supabase/migrations/019_month_approved.sql tests/db/month_approved.test.sql supabase/migrations/020_night_shift_by_assignment.sql tests/db/night_assigned.test.sql supabase/migrations/021_forgotten_out.sql tests/db/forgotten_out.test.sql; do
  echo "--- $f"
  out=$(psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); code=$?
  echo "$out" | grep -E "NOTICE:  (PASS|FAIL)|ERROR" | sed -E 's/^psql:[^ ]* NOTICE:  //; s/^psql:[^ ]* //'
  if [ $code -ne 0 ]; then echo "SQL ERROR while running $f"; FAILED=1; fi
  if echo "$out" | grep -q "NOTICE:  FAIL"; then FAILED=1; fi
done
if [ $FAILED -eq 0 ]; then echo "RESULT: all database security checks passed"; else echo "RESULT: FAILED"; fi
exit $FAILED
