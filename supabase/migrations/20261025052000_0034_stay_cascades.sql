-- =====================================================================
-- 0034 — what a purge needs for the stay cycle's tables (Phase 3).
-- Pasted by the owner in the Supabase SQL editor, after 0033, together with 0022 and 0031 (STAGING.md §0-ب): the SQL
-- tools that apply the other migrations refuse any statement that removes rows, and this one has to.
--   * rows left without their stay by a purge run before this migration are removed;
--   * the inspections, the overdue reasons and the review items of a stay now go with it in a purge.
-- =====================================================================
delete from checkout_inspections i where not exists (select 1 from reservations r where r.id = i.reservation_id);
delete from stay_payment_exceptions e where not exists (select 1 from reservations r where r.id = e.reservation_id);
delete from review_items v where v.reservation_id is not null and not exists (select 1 from reservations r where r.id = v.reservation_id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'checkout_inspections_reservation_fk') then
    alter table checkout_inspections add constraint checkout_inspections_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stay_payment_exceptions_reservation_fk') then
    alter table stay_payment_exceptions add constraint stay_payment_exceptions_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'review_items_reservation_fk') then
    alter table review_items add constraint review_items_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
end $$;
