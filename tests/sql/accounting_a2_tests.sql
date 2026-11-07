-- =====================================================================
-- Accounting stage, tasks A2 and A3 (DC*; migration 0063): the closing of a day computed by the system, the counts and
-- reasons entered by the supervisor, the mandatory review, the free edit window recorded for review, and after it the
-- request the management approves or refuses. Every rule is tried from outside the screens.
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
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
create or replace function t_closing(p uuid) returns day_closings language sql security definer as $$ select * from day_closings where id = p $$;
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
-- what a script could compute itself from what it reads: the md5 of the day's money (no review token)
create or replace function t_forge(p uuid) returns text language sql security definer as $$
  select fn_day_closing_summary_hash(fn_day_closing_compute(c.branch_id, c.business_date), fn_day_closing_lines_json(c.id)) from day_closings c where c.id = p $$;
-- the window passing, as time would
create or replace function t_expire(p uuid) returns void language sql security definer as $$ update day_closings set edit_until = now() - interval '1 minute' where id = p $$;

-- ---------------------------------------------------------------- DC01 the matrix knows the two operations
select t_record('DC01 the permissions matrix has «day.close» (owner, manager, supervisor, finance) and «day.close.approve» (owner, manager)',
  exists (select 1 from fn_permission_catalog() c where c.code = 'day.close' and c.default_roles = '{owner,manager,supervisor,finance}')
  and exists (select 1 from fn_permission_catalog() c where c.code = 'day.close.approve' and c.default_roles = '{owner,manager}'));

-- ---------------------------------------------------------------- a branch of its own with a day of money
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; res uuid; ota uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الإقفال","name_en":"Closing branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة الإقفال', 'base_price_halalas', 20000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '701'));
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '702'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 20)::text,
         'check_out', (t_today(b) + 22)::text, 'guest_phone', '0551000091', 'guest_name', 'نزيل الإقفال', 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 20)::text,
         'check_out', (t_today(b) + 22)::text, 'guest_phone', '0551000092', 'guest_name', 'ضيف المنصة', 'source_id', '00000000-0000-0000-0000-000000000020',
         'external_ref', 'DC-OTA-1', 'platform_collects', true, 'platform_booked_on', t_today(b)::text));
  ota := (r->>'id')::uuid;
  insert into ids values ('b', b), ('res', res), ('ota', ota);
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 15000, 'method','cash', 'idempotency_key','dc-1'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','deposit', 'amount_halalas', 5000, 'method','cash', 'idempotency_key','dc-2'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 10000, 'method','pos', 'reference','DC-TRX-1', 'idempotency_key','dc-3'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', ota, 'kind','receipt', 'amount_halalas', 30000, 'method','ota_deferred', 'idempotency_key','dc-4'));
exception when others then perform t_record('DC00 the day''s money is set up', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- DC02 what the system computes
do $$ declare g jsonb; boxes jsonb; cash bigint; pos bigint; tr bigint; plat jsonb; m jsonb; begin
  g := fn_day_closing_get(t_id('b'), t_today(t_id('b')));
  boxes := g->'live'->'boxes';
  cash := (select (b->>'system_halalas')::bigint from jsonb_array_elements(boxes) b where b->>'key' = 'cash');
  pos := (select (b->>'system_halalas')::bigint from jsonb_array_elements(boxes) b where b->>'key' = 'pos');
  tr := (select (b->>'system_halalas')::bigint from jsonb_array_elements(boxes) b where b->>'key' = 'bank_transfer');
  plat := (select b from jsonb_array_elements(boxes) b where b->>'box' = 'platform' limit 1);
  m := (select x from jsonb_array_elements(g->'live'->'matrix') x where x->>'box' = 'cash' limit 1);
  perform t_record('DC02 the day is computed: cash 200.00 (rent 150 + deposit 50), terminal 100.00, transfer 0, one platform line with that platform''s deferred money, the method × source table, 2 units',
    g->>'state' = 'none' and cash = 20000 and pos = 10000 and tr = 0 and (plat->>'system_halalas')::bigint = t_count(format('select sum(amount_halalas) from financial_vouchers where reservation_id = %L and method = ''ota_deferred'' and status = ''approved''', t_id('ota')))
    and (m->>'rent_in')::bigint = 15000 and (m->>'deposit_in')::bigint = 5000 and (g->'live'->'rooms'->>'units')::int = 2,
    concat_ws(' / ', cash, pos, tr, g->'live'->>'rooms', m::text));
exception when others then perform t_record('DC02 the day is computed: cash 200.00 (rent 150 + deposit 50), terminal 100.00, transfer 0, one platform line with that platform''s deferred money, the method × source table, 2 units', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- DC03–DC06 as the supervisor of that branch
insert into branch_memberships(staff_id, branch_id) select '10000000-0000-0000-0000-000000000002', t_id('b')
  where not exists (select 1 from branch_memberships where staff_id = '10000000-0000-0000-0000-000000000002' and branch_id = t_id('b'));
select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
set role authenticated;
do $$ declare r jsonb; future text; begin
  future := t_fails(format('select fn_day_closing_save(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'business_date', t_today(t_id('b')) + 1)), 'VALIDATION: business_date%');
  r := fn_day_closing_save(jsonb_build_object('branch_id', t_id('b'), 'business_date', t_today(t_id('b')),
         'lines', jsonb_build_array(jsonb_build_object('key', 'cash', 'entered_halalas', 19000))));
  insert into ids values ('c', (r->>'id')::uuid);
  perform t_record('DC03 a draft keeps what was counted and the difference against the system (cash 190.00 − 200.00 = −10.00); a future day is refused',
    future = 'ok' and (select difference_halalas from day_closing_lines where closing_id = (r->>'id')::uuid and line_key = 'cash') = -1000
    and (t_closing((r->>'id')::uuid)).status = 'draft', future);
exception when others then perform t_record('DC03 a draft keeps what was counted and the difference against the system (cash 190.00 − 200.00 = −10.00); a future day is refused', false, sqlerrm);
end $$;
do $$ declare rv jsonb; nohash text; stale text; missing text; noreason text; forged text; s jsonb; v int; begin
  -- the review lists what is missing: the terminal count, and the reason of the cash difference
  rv := fn_day_closing_review(t_id('c'));
  missing := t_fails(format('select fn_day_closing_submit(%L, %s, %L)', t_id('c'), (rv->>'version')::int, rv->>'hash'), 'VALIDATION: closing_counts%');
  v := (t_closing(t_id('c'))).version;
  perform fn_day_closing_save(jsonb_build_object('branch_id', t_id('b'), 'business_date', t_today(t_id('b')), 'version', v,
         'lines', jsonb_build_array(jsonb_build_object('key', 'pos', 'entered_halalas', 10000))));
  rv := fn_day_closing_review(t_id('c'));
  noreason := t_fails(format('select fn_day_closing_submit(%L, %s, %L)', t_id('c'), (rv->>'version')::int, rv->>'hash'), 'VALIDATION: closing_reason%');
  v := (t_closing(t_id('c'))).version;
  perform fn_day_closing_save(jsonb_build_object('branch_id', t_id('b'), 'business_date', t_today(t_id('b')), 'version', v,
         'lines', jsonb_build_array(jsonb_build_object('key', 'cash', 'entered_halalas', 19000, 'reason', 'صرف فكة للضيف'))));
  -- sending without the reviewed summary, or with a summary that is no longer the current one, is refused
  nohash := t_fails(format('select fn_day_closing_submit(%L, %s, null)', t_id('c'), (t_closing(t_id('c'))).version), 'REVIEW_STALE%');
  stale := t_fails(format('select fn_day_closing_submit(%L, %s, %L)', t_id('c'), (t_closing(t_id('c'))).version, rv->>'hash'), 'REVIEW_STALE%');
  forged := t_fails(format('select fn_day_closing_submit(%L, %s, %L)', t_id('c'), (t_closing(t_id('c'))).version, t_forge(t_id('c'))), 'REVIEW_STALE%');
  rv := fn_day_closing_review(t_id('c'));
  s := fn_day_closing_submit(t_id('c'), (rv->>'version')::int, rv->>'hash');
  perform t_record('DC04 sending needs the review (its token, not a hash a script computes), the cash and terminal counts, and a reason for every difference; then the closing is open for its window',
    missing = 'ok' and noreason = 'ok' and nohash = 'ok' and stale = 'ok' and forged = 'ok' and (s->>'ok')::boolean
    and (t_closing(t_id('c'))).status = 'submitted' and (t_closing(t_id('c'))).edit_until between now() + interval '29 minutes' and now() + interval '31 minutes'
    and fn_day_closing_get(t_id('b'), t_today(t_id('b')))->>'state' = 'open',
    concat_ws(' / ', missing, noreason, nohash, stale, forged));
exception when others then perform t_record('DC04 sending needs the review (its token, not a hash a script computes), the cash and terminal counts, and a reason for every difference; then the closing is open for its window', false, sqlerrm);
end $$;
do $$ declare r jsonb; noreason text; again text; begin
  noreason := t_fails(format('select fn_day_closing_amend(%L::jsonb)', jsonb_build_object('id', t_id('c'), 'version', (t_closing(t_id('c'))).version,
                 'lines', jsonb_build_array(jsonb_build_object('key', 'cash', 'entered_halalas', 20000, 'reason', '')))), 'VALIDATION: reason%');
  r := fn_day_closing_amend(jsonb_build_object('id', t_id('c'), 'version', (t_closing(t_id('c'))).version, 'reason', 'وُجدت الفكة في الدرج',
         'lines', jsonb_build_array(jsonb_build_object('key', 'cash', 'entered_halalas', 20000, 'reason', ''))));
  again := t_fails(format('select fn_day_closing_save(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'business_date', t_today(t_id('b')), 'version', (t_closing(t_id('c'))).version)), 'CLOSING_SENT%');
  perform t_record('DC05 inside the window an edit needs its reason, is recorded with before and after, and lands in «بحاجة لمراجعة»; a sent closing is no draft again',
    noreason = 'ok' and again = 'ok' and (r->>'ok')::boolean
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = ''day_closing.amended''', t_id('c'))) = 1
    and t_count(format('select count(*) from review_items where entity_id = %L and kind = ''day_closing_amended''', t_id('c'))) = 1
    and t_count(format('select count(*) from day_closing_lines where closing_id = %L and line_key = ''cash'' and difference_halalas = 0', t_id('c'))) = 1,
    concat_ws(' / ', noreason, again));
exception when others then perform t_record('DC05 inside the window an edit needs its reason, is recorded with before and after, and lands in «بحاجة لمراجعة»; a sent closing is no draft again', false, sqlerrm);
end $$;
reset role;
select t_expire(t_id('c'));
set role authenticated;
do $$ declare locked text; early text; r jsonb; twice text; selfok text; begin
  locked := t_fails(format('select fn_day_closing_amend(%L::jsonb)', jsonb_build_object('id', t_id('c'), 'version', (t_closing(t_id('c'))).version, 'reason', 'x',
                 'lines', jsonb_build_array(jsonb_build_object('key', 'cash', 'entered_halalas', 20000)))), 'CLOSING_LOCKED%');
  r := fn_day_closing_request_edit(t_id('c'), 'نُسي سند تحويل');
  insert into ids values ('req', (r->>'request_id')::uuid);
  twice := t_fails(format('select fn_day_closing_request_edit(%L, %L)', t_id('c'), 'مرة ثانية'), 'REQUEST_PENDING%');
  selfok := t_fails(format('select fn_day_closing_decide(%L, true, null)', t_id('req')), 'FORBIDDEN%');
  perform t_record('DC06 after the window the closing refuses every edit; a request with its reason is raised once; the supervisor cannot approve it',
    locked = 'ok' and twice = 'ok' and selfok = 'ok' and fn_day_closing_get(t_id('b'), t_today(t_id('b')))->>'state' = 'locked',
    concat_ws(' / ', locked, twice, selfok));
exception when others then perform t_record('DC06 after the window the closing refuses every edit; a request with its reason is raised once; the supervisor cannot approve it', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- DC07 the management decides
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare nonote text; r jsonb; l jsonb; begin
  nonote := t_fails(format('select fn_day_closing_decide(%L, false, null)', t_id('req')), 'VALIDATION: note_required%');
  l := fn_day_closing_list(t_id('b'), t_today(t_id('b')) - 7, t_today(t_id('b')));
  r := fn_day_closing_decide(t_id('req'), true, null);
  perform t_record('DC07 the owner sees the pending request in the archive; a refusal needs its note; an approval opens a new window of the branch''s minutes',
    nonote = 'ok' and jsonb_array_length(l->'pending_requests') = 1 and (l->'closings'->0->>'pending_request')::boolean
    and r->>'status' = 'approved' and fn_day_closing_get(t_id('b'), t_today(t_id('b')))->>'state' = 'open',
    concat_ws(' / ', nonote, l::text));
exception when others then perform t_record('DC07 the owner sees the pending request in the archive; a refusal needs its note; an approval opens a new window of the branch''s minutes', false, sqlerrm);
end $$;
do $$ declare bad text; r jsonb; begin
  bad := t_fails(format('select fn_admin_set_day_close_minutes(%L, 2)', t_id('b')), 'VALIDATION: edit_minutes%');
  r := fn_admin_set_day_close_minutes(t_id('b'), 45);
  perform t_record('DC08 the edit window is a setting of the branch (5–240 minutes), changed with a line in the log',
    bad = 'ok' and (select day_close_edit_minutes from branches where id = t_id('b')) = 45
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = ''branch.day_close_rules_changed''', t_id('b'))) = 1, bad);
exception when others then perform t_record('DC08 the edit window is a setting of the branch (5–240 minutes), changed with a line in the log', false, sqlerrm);
end $$;
-- a voucher of that day after sending: the frozen figures stay, the closing says the day changed
do $$ declare g jsonb; begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 2500, 'method','bank_transfer', 'reference','DC-TR-9', 'idempotency_key','dc-9'));
  g := fn_day_closing_get(t_id('b'), t_today(t_id('b')));
  perform t_record('DC09 a voucher of the day after sending leaves the sent figures as they were, and the closing says the day changed',
    (g->>'changed_since_sent')::boolean
    and (select (b->>'system_halalas')::bigint from jsonb_array_elements(g->'closing'->'figures'->'boxes') b where b->>'key' = 'bank_transfer') = 0
    and (select (b->>'system_halalas')::bigint from jsonb_array_elements(g->'live'->'boxes') b where b->>'key' = 'bank_transfer') = 2500, g->>'changed_since_sent');
exception when others then perform t_record('DC09 a voucher of the day after sending leaves the sent figures as they were, and the closing says the day changed', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- DC14 the one who asked does not decide (the owner excepted)
insert into branch_memberships(staff_id, branch_id) select '10000000-0000-0000-0000-000000000008', t_id('b')
  where not exists (select 1 from branch_memberships where staff_id = '10000000-0000-0000-0000-000000000008' and branch_id = t_id('b'));
select t_expire(t_id('c'));
select t_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
do $$ declare r jsonb; selfd text; begin
  r := fn_day_closing_request_edit(t_id('c'), 'تصحيح مبلغ التحويل');
  selfd := t_fails(format('select fn_day_closing_decide(%L, true, null)', r->>'request_id'), 'SELF_DECISION%');
  insert into ids values ('req2', (r->>'request_id')::uuid);
  perform t_record('DC14 a manager cannot decide the request they raised; the owner decides it', selfd = 'ok', selfd);
exception when others then perform t_record('DC14 a manager cannot decide the request they raised; the owner decides it', false, sqlerrm); end $$;
reset role;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_day_closing_decide(t_id('req2'), false, 'المبلغ صحيح كما أُرسل');
  perform t_record('DC14b the owner refuses it with a note; the closing stays closed', r->>'status' = 'rejected'
    and fn_day_closing_get(t_id('b'), t_today(t_id('b')))->>'state' = 'locked', r::text);
exception when others then perform t_record('DC14b the owner refuses it with a note; the closing stays closed', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- DC10 housekeeping sees none of it; DC11 the log reads in Arabic
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
set role authenticated;
do $$ declare r text; begin
  r := t_fails(format('select fn_day_closing_get(%L, %L)', '00000000-0000-0000-0000-000000000010', current_date), 'FORBIDDEN%');
  perform t_record('DC10 housekeeping cannot read or write a closing', r = 'ok' and (select count(*) from day_closings) = 0 and (select count(*) from day_closing_lines) = 0, r);
end $$;
reset role;
select t_record('DC11 the closing''s log lines read in Arabic', fn_audit_action_label('day_closing.amended') = 'تعديل إقفال يوم خلال المهلة'
  and fn_audit_entity_label('day_closing') = 'إقفال يوم' and fn_audit_action_label('reservation.created') = 'إنشاء حجز');

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTING A2 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 13 then raise exception 'ACCOUNTING A2 TESTS INCOMPLETE: % of 13 checks ran', (select count(*) from test_results); end if;
end $$;
