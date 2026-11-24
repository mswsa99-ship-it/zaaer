-- tests/isolation/rpc-fixtures.sql: (v1: priced+partly paid confirmed reservation with room, keybox codes, expense category; check-in state NOT built: needs guest data, identity approval, Shomoos registration)
--  extra synthetic state for RPC adapters, created through production RPC paths as the hotel owner.
-- Loaded after fixtures.sql and before rpc-adapters*.sql. Registers rows in iso.created (purpose 'victim').
do $$
declare
  res4 uuid; gphone text;
  rm9 uuid; gid uuid; src uuid; t record; own uuid; r jsonb; cat uuid; rm uuid; k int := 0; res1 uuid; res2 uuid; res3 uuid; ec jsonb;
begin
  for t in select * from iso.target order by key loop
    k := k + 1; res4 := null;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id = t.org and c.branch_id = t.branch_id order by c.id limit 1;
    select gs.phone into gphone from guest_phone_sessions gs where gs.organization_id = t.org and gs.branch_id is not distinct from t.branch_id order by gs.token limit 1;
    perform iso.set_claims(own);
    set local role authenticated;
    for rm in select c.id::uuid from iso.created c where c.tbl = 'rooms' and c.org = t.org and c.branch = t.branch_id and c.purpose = 'victim' loop
      perform fn_staff_rotate_keybox_code(rm, lpad((4000 + k)::text, 6, '7'), false);
    end loop;
    -- expense category
    ec := fn_admin_upsert_expense_category(jsonb_build_object('name', 'ISO-' || t.key || '-exp'));
    -- priced reservations (distinct totals per target come from the category price), one paid + checked in, one confirmed unassigned
    select b.id into src from booking_sources b where b.organization_id = t.org and b.kind = 'direct' and b.is_active order by b.id limit 1;
    if src is null then src := (fn_admin_upsert_source(jsonb_build_object('name', 'Isosource ' || chr(96 + k), 'kind', 'direct'))->>'id')::uuid; end if;
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 2)::text,
           'guest_phone', '05510' || lpad(k::text, 5, '5'), 'guest_name', 'Zorvak ' || repeat(chr(96 + k), 4)));
    res1 := (r->>'id')::uuid;
    perform fn_create_voucher(jsonb_build_object('reservation_id', res1, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 21000 + k * 7, 'method', 'cash', 'idempotency_key', 'isorpc-' || k));
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', '9' || lpad(k::text, 2, '0')))->>'id')::uuid;
    r := fn_staff_assign_room(res1, rm);
    rm9 := rm;
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 3)::text,
           'guest_phone', '05511' || lpad(k::text, 5, '6'), 'guest_name', 'Qelmun ' || repeat(chr(96 + k), 4)));
    res2 := (r->>'id')::uuid;
    -- a reservation for the target's own guest-phone session (the isolation worker's session phone), carrying an ISO-<key>- external_ref marker
    if gphone is not null then
      r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 2)::text,
             'guest_phone', gphone, 'guest_name', 'Dalvor ' || repeat(chr(96 + k), 4), 'external_ref', 'ISO-' || t.key || '-gref'));
      res4 := (r->>'id')::uuid;
    end if;
    -- identity + government-registration prerequisites through the production RPCs (local DB only; fn_staff_shomoos stores the reference, no external call), then arrival
    select g.id into gid from reservation_guests g where g.reservation_id = res1 and g.is_primary limit 1;
    r := fn_staff_enter_guest(jsonb_build_object('reservation_id', res1, 'guest_id', gid, 'full_name', 'Zorvak ' || repeat(chr(96 + k), 4) || ' Alharbi', 'identity_type', 'national_id',
           'identity_number', '10000000' || lpad(k::text, 2, '0'), 'nationality', 'SA', 'birth_date', '1990-01-01', 'document_matched', true));
    r := fn_staff_approve_identity(gid, true);
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', res1, 'action', 'register', 'reference', 'ISOREF' || k, 'all_guests', true));
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', res1, 'action', 'accept'));
    r := fn_staff_check_in(jsonb_build_object('reservation_id', res1));
    if (r->>'ok')::boolean is not true and r->>'duplicate' is null then raise exception 'RPC FIXTURE CHECKIN BLOCKED: %', r; end if;
    -- settle the balance (a second distinct confirmed receipt) so checkout has no money blocker
    perform fn_create_voucher(jsonb_build_object('reservation_id', res1, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 19000 - k * 7, 'method', 'cash', 'idempotency_key', 'isorpc2-' || k));
    -- first use of the ISO category through the production path, so its lazy GL account (fn_gl_for_category) exists before every control: consistent GL state on all four targets
    r := fn_expense_create(jsonb_build_object('branch_id', t.branch_id, 'account_id', (select a.id from cash_accounts a where a.branch_id = t.branch_id and a.kind = 'cash_box' and a.archived_at is null order by a.id limit 1),
           'amount_halalas', 1, 'category_id', (ec->>'id')::uuid, 'attachments', jsonb_build_array(jsonb_build_object('file_name', 'iso.png', 'data_base64', 'iVBORw0KGgo=')),
           'description', 'ISO-' || t.key || '-seedexp', 'idempotency_key', 'isoseedexp-' || k));
    -- a free, clean, ticket-free room for room-assignment adapters
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', '7' || lpad(k::text, 2, '0')))->>'id')::uuid;
    perform fn_staff_rotate_keybox_code(rm9, lpad((4100 + k)::text, 6, '7'), false);
    perform fn_staff_rotate_keybox_code(rm, lpad((5000 + k)::text, 6, '7'), false);
    for gid in select h.id from housekeeping_tasks h where h.room_id = rm and h.status in ('pending','in_progress') loop
      r := fn_staff_complete_cleaning(gid);
    end loop;
    r := fn_staff_mark_keybox_tested(rm);
    r := fn_hk_set_cleanliness(rm, 'clean');
    if r->>'room_status' <> 'ready' then raise exception 'RPC FIXTURE FREE ROOM NOT AVAILABLE: %', r; end if;
    reset role;
    insert into iso.created(tbl, id, org, branch, purpose) values ('rooms', rm9::text, t.org, t.branch_id, 'victim');
    insert into iso.created(tbl, id, org, branch, purpose) values ('rooms', rm::text, t.org, t.branch_id, 'victim');
    insert into iso.created(tbl, id, org, branch, purpose) values ('reservations', res1::text, t.org, t.branch_id, 'victim'), ('reservations', res2::text, t.org, t.branch_id, 'victim');
    if res4 is not null then insert into iso.created(tbl, id, org, branch, purpose) values ('reservations', res4::text, t.org, t.branch_id, 'victim'); end if;
    insert into iso.created(tbl, id, org, branch, purpose) values ('expense_categories', ec->>'id', t.org, null, 'victim') on conflict do nothing;
  end loop;
end $$;
