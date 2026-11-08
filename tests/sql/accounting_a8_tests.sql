-- =====================================================================
-- Accounting stage, task A8 (MT*; migration 0067): matching the bank's movements. A movement waits until the owner
-- matches it with a record or turns it into a voucher; a movement is used once and a record matched once; a different
-- amount needs a reason and is booked; undoing or cancelling lets it wait again; the books hold it in suspense meanwhile.
-- Tried from outside the screens. The movements are written straight into the table (as 0066 would have read them).
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
create or replace function t_count(p_sql text) returns bigint language plpgsql security definer as $$ declare n bigint; begin execute p_sql into n; return n; end $$;
create or replace function t_accid(p_branch uuid, p_kind text) returns uuid language sql security definer as $$
  select id from cash_accounts where branch_id = p_branch and kind = p_kind and archived_at is null $$;
create or replace function t_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
-- a movement as 0066 would have read it (its message kept raw)
create or replace function t_movement(p_branch uuid, p_dir text, p_kind text, p_amount bigint, p_ref text, p_assigned boolean default true) returns uuid
language plpgsql security definer as $$
declare m uuid; v uuid; org uuid := (select organization_id from branches where id = p_branch);
begin
  insert into bank_messages(organization_id, raw_body, content_hash, sms_text, status) values (org, 'رسالة اختبار ' || p_ref, md5(p_ref || clock_timestamp()::text), 'رسالة ' || p_ref, 'parsed') returning id into m;
  insert into bank_movements(organization_id, branch_id, cash_account_id, message_id, kind, direction, amount_halalas, occurred_at, reference, account_hint, dedupe_key)
  values (org, case when p_assigned then p_branch end, case when p_assigned then t_accid(p_branch, 'bank_account') end, m, p_kind, p_dir, p_amount, now(), p_ref, '**999', 'msg:' || m)
  returning id into v;
  update bank_messages set movement_id = v where id = m;
  return v;
end $$;
create or replace function t_bal(p_branch uuid, p_key text) returns bigint language sql security definer as $$
  select coalesce(sum(l.debit_halalas - l.credit_halalas), 0)::bigint from journal_lines l join journal_entries e on e.id = l.entry_id join gl_accounts g on g.id = l.account_id
  where e.branch_id = p_branch and (g.system_key = p_key or (p_key = 'bank' and g.cash_account_id = t_accid(p_branch, 'bank_account'))) $$;
create or replace function t_mv(p uuid) returns bank_movements language sql security definer as $$ select * from bank_movements where id = p $$;

-- ---------------------------------------------------------------- a branch with a reservation paid by transfer
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; res uuid; v jsonb; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع المطابقة","name_en":"Matching branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة المطابقة', 'base_price_halalas', 30000)); cat := (r->>'id')::uuid;
  perform fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '951'));
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (t_today(b) + 20)::text,
         'check_out', (t_today(b) + 22)::text, 'guest_phone', '0551000095', 'guest_name', 'نزيل المطابقة', 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid;
  insert into ids values ('b', b), ('res', res);
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 50000, 'method','bank_transfer', 'reference','MT-TR-1', 'idempotency_key','mt-1'));
  insert into ids values ('v1', (v->>'voucher_id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 10000, 'method','bank_transfer', 'reference','MT-TR-2', 'idempotency_key','mt-2'));
  insert into ids values ('v2', (v->>'voucher_id')::uuid);
exception when others then perform t_record('MT00 the branch and its vouchers are set up', false, sqlerrm);
end $$;
reset role;
insert into ids select 'm1', t_movement(t_id('b'), 'in', 'transfer_in', 50000, 'MTREF1');
insert into ids select 'm2', t_movement(t_id('b'), 'in', 'transfer_in', 50000, 'MTREF2');
insert into ids select 'm3', t_movement(t_id('b'), 'in', 'transfer_in', 9900, 'MTREF3');
insert into ids select 'm4', t_movement(t_id('b'), 'out', 'fee', 575, 'MTREF4');
insert into ids select 'm5', t_movement(t_id('b'), 'in', 'other_in', 2500, 'MTREF5');
insert into ids select 'mu', t_movement(t_id('b'), 'in', 'deposit', 7000, 'MTREFU', false);

-- ---------------------------------------------------------------- MT01 a waiting movement is held in suspense
select t_record('MT01 a waiting movement of a known account is booked bank against suspense (129): the bank follows the bank, the suspense shows what is not explained; an unassigned one is not booked',
  t_bal(t_id('b'), 'suspense') = -(50000 + 50000 + 9900 + 2500 - 575)
  and t_count(format('select count(*) from journal_entries where source_type = ''bank_movement'' and source_id = %L', t_id('mu'))) = 0,
  t_bal(t_id('b'), 'suspense')::text);

-- ---------------------------------------------------------------- MT02–MT03 match, once
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare c jsonb; r jsonb; used text; again text; bad text; unas text; begin
  c := fn_bank_candidates(t_id('m1'));
  r := fn_bank_match(t_id('m1'), 'voucher', t_id('v1'), null);
  used := t_fails(format('select fn_bank_match(%L, %L, %L, null)', t_id('m2'), 'voucher', t_id('v1')), 'VALIDATION: target_used%');
  again := t_fails(format('select fn_bank_match(%L, %L, %L, null)', t_id('m1'), 'voucher', t_id('v2')), 'VALIDATION: movement_used%');
  bad := t_fails(format('select fn_bank_match(%L, %L, %L, null)', t_id('m4'), 'voucher', t_id('v2')), 'VALIDATION: target%');
  unas := t_fails(format('select fn_bank_match(%L, %L, %L, null)', t_id('mu'), 'voucher', t_id('v2')), 'VALIDATION: movement_unassigned%');
  perform t_record('MT02 the candidates of a movement are its account''s records of the same direction around its day, the same amount first; the owner matches it; the suspense entry is reversed',
    c->0->>'id' = t_id('v1')::text and (c->0->>'exact')::boolean and (r->>'difference_halalas')::bigint = 0 and (t_mv(t_id('m1'))).status = 'matched'
    and t_bal(t_id('b'), 'suspense') = -(50000 + 9900 + 2500 - 575), c::text);
  perform t_record('MT03 a movement is used once and a record matched once; money out is not matched with a receipt; an unassigned movement is not matched',
    used = 'ok' and again = 'ok' and bad = 'ok' and unas = 'ok', concat_ws(' / ', used, again, bad, unas));
exception when others then perform t_record('MT02 the candidates of a movement are its account''s records of the same direction around its day, the same amount first; the owner matches it; the suspense entry is reversed', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT04 a different amount: a reason, and the difference booked
do $$ declare noreason text; r jsonb; bank0 bigint; begin
  bank0 := t_bal(t_id('b'), 'bank');
  noreason := t_fails(format('select fn_bank_match(%L, %L, %L, null)', t_id('m3'), 'voucher', t_id('v2')), 'VALIDATION: difference_reason%');
  r := fn_bank_match(t_id('m3'), 'voucher', t_id('v2'), 'رسوم التحويل خُصمت من المبلغ');
  perform t_record('MT04 a movement of another amount than its record needs a reason; the difference is booked to the bank''s fees (57), so the bank account stands at what the bank holds',
    noreason = 'ok' and (r->>'difference_halalas')::bigint = -100 and t_bal(t_id('b'), 'bank_fees') = 100
    and t_bal(t_id('b'), 'bank') = bank0 - 9900 - 100, concat_ws(' / ', noreason, r::text, t_bal(t_id('b'), 'bank')));
exception when others then perform t_record('MT04 a movement of another amount than its record needs a reason; the difference is booked to the bank''s fees (57), so the bank account stands at what the bank holds', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT05 undo, and a cancelled voucher lets go
do $$ declare nor text; r jsonb; begin
  nor := t_fails(format('select fn_bank_unmatch(%L, %L)', t_id('m3'), ''), 'VALIDATION: reason%');
  perform fn_bank_unmatch(t_id('m3'), 'مطابقة خاطئة');
  perform fn_cancel_voucher(t_id('v1'), 'سند مكرر');
  perform t_record('MT05 the owner undoes a match with a reason (the difference reversed, the movement waits again in suspense); cancelling a matched voucher lets its movement wait again; the history stays',
    nor = 'ok' and (t_mv(t_id('m3'))).status = 'pending' and (t_mv(t_id('m1'))).status = 'pending' and t_bal(t_id('b'), 'bank_fees') = 0
    and t_bal(t_id('b'), 'suspense') = -(50000 + 50000 + 9900 + 2500 - 575)
    and t_count(format('select count(*) from bank_matches where movement_id in (%L, %L) and not active and release_reason is not null', t_id('m1'), t_id('m3'))) = 2, nor);
exception when others then perform t_record('MT05 the owner undoes a match with a reason (the difference reversed, the movement waits again in suspense); cancelling a matched voucher lets its movement wait again; the history stays', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT06 turn into a voucher
do $$ declare e jsonb; i jsonb; nocat text; undo text; begin
  nocat := t_fails(format('select fn_bank_convert(%L, %L::jsonb)', t_id('m4'), jsonb_build_object('description', 'رسوم')), 'VALIDATION: category%');
  e := fn_bank_convert(t_id('m4'), jsonb_build_object('description', 'رسوم تحويل البنك', 'category_id', (select id from expense_categories where name = 'رسوم بنكية ونقاط بيع' and organization_id = fn_user_org_id())));
  undo := t_fails(format('select fn_bank_unmatch(%L, %L)', t_id('m4'), 'خطأ'), 'VALIDATION: cancel_the_expense%');
  i := fn_bank_convert(t_id('m5'), jsonb_build_object('description', 'فرق عملة من البنك'));
  perform t_record('MT06 the owner turns money out into an expense of its category (the bank''s message is its receipt) and money in into other income; the movements are used; an expense made so is undone by cancelling it',
    nocat = 'ok' and undo = 'ok' and e->>'expense_number' like 'EXP-%' and (t_mv(t_id('m4'))).status = 'converted' and (t_mv(t_id('m5'))).status = 'converted'
    and (select amount_halalas from expense_vouchers where id = (e->>'expense_id')::uuid) = 575 and t_bal(t_id('b'), 'other_income') = -2500
    and t_bal(t_id('b'), 'suspense') = -(50000 + 50000 + 9900), concat_ws(' / ', nocat, undo, e::text));
  perform fn_expense_cancel((e->>'expense_id')::uuid, 'ليست رسومًا');
  perform fn_bank_unmatch(t_id('m5'), 'ليست إيرادًا');
  perform t_record('MT07 cancelling the expense made from a movement, or undoing the income, lets the movement wait again, in suspense',
    (t_mv(t_id('m4'))).status = 'pending' and (t_mv(t_id('m5'))).status = 'pending' and t_bal(t_id('b'), 'other_income') = 0
    and t_bal(t_id('b'), 'suspense') = -(50000 + 50000 + 9900 + 2500 - 575));
exception when others then perform t_record('MT06 the owner turns money out into an expense of its category (the bank''s message is its receipt) and money in into other income; the movements are used; an expense made so is undone by cancelling it', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- MT08 who matches
insert into branch_memberships(staff_id, branch_id) select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000008']::uuid[]) s
  where not exists (select 1 from branch_memberships where staff_id = s and branch_id = t_id('b'));
select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
set role authenticated;
select t_record('MT08 finance and the manager read the movements but match, undo or convert nothing',
  t_fails(format('select fn_bank_match(%L, %L, %L, null)', t_id('m2'), 'voucher', t_id('v2')), 'FORBIDDEN%') = 'ok'
  and t_fails(format('select fn_bank_candidates(%L)', t_id('m2')), 'FORBIDDEN%') = 'ok'
  and t_fails(format('select fn_bank_convert(%L, %L::jsonb)', t_id('m2'), '{"description":"x"}'), 'FORBIDDEN%') = 'ok'
  and jsonb_array_length(fn_bank_movements(t_id('b'), t_today(t_id('b')) - 1, t_today(t_id('b')))) >= 5);
reset role;
select t_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
select t_record('MT08b the manager does not match either', t_fails(format('select fn_bank_unmatch(%L, %L)', t_id('m2'), 'x'), 'FORBIDDEN%') = 'ok');
reset role;
select t_record('MT09 the books still balance after every match, difference, undo and conversion (the trial balance has no difference)',
  t_count('select count(*) from (select entry_id from journal_lines group by entry_id having sum(debit_halalas) <> sum(credit_halalas)) x') = 0);
select t_record('MT10 the matching''s log lines read in Arabic', fn_audit_action_label('bank_movement.matched') = 'مطابقة حركة بنكية'
  and fn_audit_action_label('bank_movement.converted') = 'تحويل حركة بنكية إلى سند');

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),200) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTING A8 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 11 then raise exception 'ACCOUNTING A8 TESTS INCOMPLETE: % of 11 checks ran', (select count(*) from test_results); end if;
end $$;
