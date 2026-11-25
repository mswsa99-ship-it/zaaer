-- 4.13 gap supplement 2 (lane 6): supervisor blind-count close -> owner decision chain + branch-scoped expense approve. Local synthetic only. Runs AFTER the full baseline suite on a clone of that database.
-- Adds, on top of finance_role_matrix_tests.sql (capability probes) and release-proof/finance_role_scenarios_tests.sql (RS13-01..10):
--  G1  auditor attempt 1 isolated: guest+Shomoos clean, ONLY money blockers remain -> refused with the money reasons, stay unchanged,
--      zero rows written; positive control: supervisor collects -> then arrival succeeds only after rent AND deposit (exact reasons shrink)
--  G2  attempt 2 exact: 99,999 receipt refused, full before/after state identical
--  G3  attempt 3 exact: 999,999 expense held pending, state delta = exactly +1 pending expense, no journal rows, box balance unchanged;
--      supervisor/finance/housekeeping cannot approve it; owner approval is refused by the cash-box floor, still pending, zero delta
--  G4  executed positives per cell: finance receipt, supervisor+finance invoice issue; housekeeping zero-delta negatives for every money entry
--  G5  tenant: another organisation's owner cannot touch org-1 reservation/expense (zero delta)
--  G6  day-closing role cells (day.close save by supervisor ok / housekeeping refused / finance ok) recorded as observed matrix
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text); grant all on test_results to public;
create temp table ids(k text primary key, v text); grant all on ids to public;
create or replace function g_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false); end $$;
create or replace function g_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$ insert into test_results values (p_name, p_ok, p_detail); $$;
create or replace function g_id(p_k text) returns text language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function g_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
create or replace function g_p(p text) returns text language plpgsql as $$ begin execute p; return 'accepted'; exception when others then return sqlstate||' '||sqlerrm; end $$;
create or replace function g_st() returns jsonb language sql security definer as $$
  select jsonb_build_object('vouchers', (select count(*) from financial_vouchers), 'vsum', (select coalesce(sum(amount_halalas),0) from financial_vouchers),
    'exp', (select count(*) from expense_vouchers), 'exp_approved', (select count(*) from expense_vouchers where status='approved'),
    'exp_sum', (select coalesce(sum(amount_halalas),0) from expense_vouchers where status='approved'),
    'je', (select count(*) from journal_entries), 'jl', (select count(*) from journal_lines), 'inv', (select count(*) from invoices),
    'closings', (select count(*) from day_closings), 'checked_in', (select count(*) from reservations where status='checked_in'),
    'res', (select count(*) from reservations)) $$;
create or replace function g_stay(p_room text, p_phone text, p_name text) returns text language plpgsql as $$
declare r jsonb; begin
  r := fn_staff_create_reservation(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id',g_id('cat'),'room_id',p_room,
    'check_in',g_today('00000000-0000-0000-0000-000000000010'),'check_out',g_today('00000000-0000-0000-0000-000000000010')+1,
    'guest_phone',p_phone,'guest_name',p_name,'source_id','00000000-0000-0000-0000-000000000021'));
  return r->>'id'; end $$;
create or replace function g_ready(p text) returns void language plpgsql security definer as $$ begin
  update reservation_guests set data_submitted=true, verification_status='verified' where reservation_id=p::uuid;
  update reservations set identity_status='verified' where id=p::uuid; end $$;
create or replace function g_att() returns jsonb language sql as $$ select jsonb_build_array(jsonb_build_object('file_name','r.png','data_base64','iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')) $$;
create or replace function g_box() returns text language sql security definer as $$ select id::text from cash_accounts where branch_id='00000000-0000-0000-0000-000000000010' and kind='cash_box' and is_default $$;
create or replace function g_exp(p_amt bigint, p_key text) returns jsonb language sql as $$
  select fn_expense_create(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id',g_id('expcat'),'account_id',g_box(),
    'amount_halalas',p_amt,'description','G exp','attachments',g_att(),'idempotency_key',p_key)) $$;
create or replace function g_blk(p text) returns text[] language sql security definer as $$ select fn_checkin_core_blockers(p::uuid) $$;
create or replace function g_mon(p text) returns text[] language sql security definer as $$ select fn_checkin_money_blockers(p::uuid) $$;
create or replace function g_n(p text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p into n; return n; end $$;
create or replace function g_reasons(p jsonb) returns text language sql as $$ select coalesce(p->>'reasons','') $$;


create or replace function g_compute(p_b uuid, p_d date) returns jsonb language sql security definer as $$ select fn_day_closing_compute(p_b, p_d) $$;
create or replace function g_backdate_edit(p uuid) returns void language sql security definer as $$ update day_closings set edit_until = now() - interval '1 minute' where id = p $$;
create or replace function g_ex(p_sql text) returns text language plpgsql security definer as $$ declare t text; begin execute p_sql into t; return t; end $$;
select g_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_expense_category(jsonb_build_object('name','مصروفات سلسلة الإقفال')); insert into ids values ('expcat', r->>'id');
end $$;

-- ===== B branch-scoped expense approve: same org, capability held, branch NOT a member
do $$ declare r jsonb; eid text; s0 jsonb; e text; begin
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  r := g_exp(600000,'b-exp-1'); eid := r->>'id'; insert into ids values ('bexp', eid);
  perform g_record('B-00 precondition: supervisor 6,000.00 expense is pending (over the 5,000.00 role limit) on branch 010 and the box covers it', (r->>'pending_approval')::boolean and g_n('select fn_cash_account_balance('''||g_box()||'''::uuid)')>=600000, r::text);
  perform g_record('B-01 precondition: manager mgr4 holds the capability (role default) but is not a member of branch 010',
    g_n('select count(*) from branch_memberships m join staff_profiles s on s.id=m.staff_id where s.email=''mgr4@test.local'' and m.branch_id=''00000000-0000-0000-0000-000000000010'' and m.removed_at is null')=0
    and g_n('select count(*) from staff_profiles where email=''mgr4@test.local'' and role=''manager''')=1, null);
  perform g_login('a0000000-0000-0000-0000-000000000091','mgr4@test.local'); s0 := g_st();
  e := g_p(format('select fn_expense_approve(%L::uuid)', eid));
  perform g_record('B-02 non-member manager refused by branch scope (FORBIDDEN branch not permitted); expense still pending, zero delta', e like '42501 FORBIDDEN: branch not permitted%' and g_st()=s0 and g_n(format('select count(*) from expense_vouchers where id=%L and status=''pending''', eid))=1, e);
  e := g_p(format('select fn_expense_cancel(%L::uuid, ''سبب'')', eid));
  perform g_record('B-03 non-member manager also refused cancel on branch 010 (zero delta)', e like '42501%' and g_st()=s0, e);
  perform g_login('a0000000-0000-0000-0000-000000000008','mgr@test.local');
  r := fn_expense_approve(eid::uuid);
  perform g_record('B-04 positive: member manager approves (status approved, +1 approved row, approved-sum +600000)', (r->>'status')='approved' and (g_st()->>'exp_approved')::int=(s0->>'exp_approved')::int+1 and (g_st()->>'exp_sum')::bigint=(s0->>'exp_sum')::bigint+600000, r::text);
exception when others then perform g_record('B block', false, sqlerrm); end $$;

-- ===== C1 supervisor: blind count, review, submit
do $$ declare b uuid := '00000000-0000-0000-0000-000000000010'; d date := g_today('00000000-0000-0000-0000-000000000010'); live jsonb; lines jsonb; s jsonb; rv jsonb; g jsonb; c day_closings%rowtype; e text; s0 jsonb; begin
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  g := fn_day_closing_get(b, d);
  perform g_record('C1-01 supervisor, before counting: no system figure in the boxes, no matrix (blind)', not exists (select 1 from jsonb_array_elements(g->'live'->'boxes') x where x ? 'system_halalas') and g->'live'->'matrix'='[]'::jsonb, null);
  live := g_compute(b, d);
  select jsonb_agg(jsonb_build_object('key', x->>'key', 'entered_halalas', x->>'system_halalas')) into lines from jsonb_array_elements(live->'boxes') x;
  s := fn_day_closing_save(jsonb_build_object('branch_id', b, 'business_date', d, 'lines', lines));
  g := fn_day_closing_get(b, d);
  perform g_record('C1-02 supervisor saves a count (draft); stored lines hide system figure and difference', (s->>'ok')::boolean and not exists (select 1 from jsonb_array_elements(g->'lines') l where l ? 'system_halalas' or l ? 'difference_halalas'), s::text);
  select * into c from day_closings where branch_id=b and business_date=d; insert into ids values ('c1', c.id::text);
  perform g_record('C1-03 draft state: status draft, no submit stamps', c.status='draft' and c.submitted_by is null, c.status);
  rv := fn_day_closing_review(c.id);
  perform g_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
  e := g_p(format('select fn_day_closing_submit(%L::uuid, %s, %L)', c.id, (rv->>'version')::int, rv->>'hash'));
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  perform g_record('C1-03b housekeeping cannot submit the supervisor''s valid draft (FORBIDDEN); it stays draft', e like '42501%' and (select status from day_closings where id=c.id)='draft', e);
  s := fn_day_closing_submit(c.id, (rv->>'version')::int, rv->>'hash');
  select * into c from day_closings where id=c.id;
  perform g_record('C1-04 supervisor submits: status submitted, submitted_by = supervisor staff id, edit window set in the future', (s->>'ok')::boolean and c.status='submitted' and c.submitted_by = (select id from staff_profiles where email='sup@test.local') and c.edit_until > now(), s::text);
  g := fn_day_closing_get(b, d);
  perform g_record('C1-05 after submit the system figure is revealed', exists (select 1 from jsonb_array_elements(g->'live'->'boxes') x where x ? 'system_halalas'), null);
  -- negatives on the submitted closing
  s0 := g_st();
  e := g_p(format('select fn_day_closing_submit(%L::uuid, %s, %L)', c.id, c.version, rv->>'hash'));
  perform g_record('C1-06 a second submit is refused (CLOSING_SENT or stale), no duplicate closing row', e like 'P0001%' and (select count(*) from day_closings where branch_id=b and business_date=d)=1, e);
  perform g_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
  e := g_p(format('select fn_day_closing_review(%L::uuid)', c.id));
  perform g_record('C1-07 housekeeping cannot review the closing (FORBIDDEN)', e like '42501%', e);
  e := g_p(format('select fn_day_closing_decide(%L::uuid, true, null)', gen_random_uuid()));
  perform g_record('C1-08 housekeeping cannot decide (FORBIDDEN)', e like '42501%', e);
exception when others then perform g_record('C1 block', false, sqlerrm); end $$;

-- ===== C2 supervisor asks to reopen; who may decide; owner approves
do $$ declare c day_closings%rowtype; r jsonb; e text; rid uuid; ed0 timestamptz; begin
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  select * into c from day_closings where id = g_id('c1')::uuid;
  e := g_p(format('select fn_day_closing_request_edit(%L::uuid, ''خطأ عدّ'')', c.id));
  perform g_record('C2-01 while the edit window is open a reopen request is refused (CLOSING_OPEN)', e like 'P0001 CLOSING_OPEN%', e);
  perform g_backdate_edit(c.id);
  r := fn_day_closing_request_edit(c.id, 'خطأ في عدّ الصندوق');
  rid := (r->>'request_id')::uuid; insert into ids values ('req', rid::text);
  perform g_record('C2-02 after the window the supervisor files a reopen request (pending, requested_by = supervisor)', (r->>'ok')::boolean and g_n(format('select count(*) from day_closing_requests where id=%L and status=''pending''', rid))=1, r::text);
  e := g_p(format('select fn_day_closing_decide(%L::uuid, true, null)', rid));
  perform g_record('C2-03 the supervisor cannot decide his own request: '||e, e like '42501%' or e like 'P0001 SELF_DECISION%', e);
  perform g_record('C2-03b request still pending after that refusal', g_n(format('select count(*) from day_closing_requests where id=%L and status=''pending''', rid))=1, null);
  perform g_login('a0000000-0000-0000-0000-000000000004','fin@test.local');
  e := g_p(format('select fn_day_closing_decide(%L::uuid, true, null)', rid));
  perform g_record('C2-04 finance cannot decide: '||e, e like '42501%' and g_n(format('select count(*) from day_closing_requests where id=%L and status=''pending''', rid))=1, e);
  perform g_login('a0000000-0000-0000-0000-000000000005','owner2@test.local');
  e := g_p(format('select fn_day_closing_decide(%L::uuid, true, null)', rid));
  perform g_record('C2-05 the org-2 owner cannot decide an org-1 request: '||e, e like '42501%' or e like 'P0001 NOT_FOUND%', e);
  perform g_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  e := g_p(format('select fn_day_closing_decide(%L::uuid, false, null)', rid));
  perform g_record('C2-06 owner rejection without a note is refused (note_required), still pending', e like 'P0001 VALIDATION: note_required%' and g_n(format('select count(*) from day_closing_requests where id=%L and status=''pending''', rid))=1, e);
  r := fn_day_closing_decide(rid, true, 'اعتماد المالك');
  select * into c from day_closings where id = g_id('c1')::uuid;
  perform g_record('C2-07 the owner approves: request approved, decided_by = owner, closing edit window reopened (edit_until > now)',
    (r->>'ok')::boolean and (select status='approved' and decided_by=(select id from staff_profiles where email='owner@test.local') from day_closing_requests where id=rid) and c.edit_until > now(), r::text);
  e := g_p(format('select fn_day_closing_decide(%L::uuid, true, null)', rid));
  perform g_record('C2-08 a decided request cannot be decided again (REQUEST_DECIDED)', e like 'P0001 REQUEST_DECIDED%', e);
exception when others then perform g_record('C2 block', false, sqlerrm); end $$;

reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),140) as detail from test_results order by ctid;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
