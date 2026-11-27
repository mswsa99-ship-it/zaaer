-- 0147: fn_staff_day_summary_range aggregates approved vouchers over a from-to period, both ends included,
-- by the branch's own days. Existing coverage was only the cross-branch FORBIDDEN smoke call (X04a) and the
-- one-day function's scoping (SC16); the range semantics themselves had no test. Synthetic, rolled back.
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

-- ---------------------------------------------------------------- fixtures (the owner): a branch of its own, one stay, three approved cash receipts
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; v jsonb; b uuid; cat uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع ملخص الفترة","name_en":"Range branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الفترة', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '901'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 70)::text,
         'check_out', (t_today(b) + 71)::text, 'guest_phone', '0551000171', 'guest_name', 'ضيف الفترة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('b', b), ('res', (r->>'id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 8000, 'method', 'cash', 'idempotency_key', 'dsr-1'));
  insert into ids values ('v1', (v->>'voucher_id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 7000, 'method', 'cash', 'idempotency_key', 'dsr-2'));
  insert into ids values ('v2', (v->>'voucher_id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind', 'receipt', 'received_confirmed', true, 'amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'dsr-3'));
  insert into ids values ('v3', (v->>'voucher_id')::uuid);
  perform t_record('DS90 the three receipts are approved at once (the range reads approved only)',
    (select count(*) from financial_vouchers where id in (t_id('v1'), t_id('v2'), t_id('v3')) and status = 'approved') = 3, null);
exception when others then perform t_record('DS91 fixture', false, sqlerrm); end $$;
reset role;

-- spread the three receipts over the branch's own days: v1 on d0, v2 on d0+2, v3 exactly at the exclusive end (d0+3 00:00)
do $$ declare b uuid := t_id('b'); d0 date; tz text; begin
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = b;
  d0 := fn_branch_today(b);
  update financial_vouchers set occurred_at = (d0::timestamp at time zone tz) + interval '12 hours' where id = t_id('v1');
  update financial_vouchers set occurred_at = ((d0 + 2)::timestamp at time zone tz) + interval '12 hours' where id = t_id('v2');
  update financial_vouchers set occurred_at = ((d0 + 3)::timestamp at time zone tz) where id = t_id('v3');
exception when others then perform t_record('DS92 spreading the voucher days failed', false, sqlerrm); end $$;

select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := t_id('b'); d0 date := t_today(b); r jsonb; x jsonb; begin
  r := fn_staff_day_summary_range(b, d0, d0 + 2);
  x := (select e from jsonb_array_elements(r->'rows') e where e->>'kind' = 'receipt' and e->>'method' = 'cash');
  perform t_record('DS01 the period takes both ends in the branch''s days: two receipts on d0 and d0+2 add up, the one at the exclusive end stays out',
    x is not null and (x->>'count')::int = 2 and (x->>'total')::bigint = 15000, r::text);
  perform t_record('DS04 the owner reads everyone''s rows and the answer names the asked period',
    (r->>'everyone')::boolean and (r->>'from')::date = d0 and (r->>'to')::date = d0 + 2, r::text);
  r := fn_staff_day_summary_range(b, d0, d0);
  x := (select e from jsonb_array_elements(r->'rows') e where e->>'kind' = 'receipt' and e->>'method' = 'cash');
  perform t_record('DS02 one day only: from = to lists that day alone',
    x is not null and (x->>'count')::int = 1 and (x->>'total')::bigint = 8000, r::text);
  perform t_record('DS03 a reversed period and a missing end are validation errors, not empty answers',
    t_fails(format('select fn_staff_day_summary_range(%L, %L, %L)', b, d0 + 1, d0), 'VALIDATION: date_range%') = 'ok'
    and t_fails(format('select fn_staff_day_summary_range(%L, %L, null)', b, d0), 'VALIDATION: business_date%') = 'ok', null);
exception when others then perform t_record('DS93 range checks unexpected error', false, sqlerrm); end $$;
reset role;

-- move v3 inside the period (d0+2 23:59 branch time): the inclusive end takes it
do $$ declare b uuid := t_id('b'); d0 date := fn_branch_today(b); tz text; begin
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = b;
  update financial_vouchers set occurred_at = ((d0 + 2)::timestamp at time zone tz) + interval '23 hours 59 minutes 59 seconds' where id = t_id('v3');
end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare b uuid := t_id('b'); d0 date := t_today(b); r jsonb; x jsonb; begin
  r := fn_staff_day_summary_range(b, d0, d0 + 2);
  x := (select e from jsonb_array_elements(r->'rows') e where e->>'kind' = 'receipt' and e->>'method' = 'cash');
  perform t_record('DS05 the last second of the last day still counts (the end is inclusive, the next midnight exclusive)',
    x is not null and (x->>'count')::int = 3 and (x->>'total')::bigint = 20000, r::text);
exception when others then perform t_record('DS94 boundary check unexpected error', false, sqlerrm); end $$;
reset role;

-- the same scoping as the one-day summary (SC16): a supervisor reads their own vouchers only, over a period
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_staff_day_summary_range('00000000-0000-0000-0000-000000000010', t_today('00000000-0000-0000-0000-000000000010') - 30, t_today('00000000-0000-0000-0000-000000000010'));
  perform t_record('DS06 the range keeps the one-day scope: a supervisor sees everyone = false and only rows they created',
    not (r->>'everyone')::boolean
    and not exists (select 1 from jsonb_array_elements(r->'rows') e where e->>'staff_id' <> fn_staff_id()::text), left(r::text, 200));
exception when others then perform t_record('DS95 scope check unexpected error', false, sqlerrm); end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by name;
rollback;
