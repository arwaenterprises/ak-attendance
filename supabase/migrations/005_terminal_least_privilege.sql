-- ============================================================
-- Migration 005: a terminal cannot read the company row (ROADMAP S3 hardening)
-- ============================================================
-- Found by the end-to-end terminal test on staging: the rule "you may read your own company row" (migration 001) also let a
-- terminal read its company's contact and subscription details. A terminal does not need them (it gets the company name and code
-- through terminal_bootstrap), so only staff (admin / supervisor) may read the company row now.
drop policy if exists "own client row" on public.clients;
create policy "own client row" on public.clients for select to authenticated
    using (id = (select public.current_client_id()) and (select public.is_staff()));
