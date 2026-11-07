-- =====================================================================
-- Accounting stage, task A1 (AC*; migration 0062): each branch has one cash box and one bank account in use; the bank
-- account is known by the start and end of its number, which belong to one branch only and agree with the branch's
-- IBAN; and a voucher, a terminal settlement or a platform payout on another branch's account is refused by the
-- database itself, whatever path writes it.
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
create or replace function t_ver(p_id uuid) returns int language sql security definer as $$ select version from cash_accounts where id = p_id $$;
create or replace function t_acc(p_branch uuid, p_kind text) returns cash_accounts language sql security definer as $$
  select * from cash_accounts where branch_id = p_branch and kind = p_kind and archived_at is null $$;
-- a valid Saudi IBAN for a 20-character BBAN (ISO 13616 check digits: S=28, A=10)
create or replace function t_iban(p_bban text) returns text language sql immutable as $$
  select 'SA' || lpad((98 - ((p_bban || '281000')::numeric % 97))::int::text, 2, '0') || p_bban $$;

-- ---------------------------------------------------------------- AC01 one of each, in every branch
select t_record('AC01 every branch has exactly one cash box and one bank account in use',
  not exists (select 1 from branches b where (select count(*) from cash_accounts a where a.branch_id = b.id and a.kind = 'cash_box' and a.archived_at is null) <> 1
                                         or (select count(*) from cash_accounts a where a.branch_id = b.id and a.kind = 'bank_account' and a.archived_at is null) <> 1)
  and exists (select 1 from pg_indexes where indexname = 'uniq_cash_account_one_per_kind'));

-- ---------------------------------------------------------------- AC02–AC06 as the owner
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع الحسابات","name_en":"Accounts branch","tax_rate_bp":0}'); b := (r->>'id')::uuid;
  insert into ids values ('b', b), ('box_b', (t_acc(b, 'cash_box')).id), ('bank_b', (t_acc(b, 'bank_account')).id),
                         ('bank10', (t_acc('00000000-0000-0000-0000-000000000010', 'bank_account')).id),
                         ('box10', (t_acc('00000000-0000-0000-0000-000000000010', 'cash_box')).id);
end $$;
do $$ declare r1 text; r2 text; begin
  r1 := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'kind','cash_box', 'name','صندوق ثانٍ')), 'ACCOUNT_EXISTS%');
  r2 := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'kind','bank_account', 'name','حساب ثانٍ')), 'ACCOUNT_EXISTS%');
  perform t_record('AC02 a second cash box or bank account in use in the same branch is refused', r1 = 'ok' and r2 = 'ok', r1 || ' / ' || r2);
end $$;
do $$ declare r jsonb; bad1 text; bad2 text; bad3 text; a cash_accounts; begin
  bad1 := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('id', t_id('bank_b'), 'name','حساب الفرع', 'version', t_ver(t_id('bank_b')), 'account_prefix','3a6', 'account_suffix','192')), 'VALIDATION: account_prefix%');
  bad2 := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('id', t_id('bank_b'), 'name','حساب الفرع', 'version', t_ver(t_id('bank_b')), 'account_prefix','346')), 'VALIDATION: account_rule%');
  bad3 := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('id', t_id('bank_b'), 'name','حساب الفرع', 'version', t_ver(t_id('bank_b')), 'account_prefix','3', 'account_suffix','1234567')), 'VALIDATION: account_%');
  -- Arabic digits are taken as their Latin form
  r := fn_admin_upsert_cash_account(jsonb_build_object('id', t_id('bank_b'), 'name','حساب الفرع', 'version', t_ver(t_id('bank_b')), 'bank_name','مصرف الاختبار', 'account_prefix','٣٤٦', 'account_suffix','1192'));
  select * into a from cash_accounts where id = t_id('bank_b');
  perform t_record('AC03 the bank account keeps the start and end of its number (2–6 digits each, both or neither), and its last four follow the end',
    bad1 = 'ok' and bad2 = 'ok' and bad3 = 'ok' and a.account_prefix = '346' and a.account_suffix = '1192' and a.account_last4 = '1192' and a.is_default and a.bank_name = 'مصرف الاختبار',
    concat_ws(' / ', bad1, bad2, bad3, a.account_prefix, a.account_suffix, a.account_last4));
exception when others then perform t_record('AC03 the bank account keeps the start and end of its number (2–6 digits each, both or neither), and its last four follow the end', false, sqlerrm); end $$;
do $$ declare dup text; begin
  dup := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('id', t_id('bank10'), 'name', (select name from cash_accounts where id = t_id('bank10')), 'version', t_ver(t_id('bank10')), 'account_prefix','346', 'account_suffix','1192')), 'DUPLICATE_ACCOUNT_RULE%');
  perform t_record('AC04 two branches cannot share the same start and end of an account number', dup = 'ok', dup);
end $$;
do $$ declare r jsonb; ok_iban text := t_iban('80000000000000001192'); bad_iban text := t_iban('80000000000000005555'); g1 text; g2 text; a1 text; begin
  -- the branch's IBAN must end with the account's last digits …
  g1 := t_fails(format('select fn_admin_set_branch_guide(%L::jsonb)', jsonb_build_object('branch_id', t_id('b'), 'bank_name','مصرف الاختبار', 'bank_beneficiary','فايف اورز', 'bank_iban', bad_iban)), 'VALIDATION: iban_suffix%');
  r := fn_admin_set_branch_guide(jsonb_build_object('branch_id', t_id('b'), 'bank_name','مصرف الاختبار', 'bank_beneficiary','فايف اورز', 'bank_iban', ok_iban));
  -- … and an account end that disagrees with the saved IBAN is refused in turn
  a1 := t_fails(format('select fn_admin_upsert_cash_account(%L::jsonb)', jsonb_build_object('id', t_id('bank_b'), 'name','حساب الفرع', 'version', t_ver(t_id('bank_b')), 'account_prefix','346', 'account_suffix','5555')), 'VALIDATION: iban_suffix%');
  g2 := (select bank_iban from branches where id = t_id('b'));
  perform t_record('AC05 the IBAN in the branch''s bank details and the end of the bank account''s number must agree, whichever is saved second',
    g1 = 'ok' and a1 = 'ok' and g2 = ok_iban and g2 like '%1192', concat_ws(' / ', g1, a1, g2));
exception when others then perform t_record('AC05 the IBAN in the branch''s bank details and the end of the bank account''s number must agree, whichever is saved second', false, sqlerrm); end $$;
do $$ declare r jsonb; back text; n jsonb; begin
  r := fn_admin_archive_cash_account(t_id('box_b'), true, 'أُغلق الصندوق');
  n := fn_admin_upsert_cash_account(jsonb_build_object('branch_id', t_id('b'), 'kind','cash_box', 'name','صندوق الاستقبال الجديد'));
  back := t_fails(format('select fn_admin_archive_cash_account(%L, false, %L)', t_id('box_b'), 'إعادة'), 'ACCOUNT_EXISTS%');
  perform t_record('AC06 a closed box is replaced: archived with its reason, the new one is the default, and the old one cannot return while the new one is in use',
    back = 'ok' and (t_acc(t_id('b'), 'cash_box')).id = (n->>'id')::uuid and (t_acc(t_id('b'), 'cash_box')).is_default, back);
exception when others then perform t_record('AC06 a closed box is replaced: archived with its reason, the new one is the default, and the old one cannot return while the new one is in use', false, sqlerrm); end $$;
reset role;

-- ---------------------------------------------------------------- AC07–AC08 the database refuses another branch's account on every path
do $$ declare r1 text; r2 text; r3 text; v uuid; begin
  select id into v from financial_vouchers where account_id is not null and branch_id = '00000000-0000-0000-0000-000000000010' limit 1;
  r1 := t_fails(format('update financial_vouchers set account_id = %L where id = %L', t_id('bank_b'), v), 'BRANCH_MISMATCH: account%');
  r2 := t_fails(format('insert into pos_settlements(organization_id, branch_id, account_id, business_date, terminal_total_halalas, system_total_halalas, difference_halalas, status)
                        select organization_id, %L, %L, current_date - 300, 0, 0, 0, ''matched'' from branches where id = %L',
                       '00000000-0000-0000-0000-000000000010', t_id('bank_b'), '00000000-0000-0000-0000-000000000010'), 'BRANCH_MISMATCH: account%');
  r3 := t_fails(format('insert into platform_payouts(organization_id, branch_id, source_id, account_id, expected_halalas, received_halalas, difference_halalas, voucher_count, received_on, reference)
                        select b.organization_id, b.id, (select id from booking_sources where organization_id = b.organization_id limit 1), %L, 0, 0, 0, 0, current_date, ''AC07''
                        from branches b where b.id = %L', t_id('bank_b'), '00000000-0000-0000-0000-000000000010'), 'BRANCH_MISMATCH: account%');
  perform t_record('AC07 written directly (not through the screens), a voucher, a terminal settlement and a platform payout on another branch''s account are refused',
    v is not null and r1 = 'ok' and r2 = 'ok' and r3 = 'ok', concat_ws(' / ', v::text, r1, r2, r3));
end $$;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r1 text; begin
  r1 := t_fails(format('select fn_pos_settle(%L::jsonb)', jsonb_build_object('branch_id','00000000-0000-0000-0000-000000000010', 'account_id', t_id('bank_b'), 'business_date', current_date - 1, 'terminal_total_halalas', 0)), 'BRANCH_MISMATCH: account%');
  perform t_record('AC08 through the screens too: the terminal settlement of one branch cannot use the bank account of another', r1 = 'ok', r1);
end $$;
reset role;

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),160) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTING A1 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 8 then raise exception 'ACCOUNTING A1 TESTS INCOMPLETE: % of 8 checks ran', (select count(*) from test_results); end if;
end $$;
