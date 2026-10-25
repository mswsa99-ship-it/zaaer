-- =====================================================================
-- 0039 — what phase 5 needs that the SQL tools refuse (they refuse any statement that removes rows or objects).
-- Pasted by the owner in the Supabase SQL editor, after 0038, together with 0022, 0031 and 0034 (STAGING.md §0-ب).
--   * decision 69: the older unique index on the platform number allowed it on one booking only, so a group whose
--     units share their platform number could not be created. 0038's constraint (one booking or one group per number)
--     replaces it.
--   * the stay summaries accepted by a guest go with their stay in a purge; a branch's logo and image go with an
--     unused branch that is removed; a ban stays when the profile it was made on is purged (its phones and documents
--     still match).
-- =====================================================================
drop index if exists uniq_reservation_source_ref;

delete from stay_acknowledgements a where not exists (select 1 from reservations r where r.id = a.reservation_id);
update stay_acknowledgements a set guest_id = null where guest_id is not null and not exists (select 1 from reservation_guests g where g.id = a.guest_id);
delete from branch_media m where not exists (select 1 from branches b where b.id = m.branch_id);
update guest_bans b set guest_profile_id = null where guest_profile_id is not null and not exists (select 1 from guest_profiles p where p.id = b.guest_profile_id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'stay_acknowledgements_reservation_fk') then
    alter table stay_acknowledgements add constraint stay_acknowledgements_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stay_acknowledgements_guest_fk') then
    alter table stay_acknowledgements add constraint stay_acknowledgements_guest_fk
      foreign key (guest_id) references reservation_guests(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'branch_media_branch_fk') then
    alter table branch_media add constraint branch_media_branch_fk
      foreign key (branch_id) references branches(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'guest_bans_profile_fk') then
    alter table guest_bans add constraint guest_bans_profile_fk
      foreign key (guest_profile_id) references guest_profiles(id) on delete set null;
  end if;
end $$;
