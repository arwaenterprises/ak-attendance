-- ============================================================
-- Migration 014: clean-up - remove the old, unused punch rule function (_punch_rule)
-- ============================================================
-- Migrations 009 / 011 replaced it by _punch_check, and terminal_record_punch / terminal_check_punch call _punch_check only.
-- Supabase may show a pop-up about a "destructive operation" for the drop lines: confirm it (it removes only this old internal helper).
-- Safe to run again.
-- ============================================================
drop function if exists public._punch_rule(uuid, text, text, timestamp);
drop function if exists public._punch_rule(uuid, text, text, timestamp, date);

-- ============================================================
-- Changelog
-- 2026-10-02  014  Written and tested locally. Not applied to any Supabase project yet.
-- ============================================================

select 'migration 014 applied' as result,
       (select count(*) from pg_proc where proname = '_punch_rule') as old_rule_functions_left,
       (select count(*) from pg_proc where proname = '_punch_check') as new_rule_functions;
