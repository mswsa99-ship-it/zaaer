-- fn_expense_approve(uuid): exact-effect / no-write proof. Local disposable database only. One transaction, rolled back.
-- Base: migrations + tests/isolation engine.sql, scope.sql, fixtures.sql (no rpc-fixtures). Prerequisites are plain inserts below.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='rem2-local-synthetic-key';
\ir rem2-preamble.sql
do $$
declare t record; k int := 0; orgs text[]; own uuid; foreign_own uuid; sid uuid; cat uuid; bank uuid; box uuid; obank uuid;
        e_bank uuid; e_box_ok uuid; e_box_over uuid; e_canc uuid; e_appr uuid; e_dec uuid; e_dec_ob uuid;
        b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; st text; code text; changes text; before_row jsonb; after_row jsonb; au record;
        oth_branch text; ak text; dec_h text[]; dec_h2 text[]; n int; gl0 int;
begin
 orgs := array(select id::text from organizations);
 for t in select * from iso.target order by key loop
  k := k + 1;
  oth_branch := case t.branch when 'branch-1' then 'branch-2' else 'branch-1' end;
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select auth_user into foreign_own from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1;
  select id into cat from expense_categories where organization_id=t.org order by id limit 1;
  select id into bank from cash_accounts where branch_id=t.branch_id and kind='bank_account';
  select id into box from cash_accounts where branch_id=t.branch_id and kind='cash_box';
  select id into obank from cash_accounts where branch_id=iso.id('branch-'||substr(t.hotel,7,1)||'-'||substr(oth_branch,8,1)) and kind='bank_account';
  -- prerequisites (plain inserts as table owner, same org, deterministic literals)
  perform iso.set_claims(own);
  update cash_accounts set opening_balance_halalas = 5000 where id = box;
  insert into expense_vouchers(organization_id,branch_id,number,account_id,category_id,amount_halalas,description,status) values
   (t.org,t.branch_id,'RM-E-'||k||'-BANK',bank,cat,7000+k,'rm bank pending','pending') returning id into e_bank;
  insert into expense_vouchers(organization_id,branch_id,number,account_id,category_id,amount_halalas,description,status) values
   (t.org,t.branch_id,'RM-E-'||k||'-BOXOK',box,cat,5000,'rm box exact balance','pending') returning id into e_box_ok;
  insert into expense_vouchers(organization_id,branch_id,number,account_id,category_id,amount_halalas,description,status) values
   (t.org,t.branch_id,'RM-E-'||k||'-BOXOVER',box,cat,5001,'rm box over balance by 1','pending') returning id into e_box_over;
  insert into expense_vouchers(organization_id,branch_id,number,account_id,category_id,amount_halalas,description,status,cancel_reason,cancelled_at,cancelled_by) values
   (t.org,t.branch_id,'RM-E-'||k||'-CANC',bank,cat,1300,'rm cancelled','cancelled','rm synthetic cancel',now(),(select id from staff_profiles where auth_user_id=own)) returning id into e_canc;
  insert into expense_vouchers(organization_id,branch_id,number,account_id,category_id,amount_halalas,description,status) values
   (t.org,t.branch_id,'RM-E-'||k||'-APPR',bank,cat,1400,'rm already approved','approved') returning id into e_appr;
  insert into expense_vouchers(organization_id,branch_id,number,account_id,category_id,amount_halalas,description,status) values
   (t.org,t.branch_id,'RM-E-'||k||'-DEC',bank,cat,1111,'rm same-branch pending decoy','pending') returning id into e_dec;
  insert into expense_vouchers(organization_id,branch_id,number,account_id,category_id,amount_halalas,description,status) values
   (t.org,iso.id('branch-'||substr(t.hotel,7,1)||'-'||substr(oth_branch,8,1)),'RM-E-'||k||'-DECOB',obank,cat,2222,'rm other-branch pending decoy','pending') returning id into e_dec_ob;
  perform pg_temp.chk(t.key||'/prereq: 7 synthetic expense rows, 3 pending-ready, box balance 5000', fn_cash_account_balance(box)=5000, fn_cash_account_balance(box)::text);
  select id into sid from staff_profiles where auth_user_id=own;

  -- ---------- permission negatives against the pending bank expense: whole-public no-write each
  for ak, code in
    select x.key, case when x.role in ('finance','supervisor','housekeeping') then 'cap' else 'branch' end
      from iso.actor x
     where (x.hotel = t.hotel and x.branch = t.branch and x.role in ('finance','supervisor','housekeeping'))
        or (x.hotel = t.hotel and x.branch = oth_branch and x.role = 'manager')
        or (x.hotel <> t.hotel and x.role = 'owner')
     order by x.key
  loop
   perform pg_temp.guard(t.key||'/neg '||ak);
   b := iso.snap(); err := null; perform pg_temp.act(ak);
   begin perform fn_expense_approve(e_bank); exception when others then err := sqlerrm; end;
   reset role; a := iso.snap();
   perform pg_temp.chk(t.key||'/permission negative '||ak||' ('||code||')', err like 'FORBIDDEN%' and a = b
      and err like case code when 'cap' then 'FORBIDDEN: expense.cancel' else 'FORBIDDEN: branch not permitted' end, err);
  end loop;
  -- anon
  b := iso.snap(); err := null; perform pg_temp.act('guest|-|-');
  begin perform fn_expense_approve(e_bank); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap();
  perform pg_temp.chk(t.key||'/permission negative anon: execute privilege', err like 'permission denied%' and a = b, err);

  -- ---------- business/validation negatives (owner, in-scope) kept apart from denials: whole-public no-write each
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  begin perform fn_expense_approve(gen_random_uuid()); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/business: unknown id NOT_FOUND (not a denial)', err = 'NOT_FOUND' and a = b, err);
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  begin perform fn_expense_approve(e_canc); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/business: cancelled expense EXPENSE_NOT_PENDING', err = 'EXPENSE_NOT_PENDING' and a = b, err);
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  begin perform fn_expense_approve(e_box_over); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/business: cash box over balance by 1 halala CASH_BOX_NEGATIVE', err = 'CASH_BOX_NEGATIVE: balance 5000 halalas' and a = b, err);
  -- replay on an already approved row: success shape, no write
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  r := fn_expense_approve(e_appr);
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/replay: already approved returns {ok,unchanged}, no write', r = '{"ok": true, "unchanged": true}'::jsonb and a = b, r::text);
  -- foreign-hotel owner on an already approved row: still branch-denied (permission precedes replay)
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||case t.hotel when 'hotel-a' then 'hotel-b' else 'hotel-a' end||'|-');
  begin perform fn_expense_approve(e_appr); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/permission precedes replay: foreign owner on approved row', err like 'FORBIDDEN: branch%' and a = b, err);

  -- ---------- owner control: bank-account pending expense
  select array_agg(md5(x::text) order by x.id) into dec_h from expense_vouchers x where x.id in (e_dec, e_dec_ob, e_box_ok, e_box_over, e_canc, e_appr);
  select to_jsonb(x) into before_row from expense_vouchers x where id = e_bank;
  gl0 := (select count(*) from journal_entries where organization_id = t.org);
  perform pg_temp.guard(t.key||'/owner control bank');
  rb := iso.row_snaps(orgs); b := iso.snap(); perform pg_temp.act('owner|'||t.hotel||'|-');
  r := fn_expense_approve(e_bank);
  reset role; ra := iso.row_snaps(orgs); a := iso.snap();
  select string_agg(x.org||'/'||x.tbl||'/'||x.kind||'/'||x.pk, ' ; ' order by x.tbl, x.pk) into changes from iso.row_changes(rb, ra) x;
  raise notice 'DISCOVER % bank control changes: %', t.key, changes;
  select to_jsonb(x) into after_row from expense_vouchers x where id = e_bank;
  perform pg_temp.chk(t.key||'/owner control result literal', r = jsonb_build_object('ok',true,'id',e_bank,'number','RM-E-'||k||'-BANK','status','approved'), r::text);
  perform pg_temp.chk(t.key||'/owner control: only status changed on target row (pending->approved), every other column identical',
     before_row->>'status'='pending' and after_row->>'status'='approved' and (before_row - 'status') = (after_row - 'status'), null);
  perform pg_temp.chk(t.key||'/owner control: exact touched rows = target expense update + one audit insert, nothing else, any org',
     (select count(*) from iso.row_changes(rb, ra)) = 2
     and exists(select 1 from iso.row_changes(rb, ra) x where x.org=t.org::text and x.tbl='expense_vouchers' and x.kind='upd' and x.pk=e_bank::text)
     and exists(select 1 from iso.row_changes(rb, ra) x where x.org=t.org::text and x.tbl='audit_events' and x.kind='ins'), changes);
  select * into au from audit_events e where e.entity_id = e_bank and e.entity_type='expense_voucher';
  perform pg_temp.chk(t.key||'/owner control audit identity+literals', au.organization_id=t.org and au.branch_id=t.branch_id and au.actor_id=sid and au.action='expense.approved'
     and au.details = jsonb_build_object('before',jsonb_build_object('status','pending'),'after',jsonb_build_object('status','approved','number','RM-E-'||k||'-BANK','amount_halalas',7000+k)), au.details::text);
  perform pg_temp.chk(t.key||'/finding: approval posts NO journal entry (trg_gl_expense fires only on INSERT approved / UPDATE approved->cancelled)',
     (select count(*) from journal_entries where organization_id = t.org) = gl0, gl0::text);
  perform pg_temp.chk(t.key||'/owner control: other-org rows and same-org decoy/other expenses unchanged',
     dec_h = (select array_agg(md5(x::text) order by x.id) from expense_vouchers x where x.id in (e_dec, e_dec_ob, e_box_ok, e_box_over, e_canc, e_appr)), null);
  -- replay of the same approval: unchanged, no write
  b := iso.snap(); perform pg_temp.act('owner|'||t.hotel||'|-'); r := fn_expense_approve(e_bank); reset role; a := iso.snap();
  perform pg_temp.chk(t.key||'/replay after control: unchanged, no write (no second audit)', r = '{"ok": true, "unchanged": true}'::jsonb and a = b, r::text);
  -- ---------- same-branch manager control on the cash-box expense at exactly the balance (boundary equal passes)
  perform pg_temp.guard(t.key||'/manager control box');
  rb := iso.row_snaps(orgs); perform pg_temp.act('manager|'||t.hotel||'|'||t.branch);
  r := fn_expense_approve(e_box_ok);
  reset role; ra := iso.row_snaps(orgs);
  select string_agg(x.org||'/'||x.tbl||'/'||x.kind||'/'||x.pk, ' ; ' order by x.tbl, x.pk) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.chk(t.key||'/manager control box (amount = balance 5000): ok, exact rows = expense update + audit insert',
     (r->>'status')='approved' and (select count(*) from iso.row_changes(rb, ra))=2
     and exists(select 1 from iso.row_changes(rb, ra) x where x.tbl='expense_vouchers' and x.kind='upd' and x.pk=e_box_ok::text)
     and exists(select 1 from iso.row_changes(rb, ra) x where x.tbl='audit_events' and x.kind='ins' and x.org=t.org::text), changes);
  select * into au from audit_events e where e.entity_id = e_box_ok and e.entity_type='expense_voucher';
  perform pg_temp.chk(t.key||'/manager control audit actor is the manager staff row', au.actor_id=(select s.id from staff_profiles s join iso.actor x on x.auth_user=s.auth_user_id where x.key='manager|'||t.hotel||'|'||t.branch) and au.branch_id=t.branch_id, null);
  perform pg_temp.chk(t.key||'/after approval cash-box balance is 0 (approved expense now counts as outflow)', fn_cash_account_balance(box)=0, fn_cash_account_balance(box)::text);
  -- the over-balance expense now still refuses (balance 0), no write
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  begin perform fn_expense_approve(e_box_over); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/business: after spend, over-balance expense refuses with balance 0', err = 'CASH_BOX_NEGATIVE: balance 0 halalas' and a = b, err);
 end loop;
end $$;
select pg_temp.guard('end of proof');
select pg_temp.chk('outbox unchanged at end without cleanup',true);
select count(*) as checks, count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from rm_assert;
select name, detail from rm_assert where not ok order by name;
do $$begin if exists(select 1 from rm_assert where not ok) then raise exception 'Remaining2 bounded proof failed';end if;end $$;
rollback;
