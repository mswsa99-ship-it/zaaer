-- Dedicated local paid checked-in refundother stays. Production owner RPCs, no broad preload.
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
           'guest_phone', '05518' || lpad(k::text, 5, '9'), 'guest_name', 'Depart ' || repeat(chr(96 + k), 4)));
    rid := (r->>'id')::uuid;
    perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 21000 + k * 7, 'method', 'cash', 'idempotency_key', 'isorfo-room-' || k));
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', 'RFO' || k::text))->>'id')::uuid;
    r := fn_staff_assign_room(rid, rm);
    select g.id into gid from reservation_guests g where g.reservation_id = rid and g.is_primary limit 1;
    r := fn_staff_enter_guest(jsonb_build_object('reservation_id', rid, 'guest_id', gid, 'full_name', 'Depart ' || repeat(chr(96 + k), 4) || ' Alharbi', 'identity_type', 'national_id',
           'identity_number', '10000400' || lpad(k::text, 2, '0'), 'nationality', 'SA', 'birth_date', '1990-01-01', 'document_matched', true));
    r := fn_staff_approve_identity(gid, true);
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'register', 'reference', 'ISODP' || k, 'all_guests', true));
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'accept'));
    r := fn_staff_check_in(jsonb_build_object('reservation_id', rid));
    if (r->>'ok')::boolean is not true and r->>'duplicate' is null then raise exception 'VARIANT FIXTURE refundother CHECKIN BLOCKED: % %', t.key, r; end if;
    reset role;
    select count(*) into n from registration_sessions where reservation_id = rid;
    if n = 0 then insert into registration_sessions(reservation_id, token, expires_at, organization_id) values (rid, 'ISO-RFO-' || t.key, now() + interval '1 day', t.org); end if;
    insert into iso.created(tbl, id, org, branch, purpose)
      select 'registration_sessions', s.id::text, t.org, t.branch_id, 'refundother' from registration_sessions s where s.reservation_id = rid;
    insert into iso.created(tbl, id, org, branch, purpose) values ('reservations', rid::text, t.org, t.branch_id, 'refundother'), ('rooms', rm::text, t.org, t.branch_id, 'refundother');
  end loop;
  -- Fixture owner claims must not leak into subsequent anon probes.
  perform iso.set_claims(null);
end $$;
