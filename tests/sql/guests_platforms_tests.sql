-- =====================================================================
-- Guests, platforms and the website (Phase 5, migrations 0038–0039): decisions 2, 4, 19, 21, 22, 23, 31, 69.
-- GD01–GD10 guest data on two paths, corrections with masked values, profiles and the owner's identity report.
-- BN01–BN07 guest bans (by profile, phone or document), ratings with an internal note, holds on one booking.
-- SO01      the twelve booking sources.
-- PF01–PF08 platform fields, the platform's receipt, cancelling by the platform's number, the daily matching list,
--           the bookings entered late.
-- GP01–GP05 one platform number for a group.
-- SS01–SS04 «ملخص الإقامة» and its acceptance (electronic or on paper).
-- BR01–BR05 the branch's fields, logo and image.
-- WS01      no availability for visitors.
-- Runs after monitors_tests.sql on the same database (its synthetic organisation, branch 010 and staff).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create temp table vals(k text primary key, v text);
grant all on vals to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_val(p_k text) returns text language sql security definer as $$ select v from vals where k = p_k $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
create or replace function t_res(p uuid) returns reservations language sql security definer as $$ select * from reservations where id = p $$;
create or replace function t_guest(p uuid) returns reservation_guests language sql security definer as $$ select * from reservation_guests where id = p $$;
create or replace function t_primary(p uuid) returns uuid language sql security definer as $$ select id from reservation_guests where reservation_id = p and is_primary limit 1 $$;
create or replace function t_profile(p uuid) returns guest_profiles language sql security definer as $$ select * from guest_profiles where id = p $$;
create or replace function t_blockers(p uuid) returns text[] language sql security definer as $$ select fn_checkin_core_blockers(p) $$;
create or replace function t_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function t_due(p uuid) returns jsonb language sql security definer as $$ select fn_stay_due_internal(p, now()) $$;
create or replace function t_token(p uuid) returns text language sql security definer as $$ insert into registration_sessions(reservation_id) values (p) returning token $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
-- a booking from the reception (direct), on a given unit or none
create or replace function t_gstay(p_room uuid, p_from date, p_to date, p_name text, p_phone text default null, p_extra jsonb default '{}'::jsonb) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'room_id', p_room, 'check_in', p_from, 'check_out', p_to, 'guest_name', p_name,
         'guest_phone', coalesce(p_phone, '0500007' || lpad((floor(random() * 1000))::int::text, 3, '0')),
         'source_id', '00000000-0000-0000-0000-000000000021') || p_extra);
  return (r->>'id')::uuid;
end $$;
-- a platform's booking (Booking.com)
create or replace function t_ota(p_from date, p_to date, p_ref text, p_collects boolean, p_booked date, p_extra jsonb default '{}'::jsonb) returns jsonb language plpgsql as $$
begin
  return fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', p_from, 'check_out', p_to, 'guest_name', 'ضيف منصة', 'guest_phone', '0500006' || lpad((floor(random() * 1000))::int::text, 3, '0'),
         'source_id', t_id('src_booking'), 'external_ref', p_ref, 'platform_collects', p_collects, 'platform_booked_on', p_booked) || p_extra);
end $$;
create or replace function t_doc(p_res uuid, p_guest uuid, p_name text, p_number text, p_extra jsonb default '{}'::jsonb) returns jsonb language plpgsql as $$
begin
  return fn_staff_enter_guest(jsonb_build_object('reservation_id', p_res, 'guest_id', p_guest, 'full_name', p_name, 'identity_type', 'national_id',
         'identity_number', p_number, 'nationality', 'سعودي', 'birth_date', '1990-01-01', 'document_matched', true) || p_extra);
end $$;

-- ---------------------------------------------------------------- fixtures
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; i int; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع الضيوف', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  for i in 1..8 loop
    r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'GP-' || i));
    insert into ids values ('g' || i, (r->>'id')::uuid);
  end loop;
  insert into ids select 'src_' || replace(code, '_com', ''), id from booking_sources where organization_id = '00000000-0000-0000-0000-000000000001' and code in ('booking_com', 'airbnb', 'reception', 'airport');
end $$;

-- =====================================================================
-- SO: the twelve booking sources (decision 22)
-- =====================================================================
reset role;
do $$ declare n int; codes text[]; begin
  select count(*), array_agg(code order by code) into n, codes from booking_sources
   where organization_id = '00000000-0000-0000-0000-000000000001'
     and code in ('reception', 'booking_com', 'airbnb', 'almosafer', 'airport', 'agoda', 'hotels_com', 'expedia', 'jathr_inn', 'booking_engine', 'trip_com', 'gathern');
  perform t_record('SO01 the twelve sources, each with a code, a kind and whether the platform''s number is needed (Airbnb once, Booking Engine off)',
    n = 12 and (select count(*) from booking_sources where organization_id = '00000000-0000-0000-0000-000000000001' and code = 'airbnb') = 1
    and exists (select 1 from booking_sources where code = 'reception' and kind = 'direct' and not external_reference_required and name = 'الاستقبال')
    and exists (select 1 from booking_sources where code = 'booking_engine' and not is_active)
    and exists (select 1 from booking_sources where code = 'airport' and kind = 'external' and not external_reference_required)
    and not exists (select 1 from booking_sources where code in ('booking_com', 'airbnb', 'gathern', 'jathr_inn', 'expedia') and (kind <> 'external' or not external_reference_required)),
    array_to_string(codes, ','));
end $$;

-- =====================================================================
-- GD: guest data on two paths (decision 2)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare res uuid; r jsonb; g reservation_guests%rowtype; a jsonb; begin
  res := t_gstay(t_id('g1'), t_today() + 30, t_today() + 32, 'محمد عبدالله الحربي', '0551110001', '{"companions": 1}');
  insert into ids values ('resGD', res);
  -- GD02: without «طابقتُ الوثيقة الأصلية» nothing is entered
  perform t_record('GD02 the office path needs «طابقتُ الوثيقة الأصلية»',
    t_fails(format('select fn_staff_enter_guest(%L::jsonb)', jsonb_build_object('reservation_id', res, 'guest_id', t_primary(res), 'full_name', 'محمد عبدالله الحربي',
       'identity_type', 'national_id', 'identity_number', '1023456781', 'nationality', 'سعودي', 'birth_date', '1990-01-01')), '%document_matched%') = 'ok');
  r := t_doc(res, t_primary(res), 'محمد عبدالله الحربي', '1023456781');
  g := t_guest(t_primary(res));
  select details into a from audit_events where entity_id = res and action = 'guest.entered_from_document' order by created_at desc limit 1;
  perform t_record('GD01 the supervisor enters the main guest from the document: verified at once, office path, who and when kept, profile linked, audit masked',
    g.verification_status = 'verified' and g.entry_path = 'office' and g.entered_by is not null and g.verified_by = g.entered_by and g.identity_fingerprint is not null
    and g.identity_number_last4 = '6781' and g.guest_profile_id is not null and (t_profile(g.guest_profile_id)).identity_fingerprint = g.identity_fingerprint
    and a::text like '%••••6781%' and a::text not like '%1023456781%' and (t_res(res)).identity_status = 'data_submitted',
    coalesce(a::text, 'no audit') || ' / ' || (t_res(res)).identity_status);
  -- the companion, entered from the document too → the stay is verified
  r := t_doc(res, null, 'سارة محمد الحربي', '1034567892', '{"relationship": "spouse"}');
  perform t_record('GD01b with every guest entered from the document the stay''s identity is verified',
    (t_res(res)).identity_status = 'verified' and (r->>'identity_status') = 'verified', r::text);
  -- GD05: the same document twice in one stay
  perform t_record('GD05 the same document twice in one stay is refused',
    t_fails(format('select fn_staff_enter_guest(%L::jsonb)', jsonb_build_object('reservation_id', res, 'guest_id', t_primary(res), 'full_name', 'محمد عبدالله الحربي',
       'identity_type', 'national_id', 'identity_number', '1034567892', 'nationality', 'سعودي', 'birth_date', '1990-01-01', 'document_matched', true, 'reason', 'تجربة')), '%DUPLICATE_GUEST%') = 'ok');
end $$;

do $$ declare res uuid := t_id('resGD'); r jsonb; g0 reservation_guests%rowtype; g reservation_guests%rowtype; a jsonb; n bigint; begin
  g0 := t_guest(t_primary(res));
  -- GD03: a correction needs a reason; the trail keeps masked values before and after
  perform t_record('GD03a a correction without a reason is refused',
    t_fails(format('select fn_staff_enter_guest(%L::jsonb)', jsonb_build_object('reservation_id', res, 'guest_id', t_primary(res), 'full_name', 'محمد عبدالله الحربي',
       'identity_type', 'national_id', 'identity_number', '1023456781', 'nationality', 'سعودي', 'birth_date', '1991-02-02', 'document_matched', true)), '%reason%') = 'ok');
  n := t_count('select count(*) from review_items where kind = ''guest_corrected''');
  r := t_doc(res, t_primary(res), 'محمد عبدالله الحربي', '', jsonb_build_object('birth_date', '1991-02-02', 'reason', 'تاريخ الميلاد خطأ في الإدخال'));
  g := t_guest(t_primary(res));
  select details into a from audit_events where entity_id = res and action = 'guest.corrected' order by created_at desc limit 1;
  perform t_record('GD03 a correction with a reason: masked before and after (birth year, last four), into the owner''s review list',
    a->'before'->>'birth_year' = '1990' and a->'after'->>'birth_year' = '1991' and a->>'reason' = 'تاريخ الميلاد خطأ في الإدخال' and a::text not like '%1023456781%'
    and a::text not like '%1991-02-02%' and t_count('select count(*) from review_items where kind = ''guest_corrected''') = n + 1, a::text);
  perform t_record('GD04 a correction that leaves the number empty keeps the one on file; changing the document''s kind needs the number',
    g.identity_fingerprint = g0.identity_fingerprint and g.identity_number_last4 = '6781' and g.birth_date = '1991-02-02'
    and t_fails(format('select fn_staff_enter_guest(%L::jsonb)', jsonb_build_object('reservation_id', res, 'guest_id', t_primary(res), 'full_name', 'محمد عبدالله الحربي',
         'identity_type', 'passport', 'identity_number', '', 'nationality', 'سعودي', 'birth_date', '1991-02-02', 'document_matched', true, 'reason', 'تجربة')), '%identity_number_format%') = 'ok', g.birth_date::text);
end $$;

-- GD06: neither housekeeping nor finance enter guest data
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
do $$ declare a text; b text; begin
  a := t_fails(format('select fn_staff_enter_guest(%L::jsonb)', jsonb_build_object('reservation_id', t_id('resGD'), 'full_name', 'أ ب ج', 'identity_type', 'national_id',
         'identity_number', '1045678903', 'nationality', 'سعودي', 'birth_date', '1990-01-01', 'document_matched', true)), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
  b := t_fails(format('select fn_staff_enter_guest(%L::jsonb)', jsonb_build_object('reservation_id', t_id('resGD'), 'full_name', 'أ ب ج', 'identity_type', 'national_id',
         'identity_number', '1045678903', 'nationality', 'سعودي', 'birth_date', '1990-01-01', 'document_matched', true)), 'FORBIDDEN%');
  perform t_record('GD06 housekeeping and finance cannot enter or correct guest data', a = 'ok' and b = 'ok', a || ' / ' || b);
end $$;

-- GD07 / GD10: the guest's own entry, then its approval, links the document's profile (the same guest again → the same profile)
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid; tok text; s jsonb; r jsonb; g reservation_guests%rowtype; p0 uuid; begin
  res := t_gstay(t_id('g2'), t_today() + 40, t_today() + 41, 'محمد عبدالله الحربي', '0559990001');
  insert into ids values ('resGD2', res);
  tok := t_token(res);
  insert into vals values ('tokGD2', tok);
end $$;
set role anon;
do $$ declare tok text := t_val('tokGD2'); r jsonb; h0 text := fn_guest_stay_summary(tok)->>'hash'; begin
  -- the guest corrects their name while accepting: the summary they read (with the old name) is what is recorded
  r := fn_guest_submit(tok, (fn_guest_session(tok)->'guests'->0->>'id')::uuid,
         '{"full_name":"محمد عبدالله سعد الحربي","identity_type":"national_id","identity_number":"1023456781","nationality":"سعودي","birth_date":"1990-01-01","consent":"true"}'::jsonb
         || jsonb_build_object('ack_hash', h0, 'phone', '0559990001'));
  perform t_record('SS04 accepting the summary while correcting the name keeps the text the guest actually read',
    (r->>'ok')::boolean and (fn_guest_stay_summary(tok)->>'accepted_at') is not null and fn_guest_stay_summary(tok)->>'hash' <> h0
    and not (fn_guest_stay_summary(tok)->>'current')::boolean, r::text);
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid := t_id('resGD2'); g reservation_guests%rowtype; p0 uuid; r jsonb; begin
  g := t_guest(t_primary(res));
  perform t_record('GD10 the guest''s own entry: the guest path, the document''s fingerprint, not yet verified',
    g.entry_path = 'guest' and g.identity_fingerprint = (t_guest(t_primary(t_id('resGD')))).identity_fingerprint and g.verification_status = 'data_submitted' and g.verified_by is null,
    g.entry_path || '/' || g.verification_status);
  p0 := (t_guest(t_primary(t_id('resGD')))).guest_profile_id;
  r := fn_staff_approve_identity(g.id, true, null);
  g := t_guest(g.id);
  -- the second stay was made with another phone: its own profile. Its approved document matches the first profile's,
  -- so the two profiles show as a possible duplicate (by document) and stay separate
  perform t_record('GD07 approving keeps who and when; a second profile with the same document is flagged, never merged',
    g.verified_by is not null and g.verified_at is not null and g.guest_profile_id is not null and g.guest_profile_id <> p0
    and (t_profile(g.guest_profile_id)).identity_fingerprint = (t_profile(p0)).identity_fingerprint
    and exists (select 1 from jsonb_array_elements(fn_guest_profile(p0)->'duplicates') x where (x->>'id')::uuid = g.guest_profile_id and x->>'match' = 'identity'),
    g.guest_profile_id::text || ' / ' || p0::text);
end $$;

-- GD08: searching profiles by name, phone digits, the whole document number and its last four; duplicates are shown
do $$ declare by_name jsonb; by_phone jsonb; by_doc jsonb; by_last4 jsonb; dup jsonb; res uuid; p1 uuid; p2 uuid; begin
  by_name := fn_guest_profiles('{"q":"الحربي"}');
  by_phone := fn_guest_profiles('{"q":"0551110001"}');
  by_doc := fn_guest_profiles('{"q":"1023456781"}');
  by_last4 := fn_guest_profiles('{"q":"6781"}');
  -- two different people booked on one phone: two profiles, flagged, not merged
  res := t_gstay(t_id('g3'), t_today() + 50, t_today() + 51, 'خالد سعد العتيبي', '0552220002', '{"new_profile": true}');
  insert into ids values ('resDup1', res);
  res := t_gstay(t_id('g4'), t_today() + 52, t_today() + 53, 'فيصل سعد العتيبي', '0552220002', '{"new_profile": true}');
  insert into ids values ('resDup2', res);
  p1 := (t_guest(t_primary(t_id('resDup1')))).guest_profile_id; p2 := (t_guest(t_primary(t_id('resDup2')))).guest_profile_id;
  dup := fn_guest_profiles('{"filter":"duplicates"}');
  perform t_record('GD08 profile search by name, phone, the whole document (no decryption) and its last four; duplicates flagged and never merged',
    (by_name->>'total')::int >= 1 and (by_phone->>'total')::int >= 1 and (by_doc->>'total')::int >= 1 and (by_last4->>'total')::int >= 1
    and by_doc::text not like '%1023456781%' and p1 <> p2
    and exists (select 1 from jsonb_array_elements(dup->'rows') x where (x->>'id')::uuid = p1)
    and exists (select 1 from jsonb_array_elements(dup->'rows') x where (x->>'id')::uuid = p2)
    and exists (select 1 from jsonb_array_elements(fn_guest_profile(p1)->'duplicates') x where (x->>'id')::uuid = p2 and x->>'match' = 'phone'),
    format('name %s phone %s doc %s last4 %s', by_name->>'total', by_phone->>'total', by_doc->>'total', by_last4->>'total'));
end $$;

-- GD09: the owner's report of identities approved at the office (the owner only)
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare m text; rep jsonb; begin
  m := t_fails(format('select fn_reports_identities(%L, %L, %L, ''office'', ''{}''::jsonb)', '00000000-0000-0000-0000-000000000010', t_today() - 1, t_today()), 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  rep := fn_reports_identities('00000000-0000-0000-0000-000000000010', t_today() - 1, t_today(), 'office', '{}'::jsonb);
  perform t_record('GD09 the owner''s report lists the identities approved at the office with who and when (a manager is refused)',
    m = 'ok' and (rep->>'count')::int >= 2 and not exists (select 1 from jsonb_array_elements(rep->'rows') x where x->>'entry_path' <> 'office')
    and exists (select 1 from jsonb_array_elements(rep->'rows') x where x->>'identity_last4' = '6781' and x->>'verified_by' is not null)
    and rep::text not like '%1023456781%' and (fn_reports_identities('00000000-0000-0000-0000-000000000010', t_today() - 1, t_today(), 'all', '{}'::jsonb)->>'count')::int > (rep->>'count')::int,
    m || ' / ' || (rep->>'count'));
end $$;

-- =====================================================================
-- BN: bans, ratings and holds (decision 21)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid; p uuid; begin
  -- the guest to be banned: a verified stay, and a second booking (same phone) later on
  res := t_gstay(t_id('g5'), t_today() + 60, t_today() + 61, 'عمر ناصر القحطاني', '0553330003');
  perform t_doc(res, t_primary(res), 'عمر ناصر القحطاني', '1056789014');
  insert into ids values ('resBan1', res);
  insert into ids values ('pBan', (t_guest(t_primary(res))).guest_profile_id);
  insert into ids values ('resBan2', t_gstay(t_id('g6'), t_today(), t_today() + 1, 'عمر ناصر القحطاني', '0553330003'));
  perform t_record('BN01a a supervisor cannot ban a guest',
    t_fails(format('select fn_guest_ban(%L::jsonb)', jsonb_build_object('profile_id', t_id('pBan'), 'ban', true, 'reason', 'إزعاج')), 'FORBIDDEN%') = 'ok');
end $$;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare r jsonb; b2 text[]; bl text[]; lst jsonb; d jsonb; begin
  perform t_record('BN01b a ban needs a reason',
    t_fails(format('select fn_guest_ban(%L::jsonb)', jsonb_build_object('profile_id', t_id('pBan'), 'ban', true)), '%reason%') = 'ok');
  r := fn_guest_ban(jsonb_build_object('profile_id', t_id('pBan'), 'ban', true, 'reason', 'أضرار متكررة في الوحدة'));
  b2 := t_blockers(t_id('resBan2'));
  lst := fn_reservation_list('00000000-0000-0000-0000-000000000010', jsonb_build_object('q', (t_res(t_id('resBan2'))).internal_ref));
  d := fn_reservation_detail(t_id('resBan2'));
  perform t_record('BN02 a manager bans with a reason: the guest''s other booking shows the red alert and cannot arrive',
    (r->>'ok')::boolean and 'الضيف محظور من الإدارة' = any(b2) and (lst->'rows'->0->>'ban')::boolean
    and jsonb_array_length(d->'bans') = 1 and d->'bans'->0->>'reason' = 'أضرار متكررة في الوحدة'
    and t_count('select count(*) from review_items where kind = ''guest_banned''') >= 1, array_to_string(b2, ' | '));
end $$;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid; res2 uuid; m1 jsonb; m2 jsonb; begin
  -- a new profile on the same phone still matches (by phone); a companion carrying the banned document matches (by document)
  res := t_gstay(t_id('g7'), t_today() + 70, t_today() + 71, 'عمر القحطاني ن', '0553330003', '{"new_profile": true}');
  res2 := t_gstay(t_id('g8'), t_today() + 72, t_today() + 73, 'زائر آخر تماما', '0554440004', '{"companions": 1}');
  perform t_doc(res2, null, 'عمر ناصر القحطاني', '1056789014');
  m1 := fn_reservation_detail(res)->'bans'; m2 := fn_reservation_detail(res2)->'bans';
  perform t_record('BN03 the ban matches a new profile by phone and a companion by the document',
    jsonb_array_length(m1) = 1 and m1->0->'matched_by' ? 'phone' and jsonb_array_length(m2) = 1 and m2->0->'matched_by' ? 'identity', m1::text || m2::text);
  insert into vals values ('tokBan', t_token(t_id('resBan2')));
end $$;
set role anon;
do $$ declare s jsonb := fn_guest_session(t_val('tokBan')); begin
  perform t_record('BN04 the guest''s own page says only «يرجى مراجعة الاستقبال»',
    s->'access'->'reasons' ? 'يرجى مراجعة الاستقبال' and s::text not like '%محظور%' and s::text not like '%أضرار%', s->'access'->>'reasons');
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
do $$ declare r jsonb; begin
  perform t_record('BN05a lifting a ban needs a reason',
    t_fails(format('select fn_guest_ban(%L::jsonb)', jsonb_build_object('profile_id', t_id('pBan'), 'ban', false)), '%reason%') = 'ok');
  r := fn_guest_ban(jsonb_build_object('profile_id', t_id('pBan'), 'ban', false, 'reason', 'سوّى الأضرار'));
  perform t_record('BN05 the owner lifts the ban with a reason: the alert and the block go, the history stays',
    not ('الضيف محظور من الإدارة' = any(t_blockers(t_id('resBan2')))) and jsonb_array_length(fn_reservation_detail(t_id('resBan2'))->'bans') = 0
    and jsonb_array_length(fn_guest_profile(t_id('pBan'))->'ban_history') = 1 and fn_guest_profile(t_id('pBan'))->'ban_history'->0->>'lift_reason' = 'سوّى الأضرار'
    and t_count('select count(*) from review_items where kind = ''guest_unbanned''') >= 1, r::text);
end $$;

-- BN06: the rating 1–5 with an internal note, seen on the guest's next booking
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r jsonb; d jsonb; h text; begin
  perform t_record('BN06a a rating outside 1–5 is refused',
    t_fails(format('select fn_guest_rate(%L::jsonb)', jsonb_build_object('profile_id', t_id('pBan'), 'rating', 6)), '%rating%') = 'ok');
  r := fn_guest_rate(jsonb_build_object('profile_id', t_id('pBan'), 'rating', 2, 'note', 'يتأخر في المغادرة'));
  d := fn_reservation_detail(t_id('resBan2'));
  perform t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
  h := t_fails(format('select fn_guest_rate(%L::jsonb)', jsonb_build_object('profile_id', t_id('pBan'), 'rating', 5)), 'FORBIDDEN%');
  perform t_record('BN06 a supervisor rates the guest with a note; staff see it on the next booking; housekeeping cannot rate',
    (d->'guest_profile'->>'rating')::int = 2 and d->'guest_profile'->>'rating_note' = 'يتأخر في المغادرة' and h = 'ok'
    and (fn_reservation_list('00000000-0000-0000-0000-000000000010', jsonb_build_object('q', (t_res(t_id('resBan2'))).internal_ref))->'rows'->0 is not null), d->>'guest_profile');
end $$;

-- BN07: a hold on one booking — placed by a supervisor, lifted only by the owner or a manager, each with a reason
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid := t_id('resDup1'); r jsonb; lift text; begin
  perform t_record('BN07a a hold needs a reason', t_fails(format('select fn_staff_set_hold(%L::jsonb)', jsonb_build_object('reservation_id', res, 'hold', true)), '%reason%') = 'ok');
  r := fn_staff_set_hold(jsonb_build_object('reservation_id', res, 'hold', true, 'reason', 'بلاغ من الجيران'));
  lift := t_fails(format('select fn_staff_set_hold(%L::jsonb)', jsonb_build_object('reservation_id', res, 'hold', false, 'reason', 'انتهى')), 'FORBIDDEN%');
  perform t_record('BN07 a supervisor places a hold (blocks arrival, into the review list) but cannot lift it',
    (t_res(res)).security_hold and (t_res(res)).security_hold_by is not null and 'يوجد حظر أمني على الحجز' = any(t_blockers(res)) and lift = 'ok'
    and t_count(format('select count(*) from review_items where kind = ''security_hold'' and entity_id = %L', res)) = 1, lift);
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  r := fn_staff_set_hold(jsonb_build_object('reservation_id', res, 'hold', false, 'reason', 'تواصلنا مع الضيف'));
  perform t_record('BN07b a manager lifts the hold with a reason (kept in the trail)',
    not (t_res(res)).security_hold and t_count(format('select count(*) from audit_events where entity_id = %L and action = ''reservation.hold_lifted''', res)) = 1, r::text);
end $$;

-- =====================================================================
-- PF: platform fields, the platform's receipt, cancelling by the platform's number (decision 4)
-- =====================================================================
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare r jsonb; a text; b text; c text; res uuid; f jsonb; begin
  a := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', t_today() + 80, 'check_out', t_today() + 82, 'guest_phone', '0551000011', 'guest_name', 'ضيف منصة', 'source_id', t_id('src_booking'), 'external_ref', 'PF-0', 'platform_booked_on', t_today())), '%platform_collects%');
  b := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', t_today() + 80, 'check_out', t_today() + 82, 'guest_phone', '0551000012', 'guest_name', 'ضيف منصة', 'source_id', t_id('src_booking'), 'external_ref', 'PF-0', 'platform_collects', false)), '%platform_booked_on%');
  c := t_fails(format('select fn_staff_create_reservation(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'check_in', t_today() + 80, 'check_out', t_today() + 82, 'guest_phone', '0551000013', 'guest_name', 'ضيف منصة', 'source_id', t_id('src_booking'), 'external_ref', 'PF-0', 'platform_collects', false,
         'platform_booked_on', t_today() + 1)), '%platform_booked_on%');
  perform t_record('PF01 a platform''s booking says who collects and the day it was booked there (not a day still to come)', a = 'ok' and b = 'ok' and c = 'ok', a || ' / ' || b || ' / ' || c);
  r := t_ota(t_today() + 80, t_today() + 82, 'PF-1', true, t_today());
  res := (r->>'id')::uuid; insert into ids values ('resPF1', res);
  f := t_fin(res);
  perform t_record('PF02 the platform collects → its receipt «آجل عبر المنصات» for the whole stay, once, waiting for the platform''s deposit',
    r->>'platform_voucher' is not null and (f->>'net_collected')::bigint = (f->>'total')::bigint and (f->>'total')::bigint > 0
    and t_count(format('select count(*) from financial_vouchers where reservation_id = %L and method = ''ota_deferred'' and kind = ''receipt''', res)) = 1
    and (t_res(res)).payment_status = 'paid' and (t_res(res)).platform_collects and (t_res(res)).platform_booked_on = t_today(), f::text);
  r := t_ota(t_today() + 83, t_today() + 85, 'PF-2', false, t_today());
  res := (r->>'id')::uuid; insert into ids values ('resPF2', res);
  perform t_record('PF03 the property collects → no receipt is made', r->>'platform_voucher' is null and (t_fin(res)->>'net_collected')::bigint = 0, r::text);
end $$;

do $$ declare res uuid := t_id('resPF1'); r1 jsonb; r2 jsonb; n text; lst jsonb; begin
  n := t_fails(format('select fn_staff_cancel(%L::jsonb)', jsonb_build_object('reservation_id', res, 'reason', 'ألغاه الضيف على المنصة')), '%cancel_number%');
  r1 := fn_staff_cancel(jsonb_build_object('reservation_id', res, 'reason', 'ألغاه الضيف على المنصة', 'cancel_number', 'CXL-PF-1'));
  r2 := fn_staff_cancel(jsonb_build_object('reservation_id', res, 'reason', 'ألغاه الضيف على المنصة', 'cancel_number', 'CXL-PF-1'));
  lst := fn_reservation_list('00000000-0000-0000-0000-000000000010', '{"q":"CXL-PF-1"}');
  perform t_record('PF04 a platform''s booking is cancelled with its cancellation number, once; nothing is refunded; the platform''s receipt is flagged; it is found by that number',
    n = 'ok' and (r1->>'cancelled')::int = 1 and (r2->>'duplicate')::boolean and (t_res(res)).status = 'cancelled' and (t_res(res)).cancel_reference = 'CXL-PF-1'
    and (t_res(res)).cancel_source = 'platform' and (r1->>'platform_collected')::boolean
    and t_count(format('select count(*) from financial_vouchers where reservation_id = %L and kind = ''refund''', res)) = 0
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = ''reservation.cancelled''', res)) = 1
    and (lst->>'total')::int = 1, r1::text || r2::text);
end $$;

do $$ declare res uuid := t_id('resPF2'); r jsonb; other uuid; begin
  -- PF05: entered here by mistake → an internal cancellation needs no platform number, only a reason
  other := (t_ota(t_today() + 86, t_today() + 87, 'PF-3', false, t_today())->>'id')::uuid;
  r := fn_staff_cancel(jsonb_build_object('reservation_id', other, 'reason', 'أُدخل بالخطأ', 'by_platform', false));
  perform t_record('PF05 a booking entered by mistake is cancelled with a reason and no platform number', (t_res(other)).status = 'cancelled' and (t_res(other)).cancel_source = 'staff', r::text);
  -- PF06: a cancellation undone within the hour frees its number for the right booking
  r := fn_staff_cancel(jsonb_build_object('reservation_id', res, 'reason', 'ألغيت على المنصة', 'cancel_number', 'CXL-PF-2'));
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  r := fn_staff_undo_cancel(jsonb_build_object('reservation_id', res, 'reason', 'ألغيت الحجز الخطأ'));
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  insert into ids values ('resPF4', (t_ota(t_today() + 88, t_today() + 89, 'PF-4', false, t_today())->>'id')::uuid);
  r := fn_staff_cancel(jsonb_build_object('reservation_id', t_id('resPF4'), 'reason', 'ألغيت على المنصة', 'cancel_number', 'CXL-PF-2'));
  perform t_record('PF06 undoing a cancellation frees its platform number, which then cancels the right booking',
    (t_res(res)).status = 'confirmed' and (t_res(res)).cancel_reference is null and (t_res(t_id('resPF4'))).status = 'cancelled' and (r->>'cancelled')::int = 1, r::text);
end $$;

-- PF07: today's and tomorrow's platform arrivals, matched against the platform
do $$ declare l jsonb; r jsonb; a uuid; b uuid; c uuid; d uuid; begin
  a := (t_ota(t_today(), t_today() + 2, 'PF-T0', true, t_today() - 3)->>'id')::uuid;
  b := (t_ota(t_today() + 1, t_today() + 2, 'PF-T1', false, t_today())->>'id')::uuid;
  c := (t_ota(t_today() + 3, t_today() + 4, 'PF-T3', false, t_today())->>'id')::uuid;
  d := t_gstay(null, t_today(), t_today() + 1, 'ضيف مباشر اليوم');
  insert into ids values ('resT0', a);
  l := fn_platform_check_list('00000000-0000-0000-0000-000000000010', null);
  r := fn_platform_mark_checked(jsonb_build_object('reservation_id', a));
  perform t_record('PF07 the daily list holds the platforms'' arrivals of today and tomorrow only; «طابقتُ» keeps who and when',
    exists (select 1 from jsonb_array_elements(l->'rows') x where (x->>'id')::uuid = a) and exists (select 1 from jsonb_array_elements(l->'rows') x where (x->>'id')::uuid = b)
    and not exists (select 1 from jsonb_array_elements(l->'rows') x where (x->>'id')::uuid in (c, d))
    and (t_res(a)).platform_verified_at is not null and (t_res(a)).platform_verified_by is not null
    and exists (select 1 from jsonb_array_elements(fn_platform_check_list('00000000-0000-0000-0000-000000000010', null)->'rows') x where (x->>'id')::uuid = a and x->>'verified_by' is not null),
    jsonb_array_length(l->'rows')::text);
end $$;

-- PF08: bookings entered late (the owner and managers; the supervisor is refused)
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare rep jsonb; s text; begin
  rep := fn_reports_late_entries('00000000-0000-0000-0000-000000000010', t_today(), t_today(), 1, '{}'::jsonb);
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  s := t_fails(format('select fn_reports_late_entries(%L, %L, %L, 1, ''{}''::jsonb)', '00000000-0000-0000-0000-000000000010', t_today(), t_today()), 'FORBIDDEN%');
  perform t_record('PF08 the late-entry report lists a booking entered three days after the platform took it, not the same-day ones',
    exists (select 1 from jsonb_array_elements(rep->'rows') x where (x->>'id')::uuid = t_id('resT0') and (x->>'lag_days')::int = 3)
    and not exists (select 1 from jsonb_array_elements(rep->'rows') x where (x->>'lag_days')::int < 1) and s = 'ok', (rep->>'late') || ' / ' || s);
end $$;

-- =====================================================================
-- GP: one platform number for a group (decision 69)
-- =====================================================================
do $$ declare r jsonb; e text; n bigint; s jsonb; d jsonb; begin
  r := t_ota(t_today() + 100, t_today() + 102, 'GR-1', false, t_today(), jsonb_build_object('units', jsonb_build_array(
         jsonb_build_object('category_id', t_id('cat')), jsonb_build_object('category_id', t_id('cat')), jsonb_build_object('category_id', t_id('cat')))));
  insert into ids values ('grp1', (r->>'id')::uuid);
  perform t_record('GP01 a group of three units with one platform number is created whole; every unit carries the number',
    (r->>'units')::int = 3 and t_count('select count(*) from reservations where external_ref = ''GR-1''') = 3
    and t_count(format('select count(distinct group_ref) from reservations where external_ref = %L', 'GR-1')) = 1, r->>'group_ref');
  e := t_fails(format('select t_ota(%L, %L, %L, false, %L)', t_today() + 110, t_today() + 111, 'GR-1', t_today()), '%DUPLICATE_EXTERNAL_REF%');
  perform t_record('GP02 the same platform number on another booking or group is refused',
    e = 'ok' and t_fails(format('select t_ota(%L, %L, %L, false, %L, %L::jsonb)', t_today() + 110, t_today() + 111, 'GR-1', t_today(),
                                jsonb_build_object('units', jsonb_build_array(jsonb_build_object('category_id', t_id('cat')), jsonb_build_object('category_id', t_id('cat'))))),
                         '%DUPLICATE_EXTERNAL_REF%') = 'ok', e);
  -- one unit too many people → nothing at all is created
  e := t_fails(format('select t_ota(%L, %L, %L, false, %L, %L::jsonb)', t_today() + 120, t_today() + 121, 'GR-2', t_today(),
               jsonb_build_object('units', jsonb_build_array(jsonb_build_object('category_id', t_id('cat')), jsonb_build_object('category_id', t_id('cat')),
                                                             jsonb_build_object('category_id', t_id('cat'), 'adults', 9)))), '%CAPACITY%');
  perform t_record('GP03 one unit failing creates none of the group', e = 'ok' and t_count('select count(*) from reservations where external_ref = ''GR-2''') = 0, e);
  s := fn_reservation_group_summary(t_id('grp1'));
  d := t_due(t_id('grp1'));
  perform t_record('GP04 the group''s page: each unit with its own money; the totals add up; the deposit is per unit (50 riyals)',
    jsonb_array_length(s->'units') = 3 and (s->'totals'->>'total_halalas')::bigint = (select sum((x->>'total_halalas')::bigint) from jsonb_array_elements(s->'units') x)
    and (s->'totals'->>'units')::int = 3 and (d->>'deposit_required')::bigint = (select default_deposit_halalas from branches where id = '00000000-0000-0000-0000-000000000010')
    and s->>'external_ref' = 'GR-1', s->>'totals');
  r := fn_staff_cancel(jsonb_build_object('reservation_id', t_id('grp1'), 'reason', 'أُلغيت المجموعة على المنصة', 'cancel_number', 'CXL-GR-1', 'whole_group', true));
  perform t_record('GP05 the whole group is cancelled with one platform cancellation number',
    (r->>'cancelled')::int = 3 and t_count('select count(*) from reservations where external_ref = ''GR-1'' and status = ''cancelled'' and cancel_reference = ''CXL-GR-1''') = 3, r::text);
end $$;

-- =====================================================================
-- SS: «ملخص الإقامة» and its acceptance (decision 19)
-- =====================================================================
reset role;
insert into property_policies(organization_id, branch_id, topic, title, content_ar, content_en, is_public, sort_order) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', 'stay', 'الهدوء', 'يمنع الإزعاج بعد منتصف الليل', 'No noise after midnight', true, 1),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', 'other', 'سياسة داخلية للموظفين', 'لا تُعرض على الضيف', null, false, 2);
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid := t_id('resGD'); s jsonb; h text; r jsonb; e text; begin
  s := fn_stay_summary(res);
  h := s->>'hash';
  perform t_record('SS01 the summary carries the stay, its money, the deposit and the branch''s public policies only',
    s->>'text' like '%' || (t_res(res)).internal_ref || '%' and s->>'text' like '%عدد الليالي: 2%' and s->>'text' like '%الإجمالي%' and s->>'text' like '%التأمين: 50.00 ر.س%'
    and s->>'text' like '%الهدوء: يمنع الإزعاج بعد منتصف الليل%' and s->>'text' not like '%سياسة داخلية%' and s->>'language' = 'ar' and length(h) = 64, left(s->>'text', 200));
  e := t_fails(format('select fn_staff_record_paper_ack(%L::jsonb)', jsonb_build_object('reservation_id', res, 'text_hash', 'old')), '%SUMMARY_CHANGED%');
  r := fn_staff_record_paper_ack(jsonb_build_object('reservation_id', res, 'text_hash', h));
  perform t_record('SS02 the guest''s paper signature is recorded with the exact text and time; a printed copy no longer current is refused; once per text',
    e = 'ok' and not (r->>'duplicate')::boolean and (fn_staff_record_paper_ack(jsonb_build_object('reservation_id', res, 'text_hash', h))->>'duplicate')::boolean
    and t_count(format('select count(*) from stay_acknowledgements where reservation_id = %L and method = ''paper'' and text_snapshot like %L', res, '%الهدوء%')) = 1
    and jsonb_array_length(fn_stay_summary(res)->'acknowledgements') = 1, e);
end $$;
-- the branch in English: the summary follows its default language
reset role;
update branches set default_language = 'en' where id = '00000000-0000-0000-0000-000000000010';
set role authenticated;
do $$ declare s jsonb := fn_stay_summary(t_id('resGD')); begin
  perform t_record('SS01b a branch whose default language is English prints the summary in English (policies in English where written)',
    s->>'language' = 'en' and s->>'text' like 'Stay summary%' and s->>'text' like '%Deposit: SAR 50.00%' and s->>'text' like '%No noise after midnight%', left(s->>'text', 120));
end $$;
reset role;
update branches set default_language = 'ar' where id = '00000000-0000-0000-0000-000000000010';
do $$ begin perform set_config('test.tok', t_token(t_id('resDup2')), false); end $$;
set role anon;
do $$ declare tok text := current_setting('test.tok'); s jsonb; r jsonb; before_hash text; begin
  s := fn_guest_stay_summary(tok);
  r := fn_guest_acknowledge(tok, s->>'hash');
  before_hash := s->>'hash';
  perform set_config('test.ackhash', before_hash, false);
  perform t_record('SS03a the guest accepts the summary on their page; it shows accepted and current',
    (fn_guest_stay_summary(tok)->>'accepted_at') is not null and (fn_guest_stay_summary(tok)->>'current')::boolean and fn_guest_stay_summary(tok)->>'method' = 'electronic', r::text);
end $$;
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
do $$ declare res uuid := t_id('resDup2'); begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 1000, 'method', 'cash', 'idempotency_key', 'ss03-pay'));
end $$;
set role anon;
do $$ declare tok text := current_setting('test.tok'); s jsonb := fn_guest_stay_summary(tok); begin
  perform t_record('SS03 a payment changes the summary: the earlier acceptance stays with its own text, and the page says it is not the current one',
    not (s->>'current')::boolean and s->>'hash' <> current_setting('test.ackhash')
    and t_count(format('select count(*) from stay_acknowledgements where text_hash = %L', current_setting('test.ackhash'))) = 1, s->>'hash');
end $$;

-- =====================================================================
-- BR: the branch's fields, logo and image (decision 31)
-- =====================================================================
set role authenticated;
select t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
do $$ declare b branches%rowtype; a text; c text; m text; l text; ok jsonb; begin
  select * into b from branches where id = '00000000-0000-0000-0000-000000000010';
  a := t_fails(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id', b.id, 'version', b.version, 'name_ar', b.name_ar, 'name_en', '  ')), '%name_en%');
  c := t_fails(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('name_ar', 'فرع بلا اسم إنجليزي')), '%name_en%');
  m := t_fails(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id', b.id, 'version', b.version, 'name_ar', b.name_ar, 'map_url', 'http://maps.google.com/?q=1')), '%map_url%')
    || '|' || t_fails(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id', b.id, 'version', b.version, 'name_ar', b.name_ar, 'map_url', 'https://evil.example/maps')), '%map_url%');
  l := t_fails(format('select fn_admin_upsert_branch(%L::jsonb)', jsonb_build_object('id', b.id, 'version', b.version, 'name_ar', b.name_ar, 'booking_platform_url', 'javascript:alert(1)')), '%booking_url%');
  ok := fn_admin_upsert_branch(jsonb_build_object('id', b.id, 'version', b.version, 'name_ar', b.name_ar, 'map_url', 'https://maps.app.goo.gl/AbCd123',
          'booking_platform_url', 'https://www.booking.com/hotel/sa/example.html', 'default_language', 'ar', 'country_code', 'SA'));
  perform t_record('BR01 the English name is required (a change without it keeps the one on file)', a = 'ok' and c = 'ok' and (ok->>'ok')::boolean, a || ' / ' || c);
  perform t_record('BR02 the map link is a Google Maps https link; anything else is refused', m = 'ok|ok' and (select map_url from branches where id = b.id) = 'https://maps.app.goo.gl/AbCd123', m);
  perform t_record('BR03 the booking platform link is https only', l = 'ok' and (select booking_platform_url from branches where id = b.id) = 'https://www.booking.com/hotel/sa/example.html', l);
end $$;

do $$ declare png text := encode('\x89504e470d0a1a0a0000000d49484452'::bytea, 'base64'); svg text := encode(convert_to('<svg xmlns="http://www.w3.org/2000/svg"></svg>', 'UTF8'), 'base64');
              big text := encode('\x89504e470d0a1a0a'::bytea || decode(repeat('00', 210000), 'hex'), 'base64');
              jpg text := encode('\xffd8ffe000104a464946'::bytea, 'base64'); webp text := encode('\x524946462400000057454250565038'::bytea, 'base64');
              r jsonb; s1 text; s2 text; s3 text; a jsonb; sup text; begin
  s1 := t_fails(format('select fn_admin_set_branch_media(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'kind', 'logo', 'data_base64', svg)), '%image_type%');
  s2 := t_fails(format('select fn_admin_set_branch_media(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'kind', 'logo', 'data_base64', big)), '%image_too_large%');
  r := fn_admin_set_branch_media(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'kind', 'image', 'data_base64', big));
  s3 := (fn_admin_set_branch_media(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'kind', 'logo', 'data_base64', jpg))->'media'->>'mime')
     || ',' || (fn_admin_set_branch_media(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'kind', 'logo', 'data_base64', webp))->'media'->>'mime');
  r := fn_admin_set_branch_media(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'kind', 'logo', 'data_base64', 'data:image/png;base64,' || png));
  select details into a from audit_events where entity_id = '00000000-0000-0000-0000-000000000010' and action = 'branch.logo_changed' order by created_at desc limit 1;
  perform t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
  sup := t_fails(format('select fn_admin_set_branch_media(%L::jsonb)', jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'kind', 'logo', 'data_base64', png)), 'FORBIDDEN%');
  perform t_record('BR04 the logo: PNG, JPG or WebP read from the file itself, an SVG refused, over 200 KB refused (the image takes up to 1 MB); the trail keeps its fingerprint, not the file; a supervisor cannot set it',
    s1 = 'ok' and s2 = 'ok' and s3 = 'image/jpeg,image/webp' and r->'media'->>'mime' = 'image/png' and a->'after'->>'sha256' is not null and a::text not like '%' || png || '%'
    and sup = 'ok' and fn_branch_media('00000000-0000-0000-0000-000000000010', 'logo') like 'data:image/png;base64,%', s1 || ' / ' || s2 || ' / ' || s3);
end $$;
set role anon;
do $$ declare p jsonb := fn_public_branch('00000000-0000-0000-0000-000000000010'); begin
  perform t_record('BR05 a guest page reads the branch''s platform link, map, language and its logo and image',
    p->>'booking_platform_url' = 'https://www.booking.com/hotel/sa/example.html' and p->>'map_url' = 'https://maps.app.goo.gl/AbCd123' and p->>'default_language' = 'ar'
    and p->>'logo_version' is not null and p->>'image_version' is not null and fn_branch_media('00000000-0000-0000-0000-000000000010', 'image') like 'data:image/png;base64,%', p::text);
end $$;

-- =====================================================================
-- WS: visitors see no availability (decision 23)
-- =====================================================================
do $$ declare a text; b text; begin
  a := t_fails(format('select fn_get_public_availability(%L, %L)', '00000000-0000-0000-0000-000000000010', current_date), '%permission denied%');
  begin perform 1 from booking_sources limit 1; b := 'read'; exception when insufficient_privilege then b := 'ok'; end;
  perform t_record('WS01 a visitor can no longer ask for availability nor read the platforms list', a = 'ok' and b = 'ok', a || ' / ' || b);
end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
-- ---------------------------------------------------------------- VD01–VD05: data that enters right (0047; notes 1 and 4, decisions 2 and 6)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b jsonb; e text; ok int := 0; msgs text := ''; r jsonb; res uuid; begin
  b := jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'check_in', t_today() + 150, 'check_out', t_today() + 151,
       'source_id', '00000000-0000-0000-0000-000000000021');
  -- VD01: the main guest's phone is required and must be a Saudi mobile or an international number
  for e in select unnest(array['', '12345', '0412345678', '05123456', '+966412345678']) loop
    begin perform fn_staff_create_reservation(b || jsonb_build_object('guest_name', 'ضيف الاختبار', 'guest_phone', e));
          msgs := msgs || e || ' accepted; ';
    exception when others then if sqlerrm in ('VALIDATION: phone_required', 'VALIDATION: phone_format') then ok := ok + 1; else msgs := msgs || sqlerrm || '; '; end if; end;
  end loop;
  perform t_record('VD01 no booking without a valid phone for the main guest (empty, short, landline, foreign-length)', ok = 5, ok || ' / ' || msgs);
  -- VD02: written forms of one Saudi mobile are kept as 05…; an international number keeps its +
  r := fn_staff_create_reservation(b || jsonb_build_object('guest_name', 'ضيف الأرقام', 'guest_phone', '+966 ٥٥ ١٢٣ ٤٥٦٧'));
  res := (r->>'id')::uuid;
  r := fn_staff_create_reservation(b || jsonb_build_object('check_in', t_today() + 152, 'check_out', t_today() + 153, 'guest_name', 'John Smith', 'guest_phone', '00447700900123', 'new_profile', true));
  perform t_record('VD02 a Saudi mobile written +966/Arabic digits is kept as 05XXXXXXXX; an international one as +<digits>',
    (t_guest(t_primary(res))).phone = '0551234567' and (t_guest(t_primary((r->>'id')::uuid))).phone = '+447700900123',
    (t_guest(t_primary(res))).phone || ' / ' || (t_guest(t_primary((r->>'id')::uuid))).phone);
  -- VD03: names are letters only, for the main guest and a companion
  ok := 0; msgs := '';
  begin perform fn_staff_create_reservation(b || jsonb_build_object('guest_name', 'محمد 123', 'guest_phone', '0551234568')); msgs := msgs || 'digits accepted; ';
  exception when others then if sqlerrm = 'VALIDATION: name_letters_only' then ok := ok + 1; else msgs := msgs || sqlerrm || '; '; end if; end;
  begin perform fn_staff_create_reservation(b || jsonb_build_object('guest_name', 'محمد علي', 'guest_phone', '0551234569', 'companions', 1,
          'companions_details', jsonb_build_array(jsonb_build_object('full_name', 'R2-D2')))); msgs := msgs || 'companion accepted; ';
  exception when others then if sqlerrm = 'VALIDATION: name_letters_only' then ok := ok + 1; else msgs := msgs || sqlerrm || '; '; end if; end;
  perform t_record('VD03 a name with digits or symbols is refused for the main guest and a companion', ok = 2, ok || ' / ' || msgs);
  -- VD04: no guest under 15, main or companion, from the office
  ok := 0; msgs := '';
  begin perform t_doc(res, t_primary(res), 'ضيف الأرقام الصغير', '1056789012', jsonb_build_object('birth_date', (t_today() - interval '14 years')::date));
        msgs := msgs || 'main accepted; ';
  exception when others then if sqlerrm = 'VALIDATION: minimum_age_15' then ok := ok + 1; else msgs := msgs || sqlerrm || '; '; end if; end;
  update reservations set companions = 1 where id = res;
  begin perform t_doc(res, null, 'طفل المرافق الصغير', '1056789013', jsonb_build_object('birth_date', (t_today() - interval '10 years')::date, 'relationship', 'child'));
        msgs := msgs || 'companion accepted; ';
  exception when others then if sqlerrm = 'VALIDATION: minimum_age_15' then ok := ok + 1; else msgs := msgs || sqlerrm || '; '; end if; end;
  r := t_doc(res, t_primary(res), 'ضيف الأرقام الكبير', '١٠٥٦٧٨٩٠١٢', jsonb_build_object('birth_date', (t_today() - interval '15 years')::date));
  perform t_record('VD04 a guest under 15 (main or companion) is refused; 15 on the day is accepted, Arabic digits read',
    ok = 2 and (r->>'ok')::boolean, ok || ' / ' || msgs || coalesce(r::text, ''));
  -- VD05: a national ID starts with 1 and an iqama with 2
  ok := 0; msgs := '';
  begin perform t_doc(res, t_primary(res), 'ضيف الأرقام الكبير', '2056789012', jsonb_build_object('reason', 'تصحيح')); msgs := msgs || 'iqama number as ID accepted; ';
  exception when others then if sqlerrm = 'VALIDATION: identity_number_format' then ok := ok + 1; else msgs := msgs || sqlerrm || '; '; end if; end;
  begin perform t_doc(res, t_primary(res), 'ضيف الأرقام الكبير', '1056789012', jsonb_build_object('identity_type', 'iqama', 'reason', 'تصحيح')); msgs := msgs || 'ID number as iqama accepted; ';
  exception when others then if sqlerrm = 'VALIDATION: identity_number_format' then ok := ok + 1; else msgs := msgs || sqlerrm || '; '; end if; end;
  perform t_record('VD05 a national ID must start with 1 and an iqama with 2', ok = 2, ok || ' / ' || msgs);
exception when others then perform t_record('VD01–VD05 data validity', false, sqlerrm);
end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 55 then raise exception 'GUEST AND PLATFORM TESTS INCOMPLETE: % of 55 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'GUEST AND PLATFORM TESTS FAILED'; end if;
end $$;
