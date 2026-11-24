-- tests/isolation/rpc-fixtures-checkout.sql: dedicated synthetic checked-in stay per target for fn_staff_check_out / fn_staff_checkout (purpose 'checkout').
-- Loaded with rpc-fixtures*.sql (after fixtures.sql, before variant-fixtures/rpc-adapters). Local synthetic DB only; no protected function, no keybox (the stay's own room has none), no delivery.
--   Built through the production owner RPCs (create reservation, receipt, own room, guest data, identity approval, Shomoos, check-in). One test-only seed UPDATE on THIS stay only:
--     check_in = today-1, check_out = today (leaving on the departure date: no early-departure decision), then the remaining balance is paid in full with a production receipt voucher
--     (check-out is refused while balance_due > 0). No trigger or FK is disabled. The stay is registered as purpose 'checkout' (reservations, rooms) and is not a base victim.
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
    -- Dedicated checkout stay only.
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 2)::text,
           'guest_phone', '05517' || lpad(k::text, 5, '9'), 'guest_name', 'Checkout ' || repeat(chr(96 + k), 4)));
    rid := (r->>'id')::uuid;
    perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 21000 + k * 7, 'method', 'cash', 'idempotency_key', 'isoco-room-' || k));
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', 'CKO' || k::text))->>'id')::uuid;
    r := fn_staff_assign_room(rid, rm);
    select g.id into gid from reservation_guests g where g.reservation_id = rid and g.is_primary limit 1;
    r := fn_staff_enter_guest(jsonb_build_object('reservation_id', rid, 'guest_id', gid, 'full_name', 'Checkout ' || repeat(chr(96 + k), 4) || ' Alharbi', 'identity_type', 'national_id',
           'identity_number', '10000500' || lpad(k::text, 2, '0'), 'nationality', 'SA', 'birth_date', '1990-01-01', 'document_matched', true));
    r := fn_staff_approve_identity(gid, true);
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'register', 'reference', 'ISOCO' || k, 'all_guests', true));
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'accept'));
    r := fn_staff_check_in(jsonb_build_object('reservation_id', rid));
    if (r->>'ok')::boolean is not true and r->>'duplicate' is null then raise exception 'VARIANT FIXTURE checkout CHECKIN BLOCKED: % %', t.key, r; end if;
    reset role;
    -- test-only seed on THIS synthetic stay: it is a checkout-day stay (check_out today) with no free-hour override
    update reservations set check_in = current_date - 1, check_out = current_date where id = rid;
    perform fn_recompute_reservation_finance(rid);
    r := fn_reservation_finance_internal(rid);
    perform iso.set_claims(own); set local role authenticated;
    if (r->>'balance_due')::bigint > 0 then perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', (r->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'isoco-rest-' || k)); end if;
    reset role;
    insert into iso.created(tbl, id, org, branch, purpose) values ('reservations', rid::text, t.org, t.branch_id, 'checkout'), ('rooms', rm::text, t.org, t.branch_id, 'checkout');
  end loop;
  perform iso.set_claims(null);
end $$;
