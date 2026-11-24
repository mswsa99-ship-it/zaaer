-- tests/isolation/rpc-fixtures-departure.sql: departure-day stay for the guest token mutators fn_guest_departure_instructions / fn_guest_departure (purpose 'departure').
-- Loaded with rpc-fixtures*.sql (after fixtures.sql, before variant-fixtures/rpc-adapters). Local synthetic DB only; no protected function, no keybox/delivery.
--   One checked-in stay per target built through the production owner RPCs (create reservation, receipt voucher, room, guest data, identity approval, Shomoos, check-in),
--   with its own room. Two explicit test-only seed UPDATEs on THIS stay only (the rows are the fixture's own, no trigger or FK is disabled):
--     check_in = today-1, check_out = today (departure-day stay; fn_departure_instructions/fn_departure_confirm require check_out <= today)
--     late_checkout_until = 23:59 (the free-checkout hour is not passed, so the call adds no late-hours charge and is deterministic; the late-hours branch is NOT covered)
--   registration_sessions row of that stay (the guest bearer token) is registered as purpose 'departure' too. Not touched by base victims or other purposes.
do $$
declare t record; own uuid; cat uuid; src uuid; r jsonb; k int := 0; rid uuid; rm uuid; gid uuid; n int;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id = t.org and c.branch_id = t.branch_id order by c.id limit 1;
    select b.id into src from booking_sources b where b.organization_id = t.org and b.kind = 'direct' and b.is_active order by b.id limit 1;
    perform iso.set_claims(own);
    set local role authenticated;
    -- Dedicated synthetic stay, not the base victim.
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 2)::text,
           'guest_phone', '05516' || lpad(k::text, 5, '9'), 'guest_name', 'Depart ' || repeat(chr(96 + k), 4)));
    rid := (r->>'id')::uuid;
    perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 21000 + k * 7, 'method', 'cash', 'idempotency_key', 'isodep-room-' || k));
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', 'DEP' || k::text))->>'id')::uuid;
    r := fn_staff_assign_room(rid, rm);
    select g.id into gid from reservation_guests g where g.reservation_id = rid and g.is_primary limit 1;
    r := fn_staff_enter_guest(jsonb_build_object('reservation_id', rid, 'guest_id', gid, 'full_name', 'Depart ' || repeat(chr(96 + k), 4) || ' Alharbi', 'identity_type', 'national_id',
           'identity_number', '10000300' || lpad(k::text, 2, '0'), 'nationality', 'SA', 'birth_date', '1990-01-01', 'document_matched', true));
    r := fn_staff_approve_identity(gid, true);
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'register', 'reference', 'ISODP' || k, 'all_guests', true));
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'accept'));
    r := fn_staff_check_in(jsonb_build_object('reservation_id', rid));
    if (r->>'ok')::boolean is not true and r->>'duplicate' is null then raise exception 'VARIANT FIXTURE departure CHECKIN BLOCKED: % %', t.key, r; end if;
    reset role;
    -- test-only seed on THIS synthetic stay: it is a departure-day stay (check_out today) and the free-checkout hour is held to 23:59 so the call is deterministic (no late-hours charge)
    update reservations set check_in = current_date - 1, check_out = current_date, late_checkout_until = time '23:59' where id = rid;
    select count(*) into n from registration_sessions where reservation_id = rid;
    if n = 0 then insert into registration_sessions(reservation_id, token, expires_at, organization_id) values (rid, 'ISO-DEP-' || t.key, now() + interval '1 day', t.org); end if;
    insert into iso.created(tbl, id, org, branch, purpose)
      select 'registration_sessions', s.id::text, t.org, t.branch_id, 'departure' from registration_sessions s where s.reservation_id = rid;
    insert into iso.created(tbl, id, org, branch, purpose) values ('reservations', rid::text, t.org, t.branch_id, 'departure'), ('rooms', rm::text, t.org, t.branch_id, 'departure');
  end loop;
  -- Fixture owner claims must not leak into subsequent anon probes.
  perform iso.set_claims(null);
end $$;
