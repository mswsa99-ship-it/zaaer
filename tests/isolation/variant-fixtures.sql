-- tests/isolation/variant-fixtures.sql: fixture prerequisites for '#variant' RPC adapters (owned by the isolation harness).
-- Load after rpc-fixtures*.sql and before rpc-adapters*.sql. Created through production paths as the hotel owner, registered in iso.created.
-- #nogl: one expense category per org with NO gl account, so fn_expense_create reaches fn_gl_for_category's lazy first-use branch
--   (migration 0065, fn_gl_for_category). Purpose 'nogl' keeps it out of every 'victim' selector, so base probes and table probes are unchanged.
do $$
declare t record; own uuid; ec jsonb; seen text[] := '{}';
begin
  for t in select * from iso.target order by key loop
    continue when t.org::text = any (seen);
    seen := seen || t.org::text;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    perform iso.set_claims(own);
    set local role authenticated;
    ec := fn_admin_upsert_expense_category(jsonb_build_object('name', 'ISO-' || t.hotel || '-nogl'));
    reset role;
    if exists (select 1 from gl_accounts g where g.expense_category_id = (ec->>'id')::uuid) then
      raise exception 'VARIANT FIXTURE nogl: category % already has a gl account', ec->>'id';
    end if;
    insert into iso.created(tbl, id, org, branch, purpose) values ('expense_categories', ec->>'id', t.org, null, 'nogl') on conflict do nothing;
  end loop;
end $$;

-- hk room_cleaning variants (source: 0007b fn_hk_create_task/fn_hk_start_task/fn_hk_cancel_task effective bodies):
--   start on a room_cleaning task moves rooms.cleanliness to 'in_progress'; cancel resets it only when it was 'in_progress'.
--   'hkclean'  = pending room_cleaning task on a clean room (room goes dirty at creation), for the start variant.
--   'hkcancel' = room_cleaning task already started (cleanliness in_progress), for the cancel variant.
--   Separate rooms and tasks per variant: no shared-base state. fn_room_cleaning_type is the production helper that seeds the branch's system task type (internal, run outside the role).
do $$
declare t record; own uuid; cat uuid; rm uuid; tt uuid; tid uuid; r jsonb; k int := 0; v_clean text; v_stat text; p text;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id = t.org and c.branch_id = t.branch_id order by c.id limit 1;
    tt := fn_room_cleaning_type(t.branch_id);
    foreach p in array array['hkclean', 'hkcancel'] loop
      perform iso.set_claims(own);
      set local role authenticated;
      rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', (case when p = 'hkclean' then '8' else '6' end) || lpad((k + 20)::text, 2, '0')))->>'id')::uuid;
      r := fn_hk_create_task(jsonb_build_object('room_id', rm, 'task_type_id', tt, 'description', 'iso-' || p));
      tid := (r->>'id')::uuid;
      if p = 'hkcancel' then r := fn_hk_start_task(tid); end if;
      reset role;
      select h.status, ro.cleanliness into v_stat, v_clean from housekeeping_tasks h join rooms ro on ro.id = h.room_id where h.id = tid;
      if p = 'hkclean' and (v_stat, v_clean) is distinct from ('pending', 'dirty') then raise exception 'VARIANT FIXTURE hkclean: task %, room %', v_stat, v_clean; end if;
      if p = 'hkcancel' and (v_stat, v_clean) is distinct from ('in_progress', 'in_progress') then raise exception 'VARIANT FIXTURE hkcancel: task %, room %', v_stat, v_clean; end if;
      insert into iso.created(tbl, id, org, branch, purpose) values ('rooms', rm::text, t.org, t.branch_id, p), ('housekeeping_tasks', tid::text, t.org, t.branch_id, p) on conflict do nothing;
    end loop;
  end loop;
end $$;

-- latecheckout variant (source: 0033 fn_admin_upsert_service late_checkout_until > branch check_out_time, billing once; fn_staff_add_service)
--   'latecheckout' = a late-checkout service definition plus a separate confirmed reservation, so add_service also updates reservation_charges.purpose and reservations.late_checkout_until.
do $$
declare t record; own uuid; cat uuid; src uuid; r jsonb; k int := 0; sid uuid; rid uuid; lc time;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id = t.org and c.branch_id = t.branch_id order by c.id limit 1;
    select b.id into src from booking_sources b where b.organization_id = t.org and b.kind = 'direct' and b.is_active order by b.id limit 1;
    perform iso.set_claims(own);
    set local role authenticated;
    r := fn_admin_upsert_service(jsonb_build_object('branch_id', t.branch_id, 'name_ar', 'ISO late ' || t.key, 'price_halalas', 5000, 'billing_unit', 'once', 'late_checkout_until', '23:00'));
    sid := (r->>'id')::uuid;
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 2)::text,
           'guest_phone', '05512' || lpad(k::text, 5, '7'), 'guest_name', 'Velkar ' || repeat(chr(96 + k), 4)));
    rid := (r->>'id')::uuid;
    reset role;
    select s.late_checkout_until into lc from service_definitions s where s.id = sid;
    if lc is null then raise exception 'VARIANT FIXTURE latecheckout: service has no late_checkout_until'; end if;
    insert into iso.created(tbl, id, org, branch, purpose) values ('service_definitions', sid::text, t.org, t.branch_id, 'latecheckout'), ('reservations', rid::text, t.org, t.branch_id, 'latecheckout') on conflict do nothing;
  end loop;
end $$;

-- einv variant (source: 0091 fn_issue_credit_note requires a non-NULL invoices.e_invoice_ref; the repo has no reporting transport, see integrator seam note)
--   'einv' = a separate reservation with a REAL invoice issued by fn_staff_issue_invoice under the hotel owner, then the explicit local synthetic marker
--   SYNTHETIC-LOCAL-NOT-REPORTED-<target> set by the disposable-DB superuser (the same state injection as tests/sql/phase4_controls_tests.sql). No outbound call, no mocked function,
--   no trigger bypass. Exercises credit-note creation (new invoice row, document sequence, review item, audit) and never claims real e-invoice reporting.
do $$
declare t record; own uuid; cat uuid; src uuid; r jsonb; k int := 0; rid uuid; inv uuid; iv invoices%rowtype;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id = t.org and c.branch_id = t.branch_id order by c.id limit 1;
    select b.id into src from booking_sources b where b.organization_id = t.org and b.kind = 'direct' and b.is_active order by b.id limit 1;
    perform iso.set_claims(own);
    set local role authenticated;
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', (current_date + 30)::text, 'check_out', (current_date + 32)::text,
           'guest_phone', '05513' || lpad(k::text, 5, '8'), 'guest_name', 'Einvoice ' || repeat(chr(96 + k), 4)));
    rid := (r->>'id')::uuid;
    r := fn_staff_issue_invoice(jsonb_build_object('reservation_id', rid));
    inv := (r->>'id')::uuid;
    reset role;
    update invoices set e_invoice_ref = 'SYNTHETIC-LOCAL-NOT-REPORTED-' || t.key where id = inv;
    select * into iv from invoices where id = inv;
    if iv.doc_kind is distinct from 'invoice' or iv.status is distinct from 'issued' or coalesce(iv.total_halalas, 0) <= 0 or iv.e_invoice_ref is null
       or iv.organization_id is distinct from t.org or iv.branch_id is distinct from t.branch_id or iv.credit_note_of is not null then
      raise exception 'VARIANT FIXTURE einv: invoice precondition failed for %', t.key;
    end if;
    if exists (select 1 from invoices c where c.credit_note_of = inv) then raise exception 'VARIANT FIXTURE einv: credit note already exists for %', t.key; end if;
    insert into iso.created(tbl, id, org, branch, purpose) values ('invoices', inv::text, t.org, t.branch_id, 'einv'), ('reservations', rid::text, t.org, t.branch_id, 'einv') on conflict do nothing;
  end loop;
end $$;

-- paidorder variant (source: 0068 fn_staff_pay_product_order / fn_staff_cancel_product_order paid branch)
--   'paidorder' = its own checked-in stay (own room), one product order paid in cash TODAY: approved cash receipt voucher, not settled, charges not invoiced,
--   delivery task pending. This is what the paid-order cancel branch needs (fn_cancel_voucher reversal, opposite addon/tax charges, task cancel, finance recompute).
--   Built only through production RPCs under the hotel owner. Does not touch the base victim reservations or the pending-order victims.
do $$
declare t record; own uuid; cat uuid; src uuid; r jsonb; k int := 0; rid uuid; rm uuid; gid uuid; pid uuid; oid uuid; o product_orders%rowtype; vid uuid; n int;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id = t.org and c.branch_id = t.branch_id order by c.id limit 1;
    select b.id into src from booking_sources b where b.organization_id = t.org and b.kind = 'direct' and b.is_active order by b.id limit 1;
    perform iso.set_claims(own);
    set local role authenticated;
    -- a dedicated product (never the base victim product, whose availability row is part of the table fixtures) made available for this branch through the production RPCs
    r := fn_admin_upsert_product_category(jsonb_build_object('name', 'ISO paid ' || t.key));
    r := fn_admin_upsert_product(jsonb_build_object('category_id', r->>'id', 'name', 'ISO paid item ' || t.key, 'price_halalas', 7000 + k, 'taxable', true));
    pid := (r->>'id')::uuid;
    perform fn_admin_set_product_branch(pid, t.branch_id, true);
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 2)::text,
           'guest_phone', '05514' || lpad(k::text, 5, '9'), 'guest_name', 'Paidord ' || repeat(chr(96 + k), 4)));
    rid := (r->>'id')::uuid;
    perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 21000 + k * 7, 'method', 'cash', 'idempotency_key', 'isopo-room-' || k));
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', '8' || lpad(k::text, 2, '0')))->>'id')::uuid;
    r := fn_staff_assign_room(rid, rm);
    select g.id into gid from reservation_guests g where g.reservation_id = rid and g.is_primary limit 1;
    r := fn_staff_enter_guest(jsonb_build_object('reservation_id', rid, 'guest_id', gid, 'full_name', 'Paidord ' || repeat(chr(96 + k), 4) || ' Alharbi', 'identity_type', 'national_id',
           'identity_number', '10000100' || lpad(k::text, 2, '0'), 'nationality', 'SA', 'birth_date', '1990-01-01', 'document_matched', true));
    r := fn_staff_approve_identity(gid, true);
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'register', 'reference', 'ISOPO' || k, 'all_guests', true));
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'accept'));
    r := fn_staff_check_in(jsonb_build_object('reservation_id', rid));
    if (r->>'ok')::boolean is not true and r->>'duplicate' is null then raise exception 'VARIANT FIXTURE paidorder CHECKIN BLOCKED: % %', t.key, r; end if;
    r := fn_staff_create_product_order(rid, jsonb_build_array(jsonb_build_object('product_id', pid, 'quantity', 1)));
    oid := coalesce((r->>'id')::uuid, (r->'order'->>'id')::uuid);
    select * into o from product_orders where id = oid;
    r := fn_staff_pay_product_order(jsonb_build_object('order_id', oid, 'method', 'cash', 'idempotency_key', 'isopo-pay-' || k, 'expected_version', o.version));
    reset role;
    select * into o from product_orders where id = oid;
    vid := o.voucher_id;
    if o.status is distinct from 'paid' or vid is null or o.task_id is null or o.organization_id is distinct from t.org or o.branch_id is distinct from t.branch_id then
      raise exception 'VARIANT FIXTURE paidorder: order not paid as required for %', t.key;
    end if;
    if not exists (select 1 from financial_vouchers v where v.id = vid and v.status = 'approved' and v.kind = 'receipt' and v.method = 'cash' and v.product_order_id = o.id
                    and fn_branch_date(v.branch_id, v.occurred_at) = fn_branch_today(v.branch_id) and not fn_voucher_settled(v.id)) then
      raise exception 'VARIANT FIXTURE paidorder: voucher is not an approved unsettled cash receipt of today for %', t.key;
    end if;
    select count(*) into n from reservation_charges c where c.product_order_id = o.id and c.invoice_id is null and c.total_halalas > 0;
    if n < 1 or exists (select 1 from reservation_charges c where c.product_order_id = o.id and c.invoice_id is not null) then raise exception 'VARIANT FIXTURE paidorder: charges missing or invoiced for %', t.key; end if;
    if not exists (select 1 from housekeeping_tasks h where h.id = o.task_id and h.status in ('pending', 'in_progress')) then raise exception 'VARIANT FIXTURE paidorder: delivery task not open for %', t.key; end if;
    -- the pay path's own notification row (unkeyed by order: exact tuple incl. branch and the fixture room; order numbers repeat across hotels). Cancel must leave it unchanged.
    select count(*) into n from notifications x where x.organization_id = t.org and x.branch_id = t.branch_id and x.audience = 'supervisor' and x.link = '/staff/housekeeping'
       and x.title = 'تسليم طلب منتجات' and x.body = o.number || ' — غرفة ' || (select room_number from rooms where id = rm);
    if n <> 1 then raise exception 'VARIANT FIXTURE paidorder: pay notification not exactly one row for % (%)', t.key, n; end if;
    insert into iso.created(tbl, id, org, branch, purpose)
      select 'notifications', x.id::text, t.org, t.branch_id, 'paidorder' from notifications x where x.organization_id = t.org and x.branch_id = t.branch_id and x.audience = 'supervisor'
       and x.link = '/staff/housekeeping' and x.title = 'تسليم طلب منتجات' and x.body = o.number || ' — غرفة ' || (select room_number from rooms where id = rm) on conflict do nothing;
    insert into iso.created(tbl, id, org, branch, purpose) values ('product_orders', oid::text, t.org, t.branch_id, 'paidorder'), ('reservations', rid::text, t.org, t.branch_id, 'paidorder'),
      ('financial_vouchers', vid::text, t.org, t.branch_id, 'paidorder'), ('housekeeping_tasks', o.task_id::text, t.org, t.branch_id, 'paidorder'), ('rooms', rm::text, t.org, t.branch_id, 'paidorder'), ('products', pid::text, t.org, t.branch_id, 'paidorder') on conflict do nothing;
  end loop;
end $$;
-- paidordertax variant = paidorder on a stay whose products tax snapshot is ON (15%, tax added on top): the cancel must reverse the tax rows too (source: 0068 fn_staff_pay_product_order / fn_staff_cancel_product_order paid branch)
--   'paidordertax' = its own checked-in stay (own room), one product order paid in cash TODAY: approved cash receipt voucher, not settled, charges not invoiced,
--   delivery task pending. This is what the paid-order cancel branch needs (fn_cancel_voucher reversal, opposite addon/tax charges, task cancel, finance recompute).
--   Built through production RPCs under the hotel owner except the explicit local reservation tax-snapshot UPDATE below.
--   Does not touch the base victim reservations or pending-order victims. This tests cancellation of a stored tax-on state, not the branch snapshot trigger.
do $$
declare t record; own uuid; cat uuid; src uuid; r jsonb; k int := 0; rid uuid; rm uuid; gid uuid; pid uuid; oid uuid; o product_orders%rowtype; vid uuid; n int;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    own := case when t.hotel = 'hotel-a' then 'a4000000-0000-0000-0000-0000000000a1' else 'a4000000-0000-0000-0000-0000000000b1' end::uuid;
    select c.id into cat from room_categories c where c.organization_id = t.org and c.branch_id = t.branch_id order by c.id limit 1;
    select b.id into src from booking_sources b where b.organization_id = t.org and b.kind = 'direct' and b.is_active order by b.id limit 1;
    perform iso.set_claims(own);
    set local role authenticated;
    -- a dedicated product (never the base victim product, whose availability row is part of the table fixtures) made available for this branch through the production RPCs
    r := fn_admin_upsert_product_category(jsonb_build_object('name', 'ISO paidtax ' || t.key));
    r := fn_admin_upsert_product(jsonb_build_object('category_id', r->>'id', 'name', 'ISO paidtax item ' || t.key, 'price_halalas', 7000 + k, 'taxable', true));
    pid := (r->>'id')::uuid;
    perform fn_admin_set_product_branch(pid, t.branch_id, true);
    r := fn_staff_create_reservation(jsonb_build_object('source_id', src, 'branch_id', t.branch_id, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 2)::text,
           'guest_phone', '05515' || lpad(k::text, 5, '9'), 'guest_name', 'Paidord ' || repeat(chr(96 + k), 4)));
    rid := (r->>'id')::uuid;
    -- setup DML (local fixture only): the reservation's own products-tax snapshot column, which the production snapshot trigger fills from the branch; only this stay is changed
    reset role;
    update reservations set tax_products_rate_bp = 1500, prices_include_tax = false where id = rid;
    perform iso.set_claims(own);
    set local role authenticated;
    perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 21000 + k * 7, 'method', 'cash', 'idempotency_key', 'isopot-room-' || k));
    rm := (fn_admin_upsert_room(jsonb_build_object('branch_id', t.branch_id, 'category_id', cat, 'room_number', '6' || lpad(k::text, 2, '0')))->>'id')::uuid;
    r := fn_staff_assign_room(rid, rm);
    select g.id into gid from reservation_guests g where g.reservation_id = rid and g.is_primary limit 1;
    r := fn_staff_enter_guest(jsonb_build_object('reservation_id', rid, 'guest_id', gid, 'full_name', 'Paidord ' || repeat(chr(96 + k), 4) || ' Alharbi', 'identity_type', 'national_id',
           'identity_number', '10000200' || lpad(k::text, 2, '0'), 'nationality', 'SA', 'birth_date', '1990-01-01', 'document_matched', true));
    r := fn_staff_approve_identity(gid, true);
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'register', 'reference', 'ISOPT' || k, 'all_guests', true));
    r := fn_staff_shomoos(jsonb_build_object('reservation_id', rid, 'action', 'accept'));
    r := fn_staff_check_in(jsonb_build_object('reservation_id', rid));
    if (r->>'ok')::boolean is not true and r->>'duplicate' is null then raise exception 'VARIANT FIXTURE paidorder CHECKIN BLOCKED: % %', t.key, r; end if;
    r := fn_staff_create_product_order(rid, jsonb_build_array(jsonb_build_object('product_id', pid, 'quantity', 1)));
    oid := coalesce((r->>'id')::uuid, (r->'order'->>'id')::uuid);
    select * into o from product_orders where id = oid;
    r := fn_staff_pay_product_order(jsonb_build_object('order_id', oid, 'method', 'cash', 'idempotency_key', 'isopot-pay-' || k, 'expected_version', o.version));
    reset role;
    select * into o from product_orders where id = oid;
    vid := o.voucher_id;
    if o.status is distinct from 'paid' or vid is null or o.task_id is null or o.organization_id is distinct from t.org or o.branch_id is distinct from t.branch_id then
      raise exception 'VARIANT FIXTURE paidorder: order not paid as required for %', t.key;
    end if;
    if not exists (select 1 from financial_vouchers v where v.id = vid and v.status = 'approved' and v.kind = 'receipt' and v.method = 'cash' and v.product_order_id = o.id
                    and fn_branch_date(v.branch_id, v.occurred_at) = fn_branch_today(v.branch_id) and not fn_voucher_settled(v.id)) then
      raise exception 'VARIANT FIXTURE paidorder: voucher is not an approved unsettled cash receipt of today for %', t.key;
    end if;
    if not exists (select 1 from reservation_charges c where c.product_order_id = o.id and c.kind = 'tax' and c.total_halalas > 0) then raise exception 'VARIANT FIXTURE paidordertax: no tax charge row for %', t.key; end if;
    select count(*) into n from reservation_charges c where c.product_order_id = o.id and c.invoice_id is null and c.total_halalas > 0;
    if n < 1 or exists (select 1 from reservation_charges c where c.product_order_id = o.id and c.invoice_id is not null) then raise exception 'VARIANT FIXTURE paidorder: charges missing or invoiced for %', t.key; end if;
    if not exists (select 1 from housekeeping_tasks h where h.id = o.task_id and h.status in ('pending', 'in_progress')) then raise exception 'VARIANT FIXTURE paidorder: delivery task not open for %', t.key; end if;
    -- the pay path's own notification row (unkeyed by order: exact tuple incl. branch and the fixture room; order numbers repeat across hotels). Cancel must leave it unchanged.
    select count(*) into n from notifications x where x.organization_id = t.org and x.branch_id = t.branch_id and x.audience = 'supervisor' and x.link = '/staff/housekeeping'
       and x.title = 'تسليم طلب منتجات' and x.body = o.number || ' — غرفة ' || (select room_number from rooms where id = rm);
    if n <> 1 then raise exception 'VARIANT FIXTURE paidorder: pay notification not exactly one row for % (%)', t.key, n; end if;
    insert into iso.created(tbl, id, org, branch, purpose)
      select 'notifications', x.id::text, t.org, t.branch_id, 'paidordertax' from notifications x where x.organization_id = t.org and x.branch_id = t.branch_id and x.audience = 'supervisor'
       and x.link = '/staff/housekeeping' and x.title = 'تسليم طلب منتجات' and x.body = o.number || ' — غرفة ' || (select room_number from rooms where id = rm) on conflict do nothing;
    insert into iso.created(tbl, id, org, branch, purpose) values ('product_orders', oid::text, t.org, t.branch_id, 'paidordertax'), ('reservations', rid::text, t.org, t.branch_id, 'paidordertax'),
      ('financial_vouchers', vid::text, t.org, t.branch_id, 'paidordertax'), ('housekeeping_tasks', o.task_id::text, t.org, t.branch_id, 'paidordertax'), ('rooms', rm::text, t.org, t.branch_id, 'paidordertax'), ('products', pid::text, t.org, t.branch_id, 'paidordertax') on conflict do nothing;
  end loop;
end $$;
