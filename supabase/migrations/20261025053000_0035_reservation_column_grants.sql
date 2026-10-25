-- =====================================================================
-- 0035 — the reading grant of the reservation columns added by 0011 and 0033, decided on public.reservations itself.
-- The money column gate (0009) lists the readable columns of reservations explicitly, so a new column is readable
-- only once it is granted. 0011 and 0033 granted theirs only "if the gate is in place", and looked for the gate in
-- information_schema by table name alone. The hosted project also keeps a leftover schema (zz_first_attempt) with
-- its own «reservations» table, readable by authenticated: there the lookup concluded that there was no gate, 0033
-- skipped its grant, and the staff screens that read shomoos_accepted_at from the table were refused.
-- This decides with has_table_privilege / has_column_privilege on public.reservations and grants the same columns
-- (none of them carries money). Where the grants are already in place it changes nothing.
-- =====================================================================
select set_config('app.source', 'migration', true);

do $$ begin
  if has_column_privilege('authenticated', 'public.reservations', 'status', 'SELECT')
     and not has_table_privilege('authenticated', 'public.reservations', 'SELECT') then
    -- 0011
    grant select (expected_arrival_time, expected_departure_time, group_ref) on public.reservations to authenticated;
    -- 0033
    grant select (checked_in_by, checked_out_by, closed_at, deposit_waiver_reason, deposit_waiver_by, deposit_waiver_at, shomoos_guest_count,
                  shomoos_accepted_at, shomoos_accepted_by, late_checkout_until, status_before_cancel) on public.reservations to authenticated;
  end if;
end $$;
