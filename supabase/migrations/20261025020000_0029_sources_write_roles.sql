-- =====================================================================
-- 0029 — booking sources: only the owner or a manager changes them (decision 71, §16; controls G01, G03).
-- Until now the write policy on booking_sources checked the organisation only, so any signed-in staff member
-- (housekeeping included) could add a platform, rename it, switch it off, or change the booking link guests
-- are sent to, straight through the API. Reading stays open to every staff member of the organisation (old
-- reservations keep showing their platform after it is switched off); changing needs the owner or a manager.
-- A platform that reservations use cannot be removed (foreign key): switching it off is the way (decision 48).
-- =====================================================================
select set_config('app.source', 'migration', true);

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'booking_sources' and policyname = 'staff_sources_read') then
    create policy "staff_sources_read" on booking_sources for select to authenticated using (organization_id = fn_user_org_id());
  end if;
end $$;

alter policy "staff_sources_all" on booking_sources
  using (organization_id = fn_user_org_id() and fn_has_role('owner', 'manager'))
  with check (organization_id = fn_user_org_id() and fn_has_role('owner', 'manager'));
