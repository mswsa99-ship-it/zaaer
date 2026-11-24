create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;  -- 0127: authenticated cannot call fn_branch_today directly
-- =====================================================================
-- Guest journey, task W7 (UG*; migration 0071): the photos that show a guest how to enter and leave their unit. One
-- set per unit for the way in and one for the way out, uploaded in the branch's guide; a guest sees them only once the
-- owner or the manager approved them, and a unit with none approved is explained by the reception — never by a page
-- or a message. Tried from outside the screens.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table toks(k text primary key, v text);
grant all on toks to public;
create or replace function tg_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
-- a visitor's request carries no account at all
create or replace function tg_logout() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', '', false);
end $$;
create or replace function tg_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function tg_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function tg_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function tg_today(p uuid) returns date language sql security definer as $$ select t_today(p) $$;
create or replace function tg_token(p uuid) returns text language sql security definer as $$ insert into registration_sessions(reservation_id) values (p) returning token $$;
-- (a key is made in a statement of its own: a page's function reads the database as it was when its statement began)
create or replace function tg_tok(p_k text) returns text language sql security definer as $$ select v from toks where k = p_k $$;
create or replace function tg_shift(p uuid, p_days int) returns void language plpgsql security definer as $$
begin
  update reservation_allocations set from_date = from_date + p_days, to_date = to_date + p_days where reservation_id = p;
  update reservation_nights set night = night + p_days where reservation_id = p;
  update reservations set check_in = check_in + p_days, check_out = check_out + p_days where id = p;
end $$;
create or replace function tg_item(p uuid) returns branch_media_items language sql security definer as $$ select * from branch_media_items where id = p $$;
create or replace function tg_set_status(p uuid, p_status text) returns void language sql security definer as $$
  update reservations set status = p_status::reservation_status where id = p $$;
-- a photo's bytes: the PNG signature is what the upload checks
create or replace function tg_png() returns text language sql immutable as $$ select encode('\x89504e470d0a1a0a0000000d49484452'::bytea, 'base64') $$;

-- ---------------------------------------------------------------- the branch, two units, a stay in each
select tg_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الشرح المصوّر","name_en":"Guides branch"}'); b := (r->>'id')::uuid;
  insert into ids values ('b', b);
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الشرح', 'base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '891')); insert into ids values ('room1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '892')); insert into ids values ('room2', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', tg_today(b)::text, 'check_out', (tg_today(b) + 1)::text,
         'guest_phone', '0552200001', 'guest_name', 'نزيل الشرح', 'room_id', tg_id('room1'), 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res1', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', tg_today(b)::text, 'check_out', (tg_today(b) + 1)::text,
         'guest_phone', '0552200002', 'guest_name', 'نزيل الشرح', 'room_id', tg_id('room2'), 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res2', (r->>'id')::uuid);
exception when others then perform tg_record('UG00 the branch, its units and their stays are set up', false, sqlerrm);
end $$;
reset role;
insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-000000000008', tg_id('b')), ('10000000-0000-0000-0000-000000000002', tg_id('b')) on conflict do nothing;
update reservations set status = 'checked_in' where id in (tg_id('res1'), tg_id('res2'));
insert into toks values ('t1', tg_token(tg_id('res1'))), ('t2', tg_token(tg_id('res2')));

-- ---------------------------------------------------------------- UG01 a unit's way in or out is a photo of that unit
select tg_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select tg_record('UG01 a way in or out is a photo of a unit: without its unit, as a video, or with another purpose it is refused',
  tg_fails(format('select fn_admin_upsert_media_item(%L)', jsonb_build_object('branch_id', tg_id('b'), 'kind', 'photo', 'purpose', 'checkin', 'data_base64', tg_png())), 'VALIDATION: guide_photo%') = 'ok'
  and tg_fails(format('select fn_admin_upsert_media_item(%L)', jsonb_build_object('branch_id', tg_id('b'), 'kind', 'video', 'purpose', 'checkout', 'room_id', tg_id('room1'), 'url', 'https://example.com/v')), 'VALIDATION: guide_photo%') = 'ok'
  and tg_fails(format('select fn_admin_upsert_media_item(%L)', jsonb_build_object('branch_id', tg_id('b'), 'kind', 'photo', 'purpose', 'lobby', 'room_id', tg_id('room1'), 'data_base64', tg_png())), 'VALIDATION: purpose%') = 'ok');

-- ---------------------------------------------------------------- UG02 uploaded, not yet approved: not shown
do $$ declare r jsonb; g jsonb; begin
  r := fn_admin_upsert_media_item(jsonb_build_object('branch_id', tg_id('b'), 'kind', 'photo', 'purpose', 'checkin', 'room_id', tg_id('room1'), 'caption', 'الصندوق يمين الباب', 'data_base64', tg_png()));
  insert into ids values ('in1', (r->>'id')::uuid);
  r := fn_admin_upsert_media_item(jsonb_build_object('branch_id', tg_id('b'), 'kind', 'photo', 'purpose', 'checkout', 'room_id', tg_id('room1'), 'caption', 'أعد المفتاح إلى الصندوق', 'data_base64', tg_png()));
  insert into ids values ('out1', (r->>'id')::uuid);
  r := fn_admin_upsert_media_item(jsonb_build_object('branch_id', tg_id('b'), 'kind', 'photo', 'caption', 'الواجهة', 'data_base64', tg_png()));
  insert into ids values ('gallery', (r->>'id')::uuid);
exception when others then perform tg_record('UG02 the photos are uploaded', false, sqlerrm);
end $$;
reset role;
select tg_logout();
set role anon;
select tg_record('UG02 a unit''s photos just uploaded are not shown to the guest: their page says the explanation is not ready, and the photo is not served by its id; the branch''s gallery is',
  not (fn_guest_unit_guide(tg_tok('t1'), 'checkin')->>'ready')::boolean and jsonb_array_length(fn_guest_unit_guide(tg_tok('t1'), 'checkin')->'photos') = 0
  and fn_branch_photo(tg_id('in1')) is null and fn_branch_photo(tg_id('gallery')) like 'data:image/png;base64,%');
reset role;

-- ---------------------------------------------------------------- UG03 who approves
select tg_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
select tg_record('UG03a a supervisor does not approve a unit''s photo', tg_fails(format('select fn_admin_approve_media_item(%L, true)', tg_id('in1')), '%FORBIDDEN%') = 'ok');
reset role;
select tg_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
set role authenticated;
do $$ declare r1 jsonb; r2 jsonb; e text; begin
  r1 := fn_admin_approve_media_item(tg_id('in1'), true);
  r2 := fn_admin_approve_media_item(tg_id('in1'), true);
  e := tg_fails(format('select fn_admin_approve_media_item(%L, true)', tg_id('gallery')), 'VALIDATION: guide_photo%');
  perform tg_record('UG03 the manager approves the unit''s way in (approving it again changes nothing); a gallery photo has nothing to approve',
    not (r1->>'unchanged')::boolean and (r2->>'unchanged')::boolean and e = 'ok' and (tg_item(tg_id('in1'))).approved_at is not null
    and (tg_item(tg_id('in1'))).approved_by = '10000000-0000-0000-0000-000000000008', e);
exception when others then perform tg_record('UG03 the manager approves the unit''s way in', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- UG04 approved: shown to that unit's guest only
select tg_logout();
set role anon;
select tg_record('UG04 approved, the way in is shown to the guest of that unit — with its caption — and its photo is served; the guest of another unit, and the way out not yet approved, get nothing',
  (fn_guest_unit_guide(tg_tok('t1'), 'checkin')->>'ready')::boolean
  and fn_guest_unit_guide(tg_tok('t1'), 'checkin')->'photos'->0->>'caption' = 'الصندوق يمين الباب'
  and fn_guest_unit_guide(tg_tok('t1'), 'checkin')->>'room_number' = '891'
  and fn_branch_photo(tg_id('in1')) like 'data:image/png;base64,%'
  and not (fn_guest_unit_guide(tg_tok('t2'), 'checkin')->>'ready')::boolean
  and not (fn_guest_unit_guide(tg_tok('t1'), 'checkout')->>'ready')::boolean
  and tg_fails(format('select fn_guest_unit_guide(%L, %L)', tg_tok('t1'), 'kitchen'), 'VALIDATION: purpose%') = 'ok'
  and tg_fails(format('select fn_unit_guide(%L, %L)', tg_id('room1'), 'checkin'), '%permission denied%') = 'ok');
reset role;
select tg_set_status(tg_id('res1'), 'checked_out');
select tg_logout();
set role anon;
select tg_record('UG04b a stay that ended is shown no photos of its unit', not (fn_guest_unit_guide(tg_tok('t1'), 'checkin')->>'ready')::boolean);
reset role;
select tg_set_status(tg_id('res1'), 'checked_in');

-- ---------------------------------------------------------------- UG05 a change takes the approval back
select tg_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare e text; begin
  perform fn_admin_approve_media_item(tg_id('out1'), true);
  perform fn_admin_upsert_media_item(jsonb_build_object('id', tg_id('in1'), 'sort_order', 3));
  insert into ids values ('after_sort', case when (tg_item(tg_id('in1'))).approved_at is not null then tg_id('in1') end);
  perform fn_admin_upsert_media_item(jsonb_build_object('id', tg_id('in1'), 'caption', 'الصندوق يسار الباب'));
  insert into ids values ('after_caption', case when (tg_item(tg_id('in1'))).approved_at is null then tg_id('in1') end);
  perform fn_admin_approve_media_item(tg_id('in1'), true);
  perform fn_admin_upsert_media_item(jsonb_build_object('id', tg_id('in1'), 'room_id', tg_id('room2')));
  insert into ids values ('after_room', case when (tg_item(tg_id('in1'))).approved_at is null then tg_id('in1') end);
  perform fn_admin_archive_media_item(tg_id('out1'), 'صورة قديمة', true);
  e := tg_fails(format('select fn_admin_approve_media_item(%L, true)', tg_id('out1')), 'VALIDATION: archived%');
  perform tg_record('UG05 the order of the photos keeps their approval; a new caption or another unit takes it back until approved again; an archived photo is not shown and cannot be approved',
    tg_id('after_sort') is not null and tg_id('after_caption') is not null and tg_id('after_room') is not null and e = 'ok', e);
exception when others then perform tg_record('UG05 a change takes the approval back', false, sqlerrm);
end $$;
reset role;
select tg_logout();
set role anon;
select tg_record('UG05b the archived way out is no longer shown, though it had been approved',
  not (fn_guest_unit_guide(tg_tok('t1'), 'checkout')->>'ready')::boolean and fn_branch_photo(tg_id('out1')) is null);
reset role;

-- ---------------------------------------------------------------- UG06–UG07 what the journey and the settings read
select tg_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; g jsonb; begin
  r := fn_admin_upsert_media_item(jsonb_build_object('branch_id', tg_id('b'), 'kind', 'photo', 'purpose', 'checkout', 'room_id', tg_id('room2'), 'caption', 'المفتاح في الصندوق', 'data_base64', tg_png()));
  perform fn_admin_approve_media_item((r->>'id')::uuid, true);
  g := fn_admin_unit_guides(tg_id('b'));
  perform tg_record('UG06 the settings list each unit with its photos and how many are approved, for the way in and the way out',
    (select (x->>'checkin')::int = 0 and (x->>'checkout')::int = 0 from jsonb_array_elements(g) x where x->>'room_number' = '891')
    and (select (x->>'checkin')::int = 1 and (x->>'checkin_approved')::int = 0 and (x->>'checkout_approved')::int = 1 from jsonb_array_elements(g) x where x->>'room_number' = '892'),
    g::text);
exception when others then perform tg_record('UG06 the settings list each unit with its photos', false, sqlerrm);
end $$;
reset role;
select tg_shift(tg_id('res2'), -1);                          -- arrived yesterday, leaves today
select tg_record('UG07 the check-out options say whether the unit''s way out can be shown (approved photos only)',
  (fn_checkout_offer(tg_id('res2'))->>'guide_checkout')::boolean and not (fn_checkout_offer(tg_id('res1'))->>'guide_checkout')::boolean);
select tg_record('UG08 every change of a unit''s photo and its approval is on the record',
  (select count(*) from audit_events where action = 'branch.media_approved' and entity_id = tg_id('in1')) = 2
  and exists (select 1 from audit_events where action = 'branch.media_changed' and entity_id = tg_id('in1') and details->'after'->>'approved' = 'false')
  and fn_audit_action_label('branch.media_approved') = 'اعتماد صورة شرح وحدة');

-- ---------------------------------------------------------------- results
\set ON_ERROR_STOP on
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail, ''), 400) as detail from test_results order by name;
do $$
declare n int; f int;
begin
  select count(*), count(*) filter (where not ok) into n, f from test_results;
  if f > 0 then raise exception 'GUIDES W7 TESTS FAILED: % of %', f, n; end if;
  if n < 11 then raise exception 'GUIDES W7 TESTS INCOMPLETE: % of 11 checks ran', n; end if;
end $$;
