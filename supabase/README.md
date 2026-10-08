# supabase folder

| File / folder | What it is |
|---|---|
| `migrations/001 ... 021` | The database changes, in order. Each one is pasted once into the Supabase SQL Editor of the live project. This is the real history of the database. |
| `schema.sql` | The original tables before migration 001 (starting point for rebuilding a database from nothing; the tests do this). |
| `policies-temporary-open.sql` | The old open access rules that migration 001 replaces (only needed for the same rebuild). |

Rebuild from nothing (this is what `bash tests/db/run.sh` does on a throw-away Postgres): `schema.sql`, `policies-temporary-open.sql`, then `migrations/001` to `021` in number order.

The tests for every migration are in `tests/db/`.

Notes
- There is only one Supabase project now (live). Always read a migration before pasting it.
- Tables of other apps on the live project sit in the hidden schema `archive_other_apps`. Dropping it is the owner's decision.
- `ot_rates` is no longer used (overtime rates are in Roles since migration 018). Dropping it is the owner's decision.
