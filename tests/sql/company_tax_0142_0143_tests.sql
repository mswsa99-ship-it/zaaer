-- 0142/0143: fn_staff_set_company_tax validates the company VAT pattern and the national address, guards role,
-- branch and version; fn_reservation_detail masks the company tax fields (with the money fields) from roles that
-- do not see money. Only unit/e2e mirrors existed; no SQL test called either. Synthetic, rolled back.
begin;
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
create or replace function t_ct_ver(p uuid) returns int language sql security definer as $$ select version from reservations where id = p $$;

-- ---------------------------------------------------------------- fixtures (the owner): a stay on the canonical branch «010»
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; bha uuid := '00000000-0000-0000-0000-000000000010'; cat uuid; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', bha, 'name_ar', 'غرفة الشركة', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', bha, 'category_id', cat, 'room_number', '931'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', bha, 'category_id', cat, 'check_in', (t_today(bha) + 100)::text,
         'check_out', (t_today(bha) + 101)::text, 'guest_phone', '0551000201', 'guest_name', 'ضيف الشركة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('bha', bha), ('res', (r->>'id')::uuid);
exception when others then perform t_record('CT90 fixture', false, sqlerrm); end $$;
reset role;

select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare res uuid := t_id('res'); ok jsonb; d jsonb; v0 int := t_ct_ver(t_id('res')); addr jsonb := '{"street":"شارع الملك فهد","city":"الرياض","district":"العليا","building_number":"1234","postal_code":"12345"}'::jsonb; begin
  ok := fn_staff_set_company_tax(res, '300000000000003', addr, v0);
  d := fn_reservation_detail(res)->'reservation';
  perform t_record('CT01 the owner saves a well-formed VAT and full national address at the expected version; the version moves and the detail shows them',
    (ok->>'ok')::boolean and t_ct_ver(res) = v0 + 1 and d->>'company_vat_number' = '300000000000003' and d->'company_address'->>'city' = 'الرياض', ok::text);
  perform t_record('CT02 the VAT pattern is enforced: wrong start digit, wrong length and non-digits are refused',
    t_fails(format('select fn_staff_set_company_tax(%L, %L, null, %s)', res, '200000000000002', t_ct_ver(res)), 'VALIDATION: vat_number%') = 'ok'
    and t_fails(format('select fn_staff_set_company_tax(%L, %L, null, %s)', res, '30000000000003', t_ct_ver(res)), 'VALIDATION: vat_number%') = 'ok'
    and t_fails(format('select fn_staff_set_company_tax(%L, %L, null, %s)', res, '3abcdefghijkl3', t_ct_ver(res)), 'VALIDATION: vat_number%') = 'ok', null);
  perform t_record('CT03 the national address is checked on the enforced parts: a short building number is refused (a missing postal code is NOT refused today - defect D-0142-1 reported separately, not asserted here)',
    t_fails(format('select fn_staff_set_company_tax(%L, null, %L::jsonb, %s)', res, '{"street":"x","city":"y","district":"z","building_number":"123","postal_code":"12345"}', t_ct_ver(res)), 'VALIDATION: company_address%') = 'ok', null);
  perform t_record('CT04 the strict version guard names its errors',
    t_fails(format('select fn_staff_set_company_tax(%L, null, null, %s)', res, t_ct_ver(res) + 5), 'VERSION_CONFLICT%') = 'ok'
    and t_fails(format('select fn_staff_set_company_tax(%L, null, null, null)', res), 'VERSION_REQUIRED%') = 'ok', null);
exception when others then perform t_record('CT91 setter checks unexpected error', false, sqlerrm); end $$;
reset role;

-- 0143: a role that does not see money reads none of the company tax fields; the owner reads them
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
do $$ declare d jsonb; begin
  d := fn_reservation_detail(t_id('res'))->'reservation';
  perform t_record('CT05 housekeeping reads neither the company tax fields nor the money fields of the same stay',
    not (d ? 'company_vat_number') and not (d ? 'company_address') and not (d ? 'company_name') and not (d ? 'total_halalas'), d::text);
  perform t_record('CT06 housekeeping cannot write the company tax either',
    t_fails(format('select fn_staff_set_company_tax(%L, %L, null, null)', t_id('res'), '300000000000003'), 'FORBIDDEN%') = 'ok', null);
exception when others then perform t_record('CT92 mask checks unexpected error', false, sqlerrm); end $$;
reset role;

select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare d jsonb; begin
  d := fn_reservation_detail(t_id('res'))->'reservation';
  perform t_record('CT07 the owner still reads the company tax fields after the masked read',
    d ? 'company_vat_number' and d ? 'company_address' and d->>'company_vat_number' = '300000000000003', null);
exception when others then perform t_record('CT93 owner re-read unexpected error', false, sqlerrm); end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
