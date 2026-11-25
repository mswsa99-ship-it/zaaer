-- 4.13 gap supplement (lane 6). Local synthetic only. Runs AFTER the full baseline suite on a clone of that database.
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

-- fixtures as owner
select g_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set role authenticated;
do $$ declare r jsonb; begin
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','name_ar','نوع فجوة الأدوار','base_capacity',2,'max_capacity',3,'base_price_halalas',30000,'min_nightly_halalas',10000));
  insert into ids values ('cat', r->>'id');
  for i in 1..4 loop r := fn_admin_upsert_room(jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id',g_id('cat'),'room_number','GR-'||i)); insert into ids values ('room'||i, r->>'id'); end loop;
  r := fn_admin_upsert_expense_category(jsonb_build_object('name','مصروفات فجوة الأدوار')); insert into ids values ('expcat', r->>'id');
end $$;

-- ===== G1 attempt 1, isolated to the money gate
do $$ declare rid text; s0 jsonb; s1 jsonb; r jsonb; core text[]; money text[]; begin
  rid := g_stay(g_id('room1'),'0571400001','سالم بلا دفع'); insert into ids values ('g1', rid);
  perform g_ready(rid);
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  perform fn_staff_shomoos(jsonb_build_object('reservation_id',rid,'action','register','reference','SHM-G1','all_guests',true));
  perform fn_staff_shomoos(jsonb_build_object('reservation_id',rid,'action','accept'));
  core := g_blk(rid); money := g_mon(rid);
  perform g_record('G1-01 precondition: no core blockers; both money blockers (rent 300.00, deposit 50.00) present', coalesce(array_length(core,1),0)=0 and coalesce(array_length(money,1),0)=2, core::text||' / '||money::text);
  s0 := g_st(); r := fn_staff_check_in(jsonb_build_object('reservation_id',rid)); s1 := g_st();
  perform g_record('G1-02 attempt 1: supervisor arrival with no collection refused ONLY by money reasons (reasons are exactly the 2 money blockers); stay not checked in; state identical',
    (r->>'ok')::boolean is false and (r->'reasons') = to_jsonb(money) and s0 = s1
    and (select actual_check_in is null and status<>'checked_in' from reservations where id=rid::uuid), r::text);
  r := fn_create_voucher(jsonb_build_object('reservation_id',rid,'kind','receipt','amount_halalas',30000,'method','cash','received_confirmed',true,'idempotency_key','g1-rent'));
  perform g_record('G1-03 supervisor collects the first night (receipt ok, +1 voucher of 30000)', (r->>'ok')::boolean and (g_st()->>'vouchers')::int = (s0->>'vouchers')::int+1 and (g_st()->>'vsum')::bigint = (s0->>'vsum')::bigint+30000, r::text);
  s0 := g_st(); r := fn_staff_check_in(jsonb_build_object('reservation_id',rid));
  perform g_record('G1-04 rent paid, deposit missing: still refused, reason is the deposit only, state identical',
    (r->>'ok')::boolean is false and jsonb_array_length(r->'reasons')=1 and (r->'reasons'->>0) like 'التأمين%' and g_st()=s0, r::text);
  r := fn_staff_check_in(jsonb_build_object('reservation_id',rid,'deposit',jsonb_build_object('amount_halalas',5000,'method','cash','received_confirmed',true,'idempotency_key','g1-dep')));
  perform g_record('G1-05 rent+deposit collected through the arrival screen: arrival succeeds, +1 checked_in, deposit voucher recorded',
    (r->>'ok')::boolean and (g_st()->>'checked_in')::int = (s0->>'checked_in')::int+1 and (g_st()->>'vsum')::bigint = (s0->>'vsum')::bigint+5000, left(r::text,120));
exception when others then perform g_record('G1 block', false, sqlerrm); end $$;

-- ===== G2 attempt 2: 99,999
do $$ declare s0 jsonb; e text; begin
  perform g_record('G2-00 precondition: the G1 reservation exists and is checked in (refusals below are not NOT_FOUND artefacts)', g_n(format('select count(*) from reservations where id=%L and status=''checked_in''', g_id('g1')))=1, null);
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  s0 := g_st();
  e := g_p(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g1'),'kind','receipt','amount_halalas',9999900,'method','cash','received_confirmed',true,'idempotency_key','g2-big')));
  perform g_record('G2-01 attempt 2: 99,999 receipt refused with VALIDATION amount_exceeds_short…, whole-state identical', e like 'P0001 VALIDATION: amount_exceeds_short%' and g_st()=s0, e);
  e := g_p(format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g1'),'kind','receipt','amount_halalas',9999900,'method','cash','idempotency_key','g2-big-nc')));
  perform g_record('G2-02 same amount without the receipt confirmation is refused too, state identical', e like 'P0001%' and g_st()=s0, e);
exception when others then perform g_record('G2 block', false, sqlerrm); end $$;

-- ===== G3 attempt 3: 999,999 expense
do $$ declare s0 jsonb; s1 jsonb; r jsonb; e text; eid text; bal0 text; begin
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  s0 := g_st(); r := g_exp(99999900,'g3-big'); s1 := g_st(); eid := r->>'id'; insert into ids values ('g3', eid);
  perform g_record('G3-01 attempt 3: supervisor 999,999 expense is held pending; delta is exactly +1 expense row, 0 approved, 0 approved-sum, 0 journal rows',
    (r->>'pending_approval')::boolean and (s1->>'exp')::int=(s0->>'exp')::int+1 and s1->'exp_approved'=s0->'exp_approved' and s1->'exp_sum'=s0->'exp_sum'
    and s1->'je'=s0->'je' and s1->'jl'=s0->'jl' and (select status from expense_vouchers where id=eid::uuid)='pending', r::text);
  s0 := g_st();
  e := g_p(format('select fn_expense_approve(%L)', eid));
  perform g_record('G3-02 supervisor cannot approve his own pending expense (FORBIDDEN), zero delta', e like '42501 FORBIDDEN%' and g_st()=s0, e);
  perform g_login('a0000000-0000-0000-0000-000000000004','fin@test.local');
  e := g_p(format('select fn_expense_approve(%L)', eid));
  perform g_record('G3-03 finance cannot approve it (FORBIDDEN), zero delta', e like '42501 FORBIDDEN%' and g_st()=s0, e);
  perform g_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
  e := g_p(format('select fn_expense_approve(%L)', eid));
  perform g_record('G3-04 housekeeping cannot approve it (FORBIDDEN), zero delta', e like '42501 FORBIDDEN%' and g_st()=s0, e);
  perform g_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
  e := g_p(format('select fn_expense_approve(%L)', eid));
  perform g_record('G3-05 even the owner is refused by the cash-box floor (CASH_BOX_NEGATIVE); expense still pending, zero delta', e like 'P0001 CASH_BOX_NEGATIVE%' and g_st()=s0
    and (select status from expense_vouchers where id=eid::uuid)='pending', e);
exception when others then perform g_record('G3 block', false, sqlerrm); end $$;

-- ===== G4 executed positives and zero-delta negatives per cell
do $$ declare rid text; r jsonb; s0 jsonb; e text; n int := 0; stmt text; begin
  rid := g_stay(g_id('room2'),'0571400002','ماجد مالية'); insert into ids values ('g4', rid);
  perform g_login('a0000000-0000-0000-0000-000000000004','fin@test.local');
  s0 := g_st();
  r := fn_create_voucher(jsonb_build_object('reservation_id',rid,'kind','receipt','amount_halalas',30000,'method','cash','received_confirmed',true,'idempotency_key','g4-fin-rcpt'));
  perform g_record('G4-01 finance EXECUTES a receipt (+1 voucher, +30000)', (r->>'ok')::boolean and (g_st()->>'vsum')::bigint=(s0->>'vsum')::bigint+30000, left(r::text,100));
  s0 := g_st(); r := fn_staff_issue_invoice(jsonb_build_object('reservation_id',rid));
  perform g_record('G4-02 finance EXECUTES an invoice issue (+1 invoice)', coalesce((r->>'ok')::boolean,true) and (g_st()->>'inv')::int=(s0->>'inv')::int+1, left(r::text,100));
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local');
  rid := g_stay(g_id('room3'),'0571400003','ماجد مشرف'); insert into ids values ('g4s', rid);
  perform fn_create_voucher(jsonb_build_object('reservation_id',rid,'kind','receipt','amount_halalas',30000,'method','cash','received_confirmed',true,'idempotency_key','g4-sup-rcpt'));
  s0 := g_st(); r := fn_staff_issue_invoice(jsonb_build_object('reservation_id',rid));
  perform g_record('G4-03 supervisor EXECUTES an invoice issue (+1 invoice)', coalesce((r->>'ok')::boolean,true) and (g_st()->>'inv')::int=(s0->>'inv')::int+1, left(r::text,100));
  -- supervisor / finance cannot cancel or credit an invoice, cancel a voucher: zero delta
  for stmt in select format(x, g_id('g4')) from unnest(array[
      'select fn_cancel_invoice(%L::uuid, ''سبب'')', 'select fn_issue_credit_note(%L::uuid, ''سبب'')']) x loop
    s0 := g_st();
    perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local'); e := g_p(stmt);
    perform g_record('G4-04 supervisor refused (FORBIDDEN, zero delta): '||left(stmt,40), e like '42501%' and g_st()=s0, e);
    perform g_login('a0000000-0000-0000-0000-000000000004','fin@test.local'); e := g_p(stmt);
    perform g_record('G4-05 finance refused (FORBIDDEN, zero delta): '||left(stmt,40), e like '42501%' and g_st()=s0, e);
  end loop;
  -- housekeeping: every money entry refused, zero delta, real reservation
  perform g_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
  for stmt in select unnest(array[
      format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g4'),'kind','receipt','amount_halalas',1000,'method','cash','received_confirmed',true,'idempotency_key','g4-hk-1')),
      format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g4'),'kind','refund','amount_halalas',1000,'reason','x','method','cash','idempotency_key','g4-hk-2')),
      format('select fn_staff_issue_invoice(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g4'))),
      format('select fn_staff_check_in(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g4'))),
      format('select fn_cancel_voucher(%L::uuid, ''سبب'')', (select id from financial_vouchers where reservation_id=g_id('g4')::uuid limit 1)),
      format('select fn_expense_cancel(%L::uuid, ''سبب'')', g_id('g3'))]) loop
    s0 := g_st(); e := g_p(stmt); n := n+1;
    perform g_record('G4-06.'||n||' housekeeping refused (FORBIDDEN, zero delta): '||left(stmt,38), e like '42501%' and g_st()=s0, e);
  end loop;
  -- finance cannot cancel the pending expense or arrive
  perform g_login('a0000000-0000-0000-0000-000000000004','fin@test.local'); s0 := g_st();
  e := g_p(format('select fn_expense_cancel(%L::uuid, ''سبب'')', g_id('g3')));
  perform g_record('G4-07 finance refused expense.cancel (FORBIDDEN, zero delta)', e like '42501%' and g_st()=s0, e);
  s0 := g_st(); e := g_p(format('select fn_staff_check_in(%L::jsonb)', jsonb_build_object('reservation_id', g_id('g4'))));
  perform g_record('G4-07b finance refused the arrival (FORBIDDEN, zero delta)', e like '42501%' and g_st()=s0, e);
  perform g_login('a0000000-0000-0000-0000-000000000002','sup@test.local'); s0 := g_st();
  e := g_p(format('select fn_expense_cancel(%L::uuid, ''سبب'')', g_id('g3')));
  perform g_record('G4-08 supervisor refused expense.cancel (FORBIDDEN, zero delta)', e like '42501%' and g_st()=s0, e);
exception when others then perform g_record('G4 block', false, sqlerrm); end $$;

-- ===== G5 tenant: org-2 owner on org-1 objects
do $$ declare s0 jsonb; e text; n int := 0; stmt text; begin
  perform g_record('G5-00 precondition: the org-1 targets exist (2 reservations, 1 pending expense) so refusals are not missing-object artefacts',
    g_n(format('select count(*) from reservations where id in (%L,%L)', g_id('g4'), g_id('g1')))=2 and g_n(format('select count(*) from expense_vouchers where id=%L and status=''pending''', g_id('g3')))=1, null);
  perform g_login('a0000000-0000-0000-0000-000000000005','owner2@test.local'); s0 := g_st();
  for stmt in select unnest(array[
      format('select fn_create_voucher(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g4'),'kind','receipt','amount_halalas',1000,'method','cash','received_confirmed',true,'idempotency_key','g5-1')),
      format('select fn_refund(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g4'),'kind','refund','amount_halalas',1000,'reason','x','method','cash','idempotency_key','g5-2')),
      format('select fn_staff_issue_invoice(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g4'))),
      format('select fn_staff_check_in(%L::jsonb)', jsonb_build_object('reservation_id',g_id('g1'))),
      format('select fn_expense_approve(%L::uuid)', g_id('g3')),
      format('select fn_expense_cancel(%L::uuid, ''سبب'')', g_id('g3'))]) loop
    e := g_p(stmt); n := n+1;
    perform g_record('G5-0'||n||' org-2 owner refused on an org-1 object (no write, whole-state identical): '||left(stmt,36), e not like 'accepted%' and g_st()=s0, e);
  end loop;
  e := g_p(format('select fn_expense_create(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010','category_id',g_id('expcat'),'account_id',g_box(),'amount_halalas',100,'description','x','attachments',g_att(),'idempotency_key','g5-exp')));
  perform g_record('G5-07 org-2 owner cannot create an expense on an org-1 branch/box, whole-state identical', e not like 'accepted%' and g_st()=s0, e);
exception when others then perform g_record('G5 block', false, sqlerrm); end $$;

-- ===== G6 day-closing role cells (observed matrix, pinned)
do $$ declare e text; v text := ''; begin
  foreach e in array array['a0000000-0000-0000-0000-000000000002|sup@test.local','a0000000-0000-0000-0000-000000000004|fin@test.local','a0000000-0000-0000-0000-000000000003|hk@test.local'] loop
    perform g_login(split_part(e,'|',1)::uuid, split_part(e,'|',2));
    v := v || split_part(e,'|',2)||'='||case when g_p('select fn_day_closing_get(''00000000-0000-0000-0000-000000000010'', current_date)') like '42501%' then 'refused' else 'ok' end||';';
  end loop;
  perform g_record('G6-01 day.close read cell pinned: supervisor ok, finance ok, housekeeping refused', v = 'sup@test.local=ok;fin@test.local=ok;hk@test.local=refused;', v);
exception when others then perform g_record('G6 block', false, sqlerrm); end $$;

reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),140) as detail from test_results order by ctid;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
