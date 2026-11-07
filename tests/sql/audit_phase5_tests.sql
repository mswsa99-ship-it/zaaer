-- =====================================================================
-- The review of 31 October, Phase 5 adopted by recommendation (QP*; migration 0061): the server's own texts count in
-- Arabic and write money in one form; a price change without a description is named in Arabic; nightly prices and the
-- reports' filter lists only for the roles they serve; the guest's link keeps the main guest's phone; the lookup counts
-- its attempts one at a time; a visitor reads only the guest columns of a branch.
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
create or replace function t_token(p uuid) returns text language sql security definer as $$ insert into registration_sessions(reservation_id) values (p) returning token $$;
create or replace function t_p5_primary(p uuid) returns table(id uuid, phone text) language sql security definer as $$ select id, phone from reservation_guests where reservation_id = p and is_primary $$;

-- ---------------------------------------------------------------- QP01–QP02 counting and money in the server's texts
select t_record('QP01 nights are counted in Arabic: 1, 2, 3–10, 11–99, 100',
  fn_ar_nights(1) = 'ليلة واحدة' and fn_ar_nights(2) = 'ليلتان' and fn_ar_nights(4) = '4 ليالٍ' and fn_ar_nights(11) = '11 ليلة'
  and fn_ar_nights(100) = '100 ليلة' and fn_ar_nights(103) = '103 ليالٍ',
  concat_ws(' | ', fn_ar_nights(1), fn_ar_nights(2), fn_ar_nights(4), fn_ar_nights(11), fn_ar_nights(103)));
select t_record('QP02 money in the server''s texts is grouped: «1,600.00 ر.س»',
  fn_sar_text(160000) = '1,600.00 ر.س' and fn_sar_text(5) = '0.05 ر.س' and fn_sar_text(123456789) = '1,234,567.89 ر.س', fn_sar_text(160000));

-- ---------------------------------------------------------------- QP03–QP04 a stay's lines (MONEY-08, COPY-11)
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; res uuid; v int; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الصياغة","name_en":"Wording branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الصياغة', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  insert into ids values ('b', b), ('cat', cat);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '501'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (current_date + 10)::text,
         'check_out', (current_date + 14)::text, 'guest_phone', '0551000081', 'guest_name', 'نزيل الصياغة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid; insert into ids values ('res', res);
  perform t_record('QP03 the rent line counts its nights in Arabic and writes the price grouped: «إيجار 4 ليالٍ × 200.00 ر.س»',
    exists (select 1 from reservation_charges c where c.reservation_id = res and c.kind = 'rent' and c.description like '%4 ليالٍ × 200.00 ر.س%'),
    (select string_agg(description, ' | ') from reservation_charges where reservation_id = res));
  v := (select version from reservations where id = res);
  perform fn_staff_adjust_price(res, 'discount', 1000, '', 'اختبار الوصف', v);
  perform t_record('QP04 a discount without a description is named «خصم», never «discount»',
    exists (select 1 from reservation_charges c where c.reservation_id = res and c.kind = 'discount' and c.description = 'خصم')
    and not exists (select 1 from reservation_charges c where c.reservation_id = res and c.description = 'discount'),
    (select string_agg(description, ' | ') from reservation_charges where reservation_id = res));
exception when others then perform t_record('QP03 the rent line counts its nights in Arabic and writes the price grouped: «إيجار 4 ليالٍ × 200.00 ر.س»', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QP05–QP06 who is quoted prices and offered the filter lists (PERM-09)
do $$ begin
  perform t_record('QP05 the owner gets a quote and the reports'' filter lists',
    fn_staff_quote(t_id('b'), t_id('cat'), current_date + 30, current_date + 32) is not null
    and fn_report_filter_options(t_id('b')) ? 'accounts');
end $$;
reset role;
-- housekeeping in the seeded branch: no booking, pricing, extension or unit-moving rights, and no money
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
select t_record('QP06 housekeeping is quoted no prices and offered no boxes, accounts or staff',
  fn_staff_quote('00000000-0000-0000-0000-000000000010', (select id from room_categories where branch_id = '00000000-0000-0000-0000-000000000010' limit 1), current_date + 30, current_date + 32) is null
  and coalesce(fn_report_filter_options('00000000-0000-0000-0000-000000000010'), '{}'::jsonb) = '{}'::jsonb);
reset role;

-- ---------------------------------------------------------------- QP07 the guest's link keeps the main guest's phone (SEC-07)
do $$ declare tok text := t_token(t_id('res')); g uuid; before text; after text; begin
  select x.id, x.phone into g, before from t_p5_primary(t_id('res')) x;
  perform fn_guest_acknowledge(tok, fn_guest_stay_summary(tok)->>'hash');
  perform fn_guest_submit(tok, g, jsonb_build_object('full_name', 'نزيل الصياغة الأول', 'identity_type', 'national_id', 'identity_number', '1012345674',
            'nationality', 'SA', 'birth_date', '1990-01-01', 'phone', '0559999999', 'consent', 'true'));
  select x.phone into after from t_p5_primary(t_id('res')) x;
  perform t_record('QP07 a guest''s link cannot change the main guest''s recorded phone', after = before and before is not null, coalesce(before, '∅') || ' → ' || coalesce(after, '∅'));
exception when others then perform t_record('QP07 a guest''s link cannot change the main guest''s recorded phone', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- QP08–QP09 the lookup's lock (SEC-08), the visitor's columns (SEC-09)
select t_record('QP08 the phone + booking-number lookup takes a lock per phone before it counts attempts',
  (select prosrc from pg_proc where proname = 'fn_guest_phone_verify_ref') like '%pg_advisory_xact_lock(hashtext(''lookup:'' || v_phone))%');
select t_record('QP09 a visitor reads the guest columns of a branch, not its internal settings',
  has_column_privilege('anon', 'branches', 'name_ar', 'select') and has_column_privilege('anon', 'branches', 'map_url', 'select')
  and not has_column_privilege('anon', 'branches', 'email', 'select')
  and not has_column_privilege('anon', 'branches', 'supervisor_max_discount_bp', 'select')
  and not has_table_privilege('anon', 'branches', 'select'));

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'REVIEW PHASE 5 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 9 then raise exception 'REVIEW PHASE 5 TESTS INCOMPLETE: % of 9 checks ran', (select count(*) from test_results); end if;
end $$;
