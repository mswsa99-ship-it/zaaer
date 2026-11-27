-- 0148: fn_pos_settlement_range lists, per branch day, the POS total of one bank account over a from-to period
-- (both ends included), sparse: only days with POS vouchers or a saved settlement. No test called it before
-- (X04a covers the one-day preview only). Synthetic, rolled back.
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

-- ---------------------------------------------------------------- fixtures (the owner): a branch, its default bank account, one stay, POS and cash money on two days
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; v jsonb; b uuid; cat uuid; acc uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع تسوية الفترة","name_en":"POS range branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة التسوية', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '911'));
  select id into acc from cash_accounts where branch_id = b and kind = 'bank_account' and is_default and archived_at is null;
  insert into ids values ('b', b), ('acc', acc);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 80)::text,
         'check_out', (t_today(b) + 81)::text, 'guest_phone', '0551000181', 'guest_name', 'ضيف التسوية', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('res', (r->>'id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 6000, 'method', 'pos', 'reference', 'PR-1', 'idempotency_key', 'pr-1'));
  insert into ids values ('v1', (v->>'voucher_id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 4000, 'method', 'pos', 'reference', 'PR-2', 'idempotency_key', 'pr-2'));
  insert into ids values ('v2', (v->>'voucher_id')::uuid);
  v := fn_refund(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'refund', 'amount_halalas', 1000, 'method', 'pos', 'reference', 'PR-R1', 'reason', 'ترجيع جزء', 'idempotency_key', 'pr-3'));
  insert into ids values ('v3', (v->>'voucher_id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 3000, 'method', 'cash', 'idempotency_key', 'pr-4'));
  insert into ids values ('v4', (v->>'voucher_id')::uuid);
  perform t_record('PR90 the POS receipts and the refund are approved at once (the range reads approved only)',
    (select count(*) from financial_vouchers where id in (t_id('v1'), t_id('v2'), t_id('v3')) and status = 'approved') = 3,
    (select string_agg(id::text || ':' || status, ' ') from financial_vouchers where id in (t_id('v1'), t_id('v2'), t_id('v3'))));
exception when others then perform t_record('PR91 fixture', false, sqlerrm); end $$;
reset role;

-- v1 and the cash v4 on d0; v2 and the refund v3 on d0+1 (branch days)
do $$ declare b uuid := t_id('b'); d0 date; tz text; begin
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = b;
  d0 := fn_branch_today(b);
  update financial_vouchers set occurred_at = (d0::timestamp at time zone tz) + interval '12 hours' where id in (t_id('v1'), t_id('v4'));
  update financial_vouchers set occurred_at = ((d0 + 1)::timestamp at time zone tz) + interval '12 hours' where id in (t_id('v2'), t_id('v3'));
exception when others then perform t_record('PR92 spreading the voucher days failed', false, sqlerrm); end $$;

select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := t_id('b'); acc uuid := t_id('acc'); d0 date := t_today(b); r jsonb; x jsonb; y jsonb; begin
  r := fn_pos_settlement_range(b, acc, d0, d0 + 2);
  x := (select e from jsonb_array_elements(r->'days') e where (e->>'business_date')::date = d0);
  y := (select e from jsonb_array_elements(r->'days') e where (e->>'business_date')::date = d0 + 1);
  perform t_record('PR01 the period lists exactly the days that have something: two days, none for the empty third day',
    jsonb_array_length(r->'days') = 2 and x is not null and y is not null
    and not exists (select 1 from jsonb_array_elements(r->'days') e where (e->>'business_date')::date = d0 + 2), r::text);
  perform t_record('PR02 a day''s total is its POS money only: the receipt counts, the cash voucher of the same day stays out',
    (x->>'system_total_halalas')::bigint = 6000 and (x->>'voucher_count')::int = 1, x::text);
  perform t_record('PR03 a refund subtracts on its day (receipt minus refund), and both vouchers count',
    (y->>'system_total_halalas')::bigint = 3000 and (y->>'voucher_count')::int = 2, y::text);
  perform t_record('PR04 a day without a saved settlement says so (settlement = null), and the answer names the asked period',
    (x->>'settlement') is null and (y->>'settlement') is null and (r->>'from')::date = d0 and (r->>'to')::date = d0 + 2, r::text);
  perform t_record('PR05 reversed period and missing end are validation errors',
    t_fails(format('select fn_pos_settlement_range(%L, %L, %L, %L)', b, acc, d0 + 1, d0), 'VALIDATION: date_range%') = 'ok'
    and t_fails(format('select fn_pos_settlement_range(%L, %L, null, %L)', b, acc, d0), 'VALIDATION: business_date%') = 'ok', null);
  perform t_record('PR06 the cash box is not a bank account, and another branch''s bank account is not this branch''s',
    t_fails(format('select fn_pos_settlement_range(%L, (select id from cash_accounts where branch_id = %L and kind = ''cash_box'' and is_default limit 1), %L, %L)', b, b, d0, d0), 'BRANCH_MISMATCH: account%') = 'ok'
    and t_fails(format('select fn_pos_settlement_range(%L, (select id from cash_accounts where branch_id = ''00000000-0000-0000-0000-000000000010'' and kind = ''bank_account'' and is_default limit 1), %L, %L)', b, d0, d0), 'BRANCH_MISMATCH: account%') = 'ok', null);
exception when others then perform t_record('PR93 range checks unexpected error', false, sqlerrm); end $$;
reset role;

-- a saved settlement on d0 shows in the range with its version and zero difference
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := t_id('b'); acc uuid := t_id('acc'); d0 date := t_today(b); p jsonb; s jsonb; r jsonb; x jsonb; begin
  p := fn_pos_settlement_preview(b, acc, d0);
  s := fn_pos_settle(jsonb_build_object('branch_id', b, 'account_id', acc, 'business_date', d0, 'terminal_total_halalas', (p->>'system_total_halalas')::bigint));
  r := fn_pos_settlement_range(b, acc, d0, d0);
  x := (select e from jsonb_array_elements(r->'days') e where (e->>'business_date')::date = d0);
  perform t_record('PR07 the settled day carries its settlement (status, version, no difference when the terminal agrees)',
    x is not null and (x->>'settlement') is not null and (x->'settlement'->>'difference_halalas')::bigint = 0
    and (x->'settlement'->>'version')::int = 1, x::text);
exception when others then perform t_record('PR94 settlement check unexpected error', false, sqlerrm); end $$;
reset role;

-- the guard is the same as the one-day preview: a supervisor of another branch is refused
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare b uuid := t_id('b'); acc uuid := t_id('acc'); d0 date := t_today(b); begin
  perform t_record('PR08 another branch''s period is refused on the server',
    t_fails(format('select fn_pos_settlement_range(%L, %L, %L, %L)', b, acc, d0, d0), 'FORBIDDEN%') = 'ok', null);
exception when others then perform t_record('PR95 guard check unexpected error', false, sqlerrm); end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
