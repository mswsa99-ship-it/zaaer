-- =====================================================================
-- The stay cycle (Phase 3, migrations 0032–0033): decisions 1, 3, 5, 6, 7, 8, 10, 49, 59 and the matrix rows they fill.
-- SC01–SC21: the arrival's fixed conditions and its two entries, Shomoos, the code after the arrival, night-by-night
-- payment with its grace hour and the reason that lets a stay go on, check-out with nothing owed, the inspection and
-- the deposit, damages, «مغلق» by itself, the corrections and their time windows, late check-out, the day summary per
-- employee, units and types with commitments, and who may do each of these.
-- Runs after rates_tests.sql on the same database (uses its synthetic organisation, branch 010 and staff).
-- The races of decisions 45, 46 and 49 are in tests/sql/concurrency.sh (two real sessions).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
create or replace function t_unit(p uuid) returns rooms language sql security definer as $$ select * from rooms where id = p $$;
create or replace function t_box(p uuid) returns keyboxes language sql security definer as $$ select * from keyboxes where room_id = p $$;
create or replace function t_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function t_due(p uuid, p_at timestamptz) returns jsonb language sql security definer as $$ select fn_stay_due_internal(p, p_at) $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
-- a branch-local wall-clock moment as an instant
create or replace function t_at(p_day date, p_time time) returns timestamptz language sql as $$ select (p_day + p_time) at time zone 'Asia/Riyadh' $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
-- guests registered and matched (the identity path itself is tested in security_tests.sql)
create or replace function t_ready(p uuid) returns void language plpgsql security definer as $$
begin
  update reservation_guests set data_submitted = true, verification_status = 'verified' where reservation_id = p;
  update reservations set identity_status = 'verified' where id = p;
end $$;
-- moves a moment of the stay back in time, with what was stamped at that moment, so a time window can be crossed
create or replace function t_backdate(p uuid, p_what text, p_minutes int) returns void language plpgsql security definer as $$
declare r reservations%rowtype; d interval := make_interval(mins => p_minutes);
begin
  select * into r from reservations where id = p;
  if p_what = 'check_in' then update reservations set actual_check_in = actual_check_in - d where id = p;
  elsif p_what = 'check_out' then
    update reservation_allocations set closed_at = closed_at - d where reservation_id = p and closed_at = r.actual_check_out;
    update reservations set actual_check_out = actual_check_out - d where id = p;
  elsif p_what = 'cancel' then
    update reservation_allocations set closed_at = closed_at - d where reservation_id = p and closed_at = r.cancelled_at;
    update reservations set cancelled_at = cancelled_at - d where id = p;
  end if;
end $$;
-- a stay on a unit, as the current user
create or replace function t_stay(p_room uuid, p_from date, p_to date, p_name text) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'room_id', p_room, 'check_in', p_from, 'check_out', p_to, 'guest_name', p_name, 'guest_phone', '0500007' || lpad((floor(random() * 1000))::int::text, 3, '0'),
         'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;
-- Shomoos registered (every guest) and accepted, as the current user
create or replace function t_shomoos(p uuid) returns void language plpgsql as $$
begin
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', p, 'action', 'register', 'reference', 'SHM-' || left(p::text, 8), 'all_guests', true));
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', p, 'action', 'accept'));
end $$;
-- the arrival with both entries: the first night's shortfall on a receipt and the branch's deposit
create or replace function t_check_in(p uuid, p_key text) returns jsonb language plpgsql as $$
declare d jsonb;
begin
  d := t_due(p, now());
  return fn_staff_check_in(jsonb_build_object('reservation_id', p,
    'rent', case when (d->>'first_night')::bigint > (d->>'collected')::bigint then jsonb_build_object('amount_halalas', (d->>'first_night')::bigint - (d->>'collected')::bigint,
                                                                                                    'method', 'cash', 'idempotency_key', p_key || '-rent') end,
    'deposit', jsonb_build_object('amount_halalas', (d->>'deposit_required')::bigint, 'method', 'cash', 'idempotency_key', p_key || '-dep')));
end $$;

-- ---------------------------------------------------------------- fixtures
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع الإقامة', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-K1')); insert into ids values ('k1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-K2')); insert into ids values ('k2', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-K3')); insert into ids values ('k3', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-N1')); insert into ids values ('n1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-N2')); insert into ids values ('n2', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-N3')); insert into ids values ('n3', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-N4')); insert into ids values ('n4', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-N5')); insert into ids values ('n5', (r->>'id')::uuid);
  -- three units with a key box, its code set and tried on the box
  perform fn_staff_rotate_keybox_code(t_id('k1'), '3141', true);
  perform fn_staff_rotate_keybox_code(t_id('k2'), '2718', true);
  perform fn_staff_rotate_keybox_code(t_id('k3'), '1618', true);
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'مياه إضافية', 'price_halalas', 500));
  insert into ids values ('svc', (r->>'id')::uuid);
end $$;

-- ---------------------------------------------------------------- SC01–SC02: the arrival's conditions, Shomoos
do $$ declare res uuid; r jsonb; reasons text; begin
  res := t_stay(t_id('k1'), t_today(), t_today() + 3, 'ضيف الوصول');
  insert into ids values ('resA', res);
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res));
  reasons := r->>'reasons';
  perform t_record('SC01a the arrival is refused until its fixed conditions hold: identity, Shomoos, the first night, the deposit — and nothing is recorded',
    (r->>'ok')::boolean = false and reasons like '%الهوية%' and reasons like '%شموس%' and reasons like '%الليلة الأولى%' and reasons like '%التأمين%'
    and (t_res(res)).status = 'confirmed' and t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res)) = 0, reasons);
exception when others then perform t_record('SC01a the arrival is refused until its fixed conditions hold: identity, Shomoos, the first night, the deposit — and nothing is recorded', false, sqlerrm); end $$;

select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid := t_id('resA'); r jsonb; m text := ''; begin
  m := m || t_fails(format('select fn_staff_shomoos(%L)', jsonb_build_object('reservation_id', res, 'action', 'register', 'reference', 'SHM-100', 'all_guests', true)), '%IDENTITY_NOT_VERIFIED%') || ' ';
  perform t_ready(res);
  m := m || t_fails(format('select fn_staff_shomoos(%L)', jsonb_build_object('reservation_id', res, 'action', 'register', 'reference', 'SHM-100')), '%shomoos_all_guests%') || ' ';
  m := m || t_fails(format('select fn_staff_shomoos(%L)', jsonb_build_object('reservation_id', res, 'action', 'register', 'reference', 'S1', 'all_guests', true)), '%shomoos_reference%') || ' ';
  m := m || t_fails(format('select fn_staff_shomoos(%L)', jsonb_build_object('reservation_id', res, 'action', 'accept')), '%shomoos_not_registered%') || ' ';
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', res, 'action', 'register', 'reference', 'SHM-100', 'all_guests', true));
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res));
  perform t_record('SC02a Shomoos: the registration needs matched identities, a reference and «every guest registered»; acceptance comes after it and is its own condition',
    m = 'ok ok ok ok ' and (r->>'ok')::boolean = false and r->>'reasons' like '%قبول شموس%' and r->>'reasons' not like '%الهوية%'
    and (t_res(res)).gov_registration_by is not null and (t_res(res)).shomoos_guest_count = 1, m || ' ' || r::text);
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', res, 'action', 'accept'));
  -- a corrected reference waits for Shomoos's acceptance again
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', res, 'action', 'register', 'reference', 'SHM-101', 'all_guests', true));
  perform t_record('SC02b a corrected registration clears the acceptance until it is confirmed again; who and when are kept',
    (t_res(res)).shomoos_accepted_at is null and (t_res(res)).gov_registration_ref = 'SHM-101'
    and t_count(format('select count(*) from audit_events where entity_id = %L and action like %L', res, 'reservation.shomoos_%')) = 3, (t_res(res)).gov_registration_ref);
  perform fn_staff_shomoos(jsonb_build_object('reservation_id', res, 'action', 'accept'));
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res));
  perform t_record('SC02c with identity and Shomoos done, only the money remains: the first night and the deposit',
    (r->>'ok')::boolean = false and jsonb_array_length(r->'reasons') = 2 and (t_res(res)).shomoos_accepted_by is not null, r::text);
exception when others then perform t_record('SC02a Shomoos: the registration needs matched identities, a reference and «every guest registered»; acceptance comes after it and is its own condition', false, sqlerrm); end $$;

-- a companion added after the registration asks for it again
do $$ declare res uuid; r jsonb; begin
  res := t_stay(t_id('n1'), t_today(), t_today() + 2, 'ضيف المرافق');
  insert into ids values ('resN', res);
  perform t_ready(res);
  perform t_shomoos(res);
  reset role; update reservations set companions = 1 where id = res;
  insert into reservation_guests(reservation_id, is_primary, full_name, data_submitted, verification_status) values (res, false, 'مرافق إضافي', true, 'verified');
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res));
  perform t_record('SC02d a change in the number of guests after the Shomoos registration blocks the arrival until it is registered again',
    (r->>'ok')::boolean = false and r->>'reasons' like '%تغيّر عدد النزلاء%', r::text);
  perform t_shomoos(res);
exception when others then perform t_record('SC02d a change in the number of guests after the Shomoos registration blocks the arrival until it is registered again', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC03–SC05: the arrival's two entries, the deposit's reason
do $$ declare res uuid := t_id('resA'); r jsonb; r2 jsonb; n int; begin
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res,
         'rent', jsonb_build_object('amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'sc03-rent-part'),
         'deposit', jsonb_build_object('amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'sc03-dep-part')));
  perform t_record('SC05a part of the first night is not enough: refused with what remains, and neither entry is recorded',
    (r->>'ok')::boolean = false and r->>'reasons' like '%المتبقي 50.00%' and t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res)) = 0, r::text);
  perform t_record('SC05b an entry that fails its own rule (a terminal payment without its transaction number) records nothing at all',
    t_fails(format('select fn_staff_check_in(%L)', jsonb_build_object('reservation_id', res,
      'rent', jsonb_build_object('amount_halalas', 10000, 'method', 'pos', 'idempotency_key', 'sc03-rent-pos'),
      'deposit', jsonb_build_object('amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'sc03-dep-pos'))), '%reference_required%') = 'ok'
    and t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res)) = 0 and (t_res(res)).status = 'confirmed');
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res,
         'rent', jsonb_build_object('amount_halalas', 10000, 'method', 'cash', 'idempotency_key', 'sc03-rent'),
         'deposit', jsonb_build_object('amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'sc03-dep')));
  perform t_record('SC03a the arrival records the rent receipt and the deposit receipt as two vouchers, in one step; the unit is occupied and its code awaits delivery',
    (r->>'ok')::boolean and r->>'rent_voucher' like 'RCP-%' and r->>'deposit_voucher' like 'DEP-%' and (t_res(res)).status = 'checked_in'
    and (t_res(res)).actual_check_in is not null and (t_res(res)).checked_in_by = '10000000-0000-0000-0000-000000000002' and (t_res(res)).access_status = 'approved'
    and (t_unit(t_id('k1'))).status = 'occupied' and (t_fin(res)->>'net_collected')::bigint = 10000 and (t_fin(res)->>'deposit_balance')::bigint = 5000, r::text);
  r2 := fn_staff_check_in(jsonb_build_object('reservation_id', res,
         'rent', jsonb_build_object('amount_halalas', 10000, 'method', 'cash', 'idempotency_key', 'sc03-rent-again')));
  n := t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res));
  perform t_record('SC03b registering the arrival again changes nothing: one transition, one arrival time, no new voucher (R13)',
    (r2->>'duplicate')::boolean and n = 2 and t_count(format('select count(*) from audit_events where entity_id = %L and action = %L', res, 'reservation.checked_in')) = 1, r2::text);
exception when others then perform t_record('SC03a the arrival records the rent receipt and the deposit receipt as two vouchers, in one step; the unit is occupied and its code awaits delivery', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resN'); r jsonb; begin
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res,
         'rent', jsonb_build_object('amount_halalas', 10000, 'method', 'cash', 'idempotency_key', 'sc04-rent'),
         'deposit', jsonb_build_object('amount_halalas', 3000, 'method', 'cash', 'idempotency_key', 'sc04-dep')));
  perform t_record('SC04a a deposit under the branch''s amount needs the reason', (r->>'ok')::boolean = false and r->>'reasons' like '%التأمين%' and jsonb_array_length(r->'reasons') = 1, r::text);
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res, 'deposit_reason', 'ضيف دائم؛ يكمل التأمين مساءً',
         'rent', jsonb_build_object('amount_halalas', 10000, 'method', 'cash', 'idempotency_key', 'sc04-rent'),
         'deposit', jsonb_build_object('amount_halalas', 3000, 'method', 'cash', 'idempotency_key', 'sc04-dep')));
  perform t_record('SC04b with the reason the arrival goes ahead; the reason, who and when are on the stay and in the audit with the shortfall',
    (r->>'ok')::boolean and (t_res(res)).deposit_waiver_reason = 'ضيف دائم؛ يكمل التأمين مساءً' and (t_res(res)).deposit_waiver_by is not null
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = %L and details->>''reason'' = %L and (details->''after''->>''deposit_short_halalas'')::bigint = 2000',
                       res, 'reservation.checked_in', 'ضيف دائم؛ يكمل التأمين مساءً')) = 1, r::text);
exception when others then perform t_record('SC04a a deposit under the branch''s amount needs the reason', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC06–SC07: the unit, the key box, the code after the arrival
do $$ declare res uuid; r jsonb; m text := ''; begin
  -- resN is in SC-N1, a unit without a key box: its key is handed at reception and there is no code to deliver
  r := fn_staff_deliver_access_code(t_id('resN'), 'screen');
  perform t_record('SC06a a unit without a key box: the arrival hands its key («key_handed»); delivering a code is refused with why',
    (t_res(t_id('resN'))).access_status = 'key_handed' and (r->>'ok')::boolean = false and r->>'reasons' like '%بلا صندوق%', r::text);
  res := t_stay(t_id('n2'), t_today(), t_today() + 2, 'ضيف وحدة متسخة');
  insert into ids values ('resDirty', res);
  perform t_ready(res); perform t_shomoos(res);
  perform fn_hk_set_cleanliness(t_id('n2'), 'dirty', 'اختبار');
  r := t_check_in(res, 'sc06-dirty');
  m := r->>'reasons';
  perform fn_hk_set_cleanliness(t_id('n2'), 'clean', 'اختبار');
  reset role; insert into maintenance_tickets(room_id, branch_id, title, status) values (t_id('n2'), '00000000-0000-0000-0000-000000000010', 'تسريب', 'open');
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := t_check_in(res, 'sc06-maint');
  perform t_record('SC06b the unit must be clean and out of maintenance; nothing is recorded while it is not',
    m like '%غير نظيفة%' and r->>'reasons' like '%الصيانة%' and t_count(format('select count(*) from financial_vouchers where reservation_id = %L', res)) = 0, m || ' / ' || r::text);
  reset role; update maintenance_tickets set status = 'resolved' where room_id = t_id('n2');
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
exception when others then perform t_record('SC06a a unit without a key box: the arrival hands its key («key_handed»); delivering a code is refused with why', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resA'); r jsonb; s jsonb; tok text; begin
  -- before its arrival a stay gets no code; after it, with a ready code, it does
  r := fn_staff_deliver_access_code(t_id('resDirty'), 'screen');
  perform t_record('SC07a no code before the arrival is registered', (r->>'ok')::boolean = false and r->>'reasons' like '%لم يُسجَّل الوصول%', r::text);
  r := fn_staff_deliver_access_code(res, 'supervisor');
  perform t_record('SC07b after the arrival the code is delivered as its own step (by hand: shown once to the supervisor)',
    (r->>'ok')::boolean and r->>'code' = '3141' and (t_res(res)).access_status = 'delivered' and (t_box(t_id('k1'))).last_reservation_id = res, r::text);
  s := fn_stay_status(res);
  perform t_record('SC07c the stay page says the unit has a key box, the code is delivered, and what the departure time is',
    (s->>'has_keybox')::boolean and (s->'code'->>'delivered')::boolean and s->>'departure_time' = '12:00' and s->>'keybox_state' = 'ready', left(s::text, 200));
exception when others then perform t_record('SC07b after the arrival the code is delivered as its own step (by hand: shown once to the supervisor)', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC08: night by night, the deadline and its grace hour
do $$ declare res uuid := t_id('resA'); d date := t_today(); a jsonb; b jsonb; c jsonb; e jsonb; begin
  -- resA: three nights at 100.00 from today, the first paid at the arrival
  a := t_due(res, t_at(d + 1, '11:00'));
  b := t_due(res, t_at(d + 1, '12:30'));
  c := t_due(res, t_at(d + 1, '13:30'));
  e := t_due(res, t_at(d + 2, '13:30'));
  perform t_record('SC08a the second night is due at the check-out time on its day, overdue an hour later; the third the day after',
    (a->>'first_night')::bigint = 10000 and (a->>'shortfall_now')::bigint = 0 and not (a->>'overdue')::boolean
    and (b->>'due_now')::bigint = 20000 and (b->>'shortfall_now')::bigint = 10000 and not (b->>'overdue')::boolean
    and (c->>'overdue')::boolean and (c->>'overdue_amount')::bigint = 10000 and (c->>'overdue_since')::timestamptz = t_at(d + 1, '13:00')
    and (c->>'overdue_through')::date = d + 1 and (e->>'overdue_amount')::bigint = 20000 and (c->>'next_unpaid_night')::date = d + 1,
    a::text || ' | ' || c::text);
exception when others then perform t_record('SC08a the second night is due at the check-out time on its day, overdue an hour later; the third the day after', false, sqlerrm); end $$;

do $$ declare res uuid; d date := t_today(); a jsonb; b jsonb; begin
  -- a discount is spread over the nights; a service is due when it is added
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  res := t_stay(t_id('n3'), d + 30, d + 34, 'ضيف الخصم');
  perform fn_staff_adjust_price(res, 'discount', 4000, 'خصم', 'عميل دائم', (t_res(res)).version);
  a := t_due(res, t_at(d + 30, '10:00'));
  reset role;
  perform fn_add_charge(res, 'addon', 'خدمة', 1, 2500, false, null);
  set role authenticated; perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  b := t_due(res, t_at(d + 30, '10:00'));
  perform t_record('SC08b a discount is spread over the nights (4 × 100 − 40 → 90 for the first), a service is due at once (+25)',
    (a->>'total')::bigint = 36000 and (a->>'first_night')::bigint = 9000 and (b->>'first_night')::bigint = 11500 and (b->>'total')::bigint = 38500, a::text || ' | ' || b::text);
  insert into ids values ('resDisc', res);
exception when others then perform t_record('SC08b a discount is spread over the nights (4 × 100 − 40 → 90 for the first), a service is due at once (+25)', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC09: an overdue night stops extending and services, until paid or a reason
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid; r jsonb; svc uuid; m text := ''; begin
  -- a stay that began two days ago, only its first night paid: the night of yesterday is overdue whatever the hour
  res := t_stay(t_id('n4'), t_today() - 2, t_today() + 2, 'ضيف متأخر الدفع');
  insert into ids values ('resLate', res);
  perform t_ready(res); perform t_shomoos(res);
  r := t_check_in(res, 'sc09');
  if not (r->>'ok')::boolean then raise exception 'check-in refused: %', r; end if;
  svc := t_id('svc');
  m := t_fails(format('select fn_staff_amend_stay(%L, %L, %L, %L, %s)', res, t_today() + 3, 'keep_rate', 'تمديد', (t_res(res)).version), '%PAYMENT_OVERDUE%') || ' '
    || t_fails(format('select fn_staff_add_service(%L, %L)', res, svc), '%PAYMENT_OVERDUE%');
  perform t_record('SC09a with a night unpaid past its deadline, extending and adding a service are refused',
    m = 'ok ok' and (t_due(res, now())->>'overdue')::boolean, m);
  perform t_login('a0000000-0000-0000-0000-000000000004', 'finance@test.local');
  m := t_fails(format('select fn_staff_payment_exception(%L)', jsonb_build_object('reservation_id', res, 'reason', 'x')), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_staff_payment_exception(jsonb_build_object('reservation_id', res, 'reason', 'الضيف يحوّل غدًا صباحًا'));
  perform fn_staff_amend_stay(res, t_today() + 3, 'keep_rate', 'تمديد', (t_res(res)).version);
  perform fn_staff_add_service(res, svc);
  perform t_record('SC09b the supervisor records a reason (finance may not) and the stay goes on; the reason covers the overdue nights at that moment',
    m = 'ok' and (r->>'ok')::boolean and (t_res(res)).check_out = t_today() + 3
    and t_count(format('select count(*) from stay_payment_exceptions where reservation_id = %L and through_night >= %L', res, t_today() - 1)) = 1, m || ' ' || r::text);
  perform t_record('SC09c a reason is for an overdue night only', t_fails(format('select fn_staff_payment_exception(%L)', jsonb_build_object('reservation_id', t_id('resA'), 'reason', 'x')), '%not_overdue%') = 'ok');
exception when others then perform t_record('SC09a with a night unpaid past its deadline, extending and adding a service are refused', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC10: check-out with nothing owed, for anyone
do $$ declare res uuid := t_id('resLate'); r jsonb; r2 jsonb; due bigint; begin
  due := (t_fin(res)->>'balance_due')::bigint;
  r := fn_staff_check_out(jsonb_build_object('reservation_id', res));
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  r2 := fn_staff_checkout(res, 'تجاوز إداري');
  perform t_record('SC10a nothing owed, for anyone: the supervisor and the owner (even with the old override''s reason) are refused, with how to settle it',
    (r->>'ok')::boolean = false and (r2->>'ok')::boolean = false and r->>'reasons' like '%يُصفَّر بسند قبض%' and (t_res(res)).status = 'checked_in' and due > 0, r::text);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', due - 3000, 'method', 'cash', 'idempotency_key', 'sc10-pay'));
  -- the supervisor zeroes the rest from the deposit, with a reason (§16: «خصم من التأمين بسبب لتصفير الرصيد»)
  perform fn_refund(jsonb_build_object('reservation_id', res, 'kind', 'deposit_apply', 'amount_halalas', 3000, 'reason', 'تسوية الباقي من التأمين', 'idempotency_key', 'sc10-apply'));
  r := fn_staff_check_out(jsonb_build_object('reservation_id', res));
  perform t_record('SC10b once settled (a receipt, the rest from the deposit by the supervisor) the departure goes through: cleaning task, not closed while the deposit is held',
    (r->>'ok')::boolean and (t_res(res)).status = 'checked_out' and (t_res(res)).checked_out_by is not null
    and t_count(format('select count(*) from housekeeping_tasks where reservation_id = %L and status = %L', res, 'pending')) = 1
    and r->>'missing' like '%تأمين لم يُسوَّ 20.00%', r::text);
exception when others then perform t_record('SC10a nothing owed, for anyone: the supervisor and the owner (even with the old override''s reason) are refused, with how to settle it', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC11–SC12: inspection, the deposit, damages
do $$ declare res uuid := t_id('resLate'); m text := ''; r jsonb; begin
  m := t_fails(format('select fn_refund(%L)', jsonb_build_object('reservation_id', res, 'kind', 'deposit_refund', 'amount_halalas', 2000, 'method', 'cash', 'reason', 'رد', 'idempotency_key', 'sc11-a')), 'INSPECTION_REQUIRED%');
  -- before the departure day an inspection is not due
  m := m || ' ' || t_fails(format('select fn_staff_record_inspection(%L)', jsonb_build_object('reservation_id', t_id('resA'), 'result', 'ok')), '%inspection_not_due%');
  m := m || ' ' || t_fails(format('select fn_refund(%L)', jsonb_build_object('reservation_id', t_id('resA'), 'kind', 'deposit_refund', 'amount_halalas', 1000, 'method', 'cash', 'reason', 'رد', 'idempotency_key', 'sc11-b')), '%deposit_refund_before_checkout%');
  perform t_record('SC11a a stay''s deposit is refunded only after the departure and its inspection', m = 'ok ok ok', m);
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  m := t_fails(format('select fn_staff_record_inspection(%L)', jsonb_build_object('reservation_id', res, 'result', 'notes')), '%inspection_notes%');
  r := fn_staff_record_inspection(jsonb_build_object('reservation_id', res, 'result', 'ok'));
  m := m || ' ' || t_fails(format('select fn_refund(%L)', jsonb_build_object('reservation_id', res, 'kind', 'deposit_refund', 'amount_halalas', 2000, 'method', 'cash', 'reason', 'رد', 'idempotency_key', 'sc11-hk')), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  m := m || ' ' || t_fails(format('select fn_refund(%L)', jsonb_build_object('reservation_id', res, 'kind', 'refund', 'amount_halalas', 100, 'method', 'cash', 'reason', 'رد', 'idempotency_key', 'sc11-stay')), 'FORBIDDEN%');
  r := fn_refund(jsonb_build_object('reservation_id', res, 'kind', 'deposit_refund', 'amount_halalas', 2000, 'method', 'cash', 'reason', 'رد التأمين بعد الفحص', 'idempotency_key', 'sc11-c'));
  perform t_record('SC11b housekeeping records the inspection (notes need words); then the supervisor refunds the deposit — not housekeeping, and not the stay''s money',
    m = 'ok ok ok' and (r->>'ok')::boolean and (t_fin(res)->>'deposit_balance')::bigint = 0, m || ' ' || r::text);
exception when others then perform t_record('SC11a a stay''s deposit is refunded only after the departure and its inspection', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resN'); r jsonb; r2 jsonb; n int; begin
  -- resN (deposit 30.00 held): a damage of 45.00 takes the whole deposit, 15.00 stays owed
  r := fn_staff_add_damage(jsonb_build_object('reservation_id', res, 'amount_halalas', 4500, 'description', 'كسر مصباح', 'reason', 'مصباح الطاولة مكسور', 'idempotency_key', 'sc12-dmg'));
  r2 := fn_staff_add_damage(jsonb_build_object('reservation_id', res, 'amount_halalas', 4500, 'description', 'كسر مصباح', 'reason', 'مصباح الطاولة مكسور', 'idempotency_key', 'sc12-dmg'));
  n := t_count(format('select count(*) from reservation_charges where reservation_id = %L and purpose = %L', res, 'damage'));
  perform t_record('SC12a a damage charge carries its reason, comes off the deposit as far as it goes, and a replay adds nothing',
    (r->>'ok')::boolean and (r->>'from_deposit_halalas')::bigint = 3000 and (r2->>'duplicate')::boolean and n = 1
    and (t_fin(res)->>'deposit_balance')::bigint = 0 and t_count(format('select count(*) from financial_vouchers where reservation_id = %L and kind = %L', res, 'deposit_apply')) = 1, r::text);
exception when others then perform t_record('SC12a a damage charge carries its reason, comes off the deposit as far as it goes, and a replay adds nothing', false, sqlerrm); end $$;

do $$ declare res uuid; r jsonb; begin
  -- the usual case: a damage smaller than the deposit, the rest refunded on its own voucher after the inspection
  res := t_stay(t_id('n5'), t_today(), t_today() + 1, 'ضيف الأضرار');
  insert into ids values ('resDmg', res);
  perform t_ready(res); perform t_shomoos(res);
  r := t_check_in(res, 'sc12b');
  if not (r->>'ok')::boolean then raise exception 'check-in refused: %', r; end if;
  r := fn_staff_add_damage(jsonb_build_object('reservation_id', res, 'amount_halalas', 2000, 'reason', 'بقعة على السجاد', 'idempotency_key', 'sc12b-dmg'));
  r := fn_staff_check_out(jsonb_build_object('reservation_id', res));
  perform fn_staff_record_inspection(jsonb_build_object('reservation_id', res, 'result', 'notes', 'notes', 'بقعة على السجاد', 'suggested_deduction_halalas', 2000));
  r := fn_refund(jsonb_build_object('reservation_id', res, 'kind', 'deposit_refund', 'amount_halalas', 3000, 'method', 'cash', 'reason', 'باقي التأمين', 'idempotency_key', 'sc12b-ref'));
  perform t_record('SC12b damage 20.00 from a 50.00 deposit, the departure, the inspection with its suggested deduction, then 30.00 back on a separate voucher',
    (r->>'ok')::boolean and (t_fin(res)->>'deposit_balance')::bigint = 0 and (t_fin(res)->>'deposit_applied')::bigint = 2000
    and t_count(format('select count(*) from checkout_inspections where reservation_id = %L and status = %L and suggested_deduction_halalas = 2000', res, 'active')) = 1, r::text);
exception when others then perform t_record('SC12b damage 20.00 from a 50.00 deposit, the departure, the inspection with its suggested deduction, then 30.00 back on a separate voucher', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC13: «مغلق» by itself, and back when something reopens
do $$ declare res uuid := t_id('resDmg'); f jsonb; inv jsonb; s1 text; s2 text; s3 text; ai uuid; ref text; v uuid; begin
  -- Phase 4 (decision 27): the check-out invoiced the stay (its damage too); the deposit refund then closed it by itself
  s1 := (t_res(res)).status;
  ref := (t_res(res)).internal_ref;
  select id into ai from invoices where reservation_id = res and origin = 'checkout' and status = 'issued';
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform fn_cancel_invoice(ai, 'تجربة الإغلاق بلا فاتورة');
  s2 := (t_res(res)).status;
  f := fn_stay_followups('00000000-0000-0000-0000-000000000010');
  inv := fn_create_invoice(res);
  s3 := (t_res(res)).status;
  perform t_record('SC13a the departure invoices the stay and the deposit refund closes it by itself; without its invoice it is «غادر» (listed with what is missing), and a new invoice closes it again',
    s1 = 'closed' and ai is not null and s2 = 'checked_out' and f->>'departed_open' like '%' || ref || '%' and f->>'departed_open' like '%لم تُفوتر%'
    and s3 = 'closed' and (t_res(res)).closed_at is not null, format('%s → %s → %s (invoice %s)', s1, s2, s3, ai));
  select id into v from financial_vouchers where reservation_id = res and kind = 'deposit_refund' and status = 'approved';
  perform fn_cancel_voucher(v, 'رُد بالخطأ');
  perform t_record('SC13b a later change that breaks a condition takes it back to «غادر» (here the deposit refund is cancelled), in the audit',
    (t_res(res)).status = 'checked_out' and (t_res(res)).closed_at is null
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = %L', res, 'reservation.unclosed')) = 2, (t_res(res)).status::text);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
exception when others then perform t_record('SC13a the departure invoices the stay and the deposit refund closes it by itself; without its invoice it is «غادر» (listed with what is missing), and a new invoice closes it again', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC14: corrections and their windows (decisions 10, 46)
do $$ declare res uuid; r jsonb; m text := ''; begin
  res := t_stay(t_id('k2'), t_today(), t_today() + 2, 'ضيف التصحيح');
  insert into ids values ('resC', res);
  perform t_ready(res); perform t_shomoos(res);
  r := t_check_in(res, 'sc14');
  if not (r->>'ok')::boolean then raise exception 'check-in refused: %', r; end if;
  perform fn_staff_deliver_access_code(res, 'screen');
  m := t_fails(format('select fn_staff_undo_check_in(%L)', jsonb_build_object('reservation_id', res, 'reason', 'خطأ')), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  m := m || ' ' || t_fails(format('select fn_staff_undo_check_in(%L)', jsonb_build_object('reservation_id', res)), '%reason%');
  r := fn_staff_undo_check_in(jsonb_build_object('reservation_id', res, 'reason', 'سُجّل الوصول على الحجز الخطأ'));
  perform t_record('SC14a undoing an arrival: not the supervisor, a reason required; within 30 minutes the manager undoes it — a code given out must change, and the owner''s review list has it',
    m = 'ok ok' and (r->>'ok')::boolean and (t_res(res)).status = 'confirmed' and (t_res(res)).actual_check_in is null and (t_unit(t_id('k2'))).status = 'reserved'
    and (t_box(t_id('k2'))).code_status = 'needs_change' and (r->>'code_needs_change')::boolean
    and t_count(format('select count(*) from review_items where entity_id = %L and kind = %L and reviewed_at is null', res, 'check_in_undone')) = 1, m || ' ' || r::text);
  perform fn_staff_rotate_keybox_code(t_id('k2'), '9999', true);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_staff_check_in(jsonb_build_object('reservation_id', res));
  perform fn_staff_deliver_access_code(res, 'screen');
  perform t_backdate(res, 'check_in', 31);
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  perform t_record('SC14b after 30 minutes the arrival stays', (r->>'ok')::boolean and t_fails(format('select fn_staff_undo_check_in(%L)', jsonb_build_object('reservation_id', res, 'reason', 'متأخر')), 'CORRECTION_WINDOW_PASSED%') = 'ok', r::text);
exception when others then perform t_record('SC14a undoing an arrival: not the supervisor, a reason required; within 30 minutes the manager undoes it — a code given out must change, and the owner''s review list has it', false, sqlerrm); end $$;

do $$ declare res uuid := t_id('resC'); r jsonb; other uuid; m text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', (t_fin(res)->>'balance_due')::bigint, 'method', 'cash', 'idempotency_key', 'sc14c-pay'));
  r := fn_staff_check_out(jsonb_build_object('reservation_id', res));
  m := t_fails(format('select fn_staff_reopen_stay(%L)', jsonb_build_object('reservation_id', res, 'reason', 'خطأ')), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  r := fn_staff_reopen_stay(jsonb_build_object('reservation_id', res, 'reason', 'سُجّلت المغادرة قبل خروج الضيف'));
  perform t_record('SC14c reopening a departure within 2 hours (owner or manager): the stay is in house again, its unit allocated, the departure''s cleaning cancelled, the unchanged code still theirs',
    m = 'ok' and (r->>'ok')::boolean and (t_res(res)).status = 'checked_in' and (t_res(res)).actual_check_out is null
    and t_count(format('select count(*) from reservation_allocations where reservation_id = %L and status = %L', res, 'active')) = 1
    and t_count(format('select count(*) from housekeeping_tasks where reservation_id = %L and status = %L', res, 'cancelled')) = 1
    and (t_box(t_id('k2'))).code_status = 'active' and (t_unit(t_id('k2'))).status = 'occupied'
    and t_count(format('select count(*) from review_items where entity_id = %L and kind = %L', res, 'stay_reopened')) = 1, m || ' ' || r::text);
  -- leave again; meanwhile the unit is booked for someone else: the reopening is a conflict
  r := fn_staff_check_out(jsonb_build_object('reservation_id', res));
  other := t_stay(t_id('k2'), t_today(), t_today() + 1, 'ضيف بعده');
  perform t_record('SC14d a departure is not reopened over the next booking of its unit (a clear conflict), nor after 2 hours',
    t_fails(format('select fn_staff_reopen_stay(%L)', jsonb_build_object('reservation_id', res, 'reason', 'محاولة')), 'ALLOCATION_CONFLICT%') = 'ok'
    and (t_res(res)).status in ('checked_out', 'closed'), (t_res(res)).status::text);
  perform fn_staff_cancel_reservation(other, 'اختبار', 'staff');
  perform t_backdate(res, 'check_out', 121);
  perform t_record('SC14e after 2 hours the departure stays', t_fails(format('select fn_staff_reopen_stay(%L)', jsonb_build_object('reservation_id', res, 'reason', 'متأخر')), 'CORRECTION_WINDOW_PASSED%') = 'ok');
exception when others then perform t_record('SC14c reopening a departure within 2 hours (owner or manager): the stay is in house again, its unit allocated, the departure''s cleaning cancelled, the unchanged code still theirs', false, sqlerrm); end $$;

do $$ declare res uuid; res2 uuid; r jsonb; m text; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  res := t_stay(t_id('k3'), t_today() + 10, t_today() + 12, 'ضيف الإلغاء');
  perform fn_staff_cancel_reservation(res, 'طلب الضيف', 'staff');
  m := t_fails(format('select fn_staff_undo_cancel(%L)', jsonb_build_object('reservation_id', res, 'reason', 'خطأ')), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  r := fn_staff_undo_cancel(jsonb_build_object('reservation_id', res, 'reason', 'أُلغي بالخطأ'));
  perform t_record('SC14f undoing a cancellation within the hour (owner or manager): the stay is back as it was, with its unit',
    m = 'ok' and (r->>'ok')::boolean and (t_res(res)).status = 'confirmed' and (t_res(res)).cancelled_at is null
    and t_count(format('select count(*) from reservation_allocations where reservation_id = %L and status = %L', res, 'active')) = 1
    and t_count(format('select count(*) from review_items where entity_id = %L and kind = %L', res, 'cancel_undone')) = 1, m || ' ' || r::text);
  perform fn_staff_cancel_reservation(res, 'طلب الضيف مرة أخرى', 'staff');
  res2 := t_stay(t_id('k3'), t_today() + 11, t_today() + 13, 'ضيف أخذ الوحدة');
  m := t_fails(format('select fn_staff_undo_cancel(%L)', jsonb_build_object('reservation_id', res, 'reason', 'محاولة')), 'ALLOCATION_CONFLICT%');
  perform fn_staff_cancel_reservation(res2, 'اختبار', 'staff');
  perform t_backdate(res, 'cancel', 61);
  perform t_record('SC14g not over the unit''s next booking (a clear conflict), and not after the hour',
    m = 'ok' and t_fails(format('select fn_staff_undo_cancel(%L)', jsonb_build_object('reservation_id', res, 'reason', 'متأخر')), 'CORRECTION_WINDOW_PASSED%') = 'ok'
    and (t_res(res)).status = 'cancelled', m);
exception when others then perform t_record('SC14f undoing a cancellation within the hour (owner or manager): the stay is back as it was, with its unit', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC15: late check-out, a priced service with its hour
do $$ declare r jsonb; svc uuid; s jsonb; m text; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  m := t_fails(format('select fn_admin_upsert_service(%L)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'خروج 11', 'price_halalas', 1000, 'late_checkout_until', '11:00')), '%late_checkout_until%');
  r := fn_admin_upsert_service(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'خروج متأخر حتى 3 عصرًا', 'price_halalas', 5000, 'late_checkout_until', '15:00'));
  svc := (r->>'id')::uuid;
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_staff_add_service(t_id('resA'), svc);
  s := fn_stay_status(t_id('resA'));
  perform t_record('SC15 late check-out is a priced service that moves the departure to its hour (after the branch''s check-out time)',
    m = 'ok' and r->>'late_checkout_until' = '15:00' and (t_res(t_id('resA'))).late_checkout_until = '15:00' and s->>'departure_time' = '15:00'
    and t_count(format('select count(*) from reservation_charges where reservation_id = %L and purpose = %L and total_halalas = 5000', t_id('resA'), 'late_checkout')) = 1, m || ' ' || r::text);
exception when others then perform t_record('SC15 late check-out is a priced service that moves the departure to its hour (after the branch''s check-out time)', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC16: the day per employee, by method
do $$ declare s jsonb; o jsonb; begin
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  s := fn_staff_day_summary('00000000-0000-0000-0000-000000000010', t_today());
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  o := fn_staff_day_summary('00000000-0000-0000-0000-000000000010', t_today());
  perform t_record('SC16 what each employee received and paid back today, by kind and method; the supervisor sees their own only',
    not (s->>'everyone')::boolean and (o->>'everyone')::boolean
    and not exists (select 1 from jsonb_array_elements(s->'rows') x where x->>'staff_id' <> '10000000-0000-0000-0000-000000000002')
    and exists (select 1 from jsonb_array_elements(s->'rows') x where x->>'kind' = 'deposit_refund' and x->>'method' = 'cash')
    and exists (select 1 from jsonb_array_elements(o->'rows') x where x->>'staff_id' = '10000000-0000-0000-0000-000000000002')
    and jsonb_array_length(o->'rows') >= jsonb_array_length(s->'rows'), left(s::text, 200));
exception when others then perform t_record('SC16 what each employee received and paid back today, by kind and method; the supervisor sees their own only', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC17: units and types with commitments (decision 49)
do $$ declare r jsonb; cat2 uuid; res uuid; m text; v int; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  -- resA is in house in SC-K1: the unit is neither deactivated nor archived
  v := (t_unit(t_id('k1'))).version;
  m := t_fails(format('select fn_admin_upsert_room(%L)', jsonb_build_object('id', t_id('k1'), 'is_active', false, 'version', v)), 'ROOM_HAS_GUEST%')
    || ' ' || t_fails(format('select fn_admin_archive_definition(%L, %L, %L)', 'room', t_id('k1'), 'إيقاف'), 'ROOM_HAS_GUEST%');
  -- a type with a stay booked on it (no unit yet) is not archived; an archived type takes no booking
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع للأرشفة', 'base_price_halalas', 9000));
  cat2 := (r->>'id')::uuid;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', cat2, 'check_in', t_today() + 40, 'check_out', t_today() + 41,
         'guest_name', 'ضيف بلا وحدة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  m := m || ' ' || t_fails(format('select fn_admin_archive_definition(%L, %L, %L)', 'room_category', cat2, 'إيقاف'), 'HAS_OPEN_COMMITMENTS%');
  perform fn_staff_cancel_reservation(res, 'اختبار', 'staff');
  perform fn_admin_archive_definition('room_category', cat2, 'إيقاف');
  m := m || ' ' || t_fails(format('select fn_staff_create_reservation(%L)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', cat2,
         'check_in', t_today() + 42, 'check_out', t_today() + 43, 'guest_name', 'ضيف', 'source_id', '00000000-0000-0000-0000-000000000021')), '%');
  perform t_record('SC17 a unit with a guest in house is not deactivated or archived; a type with an open stay is not archived; an archived type takes no booking',
    m = 'ok ok ok ok' and (t_unit(t_id('k1'))).is_active, m);
exception when others then perform t_record('SC17 a unit with a guest in house is not deactivated or archived; a type with an open stay is not archived; an archived type takes no booking', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC18: a guest in house moves to another unit
do $$ declare r jsonb; a1 text; a2 text; begin
  -- resA (in house in SC-K1, code delivered) moves to SC-N3 (no box), then to SC-K3
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_staff_switch_room(t_id('resA'), t_id('n3'), null, 'طلب الضيف', (t_res(t_id('resA'))).version);
  a1 := (t_res(t_id('resA'))).access_status;
  r := fn_staff_switch_room(t_id('resA'), t_id('k3'), null, 'رجوع لوحدة بصندوق', (t_res(t_id('resA'))).version);
  a2 := (t_res(t_id('resA'))).access_status;
  perform t_record('SC18 moving in house: to a unit without a box its key is handed; to one with a box its code is delivered as its own step (nothing marks it the guest''s before)',
    a1 = 'key_handed' and a2 = 'approved' and (t_box(t_id('k3'))).last_reservation_id is distinct from t_id('resA')
    and (r->>'code_delivery_required')::boolean and (t_box(t_id('k1'))).code_status = 'needs_change', a1 || ' / ' || a2 || ' ' || r::text);
exception when others then perform t_record('SC18 moving in house: to a unit without a box its key is handed; to one with a box its code is delivered as its own step (nothing marks it the guest''s before)', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC19: who may (the §16 rows of this phase)
do $$ declare m text := ''; res uuid := t_id('resA'); begin
  perform t_login('a0000000-0000-0000-0000-000000000004', 'finance@test.local');
  m := m || t_fails(format('select fn_staff_check_in(%L)', jsonb_build_object('reservation_id', t_id('resDirty'))), 'FORBIDDEN%') || ' ';
  m := m || t_fails(format('select fn_staff_shomoos(%L)', jsonb_build_object('reservation_id', t_id('resDirty'), 'action', 'accept')), 'FORBIDDEN%') || ' ';
  m := m || t_fails(format('select fn_staff_check_out(%L)', jsonb_build_object('reservation_id', res)), 'FORBIDDEN%') || ' ';
  m := m || t_fails(format('select fn_staff_record_inspection(%L)', jsonb_build_object('reservation_id', res, 'result', 'ok')), 'FORBIDDEN%') || ' ';
  m := m || t_fails(format('select fn_staff_add_damage(%L)', jsonb_build_object('reservation_id', res, 'amount_halalas', 100, 'reason', 'x', 'idempotency_key', 'sc19')), 'FORBIDDEN%') || ' ';
  m := m || t_fails(format('select fn_staff_deliver_access_code(%L, %L)', res, 'screen'), 'FORBIDDEN%') || ' ';
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  m := m || t_fails(format('select fn_staff_check_in(%L)', jsonb_build_object('reservation_id', t_id('resDirty'))), 'FORBIDDEN%') || ' ';
  m := m || t_fails(format('select fn_staff_add_damage(%L)', jsonb_build_object('reservation_id', res, 'amount_halalas', 100, 'reason', 'x', 'idempotency_key', 'sc19')), 'FORBIDDEN%') || ' ';
  m := m || t_fails(format('select fn_staff_reopen_stay(%L)', jsonb_build_object('reservation_id', res, 'reason', 'x')), 'FORBIDDEN%');
  perform t_record('SC19a finance and housekeeping do not register arrivals or departures, Shomoos, damages or codes; finance does not inspect', m = 'ok ok ok ok ok ok ok ok ok', m);
  perform t_record('SC19b housekeeping''s view of a stay carries no money', (fn_stay_status(res)->'due') = 'null'::jsonb and (fn_stay_status(res)->'checkin') = 'null'::jsonb
    and fn_stay_status(res)->'shomoos'->>'reference' is null);
  perform t_login('a0000000-0000-0000-0000-000000000006', 'supB@test.local');
  perform t_record('SC19c another branch''s staff gets nothing', fn_stay_status(res) is null and t_fails(format('select fn_stay_followups(%L)', '00000000-0000-0000-0000-000000000010'), 'FORBIDDEN%') = 'ok');
exception when others then perform t_record('SC19a finance and housekeeping do not register arrivals or departures, Shomoos, damages or codes; finance does not inspect', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC20: the guest's page
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare e record; begin
  select * into e from fn_evaluate_access(t_id('resDirty'), false);
  perform t_record('SC20 before the arrival, what stands before the code is the arrival itself at reception',
    not e.allowed and array_to_string(e.reasons, ' | ') like '%يُسجَّل الوصول في الاستقبال%', array_to_string(e.reasons, ' | '));
exception when others then perform t_record('SC20 before the arrival, what stands before the code is the arrival itself at reception', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- SC21: a departure closed at once is still the day's departure
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'SC-N6'));
  insert into ids values ('n6', (r->>'id')::uuid);
end $$;
-- moves a whole stay by whole days (its nights and its unit's dates with it), so a stay that arrived yesterday can be made
reset role;
create or replace function t_shift(p uuid, p_days int) returns void language plpgsql security definer as $$
begin
  update reservation_allocations set from_date = from_date + p_days, to_date = to_date + p_days where reservation_id = p;
  update reservation_nights set night = night + p_days where reservation_id = p;
  update reservations set check_in = check_in + p_days, check_out = check_out + p_days where id = p;
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid; done0 int; done1 int; r jsonb; st text; begin
  res := t_stay(t_id('n6'), t_today(), t_today() + 1, 'ضيف يغادر اليوم');
  perform t_ready(res); perform t_shomoos(res);
  r := t_check_in(res, 'sc21');
  perform t_shift(res, -1);   -- arrived yesterday, leaves today
  done0 := (fn_ops_daily_summary('00000000-0000-0000-0000-000000000010', t_today())->'departures'->>'done')::int;
  perform fn_staff_check_out(jsonb_build_object('reservation_id', res));
  perform fn_staff_record_inspection(jsonb_build_object('reservation_id', res, 'result', 'ok'));
  perform fn_refund(jsonb_build_object('reservation_id', res, 'kind', 'deposit_refund', 'amount_halalas', 5000, 'method', 'cash', 'reason', 'إرجاع التأمين', 'idempotency_key', 'sc21-drf'));
  st := (t_res(res)).status::text;
  done1 := (fn_ops_daily_summary('00000000-0000-0000-0000-000000000010', t_today())->'departures'->>'done')::int;
  perform t_record('SC21 a departure settled at once (the check-out invoices it itself) is «مغلق» and still counts among the day''s departures',
    (r->>'ok')::boolean and st = 'closed' and done1 = done0 + 1
    and t_count(format('select count(*) from invoices where reservation_id = %L and origin = %L and status = %L', res, 'checkout', 'issued')) = 1,
    format('ok=%s status=%s done %s→%s', r->>'ok', st, done0, done1));
exception when others then perform t_record('SC21 a departure settled at once (the check-out invoices it itself) is «مغلق» and still counts among the day''s departures', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 45 then raise exception 'STAY CYCLE TESTS INCOMPLETE: % of 45 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'STAY CYCLE TESTS FAILED'; end if;
end $$;
