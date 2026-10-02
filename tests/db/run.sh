#!/usr/bin/env bash
# Database security tests on a throw-away local Postgres database (needs a running Postgres and psql; uses the usual PG* variables).
# Usage: bash tests/db/run.sh        Exit code 0 only if every check passed and no SQL error occurred.
set -uo pipefail
cd "$(dirname "$0")/../.."
DB=dawam_rls_test
FAILED=0
psql -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB" -c "create database $DB" || exit 1
for f in tests/db/stubs.sql supabase/schema.sql supabase/policies-temporary-open.sql supabase/migrations/001_security_foundation.sql tests/db/rls.test.sql; do
  echo "--- $f"
  out=$(psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); code=$?
  echo "$out" | grep -E "NOTICE:  (PASS|FAIL)|ERROR" | sed -E 's/^psql:[^ ]* NOTICE:  //; s/^psql:[^ ]* //'
  if [ $code -ne 0 ]; then echo "SQL ERROR while running $f"; FAILED=1; fi
  if echo "$out" | grep -q "NOTICE:  FAIL"; then FAILED=1; fi
done
if [ $FAILED -eq 0 ]; then echo "RESULT: all database security checks passed"; else echo "RESULT: FAILED"; fi
exit $FAILED
