-- =====================================================================
-- Plan 7.4 / observation O7: «وحدة محجوزة بلا حجز ظاهر» — a unit flagged «محجوزة» whose bookings do not
-- cover today must be raised by the post-go-live monitoring (0037, re-scoped per hotel in 0081), like the seven
-- checks of decision 54. This file CREATES the state and EXPECTS the alert (معيار القبول: SQL يصنع الحالة
-- ويتوقع التنبيه).
--
-- Cause in the code (يُعرف سببها في الكود): rooms.status = 'reserved' is a stored operational flag written
-- piecemeal — fn_allocate (0053) sets it when an allocation covers the branch's today, fn_staff_undo_check_in
-- (0043) sets it back from 'occupied', fn_staff_undo_cancel (0038) re-sets it with the restored allocation, and
-- fn_release_allocations (0007c) clears it only when the released allocation covers today. Nothing verifies the
-- invariant afterwards: fn_recompute_room_ready (0033) returns 'reserved' unchanged without looking at any
-- booking, and none of the seven monitor kinds compares rooms.status with reservation_allocations. So any drift
-- — a direct update, an interrupted operation, or a future writer that forgets the release — stays invisible
-- forever. Verified on a disposable database (24 Nov 2026, base 0d40132): creating a fully-past stay is refused
-- (PAST_STAY), and cancel / no-show / undo-cancel / undo-check-in keep the flag consistent; the missing piece
-- is detection, which is what this test pins.
--
-- Names are descriptive and carry no code: the RB prefix («المراقبة: وحدة محجوزة بلا حجز») is proposed for
-- tests/acceptance-library.json at integration, per the parallel-work contract.
--
-- The anomalies are written directly, exactly like monitors_tests.sql: the product's own functions keep the flag
-- consistent on every path they offer, so the state the monitor must catch can only be made by writing it.
-- Self-contained (own staff, category and rooms; branch 010 of the demo seed). Wire into tests/sql/run.sh AFTER
-- monitors_tests.sql: it tolerates that file's leftovers, marks its own findings reviewed, and frees its rooms.
--
-- EXPECTED TODAY: this file FAILS — the check does not exist yet. It passes once the integrator applies the
-- proposed check (tests/sql/proposed_0082_reserved_without_booking.sql) as a new migration.
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
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
create or replace function t_run() returns jsonb language sql security definer as $$ select fn_run_monitors('00000000-0000-0000-0000-000000000010') $$;
create or replace function t_findings(p_room uuid) returns bigint language sql security definer as $$
  select count(*) from review_items where kind = 'monitor:reserved_without_booking' and entity_id = p_room
$$;
create or replace function t_finding(p_room uuid) returns review_items language sql security definer as $$
  select * from review_items where kind = 'monitor:reserved_without_booking' and entity_id = p_room order by created_at desc limit 1
$$;
create or replace function t_recompute(p_room uuid) returns room_status language sql security definer as $$ select fn_recompute_room_ready(p_room) $$;
-- the anomalies are written directly (security definer, as monitors_tests.sql does): RLS would silently skip them
create or replace function t_set_reserved(p_room uuid) returns void language sql security definer as $$
  update rooms set status = 'reserved' where id = p_room
$$;
create or replace function t_set_off_reserved(p_room uuid) returns void language sql security definer as $$
  update rooms set status = 'reserved', is_active = false where id = p_room
$$;
create or replace function t_drift_cancel(p_reservation uuid) returns void language plpgsql security definer as $$
begin
  update reservation_allocations set status = 'cancelled', closed_at = now() where reservation_id = p_reservation and status = 'active';
  update reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = 'محاكاة انحراف', updated_at = now() where id = p_reservation;
end $$;
create or replace function t_reset_rooms() returns void language sql security definer as $$
  update rooms set status = 'available', is_active = true where room_number in ('RW-2', 'RW-3', 'RW-4')
$$;
create or replace function t_stay(p_room uuid, p_from date, p_to date, p_name text) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'room_id', p_room, 'check_in', p_from, 'check_out', p_to, 'guest_name', p_name, 'guest_phone', '0500007' || lpad((floor(random() * 1000))::int::text, 3, '0'),
         'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;

-- ---------------------------------------------------------------- fixtures (invented only)
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('10000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','المالك','owner@test.local','owner')
on conflict (id) do nothing;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; v uuid; begin
  select id into v from room_categories where branch_id = '00000000-0000-0000-0000-000000000010' and name_ar = 'نوع مراقبة الحجز' limit 1;
  if v is null then
    r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع مراقبة الحجز', 'base_capacity', 2, 'max_capacity', 3,
           'base_price_halalas', 10000));
    v := (r->>'id')::uuid;
  end if;
  insert into ids values ('cat', v);
  select id into v from rooms where branch_id = '00000000-0000-0000-0000-000000000010' and room_number = 'RW-1';
  if v is null then r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'RW-1')); v := (r->>'id')::uuid; end if;
  insert into ids values ('ok', v);
  select id into v from rooms where branch_id = '00000000-0000-0000-0000-000000000010' and room_number = 'RW-2';
  if v is null then r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'RW-2')); v := (r->>'id')::uuid; end if;
  insert into ids values ('bare', v);
  select id into v from rooms where branch_id = '00000000-0000-0000-0000-000000000010' and room_number = 'RW-3';
  if v is null then r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'RW-3')); v := (r->>'id')::uuid; end if;
  insert into ids values ('stale', v);
  select id into v from rooms where branch_id = '00000000-0000-0000-0000-000000000010' and room_number = 'RW-4';
  if v is null then r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'RW-4')); v := (r->>'id')::uuid; end if;
  insert into ids values ('off', v);
  -- RW-1: a real booking covering today through the product's own functions (the flag is set legitimately)
  insert into ids values ('stay', t_stay(t_id('ok'), t_today(), t_today() + 2, 'ضيف المراقبة أ'));
end $$;

do $$ declare r jsonb; ri review_items; begin
  -- the state the plan names: RW-2 flagged «محجوزة» with no allocation at all; RW-3's booking cancelled while the
  -- flag was left behind (what any writer that forgets the release leaves); RW-4 the same but out of service
  perform t_set_reserved(t_id('bare'));
  insert into ids values ('stay3', t_stay(t_id('stale'), t_today(), t_today() + 2, 'ضيف المراقبة ب'));
  perform t_drift_cancel(t_id('stay3'));
  perform t_set_off_reserved(t_id('off'));
  perform t_run();
  ri := t_finding(t_id('bare'));
  perform t_record('a unit flagged reserved with no booking at all raises the alert, naming the unit',
    ri.id is not null and ri.entity_type = 'room' and ri.summary like '%RW-2%', coalesce(ri.summary, 'no finding'));
  ri := t_finding(t_id('stale'));
  perform t_record('a unit whose booking ended while the flag stayed raises the alert, naming the unit',
    ri.id is not null and ri.summary like '%RW-3%', coalesce(ri.summary, 'no finding'));
  perform t_record('a unit whose flag matches its booking raises no alert',
    t_findings(t_id('ok')) = 0, 'findings for RW-1: ' || t_findings(t_id('ok')));
  perform t_record('a unit out of service is not flagged',
    t_findings(t_id('off')) = 0, 'findings for RW-4: ' || t_findings(t_id('off')));
exception when others then perform t_record('a unit flagged reserved with no booking at all raises the alert, naming the unit', false, sqlerrm); end $$;

do $$ declare n1 bigint; n2 bigint; ri review_items; begin
  n1 := t_findings(t_id('bare')) + t_findings(t_id('stale'));
  perform t_run();
  n2 := t_findings(t_id('bare')) + t_findings(t_id('stale'));
  perform t_record('the alert is raised once per unit, not on every run',
    n2 = n1, format('before %s, after a second run %s', n1, n2));
  ri := t_finding(t_id('stale'));
  perform t_record('the alert carries no personal data (no phone, no guest name)',
    ri.id is not null and (ri.summary || coalesce(ri.details::text, '')) !~ '05[0-9]'
    and (ri.summary || coalesce(ri.details::text, '')) not like '%ضيف المراقبة%',
    left(coalesce(ri.summary, 'no finding') || ' | ' || coalesce(ri.details::text, ''), 120));
exception when others then perform t_record('the alert is raised once per unit, not on every run', false, sqlerrm); end $$;

do $$ declare st room_status; begin
  -- why the monitor is the detector: recomputing readiness does not question a stored «محجوزة» (0033 §5)
  st := t_recompute(t_id('bare'));
  perform t_record('recomputing readiness keeps the stale flag, so detection needs the monitor',
    st = 'reserved' and (select status from rooms where id = t_id('bare')) = 'reserved'
    and not exists (select 1 from reservation_allocations a where a.room_id = t_id('bare') and a.status = 'active'),
    'recompute returned ' || st);
exception when others then perform t_record('recomputing readiness keeps the stale flag, so detection needs the monitor', false, sqlerrm); end $$;

-- ---------------------------------------------------------------- cleanup: nothing here may leak into later suite files
do $$ declare l jsonb; begin
  perform fn_staff_cancel_reservation(t_id('stay'), 'انتهى الاختبار', 'staff', null);
  perform t_reset_rooms();
  select jsonb_build_object('ids', jsonb_agg(id), 'note', 'تنظيف اختبار 7.4') into l
    from review_items where kind = 'monitor:reserved_without_booking' and entity_id in (t_id('bare'), t_id('stale'), t_id('off')) and reviewed_at is null;
  if l->'ids' is not null and jsonb_typeof(l->'ids') = 'array' and jsonb_array_length(l->'ids') > 0 then perform fn_review_mark(l); end if;
exception when others then raise warning 'cleanup: %', sqlerrm; end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 7 then raise exception 'RESERVED-WITHOUT-BOOKING TESTS INCOMPLETE: % of 7 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'RESERVED-WITHOUT-BOOKING TESTS FAILED'; end if;
end $$;
