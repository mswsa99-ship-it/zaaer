-- =====================================================================
-- Core acceptance tests (ZAAER-TESTING-AND-CONTROL-RULES §9): property
-- definitions, allocations/overlap, stay amendments, financial ledger,
-- housekeeping, branch isolation. Runs after security_tests.sql on the same DB.
-- Concurrency scenarios X01/X02 live in tests/sql/concurrency.sh (two sessions).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;

create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
-- current version of a row (security definer: readable regardless of the caller's role) — A06 strict versioning
create or replace function t_ver(p_table text, p_id uuid) returns int language plpgsql security definer as $$ declare v int; begin execute format('select version from %I where id = $1', p_table) into v using p_id; return v; end $$;
create or replace function t_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance(p) $$;
create or replace function t_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
create or replace function t_room(p uuid) returns rooms language sql security definer as $$ select * from rooms where id = p $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;

-- ---------- fixtures (synthetic) ----------
-- owner 10..01 (all branches), supervisor 10..02 (branch 10), housekeeping 10..03 (branch 10), finance 10..04 (branch 10)
-- branch B of the same org + a supervisor limited to it; a non-staff authenticated user; a deactivated staff
insert into branches(id, organization_id, name_ar, tax_rate_bp) values ('00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001','فرع B (اختبار)', 1500) on conflict do nothing;
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role, is_active) values
 ('10000000-0000-0000-0000-000000000006','a0000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000001','استقبال B','supB@test.local','supervisor', true),
 ('10000000-0000-0000-0000-000000000007','a0000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000001','موظف معطل','off@test.local','supervisor', false),
 ('10000000-0000-0000-0000-000000000008','a0000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000001','مدير','mgr@test.local','manager', true)
on conflict (id) do nothing;
insert into branch_memberships(staff_id, branch_id) values
 ('10000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000012'),
 ('10000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000010'),
 ('10000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000010')
on conflict do nothing;
insert into room_categories(id, branch_id, organization_id, name_ar, base_capacity, max_capacity, base_price_halalas) values
 ('00000000-0000-0000-0000-000000000039','00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001','نوع فرع B',2,4,20000) on conflict do nothing;
insert into rooms(id, branch_id, organization_id, category_id, room_number, is_active) values
 ('00000000-0000-0000-0000-000000000199','00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000039','B-1', true) on conflict do nothing;
insert into task_types(organization_id, branch_id, code, name) values ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000012','room_cleaning','تنظيف') on conflict do nothing;

set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');

-- =====================================================================
-- A. Definitions
-- =====================================================================
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_block('{"branch_id":"00000000-0000-0000-0000-000000000010","name":"مبنى U","description":"اختبار"}');
  insert into ids values ('block', (r->>'id')::uuid);
  r := fn_admin_upsert_floor(jsonb_build_object('block_id', (select v from ids where k='block'), 'name', 'B', 'sort_order', 1));
  insert into ids values ('floor', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','block_id',(select v from ids where k='block'),'floor_id',(select v from ids where k='floor'),'room_number','U-B-1'));
  insert into ids values ('room1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','block_id',(select v from ids where k='block'),'floor_id',(select v from ids where k='floor'),'room_number','U-B-2'));
  insert into ids values ('room2', (r->>'id')::uuid);
  perform t_record('A01 block → textual floor "B" → rooms linked', (select name from floors where id = (select v from ids where k='floor')) = 'B' and (select floor_id from rooms where id = (select v from ids where k='room1')) = (select v from ids where k='floor'));
exception when others then perform t_record('A01 block → textual floor "B" → rooms linked', false, sqlerrm); end $$;

do $$ declare r jsonb; fB uuid; begin
  r := fn_admin_upsert_block('{"branch_id":"00000000-0000-0000-0000-000000000012","name":"مبنى فرع B"}');
  r := fn_admin_upsert_floor(jsonb_build_object('block_id', (r->>'id')::uuid, 'name', 'G'));
  fB := (r->>'id')::uuid;
  begin
    perform fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','floor_id', fB,'room_number','X-1'));
    perform t_record('A02 room linked to a floor of another branch rejected', false, 'accepted');
  exception when others then perform t_record('A02 room linked to a floor of another branch rejected', sqlerrm like '%BRANCH_MISMATCH%', sqlerrm); end;
end $$;

do $$ begin
  perform fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','room_number','U-B-1'));
  perform t_record('A03 duplicate room number rejected', false, 'accepted');
exception when others then perform t_record('A03 duplicate room number rejected', sqlerrm like '%DUPLICATE_ROOM_NUMBER%' and (select count(*) from rooms where room_number='U-B-1') = 1, sqlerrm); end $$;

do $$ declare r jsonb; begin
  r := fn_admin_delete_definition('room_category', '00000000-0000-0000-0000-000000000030');
  perform t_record('A05 deleting a category with rooms is blocked (dependencies listed), rooms intact',
    (r->>'ok')::boolean = false and r->>'error' = 'HAS_DEPENDENCIES' and (r->'dependencies'->>'rooms')::int > 0 and (select count(*) from rooms where category_id='00000000-0000-0000-0000-000000000030') > 0, r::text);
end $$;

-- A06/A07/A08 facility + service lifecycle
do $$ declare r jsonb; fac uuid; svc uuid; t uuid; begin
  r := fn_admin_upsert_facility('{"branch_id":"00000000-0000-0000-0000-000000000010","name":"جلسة خارجية"}'); fac := (r->>'id')::uuid;
  r := fn_hk_create_task(jsonb_build_object('facility_id', fac, 'task_type_id', '00000000-0000-0000-0000-000000000422')); t := (r->>'id')::uuid;
  begin
    perform fn_admin_archive_definition('facility', fac, 'اختبار');
    perform t_record('A06a facility with OPEN task cannot be archived', false, 'archived');
  exception when others then perform t_record('A06a facility with OPEN task cannot be archived', sqlerrm like '%HAS_OPEN_COMMITMENTS%', sqlerrm); end;
  perform fn_hk_complete_task(t, 'تم', t_ver('housekeeping_tasks', t));
  r := fn_admin_archive_definition('facility', fac, 'لم يعد مستخدمًا');
  perform t_record('A06b facility with completed task archived; history kept', (select archived_at is not null from facilities where id = fac) and (select count(*) from housekeeping_tasks where facility_id = fac) = 1);
  r := fn_admin_delete_definition('facility', fac);
  perform t_record('A06c facility with task history cannot be hard-deleted', (r->>'ok')::boolean = false and r->>'error' = 'HAS_DEPENDENCIES', r::text);

  r := fn_admin_upsert_service('{"branch_id":"00000000-0000-0000-0000-000000000010","name_ar":"خدمة مؤقتة","price_halalas":1000}'); svc := (r->>'id')::uuid;
  r := fn_admin_delete_definition('service', svc);
  perform t_record('A07 unused service hard-deleted with audit', (r->>'ok')::boolean and (select count(*) from service_definitions where id = svc) = 0
    and (select count(*) from audit_events where entity_id = svc and action = 'service.deleted') = 1, r::text);
end $$;

-- A09: deactivating a room with a future allocation
do $$ declare r jsonb; res uuid; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
        'room_id',(select v from ids where k='room2'),'check_in',(current_date + 10)::text,'check_out',(current_date + 12)::text,'guest_name','ضيف اختبار','guest_phone','0500000001',
        'source_id','00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid; insert into ids values ('res_future', res);
  perform t_record('RS01 future allocation does not flag the room reserved today; readiness is computed (no stale available)',
    (t_room((select v from ids where k='room2'))).status not in ('reserved','available'), (t_room((select v from ids where k='room2'))).status::text);
  begin
    perform fn_admin_upsert_room(jsonb_build_object('id', (select v from ids where k='room2'), 'is_active', false, 'version', t_ver('rooms', (select v from ids where k='room2'))));
    perform t_record('A09 deactivating a room with a future reservation blocked', false, 'accepted');
  exception when others then perform t_record('A09 deactivating a room with a future reservation blocked', sqlerrm like '%HAS_FUTURE_COMMITMENTS%', sqlerrm); end;
end $$;

-- =====================================================================
-- R. Reservation core
-- =====================================================================
-- R01 partial overlap on the same unit
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
        'room_id',(select v from ids where k='room1'),'check_in',(current_date + 1)::text,'check_out',(current_date + 3)::text,'guest_name','ضيف أ','guest_phone','0500000002','source_id','00000000-0000-0000-0000-000000000021'));
  insert into ids values ('resA', (r->>'id')::uuid);
  begin
    r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
          'room_id',(select v from ids where k='room1'),'check_in',(current_date + 2)::text,'check_out',(current_date + 4)::text,'guest_name','ضيف ب','guest_phone','0500000003','source_id','00000000-0000-0000-0000-000000000021'));
    perform t_record('R01 partially overlapping allocation of same unit rejected', false, 'accepted');
  exception when others then
    perform t_record('R01 partially overlapping allocation of same unit rejected', sqlerrm like '%ROOM_NOT_AVAILABLE%' or sqlerrm like '%ALLOCATION_CONFLICT%', sqlerrm);
  end;
  -- no orphan charges for the failed reservation
  perform t_record('R01b failed reservation leaves no orphan rows', (select count(*) from reservations where room_id = (select v from ids where k='room1')) = 1);
end $$;
-- R03 back-to-back [10,12) then [12,14) allowed (half-open)
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
        'room_id',(select v from ids where k='room1'),'check_in',(current_date + 3)::text,'check_out',(current_date + 5)::text,'guest_name','ضيف ج','guest_phone','0500000004','source_id','00000000-0000-0000-0000-000000000021'));
  insert into ids values ('resC', (r->>'id')::uuid);
  perform t_record('R03 reservation starting at previous end accepted (half-open interval)', (r->>'ok')::boolean, r::text);
exception when others then perform t_record('R03 reservation starting at previous end accepted (half-open interval)', false, sqlerrm); end $$;

-- R04 extension into a booked period: nothing changes
do $$ declare before_res reservations; after_res reservations; n_before int; n_after int; begin
  before_res := t_res((select v from ids where k='resA'));
  select count(*) into n_before from reservation_charges where reservation_id = before_res.id;
  begin
    perform fn_staff_amend_stay(before_res.id, current_date + 4, 'keep_rate', 'طلب الضيف', t_ver('reservations', before_res.id));
    perform t_record('R04 extension into booked period rejected; no partial update', false, 'accepted');
  exception when others then
    after_res := t_res(before_res.id);
    select count(*) into n_after from reservation_charges where reservation_id = before_res.id;
    perform t_record('R04 extension into booked period rejected; no partial update', sqlerrm like '%ALLOCATION_CONFLICT%' and after_res.check_out = before_res.check_out and after_res.total_halalas = before_res.total_halalas and n_after = n_before, sqlerrm);
  end;
end $$;
-- R05 valid extension: date, allocation, price move together
do $$ declare r jsonb; res reservations; a record; begin
  res := t_res((select v from ids where k='resC'));
  r := fn_staff_amend_stay(res.id, res.check_out + 1, 'keep_rate', 'تمديد ليلة', t_ver('reservations', res.id));
  res := t_res(res.id);
  select * into a from reservation_allocations where reservation_id = res.id and status = 'active';
  perform t_record('R05 extension: check_out, allocation, rent charge and total consistent',
    res.check_out = a.to_date and res.total_halalas = (t_fin(res.id)->>'total')::bigint
    and (select count(*) from reservation_charges where reservation_id = res.id and kind = 'rent') = 2
    and (select count(*) from audit_events where entity_id = res.id and action = 'reservation.departure_changed') = 1, r::text);
exception when others then perform t_record('R05 extension: check_out, allocation, rent charge and total consistent', false, sqlerrm); end $$;

-- R06 switch to a room of another branch
do $$ begin
  perform fn_staff_switch_room((select v from ids where k='resA'), '00000000-0000-0000-0000-000000000199', null, 'اختبار', t_ver('reservations', (select v from ids where k='resA')));
  perform t_record('R06 switch to a unit of another branch rejected', false, 'accepted');
exception when others then perform t_record('R06 switch to a unit of another branch rejected', sqlerrm like '%ROOM_NOT_FOUND%', sqlerrm); end $$;

-- R07 switch during stay keeps history
do $$ declare r jsonb; res reservations; room3 uuid; begin
  r := fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','room_number','U-B-3')); room3 := (r->>'id')::uuid;
  insert into ids values ('room3', room3);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
        'room_id', room3,'check_in',(current_date - 1)::text,'check_out',(current_date + 2)::text,'guest_name','ضيف مقيم','guest_phone','0500000005','source_id','00000000-0000-0000-0000-000000000021'));
  insert into ids values ('resIn', (r->>'id')::uuid);
  -- simulate check-in (gate flow is covered by security_tests)
  reset role;
  update reservations set status = 'checked_in', actual_check_in = now() where id = (r->>'id')::uuid;
  update rooms set status = 'occupied' where id = room3;
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  r := fn_staff_switch_room((r->>'id')::uuid, (select v from ids where k='room2'), current_date, 'عطل تكييف', t_ver('reservations', (r->>'id')::uuid));
  res := t_res((select v from ids where k='resIn'));
  perform t_record('R07 mid-stay switch: old allocation closed, new active, old room dirty + cleaning task, new room occupied',
    (select count(*) from reservation_allocations where reservation_id = res.id and status in ('closed','cancelled') and room_id = room3) = 1
    and (select count(*) from reservation_allocations where reservation_id = res.id and status = 'active' and room_id = (select v from ids where k='room2')) = 1
    and (t_room(room3)).cleanliness = 'dirty' and (t_room((select v from ids where k='room2'))).status = 'occupied'
    and (select count(*) from housekeeping_tasks where room_id = room3 and status = 'pending') = 1
    and (r->>'entry_code_review_required')::boolean, r::text);
exception when others then perform t_record('R07 mid-stay switch: old allocation closed, new active, old room dirty + cleaning task, new room occupied', false, sqlerrm); end $$;

-- R08 supervisor discount after arrival rejected / R09 manager discount with reason audited
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ begin
  perform fn_staff_adjust_price((select v from ids where k='resIn'), 'discount', 5000, 'خصم', 'سبب', t_ver('reservations', (select v from ids where k='resIn')));
  perform t_record('R08 supervisor cannot apply discount after arrival', false, 'accepted');
exception when others then perform t_record('R08 supervisor cannot apply discount after arrival', sqlerrm like '%FORBIDDEN%', sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000008','mgr@test.local');
do $$ declare r jsonb; before_total bigint; e audit_events; begin
  before_total := (t_res((select v from ids where k='resIn'))).total_halalas;
  r := fn_staff_adjust_price((select v from ids where k='resIn'), 'discount', 5000, 'خصم تعويض', 'عطل تكييف', t_ver('reservations', (select v from ids where k='resIn')));
  select * into e from audit_events where entity_id = (select v from ids where k='resIn') and action = 'reservation.total_changed' order by created_at desc limit 1;
  perform t_record('R09 manager discount with reason: total reduced, before/after + reason audited',
    (t_res((select v from ids where k='resIn'))).total_halalas < before_total and (e.details->'before'->>'total_halalas')::bigint = before_total and e.details->>'reason' = 'عطل تكييف', r::text);
exception when others then perform t_record('R09 manager discount with reason: total reduced, before/after + reason audited', false, sqlerrm); end $$;
do $$ begin
  perform fn_staff_adjust_price((select v from ids where k='resIn'), 'discount', 5000, 'خصم', '', t_ver('reservations', (select v from ids where k='resIn')));
  perform t_record('R09b price change without reason rejected', false, 'accepted');
exception when others then perform t_record('R09b price change without reason rejected', sqlerrm like '%reason%', sqlerrm); end $$;

-- R10 no-show on checked_in rejected
do $$ begin
  perform fn_staff_no_show((select v from ids where k='resIn'), 'لم يحضر');
  perform t_record('R10 no-show for a checked-in reservation rejected', false, 'accepted');
exception when others then perform t_record('R10 no-show for a checked-in reservation rejected', sqlerrm like '%RESERVATION_STATUS_INVALID%', sqlerrm); end $$;

-- R12 duplicate external ref for same source
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000031',
        'check_in',(current_date + 20)::text,'check_out',(current_date + 22)::text,'guest_name','ضيف OTA','guest_phone','0500000006','source_id','00000000-0000-0000-0000-000000000020','external_ref','OTA-TEST-1'));
  insert into ids values ('resOTA', (r->>'id')::uuid);
  begin
    r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000031',
          'check_in',(current_date + 20)::text,'check_out',(current_date + 22)::text,'guest_name','ضيف OTA','guest_phone','0500000006','source_id','00000000-0000-0000-0000-000000000020','external_ref','OTA-TEST-1'));
    perform t_record('R12 duplicate (source, external_ref) rejected', false, 'accepted');
  exception when others then perform t_record('R12 duplicate (source, external_ref) rejected', sqlerrm like '%DUPLICATE_EXTERNAL_REF%', sqlerrm); end;
  begin
    r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000031',
          'check_in',(current_date + 20)::text,'check_out',(current_date + 22)::text,'guest_name','ضيف','source_id','00000000-0000-0000-0000-000000000020'));
    perform t_record('R12b external source without external_ref rejected', false, 'accepted');
  exception when others then perform t_record('R12b external source without external_ref rejected', sqlerrm like '%external_ref_required%', sqlerrm); end;
end $$;
-- R11 duplicate OTA cancellation event → one cancel, no refund
do $$ declare r1 jsonb; r2 jsonb; res uuid := (select v from ids where k='resOTA'); begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 10000, 'method','ota_deferred','reference','OTA-PAY-1','idempotency_key','k-ota-1'));
  r1 := fn_staff_cancel_reservation(res, 'إلغاء من المنصة', 'booking_com', 'EVT-1');
  r2 := fn_staff_cancel_reservation(res, 'إلغاء من المنصة', 'booking_com', 'EVT-1');
  perform t_record('R11 duplicate OTA cancel event processed once; no implicit refund; refund flagged as separate action',
    (r1->>'duplicate')::boolean = false and (r2->>'duplicate')::boolean and (t_res(res)).status = 'cancelled'
    and (select count(*) from financial_vouchers where reservation_id = res and kind = 'refund') = 0 and (r1->>'refund_required_separately')::boolean
    and (select count(*) from audit_events where entity_id = res and action = 'reservation.cancelled') = 1
    and (select count(*) from reservation_allocations where reservation_id = res and status = 'active') = 0, r1::text || r2::text);
exception when others then perform t_record('R11 duplicate OTA cancel event processed once; no implicit refund; refund flagged as separate action', false, sqlerrm); end $$;

-- R14 checkout twice → one cleaning task, no deposit refund
do $$ declare r1 jsonb; r2 jsonb; res uuid := (select v from ids where k='resIn'); room uuid := (select v from ids where k='room2'); begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','deposit','amount_halalas', 20000, 'method','cash','idempotency_key','k-dep-in'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', (t_fin(res)->>'balance_due')::bigint, 'method','cash','idempotency_key','k-rcp-in'));
  r1 := fn_staff_checkout(res);
  r2 := fn_staff_checkout(res);
  perform t_record('R14 repeated checkout: single transition, one cleaning task, deposit NOT auto-refunded',
    (r1->>'ok')::boolean and (r2->>'duplicate')::boolean and (select count(*) from housekeeping_tasks where room_id = room and reservation_id = res and status = 'pending') = 1
    and (t_fin(res)->>'deposit_balance')::bigint = 20000 and (r1->>'deposit_to_settle_halalas')::bigint = 20000
    and (select count(*) from reservation_allocations where reservation_id = res and status = 'active') = 0 and (t_room(room)).status = 'cleaning', r1::text);
exception when others then perform t_record('R14 repeated checkout: single transition, one cleaning task, deposit NOT auto-refunded', false, sqlerrm); end $$;

-- =====================================================================
-- F. Money (branch with tax 0 for exact arithmetic; tax policy tested separately)
-- =====================================================================
do $$ declare r jsonb; b uuid; cat uuid; res uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الاختبار المالي","tax_rate_bp":0}'); b := (r->>'id')::uuid; insert into ids values ('branchF', b);
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar','قياسي','base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', current_date::text, 'check_out', (current_date + 3)::text, 'guest_name','ضيف مالي','guest_phone','0500000007','source_id','00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid; insert into ids values ('resF', res);
  perform t_record('F01a total = 3 nights × 100 = 300.00 SAR (30000 halalas), status pending', (t_fin(res)->>'total')::bigint = 30000 and t_fin(res)->>'payment_status' = 'pending', t_fin(res)::text);
exception when others then perform t_record('F01a total = 3 nights × 100 = 300.00 SAR (30000 halalas), status pending', false, sqlerrm); end $$;

do $$ declare res uuid := (select v from ids where k='resF'); f jsonb; begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 10000, 'method','cash','idempotency_key','kF1'));
  f := t_fin(res);
  perform t_record('F01 receipt 100 of 300 → partially_paid, due 200', f->>'payment_status' = 'partially_paid' and (f->>'balance_due')::bigint = 20000, f::text);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','deposit','amount_halalas', 10000, 'method','pos','reference','MADA-1','idempotency_key','kF2'));
  f := t_fin(res);
  perform t_record('F02 deposit 100 does not settle the stay: due still 200, deposit balance 100', (f->>'balance_due')::bigint = 20000 and (f->>'deposit_balance')::bigint = 10000 and f->>'payment_status' = 'partially_paid', f::text);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 20000, 'method','cash','idempotency_key','kF3'));
  f := t_fin(res);
  perform t_record('F03 receipt 200 → paid, derived from ledger', f->>'payment_status' = 'paid' and (f->>'balance_due')::bigint = 0 and (t_res(res)).payment_status = 'paid', f::text);
  perform fn_refund(jsonb_build_object('reservation_id', res, 'kind','deposit_refund','amount_halalas', 6000, 'method','cash','reason','مغادرة دون أضرار','idempotency_key','kF4'));
  f := t_fin(res);
  perform t_record('F04 deposit refund 60 → deposit balance 40, stay revenue unchanged', (f->>'deposit_balance')::bigint = 4000 and (f->>'net_collected')::bigint = 30000 and f->>'payment_status' = 'paid', f::text);
  begin
    perform fn_refund(jsonb_build_object('reservation_id', res, 'kind','deposit_refund','amount_halalas', 5000, 'method','cash','reason','x','idempotency_key','kF5'));
    perform t_record('F05 deposit refund 50 > available 40 rejected', false, 'accepted');
  exception when others then perform t_record('F05 deposit refund 50 > available 40 rejected', sqlerrm like '%REFUND_EXCEEDS_AVAILABLE%' and (t_fin(res)->>'deposit_balance')::bigint = 4000, sqlerrm); end;
end $$;

-- F07/F08 idempotency
do $$ declare res uuid := (select v from ids where k='resF'); r1 jsonb; r2 jsonb; begin
  r1 := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 500, 'method','cash','idempotency_key','kF7'));
  r2 := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 500, 'method','cash','idempotency_key','kF7'));
  perform t_record('F07 same key + same content → one voucher, same result', (r2->>'duplicate')::boolean and r1->>'voucher_id' = r2->>'voucher_id' and (select count(*) from financial_vouchers where idempotency_key = 'kF7') = 1, r2::text);
  begin
    perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 999, 'method','cash','idempotency_key','kF7'));
    perform t_record('F08 same key + different amount rejected', false, 'accepted');
  exception when others then perform t_record('F08 same key + different amount rejected', sqlerrm like '%IDEMPOTENCY_CONFLICT%', sqlerrm); end;
  begin
    perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 0, 'method','cash','idempotency_key','kF9a'));
    perform t_record('F09 zero amount rejected', false, 'accepted');
  exception when others then perform t_record('F09 zero amount rejected', sqlerrm like '%amount%', sqlerrm); end;
  begin
    perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', -100, 'method','cash','idempotency_key','kF9b'));
    perform t_record('F09b negative amount rejected', false, 'accepted');
  exception when others then perform t_record('F09b negative amount rejected', sqlerrm like '%amount%', sqlerrm); end;
end $$;

-- F11 cancel voucher: reversal with history
do $$ declare res uuid := (select v from ids where k='resF'); vid uuid; f jsonb; r jsonb; begin
  select id into vid from financial_vouchers where idempotency_key = 'kF7';
  r := fn_cancel_voucher(vid, 'قيد خاطئ');
  f := t_fin(res);
  perform t_record('F11 cancelled voucher reverses effect, row kept with reason', (select status from financial_vouchers where id = vid) = 'cancelled' and (f->>'credit')::bigint = 0 and f->>'payment_status' = 'paid'
    and (select cancel_reason from financial_vouchers where id = vid) = 'قيد خاطئ', f::text);
  -- cancelling the deposit voucher now would make the deposit ledger negative (60 already refunded of 100)
  select id into vid from financial_vouchers where idempotency_key = 'kF2';
  begin
    perform fn_cancel_voucher(vid, 'x');
    perform t_record('F11b cancelling a deposit that was partly refunded rejected (would go negative)', false, 'accepted');
  exception when others then perform t_record('F11b cancelling a deposit that was partly refunded rejected (would go negative)', sqlerrm like '%CANCEL_WOULD_GO_NEGATIVE%', sqlerrm); end;
end $$;

-- F12/F13 invoices: snapshot immutable, no double invoicing
do $$ declare res uuid := (select v from ids where k='resF'); b uuid := (select v from ids where k='branchF'); svc uuid; r jsonb; inv uuid; snap jsonb; begin
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', b, 'name_ar','إفطار','price_halalas', 2500, 'billing_unit','once','taxable', false)); svc := (r->>'id')::uuid;
  perform fn_staff_add_service(res, svc, 1);
  r := fn_create_invoice(res); inv := (r->>'id')::uuid;
  snap := (select snapshot from invoices where id = inv);
  perform fn_admin_upsert_service(jsonb_build_object('id', svc, 'name_ar','إفطار فاخر','price_halalas', 9900, 'version', t_ver('service_definitions', svc)));
  perform t_record('F12 catalogue edit after invoicing: invoice snapshot and historical charge unchanged',
    (select snapshot from invoices where id = inv) = snap and (r->>'total_halalas')::bigint = 32500
    and (select total_halalas from reservation_charges where reservation_id = res and service_definition_id = svc) = 2500
    and (select name_ar from service_definitions where id = svc) = 'إفطار فاخر', r::text);
  begin
    perform fn_create_invoice(res);
    perform t_record('F13 invoicing the same lines again rejected', false, 'accepted');
  exception when others then perform t_record('F13 invoicing the same lines again rejected', sqlerrm like '%NOTHING_TO_INVOICE%', sqlerrm); end;
end $$;

-- X07 money units & rounding (decision 47). Every expected value below is worked out by hand, not by the functions.
-- X07a the rules' own case, tax zero: 3 × 100.05 − 0.10 = 300.05 SAR exactly; 100.01 + 200.04 leaves exactly zero;
--      a 50 SAR deposit does not change the charges.
do $$ declare q jsonb; r jsonb; res uuid; f jsonb; begin
  q := fn_staff_quote('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000030', current_date + 30, current_date + 33, 10005, 10);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
        'check_in',(current_date + 30)::text,'check_out',(current_date + 33)::text,'guest_name','ضيف التقريب','source_id','00000000-0000-0000-0000-000000000021',
        'nightly_rate_halalas', 10005, 'discount_halalas', 10, 'discount_reason', 'خصم ثابت للاختبار'));
  res := (r->>'id')::uuid; insert into ids values ('resX07', res);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 10001, 'method','cash','idempotency_key','kX07-1'));
  f := t_fin(res);
  perform t_record('X07a1 tax zero: 3 × 100.05 − 0.10 = 30005 halalas exactly, no tax line; 100.01 received leaves 20004 and is partly paid',
    (q->>'total')::bigint = 30005 and (q->>'tax')::bigint = 0 and (f->>'total')::bigint = 30005 and (f->>'tax')::bigint = 0
    and (select count(*) from reservation_charges where reservation_id = res and kind = 'tax') = 0
    and (f->>'balance_due')::bigint = 20004 and f->>'payment_status' = 'partially_paid', q::text || ' / ' || f::text);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 20004, 'method','cash','idempotency_key','kX07-2'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','deposit','amount_halalas', 5000, 'method','cash','idempotency_key','kX07-3'));
  f := t_fin(res);
  perform t_record('X07a2 then 200.04 leaves exactly zero (paid); a 50.00 deposit is held apart and changes no charge',
    (f->>'balance_due')::bigint = 0 and (f->>'credit')::bigint = 0 and f->>'payment_status' = 'paid' and (f->>'total')::bigint = 30005
    and (f->>'deposit_balance')::bigint = 5000 and (f->>'net_collected')::bigint = 30005, f::text);
exception when others then perform t_record('X07a1 tax zero: 3 × 100.05 − 0.10 = 30005 halalas exactly, no tax line; 100.01 received leaves 20004 and is partly paid', false, sqlerrm); end $$;

-- X07b a synthetic tax policy set by the owner for this test only: 15% on top of the price (exclusive).
--      rent 30015 → tax round(4502.25) = 4502; discount −10 → tax round(−1.5) = −2 (half away from zero);
--      total = 30015 − 10 + 4502 − 2 = 34505. A reservation keeps the policy it was made under (decision 68).
do $$ declare v int; q jsonb; r jsonb; res uuid; f jsonb; begin
  v := (select version from branches where id = '00000000-0000-0000-0000-000000000010');
  perform fn_admin_upsert_branch(jsonb_build_object('id','00000000-0000-0000-0000-000000000010','name_ar',(select name_ar from branches where id = '00000000-0000-0000-0000-000000000010'),
          'version', v, 'tax_rate_bp', 1500, 'prices_include_tax', false));
  q := fn_staff_quote('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000030', current_date + 40, current_date + 43, 10005, 10);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030',
        'check_in',(current_date + 40)::text,'check_out',(current_date + 43)::text,'guest_name','ضيف الضريبة','source_id','00000000-0000-0000-0000-000000000021',
        'nightly_rate_halalas', 10005, 'discount_halalas', 10, 'discount_reason', 'خصم ثابت للاختبار'));
  res := (r->>'id')::uuid; insert into ids values ('resX07b', res);
  f := t_fin(res);
  perform t_record('X07b1 15% exclusive: rent 30015, discount −10, tax 4502 − 2 = 4500, total 34505 — quote and reservation agree',
    (q->>'rent')::bigint = 30015 and (q->>'discount')::bigint = -10 and (q->>'tax')::bigint = 4500 and (q->>'total')::bigint = 34505
    and (f->>'total')::bigint = 34505 and (f->>'tax')::bigint = 4500 and (t_res(res)).tax_rate_bp = 1500, q::text || ' / ' || f::text);
  -- back to zero: the reservation made under 15% keeps 15% for what is added to it; a new one has no tax
  v := (select version from branches where id = '00000000-0000-0000-0000-000000000010');
  perform fn_admin_upsert_branch(jsonb_build_object('id','00000000-0000-0000-0000-000000000010','name_ar',(select name_ar from branches where id = '00000000-0000-0000-0000-000000000010'),
          'version', v, 'tax_rate_bp', 0));
  perform fn_staff_adjust_price(res, 'addon', 1000, 'إضافة بعد تغيير الضريبة', 'اختبار اللقطة', (t_res(res)).version);
  q := fn_staff_quote('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000030', current_date + 40, current_date + 43, 10005, 10);
  perform t_record('X07b2 a change of the tax policy applies to new reservations only: the old one taxes its new line at 15% (150), a new quote has none',
    (t_fin(res)->>'tax')::bigint = 4650 and (q->>'tax')::bigint = 0 and (q->>'total')::bigint = 30005
    and (select count(*) from audit_events where entity_id = '00000000-0000-0000-0000-000000000010' and action = 'branch.tax_changed') >= 2, t_fin(res)::text || ' / ' || q::text);
exception when others then perform t_record('X07b1 15% exclusive: rent 30015, discount −10, tax 4502 − 2 = 4500, total 34505 — quote and reservation agree', false, sqlerrm); end $$;

-- X07c 15% included in the price: 115.00 gross → net round(11500 / 1.15) = 10000, tax 1500
do $$ declare v int; q jsonb; begin
  v := (select version from branches where id = '00000000-0000-0000-0000-000000000010');
  perform fn_admin_upsert_branch(jsonb_build_object('id','00000000-0000-0000-0000-000000000010','name_ar',(select name_ar from branches where id = '00000000-0000-0000-0000-000000000010'),
          'version', v, 'tax_rate_bp', 1500, 'prices_include_tax', true));
  q := fn_staff_quote('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000030', current_date + 50, current_date + 51, 11500, 0);
  perform t_record('X07c 15% included: 115.00 → net 100.00 and tax 15.00, total unchanged at 115.00',
    (q->>'rent')::bigint = 10000 and (q->>'tax')::bigint = 1500 and (q->>'total')::bigint = 11500, q::text);
  v := (select version from branches where id = '00000000-0000-0000-0000-000000000010');
  perform fn_admin_upsert_branch(jsonb_build_object('id','00000000-0000-0000-0000-000000000010','name_ar',(select name_ar from branches where id = '00000000-0000-0000-0000-000000000010'),
          'version', v, 'tax_rate_bp', 0, 'prices_include_tax', false));
exception when others then perform t_record('X07c 15% included: 115.00 → net 100.00 and tax 15.00, total unchanged at 115.00', false, sqlerrm); end $$;

-- =====================================================================
-- H. Housekeeping
-- =====================================================================
do $$ begin
  perform fn_hk_create_task(jsonb_build_object('task_type_id','00000000-0000-0000-0000-000000000420'));
  perform t_record('H01a task without target rejected', false, 'accepted');
exception when others then perform t_record('H01a task without target rejected', sqlerrm like '%one_target%', sqlerrm); end $$;
do $$ begin
  perform fn_hk_create_task(jsonb_build_object('task_type_id','00000000-0000-0000-0000-000000000420','room_id',(select v from ids where k='room1'),'facility_id','00000000-0000-0000-0000-000000000430'));
  perform t_record('H01b task with two targets rejected', false, 'accepted');
exception when others then perform t_record('H01b task with two targets rejected', sqlerrm like '%one_target%', sqlerrm); end $$;
do $$ begin
  perform fn_hk_create_task(jsonb_build_object('task_type_id','00000000-0000-0000-0000-000000000420','room_id',(select v from ids where k='room1'),'assignee_id','10000000-0000-0000-0000-000000000006'));
  perform t_record('H02 assigning to a worker of another branch rejected', false, 'accepted');
exception when others then perform t_record('H02 assigning to a worker of another branch rejected', sqlerrm like '%ASSIGNEE_NOT_IN_BRANCH%', sqlerrm); end $$;

-- H03: completing cleaning on an OCCUPIED room keeps it occupied
do $$ declare r jsonb; t uuid; room uuid := (select v from ids where k='room3'); begin
  reset role;
  update rooms set status = 'occupied', cleanliness = 'dirty' where id = room;
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
  select id into t from housekeeping_tasks where room_id = room and status = 'pending' limit 1;
  r := fn_hk_complete_task(t, 'تم التنظيف', t_ver('housekeeping_tasks', t));
  perform t_record('H03 cleaning completed on occupied room → clean but still occupied', (t_room(room)).cleanliness = 'clean' and (t_room(room)).status = 'occupied' and r->>'room_status' = 'occupied', r::text);
exception when others then perform t_record('H03 cleaning completed on occupied room → clean but still occupied', false, sqlerrm); end $$;
-- H04: facility task completion changes no room
do $$ declare r jsonb; t uuid; before_sig text; after_sig text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  select string_agg(id::text || status::text || cleanliness, ',' order by id) into before_sig from rooms where branch_id = '00000000-0000-0000-0000-000000000010';
  r := fn_hk_create_task(jsonb_build_object('task_type_id','00000000-0000-0000-0000-000000000422','facility_id','00000000-0000-0000-0000-000000000430')); t := (r->>'id')::uuid;
  perform fn_hk_start_task(t);
  perform fn_hk_complete_task(t, null, t_ver('housekeeping_tasks', t));
  select string_agg(id::text || status::text || cleanliness, ',' order by id) into after_sig from rooms where branch_id = '00000000-0000-0000-0000-000000000010';
  perform t_record('H04 facility task lifecycle changes no room state', before_sig = after_sig and (select status from housekeeping_tasks where id = t) = 'completed');
exception when others then perform t_record('H04 facility task lifecycle changes no room state', false, sqlerrm); end $$;
-- H06: clean room whose keybox needs rotation is not "ready" (the unit gets a key box first: decision 7 makes a unit
-- without one ready by cleanliness alone)
do $$ declare room uuid := (select v from ids where k='room2'); t uuid; r jsonb; begin
  perform fn_staff_rotate_keybox_code(room, '2580', true);
  reset role; update keyboxes set code_status = 'needs_change', field_tested = false where room_id = room;
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  select id into t from housekeeping_tasks where room_id = room and status = 'pending' limit 1;
  r := fn_hk_complete_task(t, null, t_ver('housekeeping_tasks', t));
  perform t_record('H06 clean + keybox needs rotation → not ready (cleaning), not available for entry', (t_room(room)).cleanliness = 'clean' and (t_room(room)).status = 'cleaning', r::text);
exception when others then perform t_record('H06 clean + keybox needs rotation → not ready (cleaning), not available for entry', false, sqlerrm); end $$;
-- H06b (decision 7): a unit without a key box is ready as soon as it is clean
do $$ declare r jsonb; room uuid; begin
  r := fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','room_number','U-NOBOX'));
  room := (r->>'id')::uuid;
  perform fn_hk_set_cleanliness(room, 'dirty', 'اختبار');
  r := fn_hk_set_cleanliness(room, 'clean', 'اختبار');
  perform t_record('H06b a unit without a key box is ready when clean (decision 7)', r->>'room_status' = 'ready' and (t_room(room)).status = 'ready', r::text);
exception when others then perform t_record('H06b a unit without a key box is ready when clean (decision 7)', false, sqlerrm); end $$;
-- HC01 (decision 12, with the tests of decision 50): the manual change is free — it no longer waits for an open cleaning
-- task, leaves the task as it is, is recorded with who made it, and the task is still completed afterwards
do $$ declare room uuid := (select v from ids where k='room1'); r jsonb; t uuid; begin
  r := fn_hk_create_task(jsonb_build_object('task_type_id','00000000-0000-0000-0000-000000000420','room_id', room));
  t := (r->>'id')::uuid;
  r := fn_hk_set_cleanliness(room, 'clean', 'تفقد سريع');
  perform t_record('HC01 a manual «clean» is accepted while a cleaning task is open; the task stays open; the change is recorded with who made it',
    (r->>'ok')::boolean and (t_room(room)).cleanliness = 'clean' and (select status from housekeeping_tasks where id = t) = 'pending'
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = %L and actor_id is not null and (details->''after''->>''open_cleaning_task'')::boolean',
                       room, 'room.cleanliness_changed')) >= 1, r::text);
  r := fn_hk_complete_task(t, null, t_ver('housekeeping_tasks', t));
  perform t_record('HC01b the open task is completed afterwards as usual', (select status from housekeeping_tasks where id = t) = 'completed' and (t_room(room)).cleanliness = 'clean', r::text);
exception when others then perform t_record('HC01 a manual «clean» is accepted while a cleaning task is open; the task stays open; the change is recorded with who made it', false, sqlerrm); end $$;

-- =====================================================================
-- A10–A12 / X04 isolation & permission
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000006','supB@test.local');
do $$ declare n int; begin
  select count(*) into n from blocks where branch_id = '00000000-0000-0000-0000-000000000010';
  perform t_record('A10a branch-B staff sees 0 blocks of branch A (RLS)', n = 0, n::text);
  select count(*) into n from financial_vouchers where branch_id = '00000000-0000-0000-0000-000000000010';
  perform t_record('A10b branch-B staff sees 0 vouchers of branch A (RLS)', n = 0, n::text);
  perform t_record('A10c branch-B staff gets null detail for branch A reservation', fn_reservation_detail((select v from ids where k='resA')) is null);
  perform t_record('A10d branch-B staff gets empty list for branch A', (fn_reservation_list('00000000-0000-0000-0000-000000000010')->>'total')::int = 0);
end $$;
do $$ begin
  perform fn_hk_create_task(jsonb_build_object('task_type_id','00000000-0000-0000-0000-000000000420','room_id',(select v from ids where k='room1')));
  perform t_record('A10e branch-B staff cannot create task in branch A by passing its ids', false, 'accepted');
exception when others then perform t_record('A10e branch-B staff cannot create task in branch A by passing its ids', sqlerrm like '%FORBIDDEN%', sqlerrm); end $$;
do $$ begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', (select v from ids where k='resA'), 'kind','receipt','amount_halalas', 100, 'method','cash','idempotency_key','kX4'));
  perform t_record('A10f branch-B staff cannot collect money on branch A reservation', false, 'accepted');
exception when others then perform t_record('A10f branch-B staff cannot collect money on branch A reservation', sqlerrm like '%FORBIDDEN%', sqlerrm); end $$;
do $$ begin
  update blocks set name = 'hack' where branch_id = '00000000-0000-0000-0000-000000000010';
  perform t_record('A10g direct UPDATE on definitions by staff is a no-op (RLS, RPC-only writes)', (select count(*) from blocks where name = 'hack') = 0);
exception when others then perform t_record('A10g direct UPDATE on definitions by staff is a no-op (RLS, RPC-only writes)', true, sqlerrm); end $$;
do $$ begin
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, idempotency_key, content_hash)
  values ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000012',(select v from ids where k='resA'),'X','receipt',1,'cash','hack','h');
  perform t_record('A10h direct INSERT into ledger rejected', false, 'accepted');
exception when others then perform t_record('A10h direct INSERT into ledger rejected', true, sqlerrm); end $$;

-- authenticated but not a staff member
select t_login('a0000000-0000-0000-0000-00000000ffff','random@test.local');
do $$ begin
  perform fn_admin_upsert_block('{"branch_id":"00000000-0000-0000-0000-000000000010","name":"x"}');
  perform t_record('A11 authenticated non-staff cannot administer', false, 'accepted');
exception when others then perform t_record('A11 authenticated non-staff cannot administer', sqlerrm like '%FORBIDDEN%', sqlerrm); end $$;
do $$ begin
  perform t_record('A11b authenticated non-staff sees no reservations', (select count(*) from reservations) = 0 and fn_ops_daily_summary('00000000-0000-0000-0000-000000000010') is null);
end $$;
-- deactivated staff
select t_login('a0000000-0000-0000-0000-000000000007','off@test.local');
do $$ begin
  perform fn_hk_create_task(jsonb_build_object('task_type_id','00000000-0000-0000-0000-000000000420','room_id',(select v from ids where k='room1')));
  perform t_record('A12 deactivated staff cannot act even with a live session', false, 'accepted');
exception when others then perform t_record('A12 deactivated staff cannot act even with a live session', sqlerrm like '%FORBIDDEN%', sqlerrm); end $$;

-- U03 optimistic locking
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
do $$ declare b blocks; begin
  select * into b from blocks where id = (select v from ids where k='block');
  perform fn_admin_upsert_block(jsonb_build_object('id', b.id, 'name', b.name, 'description', 'v2', 'version', b.version));
  begin
    perform fn_admin_upsert_block(jsonb_build_object('id', b.id, 'name', b.name, 'description', 'v3-stale', 'version', b.version));
    perform t_record('U03 stale version write rejected (no silent overwrite)', false, 'accepted');
  exception when others then perform t_record('U03 stale version write rejected (no silent overwrite)', sqlerrm like '%VERSION_CONFLICT%' and (select description from blocks where id = b.id) = 'v2', sqlerrm); end;
end $$;

-- D03 financial audit has actor/time/reference/reason and no identity numbers or secrets
do $$ declare e audit_events; begin
  select * into e from audit_events where action = 'voucher.deposit_refund_created' order by created_at desc limit 1;
  perform t_record('D03 financial audit: actor, time, amount, reason present; no document numbers or codes',
    e.actor_id is not null and e.created_at is not null and (e.details->'after'->>'amount_halalas') is not null and e.details->>'reason' is not null
    and regexp_replace(e.details::text, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '', 'g') !~ '\d{10}'   -- ids are random: a uuid may hold 10 digits
    and not (e.details ? 'code_encrypted'), e.details::text);
end $$;

-- D02 report: deposits outside revenue
do $$ declare s jsonb; begin
  s := fn_ops_daily_summary((select v from ids where k='branchF'));
  perform t_record('D02 daily summary: received_today excludes deposits (30000 + 500 cancelled → 30000)', (s->'finance'->>'received_today')::bigint = 30000 and (s->'finance'->>'deposits_held')::bigint = 4000, (s->'finance')::text);
end $$;

-- D01 export completeness: list returns the exact total and all rows when limit is large (no silent 25)
do $$ declare l jsonb; begin
  l := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{}', 1000, 0);
  perform t_record('D01 list total matches rows returned for full export', (l->>'total')::int = jsonb_array_length(l->'rows') and (l->>'total')::int > 0, l->>'total');
end $$;


-- =====================================================================
-- AI ops proposals: human-in-the-loop, executed under the confirmer's own role
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
do $$ declare c uuid; p jsonb; r jsonb; res uuid := (select v from ids where k='resA'); st text; begin
  insert into ai_ops_conversations(organization_id, branch_id, staff_id, title) values ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000003','t') returning id into c;
  p := fn_ai_ops_propose(c, 'cancel_reservation', jsonb_build_object('reservation_id', res, 'reason', 'اقتراح'), 'إلغاء الحجز A');
  r := fn_ai_ops_execute_proposal((p->>'proposal_id')::uuid);
  st := (t_res(res)).status;
  perform t_record('AI01 housekeeping confirming a cancel proposal → refused by the real RPC; reservation untouched; proposal marked failed',
    (r->>'ok')::boolean = false and r->>'error' like '%FORBIDDEN%' and st = 'confirmed'
    and (select status from ai_action_proposals where id = (p->>'proposal_id')::uuid) = 'failed', r::text);
  p := fn_ai_ops_propose(c, 'create_task', jsonb_build_object('room_id', (select v from ids where k='room3'), 'task_type_id', '00000000-0000-0000-0000-000000000420', 'priority', 'high'), 'إنشاء مهمة تنظيف');
  r := fn_ai_ops_execute_proposal((p->>'proposal_id')::uuid);
  perform t_record('AI02 housekeeping confirming a task proposal → executed via fn_hk_create_task and audited',
    (r->>'ok')::boolean and (select status from ai_action_proposals where id = (p->>'proposal_id')::uuid) = 'executed'
    and t_count('select count(*) from audit_events where action = ''ai_proposal.executed'' and entity_id = ''' || (p->>'proposal_id') || '''') = 1, r::text);
  begin
    perform fn_ai_ops_propose(c, 'drop_everything', '{}'::jsonb, 'x');
    perform t_record('AI03 unknown action cannot be proposed', false, 'accepted');
  exception when others then perform t_record('AI03 unknown action cannot be proposed', sqlerrm like '%action%', sqlerrm); end;
end $$;
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ declare pid uuid; begin
  select id into pid from ai_action_proposals where status = 'executed' limit 1;
  begin
    perform fn_ai_ops_execute_proposal(pid);
    perform t_record('AI04 another staff member cannot execute someone else''s proposal', false, 'accepted');
  exception when others then perform t_record('AI04 another staff member cannot execute someone else''s proposal', sqlerrm like '%FORBIDDEN%', sqlerrm); end;
  perform t_record('AI05 ops context contains no document numbers / codes', (fn_ai_ops_context('00000000-0000-0000-0000-000000000010')::text !~ '(^|[^0-9a-f-])[12]\d{9}([^0-9a-f-]|$)') and not (fn_ai_ops_context('00000000-0000-0000-0000-000000000010')::text ~ 'code_encrypted'));
end $$;


-- A13: last active owner cannot be deactivated or demoted
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
do $$ begin
  update staff_profiles set is_active = false where id = '10000000-0000-0000-0000-000000000001';
  perform t_record('A13 deactivating the last active owner rejected', false, 'accepted');
exception when others then perform t_record('A13 deactivating the last active owner rejected', sqlerrm like '%LAST_OWNER%' and (select is_active from staff_profiles where id = '10000000-0000-0000-0000-000000000001'), sqlerrm); end $$;
do $$ begin
  update staff_profiles set role = 'manager' where id = '10000000-0000-0000-0000-000000000001';
  perform t_record('A13b demoting the last active owner rejected', false, 'accepted');
exception when others then perform t_record('A13b demoting the last active owner rejected', sqlerrm like '%LAST_OWNER%', sqlerrm); end $$;


-- =====================================================================
-- Review regressions (independent review findings, each reproduced before fixing)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000006','supB@test.local');
do $$ begin
  perform t_record('RV01 finance of a branch-A reservation is null for branch-B staff', fn_reservation_finance((select v from ids where k='resA')) is null);
  perform t_record('RV01b room availability of a branch-A room is false for branch-B staff', fn_room_available((select v from ids where k='room1'), current_date + 100, current_date + 101) = false);
end $$;
reset role; set role anon;
do $$ begin
  perform fn_definition_dependencies('branch', '00000000-0000-0000-0000-000000000010');
  perform t_record('RV02 anon cannot read dependency counts', false, 'returned');
exception when others then perform t_record('RV02 anon cannot read dependency counts', true, sqlerrm); end $$;
reset role; set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
do $$ declare d jsonb; begin
  d := fn_reservation_detail((select v from ids where k='resA'));
  perform t_record('RV03 housekeeping gets no guest identities, no finance and no audit history from reservation detail',
    d is not null and jsonb_typeof(d->'guests') = 'null' and jsonb_typeof(d->'finance') = 'null' and jsonb_typeof(d->'history') = 'null' and jsonb_typeof(d->'allocations') = 'array'
    and not (d->'reservation' ? 'total_halalas'), left(d::text, 100));
end $$;
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
do $$ declare r jsonb; b uuid; cat uuid; rm uuid; res uuid; begin
  -- RV04: a branch created through the RPC has the system cleaning type; checkout there works
  r := fn_admin_upsert_branch('{"name_ar":"فرع جديد RV","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  perform t_record('RV04a new branch gets room_cleaning system task type', (select count(*) from task_types where branch_id = b and code = 'room_cleaning') = 1);
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar','ق','base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number','RV-1')); rm := (r->>'id')::uuid;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_id', rm, 'check_in', (current_date - 1)::text, 'check_out', (current_date + 1)::text, 'guest_name','ضيف RV','source_id','00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  reset role; update reservations set status = 'checked_in', actual_check_in = now() where id = res; update rooms set status = 'occupied' where id = rm;
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 20000, 'method','cash','idempotency_key','rv4'));
  r := fn_staff_checkout(res);
  perform t_record('RV04b checkout in a freshly created branch creates the cleaning task', (r->>'ok')::boolean and (select count(*) from housekeeping_tasks where room_id = rm and status = 'pending') = 1, r::text);
  insert into ids values ('branchRV', b);
exception when others then perform t_record('RV04 new-branch checkout path', false, sqlerrm); end $$;

do $$ declare r jsonb; res uuid := (select v from ids where k='resIn'); begin
  -- resIn is checked_out now; use resA (confirmed, room1) for switch guards
  res := (select v from ids where k='resA');
  begin
    perform fn_staff_switch_room(res, (select v from ids where k='room1'), null, 'نفس الوحدة', t_ver('reservations', res));
    perform t_record('RV05 switching to the same room rejected', false, 'accepted');
  exception when others then perform t_record('RV05 switching to the same room rejected', sqlerrm like '%SAME_ROOM%', sqlerrm); end;
end $$;
do $$ declare r jsonb; res uuid; rm uuid; rm2 uuid; cat uuid; b uuid := (select v from ids where k='branchRV'); begin
  select id into cat from room_categories where branch_id = b limit 1;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number','RV-2')); rm := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number','RV-3')); rm2 := (r->>'id')::uuid;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_id', rm, 'check_in', (current_date - 1)::text, 'check_out', (current_date + 5)::text, 'guest_name','مقيم RV','source_id','00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  reset role; update reservations set status = 'checked_in', actual_check_in = now() where id = res; update rooms set status = 'occupied' where id = rm;
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  begin
    perform fn_staff_switch_room(res, rm2, current_date + 2, 'مستقبلي', t_ver('reservations', res));
    perform t_record('RV06 future-dated switch for a checked-in guest rejected; rooms untouched', false, 'accepted');
  exception when others then
    perform t_record('RV06 future-dated switch for a checked-in guest rejected; rooms untouched', sqlerrm like '%effective_date%' and (t_room(rm)).status = 'occupied' and (t_room(rm2)).status <> 'occupied', sqlerrm);
  end;
  insert into ids values ('resRV', res);
end $$;
do $$ declare r jsonb; res uuid := (select v from ids where k='resRV'); other uuid := (select v from ids where k='resA'); begin
  r := fn_staff_confirm_payment(res, 'pos', 1000, 'POS-RV', 'key-rv-7');
  begin
    r := fn_staff_confirm_payment(other, 'pos', 1000, 'POS-RV', 'key-rv-7');
    perform t_record('RV07 payment key reused for another reservation rejected (not silently dropped)', false, 'accepted: ' || r::text);
  exception when others then perform t_record('RV07 payment key reused for another reservation rejected (not silently dropped)', sqlerrm like '%IDEMPOTENCY_CONFLICT%', sqlerrm); end;
end $$;
do $$ declare r jsonb; res uuid := (select v from ids where k='resRV'); vid uuid; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 500, 'method','cash','idempotency_key','key-rv-8'));
  vid := (r->>'voucher_id')::uuid;
  perform fn_cancel_voucher(vid, 'خطأ');
  begin
    r := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt','amount_halalas', 500, 'method','cash','idempotency_key','key-rv-8'));
    perform t_record('RV08 replaying the key of a cancelled voucher is an explicit error, not a silent success', false, 'accepted: ' || r::text);
  exception when others then perform t_record('RV08 replaying the key of a cancelled voucher is an explicit error, not a silent success', sqlerrm like '%IDEMPOTENCY_CANCELLED%', sqlerrm); end;
end $$;
do $$ declare r jsonb; res_today uuid; res_future uuid; rm uuid; cat uuid; b uuid := (select v from ids where k='branchRV'); begin
  -- RV09: cancelling a FUTURE reservation must not touch the room flag held by today's reservation on the same room
  select id into cat from room_categories where branch_id = b limit 1;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number','RV-9')); rm := (r->>'id')::uuid;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_id', rm, 'check_in', current_date::text, 'check_out', (current_date + 2)::text, 'guest_name','اليوم','source_id','00000000-0000-0000-0000-000000000021')); res_today := (r->>'id')::uuid;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_id', rm, 'check_in', (current_date + 10)::text, 'check_out', (current_date + 12)::text, 'guest_name','مستقبل','source_id','00000000-0000-0000-0000-000000000021')); res_future := (r->>'id')::uuid;
  perform fn_staff_cancel_reservation(res_future, 'إلغاء');
  perform t_record('RV09 cancelling a future allocation leaves today''s reserved flag intact', (t_room(rm)).status = 'reserved', (t_room(rm)).status::text);
end $$;
select t_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
do $$ begin
  perform fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000030','check_in',(current_date + 40)::text,'check_out',(current_date + 41)::text,'guest_name','رخيص','source_id','00000000-0000-0000-0000-000000000021','nightly_rate_halalas', 0));
  perform t_record('RV10 supervisor cannot undercut the base price via nightly override', false, 'accepted');
exception when others then perform t_record('RV10 supervisor cannot undercut the base price via nightly override', sqlerrm like '%FORBIDDEN%', sqlerrm); end $$;
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
do $$ declare r jsonb; res uuid; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id','00000000-0000-0000-0000-000000000031','check_in',(current_date - 2)::text,'check_out',(current_date + 1)::text,'guest_name','غائب','source_id','00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  perform fn_staff_no_show(res, 'لم يحضر');
  r := fn_staff_cancel_reservation(res, 'إلغاء لاحق');
  perform t_record('RV11 cancel after no-show is a duplicate no-op; status stays no_show', (r->>'duplicate')::boolean and (t_res(res)).status = 'no_show', r::text);
end $$;
do $$ declare r jsonb; res uuid := (select v from ids where k='resRV'); t uuid; rm uuid; begin
  select room_id into rm from reservations where id = res;
  -- RV13: cancelling a started cleaning task never strands the room in 'in_progress'
  r := fn_hk_create_task(jsonb_build_object('room_id', rm, 'task_type_id', (select id from task_types where branch_id = (select v from ids where k='branchRV') and code = 'room_cleaning'))); t := (r->>'id')::uuid;
  perform fn_hk_start_task(t);
  perform t_record('RV13a starting a cleaning task marks the room in_progress', (t_room(rm)).cleanliness = 'in_progress');
  perform fn_hk_cancel_task(t, 'إلغاء');
  perform t_record('RV13b cancelling it resets cleanliness to dirty', (t_room(rm)).cleanliness = 'dirty', (t_room(rm)).cleanliness);
end $$;
do $$ declare d jsonb; begin
  d := fn_definition_dependencies('branch', (select v from ids where k='branchRV'));
  perform t_record('RV14 branch dependency count includes categories/vouchers/keyboxes/policies', (d ? 'room_categories') and (d ? 'vouchers') and (d ? 'keyboxes') and (d ? 'policies') and (d->>'room_categories')::int >= 1 and (d->>'vouchers')::int >= 1, d::text);
end $$;
do $$ begin
  perform fn_admin_upsert_branch('{"name_ar":"منطقة خاطئة","timezone":"Riyadh"}');
  perform t_record('RV19 invalid timezone rejected on branch save', false, 'accepted');
exception when others then perform t_record('RV19 invalid timezone rejected on branch save', sqlerrm like '%timezone%', sqlerrm); end $$;
do $$ begin
  perform fn_hk_create_task(jsonb_build_object('room_id', (select v from ids where k='room1'), 'task_type_id', '00000000-0000-0000-0000-000000000420', 'reservation_id', (select v from ids where k='resRV')));
  perform t_record('RV17 task cannot reference a reservation of another branch', false, 'accepted');
exception when others then perform t_record('RV17 task cannot reference a reservation of another branch', sqlerrm like '%BRANCH_MISMATCH%', sqlerrm); end $$;
do $$ declare c uuid; p jsonb; r jsonb; begin
  insert into ai_ops_conversations(organization_id, branch_id, staff_id, title) values ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000001','exp') returning id into c;
  p := fn_ai_ops_propose(c, 'set_cleanliness', jsonb_build_object('room_id', (select v from ids where k='room1'), 'state', 'dirty'), 'علامة');
  reset role; update ai_action_proposals set expires_at = now() - interval '1 minute' where id = (p->>'proposal_id')::uuid;
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  r := fn_ai_ops_execute_proposal((p->>'proposal_id')::uuid);
  perform t_record('RV16 expired proposal is persisted as expired and not executed', (r->>'ok')::boolean = false and r->>'error' = 'PROPOSAL_EXPIRED' and (select status from ai_action_proposals where id = (p->>'proposal_id')::uuid) = 'expired', r::text);
end $$;
do $$ declare res uuid := (select v from ids where k='resRV'); a record; begin
  -- RV12: an active allocation that does not end at check_out blocks amend_stay instead of silently skipping it
  reset role; update reservation_allocations set to_date = to_date - 1 where reservation_id = res and status = 'active';
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  -- paid up, so that no overdue night (decision 3) is what refuses the extension
  if (t_fin(res)->>'balance_due')::bigint > 0 then
    perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', (t_fin(res)->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'rv12-pay'));
  end if;
  begin
    perform fn_staff_amend_stay(res, (select check_out + 1 from reservations where id = res), 'keep_rate', 'تمديد', t_ver('reservations', res));
    perform t_record('RV12 amend_stay with mismatched allocation rejected', false, 'accepted');
  exception when others then perform t_record('RV12 amend_stay with mismatched allocation rejected', sqlerrm like '%ALLOCATION_MISMATCH%', sqlerrm); end;
end $$;


-- housekeeping receives an ops context without any balance (least data per role)
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
do $$ declare c jsonb; begin
  c := fn_ai_ops_context('00000000-0000-0000-0000-000000000010');
  perform t_record('RV22 housekeeping ops context carries no balances / deposits / payment status',
    c is not null and not (c ? 'in_house_with_balance') and not (c->'summary' ? 'finance') and c::text !~ 'balance_due' and c::text !~ 'deposit_balance', left(c::text, 80));
end $$;
select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
do $$ declare c jsonb; begin
  c := fn_ai_ops_context('00000000-0000-0000-0000-000000000010');
  perform t_record('RV22b owner ops context keeps finance', (c->'summary' ? 'finance'));
end $$;

reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'CORE TESTS FAILED'; end if;
end $$;
