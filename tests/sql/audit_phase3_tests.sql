-- =====================================================================
-- The review of 31 October, Phase 3a as the owner decided it (QR*; migration 0057): the front desk — past stays, what
-- an ended booking owes, «مقيم في يوم», weak key-box codes. A branch of its own, «فرع الاستقبال»: the supervisor a…02,
-- housekeeping a…03 and the manager a…08 are members.
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
-- 'ok' when the statement fails with a message like p_like, else what happened
create or replace function t_err(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
-- a 1×1 PNG
create or replace function t_png() returns text language sql as $$
  select 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
$$;

create or replace function t_kb_set(p_room uuid, p_code text) returns text language plpgsql security definer set search_path = public, extensions as $$
begin
  update keyboxes set code_encrypted = pgp_sym_encrypt(p_code, fn_secret('keybox_key')) where room_id = p_room;
  return 'accepted';
exception when others then return sqlerrm;
end $$;

-- ---------------------------------------------------------------- fixtures (the owner)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الاستقبال","name_en":"Front desk branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الاستقبال', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  insert into ids values ('b', b), ('cat', cat);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '301')); insert into ids values ('r1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '302')); insert into ids values ('r2', (r->>'id')::uuid);
end $$;
reset role;
insert into branch_memberships(staff_id, branch_id)
select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000008']::uuid[]) s
on conflict do nothing;
insert into keyboxes(branch_id, room_id, code_encrypted, code_status, field_tested)
select t_id('b'), t_id('r1'), pgp_sym_encrypt('2580', fn_secret('keybox_key')), 'active', true where not exists (select 1 from keyboxes where room_id = t_id('r1'));

-- ---------------------------------------------------------------- QR01–QR03 past stays (FRONT-08)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare base jsonb; r jsonb; begin
  base := jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'guest_name', 'ضيف متأخر', 'guest_phone', '0551000301',
    'source_id', '00000000-0000-0000-0000-000000000021', 'check_in', (current_date - 5)::text, 'check_out', (current_date - 3)::text);
  perform t_record('QR01 a stay that has already ended is refused without a reason',
    t_err(format('select fn_staff_create_reservation(%L)', base), 'PAST_STAY%') = 'ok');
  r := fn_staff_create_reservation(base || '{"late_entry_reason":"حجز منصة أُدخل بعد المغادرة"}');
  perform t_record('QR02 the supervisor enters it late with a reason; the reason is in the audit trail',
    r->>'id' is not null and exists (select 1 from audit_events where action = 'reservation.late_entry' and entity_id = (r->>'id')::uuid
                                     and details::text like '%حجز منصة أُدخل بعد المغادرة%'), r::text);
  insert into ids values ('late', (r->>'id')::uuid);
exception when others then perform t_record('QR02 the supervisor enters it late with a reason; the reason is in the audit trail', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
select t_record('QR03 a stay that starts yesterday and ends tomorrow is not a late entry (the arrival check stays as it was)',
  t_err(format('select fn_staff_create_reservation(%L)', jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'guest_name', 'ضيف ثالث', 'guest_phone', '0551000303',
    'source_id', '00000000-0000-0000-0000-000000000021', 'check_in', (current_date - 1)::text, 'check_out', (current_date + 1)::text)), 'x') = 'accepted');
reset role;

-- ---------------------------------------------------------------- QR04–QR05 what an ended booking owes (FRONT-09)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; l jsonb; row jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'guest_name', 'ضيف ملغى', 'guest_phone', '0551000304',
    'source_id', '00000000-0000-0000-0000-000000000021', 'check_in', (current_date + 2)::text, 'check_out', (current_date + 4)::text));
  insert into ids values ('cx', (r->>'id')::uuid);
  perform fn_staff_cancel_reservation((r->>'id')::uuid, 'تجربة الإلغاء');
  l := fn_reservation_list(t_id('b'), '{"has_balance":"true"}'::jsonb, 50, 0);
  select x into row from jsonb_array_elements(fn_reservation_list(t_id('b'), '{}'::jsonb, 50, 0)->'rows') x where x->>'id' = r->>'id';
  perform t_record('QR04 a cancelled booking owes nothing on the list and is not among «عليها متبقٍ»',
    (row->>'balance_due_halalas')::bigint = 0 and not exists (select 1 from jsonb_array_elements(l->'rows') x where x->>'id' = r->>'id'), row::text);
exception when others then perform t_record('QR04 a cancelled booking owes nothing on the list and is not among «عليها متبقٍ»', false, sqlerrm);
end $$;
do $$ declare l jsonb; begin
  l := fn_reservation_list(t_id('b'), jsonb_build_object('stay_on', (current_date + 3)::text), 50, 0);
  perform t_record('QR05 «مقيم في يوم» leaves out a cancelled booking',
    not exists (select 1 from jsonb_array_elements(l->'rows') x where (x->>'id')::uuid = t_id('cx')), l::text);
end $$;
reset role;

-- ---------------------------------------------------------------- QR06–QR07 weak codes (FRONT-16)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
select t_record('QR06 «1111», «1234» and «9876» are refused as key-box codes',
  t_err(format('select fn_staff_rotate_keybox_code(%L, %L, true)', t_id('r1'), '1111'), '%code_weak%') = 'ok'
  and t_err(format('select fn_staff_rotate_keybox_code(%L, %L, true)', t_id('r1'), '1234'), '%code_weak%') = 'ok'
  and t_err(format('select fn_staff_rotate_keybox_code(%L, %L, true)', t_id('r1'), '9876'), '%code_weak%') = 'ok');
select t_record('QR07 a mixed code is accepted', t_err(format('select fn_staff_rotate_keybox_code(%L, %L, true)', t_id('r1'), '7319'), 'x') = 'accepted');
reset role;
select t_record('QR07b a direct write of a weak code is refused too (every path goes through the key box row)', t_kb_set(t_id('r1'), '0000') like '%code_weak%');

-- a check that comes out NULL counts as a failure here
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'REVIEW PHASE 3 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 8 then raise exception 'REVIEW PHASE 3 TESTS INCOMPLETE: % of 8 checks ran', (select count(*) from test_results); end if;
end $$;
