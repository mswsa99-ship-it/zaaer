-- =====================================================================
-- The review of 31 October, Phase 2 as the owner decided it (QD*; migrations 0055–0056): the organisation's record, the
-- price range of each role, the inventory and release rules, unit numbers, staff invites, branches, knowledge.
-- A branch of its own, «فرع الإعدادات»: the supervisor a…02 and the manager a…08 are members.
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

-- reads of tables no signed-in role may read (the checks run as the API roles)
create or replace function t_media_archived(p_id uuid) returns boolean language sql security definer as $$ select archived_at is not null from branch_media_items where id = p_id $$;
create or replace function t_payment_secret_hidden(p_branch uuid) returns boolean language sql security definer as $$
  select secret_key_encrypted is not null and position('sk_test' in encode(secret_key_encrypted, 'escape')) = 0 from branch_payment_settings where branch_id = p_branch $$;

-- ---------------------------------------------------------------- fixtures (the owner)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الإعدادات","name_en":"Settings branch","tax_rate_bp":0,"supervisor_max_discount_bp":9000}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'جناح الإعدادات', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  insert into ids values ('b', b), ('cat', cat);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '101')); insert into ids values ('r101', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '102')); insert into ids values ('r102', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '103')); insert into ids values ('r103', (r->>'id')::uuid);
end $$;
reset role;
insert into branch_memberships(staff_id, branch_id)
select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000008']::uuid[]) s
on conflict do nothing;
insert into inventory_periods(branch_id, category_id, date, total_units, publicly_visible_units, blocked_units)
values (t_id('b'), t_id('cat'), current_date + 3, 3, 2, 0);
insert into ids select 'inv', id from inventory_periods where category_id = t_id('cat');

-- ---------------------------------------------------------------- QD01–QD02 the organisation (SETUP-04)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; o jsonb; pub jsonb; v int; begin
  v := (fn_organization_info()->>'version')::int;
  r := fn_admin_update_organization(jsonb_build_object('name_ar', 'فايف اورز للشقق', 'name_en', 'Five Hours Suites', 'license_number', '٧٣١٠٠٢', 'logo_base64', 'data:image/png;base64,' || t_png(), 'version', v));
  o := fn_organization_info(); pub := fn_public_organization();
  perform t_record('QD01 the owner edits the organisation (names, licence in Latin digits, logo); the staff and the guest pages read it; one audit row',
    o->>'name_ar' = 'فايف اورز للشقق' and o->>'name_en' = 'Five Hours Suites' and o->>'license_number' = '731002' and o->>'logo' like 'data:image/png;base64,%'
    and pub->>'name_ar' = 'فايف اورز للشقق' and pub->>'logo' like 'data:image/png;base64,%' and (o->>'version')::int = v + 1
    and exists (select 1 from audit_events where action = 'organization.updated'), o::text);
exception when others then perform t_record('QD01 the owner edits the organisation (names, licence in Latin digits, logo); the staff and the guest pages read it; one audit row', false, sqlerrm);
end $$;
do $$ begin
  perform t_record('QD02 the organisation refuses an empty name, a licence with symbols, a file that is not an image, and a price range that leaves out the base price',
    t_err($q$select fn_admin_update_organization('{"name_ar":"  "}')$q$, 'VALIDATION: name_ar%') = 'ok'
    and t_err($q$select fn_admin_update_organization('{"license_number":"12#4"}')$q$, 'VALIDATION: license_number%') = 'ok'
    and t_err($q$select fn_admin_update_organization('{"logo_base64":"PHN2Zz48L3N2Zz4="}')$q$, 'VALIDATION: image_type%') = 'ok'
    and t_err($q$select fn_admin_update_organization('{"price_min_bp_supervisor":"12000"}')$q$, 'VALIDATION: price_limits%') = 'ok'
    and t_err($q$select fn_admin_update_organization('{"price_max_bp_manager":"9000"}')$q$, 'VALIDATION: price_limits%') = 'ok'
    and t_err($q$select fn_admin_update_organization('{"price_min_bp_manager":"-5"}')$q$, 'VALIDATION: price_limits%') = 'ok');
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
set role authenticated;
select t_record('QD02b only the owner edits the organisation (a manager is refused)',
  t_err($q$select fn_admin_update_organization('{"name_ar":"اسم آخر"}')$q$, '%FORBIDDEN%') = 'ok');
reset role;

-- ---------------------------------------------------------------- QD03–QD07 the price range of each role (SETUP-12)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
select fn_admin_update_organization('{"price_min_bp_supervisor":"8000","price_max_bp_supervisor":"15000","price_min_bp_manager":"6000","price_max_bp_manager":"20000"}');
do $$ declare r jsonb; begin
  r := fn_rate_calendar_set(jsonb_build_object('branch_id', t_id('b'), 'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', current_date + 20)), 'price_halalas', 90000));
  perform t_record('QD03 the owner is not limited by the ranges (a calendar price at 450% of the base is kept)', (r->>'changed')::int = 1, r::text);
exception when others then perform t_record('QD03 the owner is not limited by the ranges (a calendar price at 450% of the base is kept)', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
set role authenticated;
do $$ declare lim jsonb; ok_mid text; begin
  lim := fn_price_limits(t_id('cat'));
  begin
    perform fn_rate_calendar_set(jsonb_build_object('branch_id', t_id('b'), 'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', current_date + 21)), 'price_halalas', 30000));
    ok_mid := 'ok';
  exception when others then ok_mid := sqlerrm; end;
  perform t_record('QD04 the manager''s calendar prices stay within 60%–200% of the base: 110 SAR and 410 SAR are refused with the limit, 300 SAR is kept; the limits are readable',
    lim->>'role' = 'manager' and (lim->>'min')::bigint = 12000 and (lim->>'max')::bigint = 40000
    and t_err(format('select fn_rate_calendar_set(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', current_date + 21)), 'price_halalas', 11000)), 'PRICE_BELOW_LIMIT: 12000%') = 'ok'
    and t_err(format('select fn_rate_calendar_set(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'cells', jsonb_build_array(jsonb_build_object('category_id', t_id('cat'), 'night', current_date + 21)), 'price_halalas', 41000)), 'PRICE_ABOVE_LIMIT: 40000%') = 'ok'
    and ok_mid = 'ok', lim::text || ' / ' || ok_mid);
exception when others then perform t_record('QD04 the manager''s calendar prices stay within 60%–200% of the base: 110 SAR and 410 SAR are refused with the limit, 300 SAR is kept; the limits are readable', false, sqlerrm);
end $$;
do $$ declare r jsonb; res uuid; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'room_id', t_id('r102'), 'check_in', (current_date + 5)::text,
         'check_out', (current_date + 7)::text, 'guest_phone', '0551000071', 'guest_name', 'ضيف السعر', 'source_id', '00000000-0000-0000-0000-000000000021',
         'nightly_rate_halalas', 30000));
  res := (r->>'id')::uuid; insert into ids values ('res', res);
  perform t_record('QD05 a manual nightly price is within the range of whoever books it: 500 SAR (250%) is refused for the manager, 300 SAR is booked',
    t_err(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'room_id', t_id('r103'), 'check_in', (current_date + 5)::text,
         'check_out', (current_date + 7)::text, 'guest_phone', '0551000072', 'guest_name', 'ضيف السعر العالي', 'source_id', '00000000-0000-0000-0000-000000000021',
         'nightly_rate_halalas', 50000)), 'PRICE_ABOVE_LIMIT: 40000%') = 'ok'
    and res is not null, r::text);
exception when others then perform t_record('QD05 a manual nightly price is within the range of whoever books it: 500 SAR (250%) is refused for the manager, 300 SAR is booked', false, sqlerrm);
end $$;
do $$ declare v int; begin
  v := (select version from reservations where id = t_id('res'));
  perform t_record('QD06 a discount that brings the nights under the manager''s lowest (120 SAR) is refused; an adjustment over the highest (400 SAR) is refused',
    t_err(format('select fn_staff_adjust_price(%L, ''discount'', 40000, ''خصم'', ''اختبار'', %s)', t_id('res'), v), 'PRICE_BELOW_LIMIT: 12000%') = 'ok'
    and t_err(format('select fn_staff_adjust_price(%L, ''adjustment'', 30000, ''زيادة'', ''اختبار'', %s)', t_id('res'), v), 'PRICE_ABOVE_LIMIT: 40000%') = 'ok');
exception when others then perform t_record('QD06 a discount that brings the nights under the manager''s lowest (120 SAR) is refused; an adjustment over the highest (400 SAR) is refused', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare r jsonb; v int; begin
  v := (select version from reservations where id = t_id('res'));
  r := fn_staff_adjust_price(t_id('res'), 'discount', 10000, 'خصم', 'عميل دائم', v);
  perform t_record('QD06b the supervisor''s range (80%–150%) applies to a discount: 450 SAR off a 600 SAR stay is refused (under 160 SAR a night), 100 SAR off is accepted',
    t_err(format('select fn_staff_adjust_price(%L, ''discount'', 30000, ''خصم'', ''اختبار'', %s)', t_id('res'), v + 1), 'PRICE_BELOW_LIMIT: 16000%') = 'ok'
    and (r->>'ok')::boolean, r::text);
exception when others then perform t_record('QD06b the supervisor''s range (80%–150%) applies to a discount: 450 SAR off a 600 SAR stay is refused (under 160 SAR a night), 100 SAR off is accepted', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ begin
  perform t_record('QD07 a unit type needs a base price above zero; a service is priced above zero unless free; a price over a million SAR a night is refused',
    t_err(format('select fn_admin_upsert_room_category(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'name_ar', 'نوع بلا سعر')), 'VALIDATION: base_price%') = 'ok'
    and t_err(format('select fn_admin_upsert_room_category(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'name_ar', 'نوع بسعر صفر', 'base_price_halalas', 0)), 'VALIDATION: base_price%') = 'ok'
    and t_err(format('select fn_admin_upsert_room_category(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'name_ar', 'نوع بسعر خيالي', 'base_price_halalas', 1000000000000)), 'VALIDATION: amount_too_large%') = 'ok'
    and t_err(format('select fn_admin_upsert_room_category(%L::jsonb)', jsonb_build_object('id', t_id('cat'), 'name_ar', 'جناح الإعدادات', 'base_price_halalas', 0, 'version', (select version from room_categories where id = t_id('cat')))), 'VALIDATION: base_price%') = 'ok'
    and t_err(format('select fn_admin_upsert_service(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'name_ar', 'خدمة صفر')), 'VALIDATION: service_price%') = 'ok'
    and t_err(format('select fn_admin_upsert_service(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'name_ar', 'خدمة مجانية', 'is_free', true)), '%') = 'accepted'
    and t_err(format('select fn_admin_upsert_service(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'name_ar', 'خدمة مدفوعة', 'price_halalas', 1500)), '%') = 'accepted');
exception when others then perform t_record('QD07 a unit type needs a base price above zero; a service is priced above zero unless free; a price over a million SAR a night is refused', false, sqlerrm);
end $$;
select fn_admin_update_organization('{"price_min_bp_supervisor":"","price_max_bp_supervisor":"","price_min_bp_manager":"","price_max_bp_manager":""}');
reset role;

-- ---------------------------------------------------------------- QD08–QD09 the inventory and the release rules (SETUP-01)
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
set role authenticated;
do $$ declare r jsonb; iv inventory_periods; direct text; begin
  begin update inventory_periods set total_units = -5 where id = t_id('inv'); direct := 'accepted';
  exception when insufficient_privilege then direct := 'refused'; end;
  r := fn_admin_set_inventory(jsonb_build_object('id', t_id('inv'), 'total_units', 3, 'blocked_units', 1, 'publicly_visible_units', 2));
  select * into iv from inventory_periods where id = t_id('inv');
  perform t_record('QD08 the inventory: no direct write; −5, more than the type''s 3 units, blocked over total and public over what is left are refused; a valid change is kept and audited',
    direct = 'refused'
    and t_err(format('select fn_admin_set_inventory(%L::jsonb)', jsonb_build_object('id', t_id('inv'), 'total_units', -5)), 'VALIDATION: inventory%') = 'ok'
    and t_err(format('select fn_admin_set_inventory(%L::jsonb)', jsonb_build_object('id', t_id('inv'), 'total_units', 999)), 'INVENTORY_OVER_UNITS: 3%') = 'ok'
    and t_err(format('select fn_admin_set_inventory(%L::jsonb)', jsonb_build_object('id', t_id('inv'), 'blocked_units', 4)), 'VALIDATION: inventory_blocked%') = 'ok'
    and t_err(format('select fn_admin_set_inventory(%L::jsonb)', jsonb_build_object('id', t_id('inv'), 'blocked_units', 2, 'publicly_visible_units', 2)), 'VALIDATION: inventory_public%') = 'ok'
    and iv.total_units = 3 and iv.blocked_units = 1 and iv.publicly_visible_units = 2 and (r->>'ok')::boolean
    and exists (select 1 from audit_events where action = 'inventory.updated' and entity_id = t_id('inv')), direct || ' ' || r::text);
exception when others then perform t_record('QD08 the inventory: no direct write; −5, more than the type''s 3 units, blocked over total and public over what is left are refused; a valid change is kept and audited', false, sqlerrm);
end $$;
do $$ declare r jsonb; r2 jsonb; rr release_rules; begin
  r := fn_admin_upsert_release_rule(jsonb_build_object('category_id', t_id('cat'), 'initial_public_release', 1, 'release_increment', 1, 'release_trigger', 'confirmed'));
  r2 := fn_admin_upsert_release_rule(jsonb_build_object('id', r->>'id', 'enabled', true, 'release_trigger', 'manual'));
  select * into rr from release_rules where id = (r->>'id')::uuid;
  perform t_record('QD09 a release rule is created for a type and its trigger changed; an initial over the units, an increment of 0, an unknown trigger and a second rule are refused',
    rr.enabled and rr.release_trigger = 'manual' and rr.initial_public_release = 1
    and t_err(format('select fn_admin_upsert_release_rule(%L::jsonb)', jsonb_build_object('id', r->>'id', 'initial_public_release', 4)), 'INVENTORY_OVER_UNITS: 3%') = 'ok'
    and t_err(format('select fn_admin_upsert_release_rule(%L::jsonb)', jsonb_build_object('id', r->>'id', 'release_increment', 0)), 'VALIDATION: release_increment%') = 'ok'
    and t_err(format('select fn_admin_upsert_release_rule(%L::jsonb)', jsonb_build_object('id', r->>'id', 'release_trigger', 'weather')), 'VALIDATION: release_trigger%') = 'ok'
    and t_err(format('select fn_admin_upsert_release_rule(%L::jsonb)', jsonb_build_object('category_id', t_id('cat'))), 'DUPLICATE_RULE%') = 'ok', r2::text);
exception when others then perform t_record('QD09 a release rule is created for a type and its trigger changed; an initial over the units, an increment of 0, an unknown trigger and a second rule are refused', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- QD10 unit numbers (SETUP-06)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'room_number', '١٠٤'));
  perform t_record('QD10 a unit number is kept in Latin digits: «١٠١» is the existing 101 and is refused; «١٠٤» is stored as 104',
    t_err(format('select fn_admin_upsert_room(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'category_id', t_id('cat'), 'room_number', '١٠١')), 'DUPLICATE_ROOM_NUMBER%') = 'ok'
    and (select room_number from rooms where id = (r->>'id')::uuid) = '104', r::text);
exception when others then perform t_record('QD10 a unit number is kept in Latin digits: «١٠١» is the existing 101 and is refused; «١٠٤» is stored as 104', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QD11 staff invites (SETUP-08)
do $$ declare r jsonb; sp staff_profiles; e jsonb; begin
  r := fn_admin_invite_staff(jsonb_build_object('email', 'Invited.One@Test.Local', 'full_name', 'موظف مدعو', 'role', 'supervisor', 'branch_ids', jsonb_build_array(t_id('b')), 'phone', '٠٥٥١٢٣٤٥٦٧'));
  e := fn_admin_update_staff(jsonb_build_object('staff_id', r->>'staff_id', 'email', 'invited.two@test.local', 'reason', 'تصحيح البريد قبل الدخول'));
  select * into sp from staff_profiles where id = (r->>'staff_id')::uuid;
  perform t_record('QD11 an invite checks the email, needs a branch for a non-owner, checks the phone (Arabic digits read); the email is corrected before the first sign-in',
    t_err(format('select fn_admin_invite_staff(%L::jsonb)', jsonb_build_object('email', 'not-an-email', 'full_name', 'س', 'role', 'supervisor', 'branch_ids', jsonb_build_array(t_id('b')))), 'VALIDATION: email%') = 'ok'
    and t_err(format('select fn_admin_invite_staff(%L::jsonb)', jsonb_build_object('email', 'nobranch@test.local', 'full_name', 'بلا فرع', 'role', 'supervisor')), 'VALIDATION: branch_required%') = 'ok'
    and t_err(format('select fn_admin_invite_staff(%L::jsonb)', jsonb_build_object('email', 'badphone@test.local', 'full_name', 'هاتف خطأ', 'role', 'supervisor', 'branch_ids', jsonb_build_array(t_id('b')), 'phone', 'abc')), 'VALIDATION: phone%') = 'ok'
    and t_err($q$select fn_staff_invite('old-path@test.local', 'المسار القديم', 'supervisor', '{}'::uuid[])$q$, 'VALIDATION: branch_required%') = 'ok'
    and t_err(format('select fn_admin_update_staff(%L::jsonb)', jsonb_build_object('staff_id', r->>'staff_id', 'phone', 'abc', 'reason', 'تعديل')), 'VALIDATION: phone%') = 'ok'
    and sp.email = 'invited.two@test.local' and sp.phone = '0551234567' and e->'changed' @> '["email"]'::jsonb, sp.email || ' ' || coalesce(sp.phone, '-'));
exception when others then perform t_record('QD11 an invite checks the email, needs a branch for a non-owner, checks the phone (Arabic digits read); the email is corrected before the first sign-in', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QD12 branches (SETUP-09)
do $$ begin
  perform t_record('QD12 a second branch with the same name (spacing and letter forms aside) is refused; a branch phone «abc» and email «not-an-email» are refused',
    t_err($q$select fn_admin_upsert_branch('{"name_ar":"  فرع الاعدادات ","name_en":"Copy"}')$q$, 'DUPLICATE_BRANCH_NAME%') = 'ok'
    and t_err(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id', t_id('b'), 'name_ar', 'فرع الإعدادات', 'phone', 'abc', 'version', (select version from branches where id = t_id('b')))), 'VALIDATION: phone%') = 'ok'
    and t_err(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id', t_id('b'), 'name_ar', 'فرع الإعدادات', 'email', 'not-an-email', 'version', (select version from branches where id = t_id('b')))), 'VALIDATION: email%') = 'ok'
    and t_err(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id', t_id('b'), 'name_ar', 'فرع الإعدادات', 'phone', '0112345678', 'email', 'jeddah@fivehours.sa', 'version', (select version from branches where id = t_id('b')))), '%') = 'accepted');
exception when others then perform t_record('QD12 a second branch with the same name (spacing and letter forms aside) is refused; a branch phone «abc» and email «not-an-email» are refused', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QD13 knowledge (SETUP-13)
do $$ declare k jsonb; k2 jsonb; ke knowledge_entries; other uuid; begin
  k := fn_admin_upsert_knowledge(jsonb_build_object('branch_id', t_id('b'), 'question', 'هل يوجد مسبح؟', 'answer', 'نعم، في الطابق الأرضي'));
  select id into other from branches where id <> t_id('b') and organization_id = '00000000-0000-0000-0000-000000000001' and archived_at is null limit 1;
  -- another branch may answer the same question for its own guests
  k2 := fn_admin_upsert_knowledge(jsonb_build_object('branch_id', other, 'question', 'هل يوجد مسبح', 'answer', 'لا يوجد'));
  select * into ke from knowledge_entries where id = (k->>'id')::uuid;
  perform t_record('QD13 a contradicting answer to the same question (marks and letter forms aside) is refused with the existing entry; another branch, an inactive draft and editing the entry itself are allowed',
    t_err(format('select fn_admin_upsert_knowledge(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'question', ' هَل يُوجد  مسبح ? ', 'answer', 'لا')), 'KNOWLEDGE_CONFLICT: ' || (k->>'id') || '%') = 'ok'
    and t_err(format('select fn_admin_upsert_knowledge(%L::jsonb)', jsonb_build_object('question', 'هل يوجد مسبح!', 'answer', 'لا')), 'KNOWLEDGE_CONFLICT%') = 'ok'
    and t_err(format('select fn_admin_upsert_knowledge(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'question', 'هل يوجد مسبح؟', 'answer', 'مسودة', 'is_active', false)), '%') = 'accepted'
    and t_err(format('select fn_admin_upsert_knowledge(%L::jsonb)', jsonb_build_object('id', ke.id, 'branch_id', t_id('b'), 'question', 'هل يوجد مسبح؟', 'answer', 'نعم، مفتوح من 8 إلى 10', 'version', ke.version)), '%') = 'accepted'
    and k2 is not null, k::text || ' ' || k2::text);
exception when others then perform t_record('QD13 a contradicting answer to the same question (marks and letter forms aside) is refused with the existing entry; another branch, an inactive draft and editing the entry itself are allowed', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- QD14–QD16 the branch's guide and media (SETUP-05, 0056)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare g jsonb; begin
  perform fn_admin_set_branch_guide(jsonb_build_object('branch_id', t_id('b'), 'arrival_instructions', 'ادخل من البوابة الشمالية ثم المصعد الثاني.',
    'bank_name', 'مصرف الراجحي', 'bank_beneficiary', 'فايف اورز للشقق', 'bank_iban', 'SA03 8000 0000 6080 1016 7519'));
  reset role;
  g := fn_public_branch_guide(t_id('b'));
  set role authenticated;
  perform t_record('QD14 the branch keeps its arrival instructions and the bank details guests see (IBAN checked, all three or none); a wrong IBAN and an IBAN without the bank are refused',
    g->>'arrival_instructions' like 'ادخل من البوابة%' and g->'bank'->>'iban' = 'SA0380000000608010167519' and g->'bank'->>'beneficiary' = 'فايف اورز للشقق'
    and t_err(format('select fn_admin_set_branch_guide(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'bank_iban', 'SA0380000000608010167518')), 'VALIDATION: iban%') = 'ok'
    and t_err(format('select fn_admin_set_branch_guide(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'bank_name', '')), 'VALIDATION: bank_details%') = 'ok', g::text);
exception when others then perform t_record('QD14 the branch keeps its arrival instructions and the bank details guests see (IBAN checked, all three or none); a wrong IBAN and an IBAN without the bank are refused', false, sqlerrm);
end $$;
do $$ declare ph jsonb; vd jsonb; g jsonb; photo text; begin
  ph := fn_admin_upsert_media_item(jsonb_build_object('branch_id', t_id('b'), 'kind', 'photo', 'caption', 'الواجهة', 'data_base64', t_png()));
  vd := fn_admin_upsert_media_item(jsonb_build_object('branch_id', t_id('b'), 'kind', 'video', 'caption', 'طريق الدخول', 'url', 'https://example.com/entry.mp4', 'room_id', t_id('r101')));
  reset role;
  g := fn_public_branch_guide(t_id('b')); photo := fn_branch_photo((ph->>'id')::uuid);
  set role authenticated;
  perform t_record('QD15 the gallery takes a photo (PNG/JPG/WebP up to 1 MB) and an entry video by https link, for a unit too; an SVG, a plain-http link and a unit of another branch are refused; guests read them',
    jsonb_array_length(g->'photos') = 1 and g->'photos'->0->>'caption' = 'الواجهة' and g->'videos'->0->>'url' = 'https://example.com/entry.mp4'
    and photo like 'data:image/png;base64,%'
    and t_err(format('select fn_admin_upsert_media_item(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'kind', 'photo', 'data_base64', 'PHN2Zz48L3N2Zz4=')), 'VALIDATION: image_type%') = 'ok'
    and t_err(format('select fn_admin_upsert_media_item(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'kind', 'video', 'url', 'http://example.com/x.mp4')), 'VALIDATION: video_url%') = 'ok'
    and t_err(format('select fn_admin_upsert_media_item(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'kind', 'video', 'url', 'https://example.com/y.mp4', 'room_id', '00000000-0000-0000-0000-000000000101')), 'BRANCH_MISMATCH%') = 'ok', g::text);
  insert into ids values ('photo', (ph->>'id')::uuid);
exception when others then perform t_record('QD15 the gallery takes a photo (PNG/JPG/WebP up to 1 MB) and an entry video by https link, for a unit too; an SVG, a plain-http link and a unit of another branch are refused; guests read them', false, sqlerrm);
end $$;
do $$ declare g jsonb; begin
  perform fn_admin_archive_media_item(t_id('photo'), 'صورة قديمة');
  reset role;
  g := fn_public_branch_guide(t_id('b'));
  set role authenticated;
  perform t_record('QD16 a photo is archived with a reason (never erased) and leaves the guest page; without a reason it is refused; it is restored',
    jsonb_array_length(g->'photos') = 0 and t_media_archived(t_id('photo'))
    and t_err(format('select fn_admin_archive_media_item(%L, '' '')', t_id('photo')), 'VALIDATION: reason%') = 'ok'
    and (fn_admin_archive_media_item(t_id('photo'), null, false)->>'ok')::boolean
    and not t_media_archived(t_id('photo')), g::text);
exception when others then perform t_record('QD16 a photo is archived with a reason (never erased) and leaves the guest page; without a reason it is refused; it is restored', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QD17 booking sources (SETUP-14, 0056)
do $$ declare s jsonb; s2 jsonb; src booking_sources; begin
  s := fn_admin_upsert_source('{"name":"منصة جديدة","kind":"external","external_reference_required":true,"commission_bp":1200}');
  s2 := fn_admin_upsert_source(jsonb_build_object('id', s->>'id', 'name', 'منصة جديدة (معدّلة)', 'commission_bp', 1000));
  select * into src from booking_sources where id = (s->>'id')::uuid;
  perform t_record('QD17 a booking source is added and edited (name, kind, platform number, commission); a duplicate name is refused; switching one off needs a reason; a used source keeps its kind',
    src.name = 'منصة جديدة (معدّلة)' and src.commission_bp = 1000 and src.kind = 'external' and src.code like 'custom_%' and src.is_active
    and t_err($q$select fn_admin_upsert_source('{"name":"منصة جديدة (معدّلة)"}')$q$, 'DUPLICATE_SOURCE_NAME%') = 'ok'
    and t_err(format('select fn_admin_set_source_active(%L::jsonb)', jsonb_build_object('id', s->>'id', 'is_active', false)), 'VALIDATION: reason%') = 'ok'
    and (fn_admin_set_source_active(jsonb_build_object('id', s->>'id', 'is_active', false, 'reason', 'توقف التعاقد'))->>'changed')::boolean
    and t_err(format('select fn_admin_upsert_source(%L::jsonb)', jsonb_build_object('id', '00000000-0000-0000-0000-000000000021', 'kind', 'external')), 'SOURCE_IN_USE%') = 'ok', s::text);
exception when others then perform t_record('QD17 a booking source is added and edited (name, kind, platform number, commission); a duplicate name is refused; switching one off needs a reason; a used source keeps its kind', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QD18 policies (SETUP-10/14, 0056)
do $$ declare pid uuid; p property_policies; erased text; begin
  insert into property_policies(organization_id, branch_id, topic, topic_label, title, content_ar, is_public)
  values ('00000000-0000-0000-0000-000000000001', t_id('b'), 'other', 'الحيوانات الأليفة', 'الحيوانات', 'لا يُسمح بالحيوانات الأليفة.', true) returning id into pid;
  begin delete from property_policies where id = pid; erased := 'erased'; exception when insufficient_privilege then erased := 'refused'; end;
  update property_policies set archived_at = now(), archive_reason = 'لم تعد سارية' where id = pid;
  select * into p from property_policies where id = pid;
  perform t_record('QD18 a policy of topic «أخرى» keeps its own label; a policy is archived with a reason, never erased, and an archived policy is not public',
    erased = 'refused' and p.topic_label = 'الحيوانات الأليفة' and p.archived_at is not null and not p.is_public
    and t_err(format('update property_policies set archived_at = now(), archive_reason = null where id = %L and archived_at is null', (select id from property_policies where branch_id = t_id('b') and archived_at is null limit 1)), '%') in ('ok', 'accepted')
    and t_err(format('insert into property_policies(organization_id, branch_id, topic, title, content_ar) values (%L, %L, ''stay'', ''  '', ''x'')', '00000000-0000-0000-0000-000000000001', t_id('b')), 'VALIDATION: policy_required%') = 'ok', erased);
exception when others then perform t_record('QD18 a policy of topic «أخرى» keeps its own label; a policy is archived with a reason, never erased, and an archived policy is not public', false, sqlerrm);
end $$;
do $$ declare pid uuid; begin
  insert into property_policies(organization_id, branch_id, topic, title, content_ar) values ('00000000-0000-0000-0000-000000000001', t_id('b'), 'stay', 'الهدوء', 'الهدوء بعد 11 مساءً.') returning id into pid;
  perform t_record('QD18b archiving a policy without a reason is refused',
    t_err(format('update property_policies set archived_at = now() where id = %L', pid), 'VALIDATION: reason%') = 'ok');
exception when others then perform t_record('QD18b archiving a policy without a reason is refused', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QD19 payment provider settings (SETUP-02, 0056)
do $$ declare s jsonb; r jsonb; begin
  r := fn_admin_save_payment_settings(jsonb_build_object('branch_id', t_id('b'), 'provider', 'moyasar', 'merchant_id', 'mch_123', 'publishable_key', 'pk_test_abc', 'pos_terminal_id', '٧٧٠٠١٢'));
  perform t_record('QD19 the branch''s payment provider is set in the settings; online payment cannot be switched on until the secret key is kept',
    t_err(format('select fn_admin_save_payment_settings(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'online_enabled', true)), 'VALIDATION: payment_incomplete%') = 'ok'
    and t_err(format('select fn_admin_save_payment_settings(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'provider', 'stripe')), 'VALIDATION: provider%') = 'ok', r::text);
  r := fn_admin_save_payment_settings(jsonb_build_object('branch_id', t_id('b'), 'secret_key', 'sk_test_secret_9876', 'online_enabled', true));
  s := fn_admin_payment_settings(t_id('b'));
  perform t_record('QD19b with the secret key kept (encrypted; only its last four shown) online payment is switched on; the secret never comes back',
    (s->>'has_secret')::boolean and s->>'secret_last4' = '9876' and (s->>'online_enabled')::boolean and (s->>'complete')::boolean
    and s->>'pos_terminal_id' = '770012' and s::text not like '%sk_test_secret%'
    and t_payment_secret_hidden(t_id('b')), s::text);
exception when others then perform t_record('QD19b with the secret key kept (encrypted; only its last four shown) online payment is switched on; the secret never comes back', false, sqlerrm);
end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
set role authenticated;
select t_record('QD19c the payment provider is the owner''s (a manager is refused)',
  t_err(format('select fn_admin_payment_settings(%L)', t_id('b')), '%FORBIDDEN%') = 'ok');
reset role;

-- a check that comes out NULL counts as a failure here
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'REVIEW PHASE 2 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 24 then raise exception 'REVIEW PHASE 2 TESTS INCOMPLETE: % of 24 checks ran', (select count(*) from test_results); end if;
end $$;
