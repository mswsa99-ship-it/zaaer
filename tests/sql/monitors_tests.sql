-- =====================================================================
-- Monitoring after go-live (decision 54, migration 0037). MN01–MN10: each of the seven checks raises its finding in the
-- owner's review list, once (not again while open), without personal data; the owner's dashboard runs them at most
-- every 10 minutes; nobody else runs them; a clean branch raises nothing.
-- The anomalies are written directly (they cannot be made through the product's own functions, which is the point).
-- Runs after invoices_review_tests.sql on the same database (its synthetic organisation, branch 010 and staff).
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
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today() returns date language sql security definer as $$ select fn_branch_today('00000000-0000-0000-0000-000000000010') $$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_stay(p_room uuid, p_from date, p_to date, p_name text) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'),
         'room_id', p_room, 'check_in', p_from, 'check_out', p_to, 'guest_name', p_name, 'guest_phone', '0500009' || lpad((floor(random() * 1000))::int::text, 3, '0'),
         'source_id', '00000000-0000-0000-0000-000000000021'));
  return (r->>'id')::uuid;
end $$;
-- the monitors as the server runs them (pg_cron), and the open findings of a kind
create or replace function t_run(p uuid) returns jsonb language sql security definer as $$ select fn_run_monitors(p) $$;
create or replace function t_findings(p_kind text) returns bigint language sql security definer as $$
  select count(*) from review_items where kind = 'monitor:' || p_kind and reviewed_at is null
$$;
create or replace function t_finding(p_kind text) returns review_items language sql security definer as $$
  select * from review_items where kind = 'monitor:' || p_kind order by created_at desc limit 1
$$;
-- the anomalies
create or replace function t_two_in_one(p_a uuid, p_b uuid, p_room uuid) returns void language sql security definer as $$
  update reservations set status = 'checked_in', room_id = p_room where id in (p_a, p_b)
$$;
create or replace function t_bad_total(p uuid) returns void language sql security definer as $$
  update reservations set total_halalas = total_halalas + 777 where id = p
$$;
create or replace function t_bad_deposit(p uuid) returns void language plpgsql security definer as $$
begin
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, status, idempotency_key, content_hash, created_by)
  select r.organization_id, r.branch_id, r.id, 'MN-DRF-1', 'deposit_refund', 5000, 'cash', 'approved', 'mn-bad-deposit', md5('mn'), null from reservations r where r.id = p;
end $$;
create or replace function t_stuck_event() returns void language sql security definer as $$
  insert into integration_events(organization_id, source, external_event_id, kind, state, created_at)
  values ('00000000-0000-0000-0000-000000000001', 'ota', 'mn-stuck-1', 'reservation.cancelled', 'received', now() - interval '2 hours')
$$;
create or replace function t_failed_lookups(p_n int) returns void language sql security definer as $$
  insert into guest_lookup_attempts(external_ref, client_fingerprint, ok) select 'MN-' || g, 'fp-mn', false from generate_series(1, p_n) g
$$;
create or replace function t_two_cleanings(p uuid, p_room uuid) returns void language sql security definer as $$
  insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description)
  select r.organization_id, r.branch_id, p_room, fn_room_cleaning_type(r.branch_id), 'تنظيف', r.id, 'high', 'تنظيف بعد المغادرة'
    from reservations r cross join generate_series(1, 2) where r.id = p
$$;
create or replace function t_refused(p_staff uuid, p_n int) returns void language sql security definer as $$
  insert into client_errors(organization_id, staff_id, trace_id, error_code, context)
  select '00000000-0000-0000-0000-000000000001', p_staff, 'MNTRACE' || g, 'FORBIDDEN', 'fn_cancel_invoice' from generate_series(1, p_n) g
$$;
create or replace function t_age_runs() returns void language sql security definer as $$
  update monitor_runs set last_run_at = last_run_at - interval '11 minutes'
$$;

-- ---------------------------------------------------------------- fixtures
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; d0 date := t_today() + 120; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'name_ar', 'نوع المراقبة', 'base_capacity', 2, 'max_capacity', 3,
         'base_price_halalas', 10000));
  insert into ids values ('cat', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'MN-1')); insert into ids values ('m1', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'MN-2')); insert into ids values ('m2', (r->>'id')::uuid);
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', '00000000-0000-0000-0000-000000000010', 'category_id', t_id('cat'), 'room_number', 'MN-3')); insert into ids values ('m3', (r->>'id')::uuid);
  insert into ids values ('a', t_stay(t_id('m1'), d0, d0 + 2, 'ضيف المراقبة أ'));
  insert into ids values ('b', t_stay(t_id('m2'), d0, d0 + 2, 'ضيف المراقبة ب'));
  insert into ids values ('c', t_stay(t_id('m3'), d0, d0 + 2, 'ضيف المراقبة ج'));
end $$;

do $$ declare r jsonb; n0 bigint; begin
  -- the first run: whatever the earlier test files left is taken as found; from here every finding is counted
  r := t_run('00000000-0000-0000-0000-000000000010');
  n0 := t_count('select count(*) from review_items where kind like ''monitor:%''');
  r := t_run('00000000-0000-0000-0000-000000000010');
  perform t_record('MN01 a second run finds nothing new: a finding is raised once',
    t_count('select count(*) from review_items where kind like ''monitor:%''') = n0 and (r->'found') = '{}'::jsonb, r::text);
exception when others then perform t_record('MN01 a second run finds nothing new: a finding is raised once', false, sqlerrm); end $$;

do $$ declare r jsonb; ri review_items; begin
  perform t_two_in_one(t_id('a'), t_id('b'), t_id('m1'));
  perform t_bad_total(t_id('c'));
  perform t_bad_deposit(t_id('c'));
  perform t_stuck_event();
  perform t_failed_lookups(12);
  perform t_two_cleanings(t_id('c'), t_id('m3'));
  perform t_refused('10000000-0000-0000-0000-000000000002', 3);
  r := t_run('00000000-0000-0000-0000-000000000010');
  ri := t_finding('allocation_conflict');
  perform t_record('MN02 two guests in house in one unit → «تعارض تخصيص» with the unit and the stays',
    t_findings('allocation_conflict') >= 1 and ri.summary like '%MN-1%' and jsonb_array_length(ri.details->'reservations') = 2, ri.summary);
  ri := t_finding('ledger_mismatch');
  perform t_record('MN03 stored totals that differ from the ledger → «الملخص المالي يختلف عن الدفتر», both sides shown',
    t_findings('ledger_mismatch') >= 1 and ri.reservation_id = t_id('c') and (ri.details->'stored'->>'total')::bigint - (ri.details->'ledger'->>'total')::bigint = 777, ri.details::text);
  ri := t_finding('deposit_invalid');
  perform t_record('MN04 a deposit below zero → «رصيد التأمين غير صالح»',
    t_findings('deposit_invalid') >= 1 and ri.reservation_id = t_id('c') and (ri.details->>'deposit_balance')::bigint < 0, ri.summary);
  ri := t_finding('provider_stuck');
  perform t_record('MN05 a provider event not processed after an hour → «أحداث مزود عالقة»',
    t_findings('provider_stuck') >= 1 and (ri.details->>'events_waiting')::int >= 1, ri.summary);
  ri := t_finding('verification_failures');
  perform t_record('MN06 repeated failed guest look-ups → «فشل تحقق متكرر», counts only (no reference, no phone)',
    t_findings('verification_failures') >= 1 and (ri.details->>'failed_lookups')::int >= 12 and ri.details::text not like '%MN-%' and ri.details::text !~ '05[0-9]{8}', ri.details::text);
  ri := t_finding('duplicate_departure');
  perform t_record('MN07 two open departure cleanings for one stay → «مهام مغادرة مكررة»',
    t_findings('duplicate_departure') >= 1 and ri.reservation_id = t_id('c') and (ri.details->>'open_tasks')::int = 2, ri.summary);
  ri := t_finding('out_of_scope');
  perform t_record('MN08 a staff member refused three times in a day → «محاولات خارج النطاق», with the operations tried',
    t_findings('out_of_scope') >= 1 and ri.entity_id = '10000000-0000-0000-0000-000000000002' and (ri.details->>'attempts')::int >= 3
    and ri.details->'operations' ? 'fn_cancel_invoice', ri.summary);
exception when others then perform t_record('MN02 two guests in house in one unit → «تعارض تخصيص» with the unit and the stays', false, sqlerrm); end $$;

do $$ declare r jsonb; s jsonb; m text; begin
  -- the owner's dashboard: throttled to every 10 minutes; nobody else; the banner counts the findings
  r := fn_monitors_if_due('00000000-0000-0000-0000-000000000010');
  perform t_age_runs();
  s := fn_monitors_if_due('00000000-0000-0000-0000-000000000010');
  perform t_login('a0000000-0000-0000-0000-000000000008', 'mgr@test.local');
  m := t_fails('select fn_monitors_if_due(''00000000-0000-0000-0000-000000000010''::uuid)', 'FORBIDDEN%');
  perform t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
  perform t_record('MN09 the owner''s dashboard runs the checks at most every 10 minutes, nobody else runs them, and the banner counts the findings',
    not (r->>'ran')::boolean and (s->>'ran')::boolean and m = 'ok' and (s->'summary'->>'monitors')::int >= 7
    and has_function_privilege('authenticated', 'fn_run_monitors(uuid)', 'execute') = false, format('first %s, after 11 min %s, manager %s', r->>'ran', s->>'ran', m));
exception when others then perform t_record('MN09 the owner''s dashboard runs the checks at most every 10 minutes, nobody else runs them, and the banner counts the findings', false, sqlerrm); end $$;

do $$ declare l jsonb; n0 int; begin
  -- the owner marks the findings; an anomaly that is still there is raised again only after a day
  l := fn_review_list(jsonb_build_object('kind', 'monitor'));
  perform fn_review_mark(jsonb_build_object('ids', (select jsonb_agg(x->'id') from jsonb_array_elements(l->'items') x), 'note', 'قيد المعالجة'));
  n0 := t_count('select count(*) from review_items where kind like ''monitor:%''');
  perform t_run('00000000-0000-0000-0000-000000000010');
  perform t_record('MN10 marked findings are not raised again within the day while the anomaly is still there',
    jsonb_array_length(l->'items') >= 7 and t_count('select count(*) from review_items where kind like ''monitor:%''') = n0
    and t_count('select count(*) from review_items where kind like ''monitor:%'' and reviewed_at is null') = 0, format('%s items, %s total', jsonb_array_length(l->'items'), n0));
exception when others then perform t_record('MN10 marked findings are not raised again within the day while the anomaly is still there', false, sqlerrm); end $$;

-- =====================================================================
-- RESULTS
-- =====================================================================
reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),150) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if (select count(*) from test_results) < 10 then raise exception 'MONITOR TESTS INCOMPLETE: % of 10 checks ran', (select count(*) from test_results); end if;
  if exists (select 1 from test_results where ok is not true) then raise exception 'MONITOR TESTS FAILED'; end if;
end $$;
