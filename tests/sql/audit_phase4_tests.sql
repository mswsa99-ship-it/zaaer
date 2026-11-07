-- =====================================================================
-- The review of 31 October, Phase 4a as the owner decided it (QO*; migration 0059): the money the owner reads — the
-- platforms' money apart from what was collected, both occupancy figures, the collection rate on what the stays owe,
-- one period limit, every day in the daily series. A branch of its own, «فرع المالك».
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

-- ---------------------------------------------------------------- fixtures (the owner): a branch of two units, one stay from today
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع المالك","name_en":"Owner branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة المالك', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  insert into ids values ('b', b), ('cat', cat);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '401')); insert into ids values ('r1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '402')); insert into ids values ('r2', (r->>'id')::uuid);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', fn_branch_today(b)::text,
         'check_out', (fn_branch_today(b) + 2)::text, 'guest_phone', '0551000061', 'guest_name', 'ضيف المالك', 'source_id', '00000000-0000-0000-0000-000000000021'));
  insert into ids values ('s1', (r->>'id')::uuid);
end $$;
do $$ declare r jsonb; begin
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('s1'), 'kind', 'receipt', 'amount_halalas', 30000, 'method', 'pos', 'reference', 'TRX-QO-1', 'idempotency_key', 'qo-1'));
  r := fn_create_voucher(jsonb_build_object('reservation_id', t_id('s1'), 'kind', 'receipt', 'amount_halalas', 10000, 'method', 'ota_deferred', 'reference', 'OTA-QO-1', 'idempotency_key', 'qo-2'));
end $$;
reset role;
-- one unit occupied, the other taken out of service: occupancy 100% of the working units, 50% of all
update rooms set status = 'occupied' where id = t_id('r1');
update rooms set is_active = false where id = t_id('r2');
set role authenticated;

-- ---------------------------------------------------------------- QO01–QO02 the owner's day (OWNER-02, OWNER-03, OWNER-04)
select t_record('QO01 «المحصّل اليوم» is the money taken at the property; the platform''s money of the day is apart',
  (fn_ops_daily_summary_at(t_id('b'), fn_branch_today(t_id('b')))->'finance'->>'received_today')::bigint = 30000
  and (fn_ops_daily_summary_at(t_id('b'), fn_branch_today(t_id('b')))->'finance'->>'platform_today')::bigint = 10000,
  (fn_ops_daily_summary_at(t_id('b'), fn_branch_today(t_id('b')))->'finance')::text);
select t_record('QO02 both occupancy figures, each by its own definition: the working units and every unit',
  (fn_ops_daily_summary_at(t_id('b'), fn_branch_today(t_id('b')))->>'occupancy_pct')::numeric = 100
  and (fn_ops_daily_summary_at(t_id('b'), fn_branch_today(t_id('b')))->>'occupancy_all_pct')::numeric = 50,
  (fn_ops_daily_summary_at(t_id('b'), fn_branch_today(t_id('b')))->>'occupancy_all_pct'));

-- ---------------------------------------------------------------- QO03–QO06 the reports (OWNER-02, OWNER-07, OWNER-08, OWNER-10)
do $$ declare b uuid := t_id('b'); d date := fn_branch_today(t_id('b')); r jsonb; begin
  r := fn_reports_finance(b, d - 6, d, '{}');
  perform t_record('QO03 net collected leaves out what the platform holds; the platform''s money and the staff table say so',
    (r->'ledger'->>'net_collected')::bigint = 30000 and (r->'ledger'->>'platform_receipts')::bigint = 10000
    and (select coalesce(sum((x->>'receipts')::bigint), 0) from jsonb_array_elements(r->'by_staff') x) = 30000, (r->'ledger')::text);
  perform t_record('QO04 the daily series has every calendar day of the period, 0 on a quiet day',
    jsonb_array_length(r->'by_day') = 7 and (r->'by_day'->0->>'receipts')::bigint = 0 and (r->'by_day'->6->>'receipts')::bigint = 30000
    and (r->'by_day'->6->>'platform')::bigint = 10000, (r->'by_day')::text);
  perform t_record('QO05 one period limit (366 days), and an end after today is read up to today',
    t_err(format('select fn_reports_finance(%L, %L, %L, %L)', b, d - 400, d, '{}'), '%period_too_long%') = 'ok'
    and (fn_reports_finance(b, d - 6, d + 30, '{}')->'period'->>'to')::date = d
    and (fn_reports_finance(b, d - 6, d + 30, '{}')->'period'->>'requested_to')::date = d + 30
    and t_err(format('select fn_reports_finance(%L, %L, %L, %L)', b, d + 3, d + 5, '{}'), '%period_future%') = 'ok');
  perform t_record('QO06 the collection rate is what the period''s stays paid at the property over their charges (75%), not the platform''s',
    (r->'collection'->>'due')::bigint = 40000 and (r->'collection'->>'paid')::bigint = 30000 and (r->'collection'->>'platform')::bigint = 10000
    and (r->>'collection_rate_pct')::numeric = 75.0, (r->'collection')::text);
  perform fn_create_voucher(jsonb_build_object('reservation_id', t_id('s1'), 'kind', 'receipt', 'amount_halalas', 20000, 'method', 'cash', 'idempotency_key', 'qo-3'));
  r := fn_reports_finance(b, d - 6, d, '{}');
  perform t_record('QO07 an overpaid stay shows 100% and keeps the raw figure to explain it',
    (r->>'collection_rate_pct')::numeric = 100 and (r->'collection'->>'raw_pct')::numeric = 125.0, (r->'collection')::text);
exception when others then perform t_record('QO03 net collected leaves out what the platform holds; the platform''s money and the staff table say so', false, sqlerrm);
end $$;
reset role;

-- a check that comes out NULL counts as a failure here
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'REVIEW PHASE 4 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 7 then raise exception 'REVIEW PHASE 4 TESTS INCOMPLETE: % of 7 checks ran', (select count(*) from test_results); end if;
end $$;
