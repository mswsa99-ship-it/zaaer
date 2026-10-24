-- =====================================================================
-- Rates (Phase 2, migration 0030): decisions 9, 15, 32, 33 and the rounding rule of 47.
-- PR01–PR12: the price calendar (base fallback, platform row, group edits, past nights, the minimum, audit),
-- weekly and monthly prices spread over the nights with the remainder on the last night, the per-night snapshot
-- used when extending and shortening, the supervisor's discount limits and the discount report, the capacity
-- impact of a unit type, and the calendar's available-of-total row.
-- Runs after core_tests.sql on the same database (uses its synthetic organisation, branch 010 and staff).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table days(k text primary key, v date);
grant all on days to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_day(p_k text) returns date language sql security definer as $$ select v from days where k = p_k $$;
create or replace function t_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_nights(p uuid) returns text language sql security definer as $$
  select string_agg(price_halalas::text || ':' || basis, ',' order by night) from reservation_nights where reservation_id = p and status = 'active'
$$;
create or replace function t_cal(p_cat uuid, p_night date) returns rate_calendar language sql security definer as $$
  select * from rate_calendar where category_id = p_cat and night = p_night
$$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
-- runs the quote as the current user
create or replace function t_quote(p_cat uuid, p_from date, p_to date, p_source text) returns jsonb language plpgsql as $$
begin
  return fn_quote_stay(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', p_cat, 'check_in', p_from, 'check_out', p_to,
                                          'source_id', p_source));
end $$;

-- ---------------------------------------------------------------- fixtures
insert into days values ('D', fn_branch_today('00000000-0000-0000-0000-000000000010') + 200);
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b branches%rowtype; begin
  -- a type priced by channel: base 200.00, weekly 1250.00 (178.57 a night), monthly 4550.00 (151.67 a night), minimum 150.00
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع الأسعار', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 20000, 'weekly_price_halalas', 125000, 'monthly_price_halalas', 455000, 'min_nightly_halalas', 15000, 'price_mode', 'by_channel'));
  insert into ids values ('cat', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'PR-1'));
  insert into ids values ('room1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'PR-2'));
  insert into ids values ('room2', (r->>'id')::uuid);
  -- the supervisor may give up to 10% (the default is 0: no supervisor discount until the owner or a manager sets it)
  select * into b from branches where id = '00000000-0000-0000-0000-000000000010';
  perform fn_admin_upsert_branch(jsonb_build_object('id', b.id, 'name_ar', b.name_ar, 'version', b.version, 'supervisor_max_discount_bp', 1000));
end $$;

-- ---------------------------------------------------------------- PR01–PR02: the calendar decides each night
do $$ declare q jsonb; begin
  perform fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 25000,
            'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', t_day('D') + 1))));
  q := t_quote(t_id('cat'), t_day('D'), t_day('D') + 3, '00000000-0000-0000-0000-000000000021');
  perform t_record('PR01 a night without a calendar price takes the base price; a calendar price replaces it for that night only',
    (q->>'rent_gross')::bigint = 65000 and jsonb_array_length(q->'runs') = 3 and q->'runs'->0->>'basis' = 'base' and q->'runs'->1->>'basis' = 'calendar'
    and (q->'runs'->1->>'price')::bigint = 25000 and q->>'basis' = 'daily' and q->>'channel' = 'system', q::text);
exception when others then perform t_record('PR01 a night without a calendar price takes the base price; a calendar price replaces it for that night only', false, sqlerrm); end $$;

do $$ declare qp jsonb; qd jsonb; u jsonb; begin
  perform fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'platform_price_halalas', 22000,
            'from', t_day('D'), 'to', t_day('D') + 2, 'category_ids', jsonb_build_array(t_id('cat'), '00000000-0000-0000-0000-000000000030')));
  qp := t_quote(t_id('cat'), t_day('D'), t_day('D') + 3, '00000000-0000-0000-0000-000000000020');
  qd := t_quote(t_id('cat'), t_day('D'), t_day('D') + 3, '00000000-0000-0000-0000-000000000021');
  u := t_quote('00000000-0000-0000-0000-000000000030', t_day('D'), t_day('D') + 1, '00000000-0000-0000-0000-000000000020');
  perform t_record('PR02 a platform booking of a type priced by channel takes the platform row; the reception takes the system row; a unified type has no platform row',
    (qp->>'rent_gross')::bigint = 66000 and qp->>'channel' = 'platform' and qp->'runs'->0->>'basis' = 'platform'
    and (qd->>'rent_gross')::bigint = 65000
    and (t_cal('00000000-0000-0000-0000-000000000030', t_day('D'))).platform_price_halalas is null
    and u->'runs'->0->>'basis' = 'base', qp::text || ' / ' || u::text);
exception when others then perform t_record('PR02 a platform booking of a type priced by channel takes the platform row; the reception takes the system row; a unified type has no platform row', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR03: weekly and monthly prices (decisions 15, 47)
do $$ declare w jsonb; m jsonb; r jsonb; rid uuid; n_rent bigint; begin
  w := t_quote(t_id('cat'), t_day('D') + 10, t_day('D') + 17, '00000000-0000-0000-0000-000000000021');
  m := t_quote(t_id('cat'), t_day('D') + 100, t_day('D') + 130, '00000000-0000-0000-0000-000000000021');
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', t_day('D') + 10, 'check_out', t_day('D') + 17, 'guest_name', 'ضيف أسبوعي', 'source_id', '00000000-0000-0000-0000-000000000021'));
  rid := (r->>'id')::uuid; insert into ids values ('resWeek', rid);
  -- a later change of the weekly price and the calendar never touches the stay
  perform fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 40000,
            'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', t_day('D') + 12))));
  select coalesce(sum(round(quantity * unit_price_halalas)), 0) into n_rent from reservation_charges where reservation_id = rid and kind = 'rent';
  perform t_record('PR03 7+ nights take the weekly price and 30+ the monthly, spread over the nights with the remainder on the last night; the stay keeps its prices',
    (w->>'rent_gross')::bigint = 125000 and w->>'basis' = 'weekly' and (w->'runs'->0->>'price')::bigint = 17857 and (w->'runs'->0->>'nights')::int = 6
    and (w->'runs'->1->>'price')::bigint = 17858
    and (m->>'rent_gross')::bigint = 455000 and m->>'basis' = 'monthly' and (m->'runs'->0->>'price')::bigint = 15166 and (m->'runs'->1->>'price')::bigint = 15186
    and (t_res(rid)).price_basis = 'weekly' and t_nights(rid) = '17857:weekly,17857:weekly,17857:weekly,17857:weekly,17857:weekly,17857:weekly,17858:weekly'
    and n_rent = 125000 and (t_res(rid)).rent_amount_halalas = 125000, w::text);
exception when others then perform t_record('PR03 7+ nights take the weekly price and 30+ the monthly, spread over the nights with the remainder on the last night; the stay keeps its prices', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR04: who edits, which nights, how low, and the audit
do $$ declare r1 text; r2 text; r3 text; r4 text; e audit_events; begin
  r1 := t_fails(format('select fn_rate_calendar_set(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 14000,
          'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', t_day('D') + 5)))), 'VALIDATION: below_minimum%');
  r2 := t_fails(format('select fn_rate_calendar_set(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 30000,
          'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', fn_branch_today('00000000-0000-0000-0000-000000000010') - 1)))), 'VALIDATION: past_night%');
  select * into e from audit_events where action = 'rates.updated' and branch_id = '00000000-0000-0000-0000-000000000010' order by created_at desc limit 1;
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r3 := t_fails(format('select fn_rate_calendar_set(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 30000,
          'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', t_day('D') + 5)))), 'FORBIDDEN%');
  r4 := t_fails(format('select fn_rate_calendar(%L, %L, %L)', '00000000-0000-0000-0000-000000000010', t_day('D'), t_day('D') + 3), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('PR04 no price under the minimum, no past night, only the owner or a manager; each edit is audited with what it replaced',
    r1 = 'ok' and r2 = 'ok' and r3 = 'ok' and r4 = 'ok' and e.id is not null
    and (e.details->'before'->'cells'->0->>'night')::date = t_day('D') + 12 and (e.details->'before'->'cells'->0->>'price') is null
    and (e.details->'after'->>'changed')::int = 1 and (e.details->'after'->>'price_halalas')::bigint = 40000,
    r1 || ' / ' || r2 || ' / ' || r3 || ' / ' || r4 || ' / ' || coalesce(e.details::text, 'no audit'));
exception when others then perform t_record('PR04 no price under the minimum, no past night, only the owner or a manager; each edit is audited with what it replaced', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR05: a group edit and clearing it
do $$ declare r jsonb; expected int; set_n bigint; other bigint; cleared jsonb; q jsonb; e audit_events; begin
  -- Fridays and Saturdays of two weeks, for two types
  r := fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 30000,
         'from', t_day('D') + 40, 'to', t_day('D') + 53, 'weekdays', jsonb_build_array(5, 6),
         'category_ids', jsonb_build_array(t_id('cat'), '00000000-0000-0000-0000-000000000030')));
  select count(*) * 2 into expected from generate_series(t_day('D') + 40, t_day('D') + 53, interval '1 day') g where extract(dow from g)::int in (5, 6);
  set_n := t_count(format('select count(*) from rate_calendar where category_id in (%L, %L) and night between %L and %L and price_halalas = 30000',
             t_id('cat'), '00000000-0000-0000-0000-000000000030', t_day('D') + 40, t_day('D') + 53));
  other := t_count(format('select count(*) from rate_calendar where category_id in (%L, %L) and night between %L and %L and price_halalas is not null and extract(dow from night)::int not in (5, 6)',
             t_id('cat'), '00000000-0000-0000-0000-000000000030', t_day('D') + 40, t_day('D') + 53));
  cleared := fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'clear', true,
         'from', t_day('D') + 40, 'to', t_day('D') + 53, 'category_ids', jsonb_build_array(t_id('cat'))));
  q := t_quote(t_id('cat'), t_day('D') + 40, t_day('D') + 42, '00000000-0000-0000-0000-000000000021');
  select * into e from audit_events where action = 'rates.updated' and branch_id = '00000000-0000-0000-0000-000000000010'
    and details->'after'->>'clear' = 'both' order by created_at desc limit 1;
  perform t_record('PR05 a group edit (from–to × types × weekdays) sets exactly the matching nights; clearing returns them to the base price',
    (r->>'changed')::int = expected and (e.details->'before'->'cells'->0->>'price')::bigint = 30000 and e.details->'after'->>'clear' = 'both'
    and (q->>'rent_gross')::bigint = 40000 and set_n = expected and other = 0 and (cleared->>'changed')::int = expected / 2
    and (select count(*) from rate_calendar where category_id = t_id('cat') and night between t_day('D') + 40 and t_day('D') + 53 and price_halalas is not null) = 0,
    r::text || ' expected=' || expected || ' set=' || set_n || ' other=' || other || ' cleared=' || cleared::text);
exception when others then perform t_record('PR05 a group edit (from–to × types × weekdays) sets exactly the matching nights; clearing returns them to the base price', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR06: the supervisor's discount limits (decision 9)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare q jsonb; ok jsonb; r1 text; r2 text; r3 text; r4 text; r5 text; base jsonb; begin
  base := jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'check_in', t_day('D') + 60, 'check_out', t_day('D') + 63,
            'guest_name', 'ضيف الخصم', 'source_id', '00000000-0000-0000-0000-000000000021');
  -- 3 nights × 200.00 = 600.00: 10% is 60.00, and the minimum (3 × 150.00) leaves room for 150.00
  q := t_quote(t_id('cat'), t_day('D') + 60, t_day('D') + 63, '00000000-0000-0000-0000-000000000021');
  ok := fn_staff_create_reservation(base || jsonb_build_object('discount_halalas', 6000, 'discount_reason', 'ضيف دائم'));
  insert into ids values ('resDisc', (ok->>'id')::uuid);
  r1 := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', base || jsonb_build_object('discount_halalas', 6001, 'discount_reason', 'أكثر')), 'VALIDATION: discount_percent%');
  r2 := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', base || jsonb_build_object('discount_halalas', 1000)), 'VALIDATION: discount_reason%');
  r3 := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', base || jsonb_build_object('nightly_rate_halalas', 19000)), 'FORBIDDEN%');
  -- on an existing stay: the discounts add up against the same limit
  r4 := t_fails(format('select fn_staff_adjust_price(%L, %L, %s, %L, %L, %s)', (ok->>'id'), 'discount', 100, 'خصم', 'إضافي', (t_res((ok->>'id')::uuid)).version), 'VALIDATION: discount_percent%');
  -- a raised manual price is fine for the supervisor
  r5 := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', base || jsonb_build_object('nightly_rate_halalas', 21000, 'guest_name', 'سعر أعلى')), 'never');
  perform t_record('PR06 the supervisor discounts with a reason within the percentage; more, no reason, or a lower manual price are refused',
    (q->>'discount_max')::bigint = 6000 and (q->>'supervisor_discount_max')::bigint = 6000 and (t_res((ok->>'id')::uuid)).discount_halalas = 6000
    and r1 = 'ok' and r2 = 'ok' and r3 = 'ok' and r4 = 'ok' and r5 = 'accepted', q::text || ' / ' || r1 || ' / ' || r2 || ' / ' || r3 || ' / ' || r4 || ' / ' || r5);
exception when others then perform t_record('PR06 the supervisor discounts with a reason within the percentage; more, no reason, or a lower manual price are refused', false, sqlerrm); end $$;
-- the minimum nightly price is the other limit: with 50% allowed, 200.00 off a 600.00 stay goes under 3 × 150.00
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare b branches%rowtype; begin
  select * into b from branches where id = '00000000-0000-0000-0000-000000000010';
  perform fn_admin_upsert_branch(jsonb_build_object('id', b.id, 'name_ar', b.name_ar, 'version', b.version, 'supervisor_max_discount_bp', 5000));
end $$;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r1 text; q jsonb; begin
  q := t_quote(t_id('cat'), t_day('D') + 64, t_day('D') + 67, '00000000-0000-0000-0000-000000000021');
  r1 := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
          'check_in', t_day('D') + 64, 'check_out', t_day('D') + 67, 'guest_name', 'تحت الأدنى', 'source_id', '00000000-0000-0000-0000-000000000021',
          'discount_halalas', 20000, 'discount_reason', 'كثير')), 'VALIDATION: discount_minimum%');
  perform t_record('PR06b the supervisor never takes a night under the type''s minimum; the window shows the smaller of the two limits',
    r1 = 'ok' and (q->>'discount_max')::bigint = 15000, r1 || ' / ' || q::text);
end $$;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', t_day('D') + 64, 'check_out', t_day('D') + 67, 'guest_name', 'خصم المدير', 'source_id', '00000000-0000-0000-0000-000000000021',
         'discount_halalas', 20000, 'discount_reason', 'تعويض'));
  perform t_record('PR06c beyond both limits the discount is the owner''s or a manager''s', (t_res((r->>'id')::uuid)).discount_halalas = 20000, r::text);
exception when others then perform t_record('PR06c beyond both limits the discount is the owner''s or a manager''s', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR07: extending and shortening by the nights' own prices
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r jsonb; rid uuid; total0 bigint; total1 bigint; total2 bigint; total3 bigint; removed int; adj bigint; begin
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 25000,
            'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', t_day('D') + 71))));
  perform fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 26000,
            'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', t_day('D') + 75))));
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', t_day('D') + 70, 'check_out', t_day('D') + 73, 'guest_name', 'ضيف التعديل', 'source_id', '00000000-0000-0000-0000-000000000021'));
  rid := (r->>'id')::uuid; insert into ids values ('resAmend', rid);
  total0 := (t_res(rid)).total_halalas;                                                   -- 200 + 250 + 200 = 650.00
  perform fn_staff_amend_stay(rid, t_day('D') + 72, 'keep_rate', 'خروج مبكر', (t_res(rid)).version);
  total1 := (t_res(rid)).total_halalas;                                                   -- the removed night was 200.00, not the 216.67 average
  select count(*) into removed from reservation_nights where reservation_id = rid and status = 'removed' and removed_reason = 'خروج مبكر';
  select sum(total_halalas) into adj from reservation_charges where reservation_id = rid and kind = 'adjustment';
  perform fn_staff_amend_stay(rid, t_day('D') + 75, 'keep_rate', 'تمديد بنفس السعر', (t_res(rid)).version);
  total2 := (t_res(rid)).total_halalas;                                                   -- + 3 nights × 250.00 (the last night's price)
  perform fn_staff_amend_stay(rid, t_day('D') + 77, 'reprice', 'تمديد بسعر التقويم', (t_res(rid)).version);
  total3 := (t_res(rid)).total_halalas;                                                   -- + 260.00 (calendar) + 200.00 (base)
  perform t_record('PR07 shortening refunds exactly the removed nights'' prices; extending keeps the last night''s price or takes the calendar''s',
    total0 = 65000 and total1 = 45000 and removed = 1 and adj = -20000 and total2 = 120000 and total3 = 166000
    and t_nights(rid) = '20000:base,25000:calendar,25000:kept,25000:kept,25000:kept,26000:calendar,20000:base',
    total0 || ' ' || total1 || ' ' || total2 || ' ' || total3 || ' removed=' || removed || ' adj=' || adj || ' nights=' || t_nights(rid));
exception when others then perform t_record('PR07 shortening refunds exactly the removed nights'' prices; extending keeps the last night''s price or takes the calendar''s', false, sqlerrm); end $$;
do $$ declare r1 text; refund bigint; before_total bigint; begin
  -- leaving a weekly stay early is the owner's or a manager's (decision 15)
  r1 := t_fails(format('select fn_staff_amend_stay(%L, %L, %L, %L, %s)', t_id('resWeek'), t_day('D') + 14, 'keep_rate', 'خروج مبكر', (t_res(t_id('resWeek'))).version), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  before_total := (t_res(t_id('resWeek'))).total_halalas;
  perform fn_staff_amend_stay(t_id('resWeek'), t_day('D') + 14, 'keep_rate', 'خروج مبكر بقرار المدير', (t_res(t_id('resWeek'))).version);
  refund := before_total - (t_res(t_id('resWeek'))).total_halalas;
  perform t_record('PR07b shortening a weekly stay is the manager''s; the refund is its removed nights at their weekly prices',
    r1 = 'ok' and refund = 17857 * 2 + 17858, r1 || ' refund=' || refund);
exception when others then perform t_record('PR07b shortening a weekly stay is the manager''s; the refund is its removed nights at their weekly prices', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR08: the discount report
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare full_r jsonb; sup_r jsonb; mine jsonb; begin
  full_r := fn_reports_discounts('00000000-0000-0000-0000-000000000010', fn_branch_today('00000000-0000-0000-0000-000000000010') - 1, fn_branch_today('00000000-0000-0000-0000-000000000010') + 1);
  select x into mine from jsonb_array_elements(full_r->'rows') x where x->>'reservation_id' = t_id('resDisc')::text;
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  sup_r := fn_reports_discounts('00000000-0000-0000-0000-000000000010', fn_branch_today('00000000-0000-0000-0000-000000000010') - 1, fn_branch_today('00000000-0000-0000-0000-000000000010') + 1);
  perform t_record('PR08 the discount report shows who, how much and why; the supervisor gets the totals only',
    (mine->>'amount_halalas')::bigint = 6000 and mine->>'reason' = 'ضيف دائم' and mine->>'role' = 'supervisor' and (full_r->>'count')::int >= 2
    and sup_r->'rows' = 'null'::jsonb and (sup_r->>'total_halalas')::bigint = (full_r->>'total_halalas')::bigint,
    coalesce(mine::text, 'no row') || ' / ' || sup_r::text);
exception when others then perform t_record('PR08 the discount report shows who, how much and why; the supervisor gets the totals only', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR09–PR10: capacity impact and the calendar's availability
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; impact jsonb; c room_categories%rowtype; up jsonb; cal jsonb; d0 jsonb; d1 jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_id', t_id('room1'),
         'check_in', t_day('D') + 1, 'check_out', t_day('D') + 2, 'guest_name', 'ثلاثة', 'adults', 2, 'companions', 1, 'source_id', '00000000-0000-0000-0000-000000000021'));
  impact := fn_category_capacity_impact(t_id('cat'), 2);
  select * into c from room_categories where id = t_id('cat');
  up := fn_admin_upsert_room_category(jsonb_build_object('id', c.id, 'name_ar', c.name_ar, 'version', c.version, 'max_capacity', 2));
  perform t_record('PR09 lowering a type''s capacity lists the upcoming stays that no longer fit',
    jsonb_array_length(impact) = 1 and impact->0->>'id' = r->>'id' and (up->>'stays_over_capacity')::int = 1, impact::text || ' / ' || up::text);
  cal := fn_rate_calendar('00000000-0000-0000-0000-000000000010', t_day('D'), t_day('D') + 2);
  select x->'days'->0, x->'days'->1 into d0, d1 from jsonb_array_elements(cal->'categories') x where x->>'id' = t_id('cat')::text;
  perform t_record('PR10 the calendar shows each night''s price (empty = base) and the units free of the type''s total',
    (d0->>'available')::int = 2 and (d1->>'available')::int = 1 and (d1->>'price')::bigint = 25000 and d0->>'price' is null
    and (d0->>'platform_price')::bigint = 22000 and cal->>'today' is not null, coalesce(d0::text, 'none') || ' / ' || coalesce(d1::text, 'none'));
exception when others then perform t_record('PR09 lowering a type''s capacity lists the upcoming stays that no longer fit', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR11: a stay made before 0030 gets its nights from its rent lines
reset role;
do $$ declare rid uuid := gen_random_uuid(); begin
  insert into reservations(id, organization_id, branch_id, source_id, status, check_in, check_out, adults, companions, room_category_id, nightly_rate_halalas, internal_ref)
  values (rid, '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000021', 'confirmed',
          t_day('D') + 150, t_day('D') + 154, 1, 0, t_id('cat'), 30000, 'R-LEGACY-PR11');
  insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, service_from, service_to)
  values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', rid, 'rent', 'إيجار قديم', 2, 30000, 60000, true, t_day('D') + 150, t_day('D') + 152),
         ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', rid, 'rent', 'تمديد قديم', 2, 35000, 70000, true, t_day('D') + 152, t_day('D') + 154);
  perform fn_recompute_reservation_finance(rid);
  insert into ids values ('resLegacy', rid);
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare rid uuid := t_id('resLegacy'); before_total bigint; begin
  before_total := (t_res(rid)).total_halalas;
  perform fn_staff_amend_stay(rid, t_day('D') + 153, 'keep_rate', 'خروج مبكر', (t_res(rid)).version);
  perform t_record('PR11 a stay without nights gets them from its rent lines; shortening it refunds the covering line''s price',
    before_total = 130000 and (t_res(rid)).total_halalas = 95000
    and t_nights(rid) = '30000:legacy,30000:legacy,35000:legacy', before_total || ' → ' || (t_res(rid)).total_halalas || ' nights=' || coalesce(t_nights(rid), 'none'));
exception when others then perform t_record('PR11 a stay without nights gets them from its rent lines; shortening it refunds the covering line''s price', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- PR12: a type with calendar prices is archived, not removed (decision 48)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; c2 uuid; res jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع بلا حجوزات', 'base_price_halalas', 18000));
  c2 := (r->>'id')::uuid;
  perform fn_rate_calendar_set(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'price_halalas', 19000,
            'cells', jsonb_build_array(jsonb_build_object('category_id', c2, 'night', t_day('D') + 3))));
  res := fn_admin_delete_definition('room_category', c2);
  perform t_record('PR12 a unit type with calendar prices is not removed: the answer lists them and the archive is offered',
    res->>'error' = 'HAS_DEPENDENCIES' and (res->'dependencies'->>'rate_calendar')::int = 1, res::text);
exception when others then perform t_record('PR12 a unit type with calendar prices is not removed: the answer lists them and the archive is offered', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 15 then raise exception 'RATES TESTS INCOMPLETE: % of 15 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'RATES TESTS FAILED'; end if;
end $$;
