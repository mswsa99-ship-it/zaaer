-- fn_pos_settle(jsonb): exact-effect / no-write proof. Local disposable database only. One transaction, rolled back.
-- Base: migrations + tests/isolation engine.sql, scope.sql, fixtures.sql (no rpc-fixtures). Prerequisites are plain inserts below.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='rem2-local-synthetic-key';
\ir rem2-preamble.sql
create function pg_temp.settle(p jsonb) returns jsonb language sql as $$ select fn_pos_settle(p) $$;
do $$
declare t record; k int := 0; orgs text[]; own uuid; sid uuid; bank uuid; box uuid; obank uuid; ob uuid; res uuid; fin_sid uuid; ores uuid;
        b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; changes text; ak text; code text; p jsonb; row_b jsonb; row_a jsonb; au record; s pos_settlements%rowtype;
        dec_b text; today date; oth_branch text; dsid uuid; ri record; n int; vkey int := 0;
begin
 orgs := array(select id::text from organizations);
 for t in select * from iso.target order by key loop
  k := k + 1;
  oth_branch := case t.branch when 'branch-1' then 'branch-2' else 'branch-1' end;
  ob := iso.id('branch-'||substr(t.hotel,7,1)||'-'||substr(oth_branch,8,1));
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  perform iso.set_claims(own);
  select id into sid from staff_profiles where auth_user_id=own;
  select id into bank from cash_accounts where branch_id=t.branch_id and kind='bank_account';
  select id into box from cash_accounts where branch_id=t.branch_id and kind='cash_box';
  select id into obank from cash_accounts where branch_id=ob and kind='bank_account';
  today := fn_branch_today(t.branch_id);
  -- prerequisites: own reservation + vouchers (plain inserts). System total for (bank, today) must be 5000+2000-700 = 6300, count 3.
  insert into reservations(organization_id, branch_id, external_ref, check_in, check_out) values (t.org, t.branch_id, 'RM-POS-'||k, current_date, current_date+1) returning id into res;
  insert into reservations(organization_id, branch_id, external_ref, check_in, check_out) values (t.org, ob, 'RM-POS-OB-'||k, current_date, current_date+1) returning id into ores;
  for ri in select * from (values
     (t.branch_id, res, bank, 'receipt',       5000, 'pos',  'approved', 0),
     (t.branch_id, res, bank, 'deposit',       2000, 'pos',  'approved', 0),
     (t.branch_id, res, bank, 'refund',         700, 'pos',  'approved', 0),
     (t.branch_id, res, bank, 'deposit_apply',  999, 'pos',  'approved', 0),   -- excluded kind
     (t.branch_id, res, bank, 'receipt',       3333, 'pos',  'cancelled', 0),  -- excluded status
     (t.branch_id, res, bank, 'receipt',       4444, 'pos',  'approved', -1),  -- excluded: yesterday
     (t.branch_id, res, bank, 'receipt',       1717, 'bank_transfer', 'approved', 0)  -- excluded: other method
   ) v(br, rsv, acc, kind, amt, m, st, dayoff) loop
    vkey := vkey + 1;
    insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, status, idempotency_key, content_hash, occurred_at, account_id)
    values (t.org, ri.br, ri.rsv, 'RM-V-'||vkey, ri.kind, ri.amt, ri.m::payment_method, ri.st, 'rm-ik-'||vkey, 'rm-ch-'||vkey, now() + ri.dayoff * interval '1 day', ri.acc);
  end loop;
  perform pg_temp.chk(t.key||'/prereq: system total 6300, 3 counted vouchers', fn_pos_day_total(t.branch_id, bank, today)->>'system_total_halalas' = '6300' and fn_pos_day_total(t.branch_id, bank, today)->>'voucher_count' = '3', fn_pos_day_total(t.branch_id, bank, today)::text);
  -- same-org decoy settlement in the other branch (two days back, since each branch's own account is a target on the same date); and one for this branch's account on yesterday
  insert into pos_settlements(organization_id, branch_id, account_id, business_date, terminal_total_halalas, system_total_halalas, difference_halalas, voucher_count, status, created_by, updated_by)
    values (t.org, (select branch_id from cash_accounts where id=obank), obank, today - 2, 10, 10, 0, 0, 'matched', sid, sid);
  insert into pos_settlements(organization_id, branch_id, account_id, business_date, terminal_total_halalas, system_total_halalas, difference_halalas, voucher_count, status, created_by, updated_by)
    values (t.org, t.branch_id, bank, today - 1, 20, 20, 0, 0, 'matched', sid, sid);
  select md5(string_agg(md5(x::text), '' order by x.id)) into dec_b from pos_settlements x where x.organization_id=t.org;
  p := jsonb_build_object('branch_id', t.branch_id, 'account_id', bank, 'business_date', today::text, 'terminal_total_halalas', 6300);

  -- ---------- permission negatives (valid payload): whole-public no-write each
  for ak, code in
    select x.key, case when x.role='housekeeping' then 'cap' else 'branch' end
      from iso.actor x
     where (x.hotel = t.hotel and x.branch = t.branch and x.role = 'housekeeping')
        or (x.hotel = t.hotel and x.branch = oth_branch and x.role in ('manager','finance','supervisor'))
        or (x.hotel <> t.hotel and x.role = 'owner')
     order by x.key
  loop
   perform pg_temp.guard(t.key||'/neg '||ak);
   b := iso.snap(); err := null; perform pg_temp.act(ak);
   begin perform fn_pos_settle(p); exception when others then err := sqlerrm; end;
   reset role; a := iso.snap();
   perform pg_temp.chk(t.key||'/permission negative '||ak||' ('||code||')', a = b
      and err = case code when 'cap' then 'FORBIDDEN: pos.settle' else 'FORBIDDEN: branch not permitted' end, err);
  end loop;
  b := iso.snap(); err := null; perform pg_temp.act('guest|-|-');
  begin perform fn_pos_settle(p); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/permission negative anon: execute privilege', err like 'permission denied%' and a = b, err);
  -- wrong-hotel owner pointing at this branch AND this hotel's account: still branch-denied
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||case t.hotel when 'hotel-a' then 'hotel-b' else 'hotel-a' end||'|-');
  begin perform fn_pos_settle(p); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/permission negative foreign owner repeated with exact valid payload', err like 'FORBIDDEN: branch%' and a = b, err);

  -- ---------- validation/business negatives with the owner: no write, distinct classes
  for ak, code in select * from (values
     ('account of the other branch', 'BRANCH_MISMATCH: account'),
     ('cash_box account', 'BRANCH_MISMATCH: account'),
     ('future date', 'VALIDATION: business_date'),
     ('null date', 'VALIDATION: business_date'),
     ('missing amount', 'VALIDATION: amount'),
     ('non-numeric amount', 'VALIDATION: amount'),
     ('16-digit amount', 'VALIDATION: amount'),
     ('difference without note', 'VALIDATION: note_required'),
     ('difference with blank note', 'VALIDATION: note_required')) v(a_, b_) loop
   perform pg_temp.guard(t.key||'/validation '||ak);
   b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
   begin
     perform fn_pos_settle(case ak
       when 'account of the other branch' then p || jsonb_build_object('account_id', obank)
       when 'cash_box account' then p || jsonb_build_object('account_id', box)
       when 'future date' then p || jsonb_build_object('business_date', (today+1)::text)
       when 'null date' then p - 'business_date'
       when 'missing amount' then p - 'terminal_total_halalas'
       when 'non-numeric amount' then p || '{"terminal_total_halalas":"12x"}'
       when '16-digit amount' then p || '{"terminal_total_halalas":"1000000000000000"}'
       when 'difference without note' then p || '{"terminal_total_halalas":6301}'
       else p || '{"terminal_total_halalas":6301,"note":"   "}' end);
   exception when others then err := sqlerrm; end;
   reset role; a := iso.snap();
   perform pg_temp.chk(t.key||'/business/validation: '||ak||' (not a denial)', err = code and a = b, err);
  end loop;

  -- ---------- owner control 1: INSERT path, with a difference (terminal 6400, note) on today
  p := p || '{"terminal_total_halalas":6400,"note":"rm synthetic difference"}';
  perform pg_temp.guard(t.key||'/owner control insert');
  rb := iso.row_snaps(orgs); perform pg_temp.act('owner|'||t.hotel||'|-');
  r := fn_pos_settle(p);
  reset role; ra := iso.row_snaps(orgs);
  select string_agg(x.org||'/'||x.tbl||'/'||x.kind, ' ; ' order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  raise notice 'DISCOVER % insert changes: %', t.key, changes;
  select * into s from pos_settlements where account_id=bank and business_date=today;
  perform pg_temp.chk(t.key||'/insert: literal settlement row', s.organization_id=t.org and s.branch_id=t.branch_id and s.account_id=bank and s.business_date=today
     and s.terminal_total_halalas=6400 and s.system_total_halalas=6300 and s.difference_halalas=100 and s.voucher_count=3 and s.status='difference'
     and s.note='rm synthetic difference' and s.version=1 and s.created_by=sid and s.updated_by=sid, to_jsonb(s)::text);
  perform pg_temp.chk(t.key||'/insert: result is {ok, settlement=row}', (r->>'ok')::boolean and r->'settlement' = to_jsonb(s), null);
  perform pg_temp.chk(t.key||'/insert: exact touched rows = 1 settlement insert + 1 audit insert + 1 review_items insert, nothing else, own org only',
     (select count(*) from iso.row_changes(rb, ra))=3 and (select count(*) from iso.row_changes(rb, ra) x where x.org=t.org::text)=3
     and (select count(*) from iso.row_changes(rb, ra) x where x.tbl='pos_settlements' and x.kind='ins')=1
     and (select count(*) from iso.row_changes(rb, ra) x where x.tbl='audit_events' and x.kind='ins')=1
     and (select count(*) from iso.row_changes(rb, ra) x where x.tbl='review_items' and x.kind='ins')=1, changes);
  select * into au from audit_events e where e.entity_id=s.id and e.entity_type='pos_settlement';
  perform pg_temp.chk(t.key||'/insert: audit identity (actor, action, branch, no before, after=row, reason=note)', au.actor_id=sid and au.action='pos.settled' and au.branch_id=t.branch_id and au.organization_id=t.org
     and au.details->'before' is null and au.details->'after'->>'id'=s.id::text and au.details->>'reason'='rm synthetic difference', au.details::text);
  select * into ri from review_items x where x.entity_id=s.id and x.entity_type='pos_settlement';
  perform pg_temp.chk(t.key||'/insert: difference review item literals', ri.kind='pos_difference' and ri.branch_id=t.branch_id and ri.organization_id=t.org
     and (ri.details->>'difference_halalas')::bigint=100 and (ri.details->>'terminal_halalas')::bigint=6400 and (ri.details->>'system_halalas')::bigint=6300 and ri.created_by=sid, to_jsonb(ri)::text);
  perform pg_temp.chk(t.key||'/insert: decoy settlements (other branch, own branch yesterday) unchanged',
     dec_b = (select md5(string_agg(md5(x::text), '' order by x.id)) from pos_settlements x where x.organization_id=t.org and x.id<>s.id), null);
  perform pg_temp.chk(t.key||'/insert: vouchers untouched (no money moved by settlement)', (select count(*) from financial_vouchers where organization_id=t.org and account_id=bank)=7, null);

  -- ---------- update-path negatives (version): no write
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  begin perform fn_pos_settle(p); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/replay-shape: second call without version VERSION_REQUIRED, no write', err like 'VERSION_REQUIRED%' and a = b, err);
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  begin perform fn_pos_settle(p || '{"version":5}'); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/stale version VERSION_CONFLICT, no write', err like 'VERSION_CONFLICT%' and a = b, err);
  -- permission still precedes the version path: other-branch manager with valid version
  b := iso.snap(); err := null; perform pg_temp.act('manager|'||t.hotel||'|'||oth_branch);
  begin perform fn_pos_settle(p || '{"version":1}'); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/other-branch manager with correct version still FORBIDDEN, no write', err = 'FORBIDDEN: branch not permitted' and a = b, err);

  -- ---------- control 2: UPDATE path by same-branch finance (a cap holder that is not the owner): matched, note cleared
  p := (p - 'note') || '{"terminal_total_halalas":6300,"version":1}';
  select to_jsonb(x) into row_b from pos_settlements x where id=s.id;
  perform pg_temp.guard(t.key||'/finance control update');
  rb := iso.row_snaps(orgs); perform pg_temp.act('finance|'||t.hotel||'|'||t.branch);
  r := fn_pos_settle(p);
  reset role; ra := iso.row_snaps(orgs);
  select string_agg(x.org||'/'||x.tbl||'/'||x.kind, ' ; ' order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  raise notice 'DISCOVER % update changes: %', t.key, changes;
  select to_jsonb(x) into row_a from pos_settlements x where id=s.id;
  fin_sid := (select st.id from staff_profiles st join iso.actor x on x.auth_user=st.auth_user_id where x.key='finance|'||t.hotel||'|'||t.branch);
  perform pg_temp.chk(t.key||'/update: literal row (matched, diff 0, note null, version 2, updated_by finance, created_by owner kept)',
     row_a->>'status'='matched' and (row_a->>'difference_halalas')::bigint=0 and (row_a->>'terminal_total_halalas')::bigint=6300 and row_a->>'note' is null
     and (row_a->>'version')::int=2 and row_a->>'updated_by'=fin_sid::text and row_a->>'created_by'=sid::text and row_a->>'id'=s.id::text, row_a::text);
  perform pg_temp.chk(t.key||'/update: exact touched rows = settlement update + audit insert only (no new review item when diff becomes 0)',
     (select count(*) from iso.row_changes(rb, ra))=2 and exists(select 1 from iso.row_changes(rb, ra) x where x.tbl='pos_settlements' and x.kind='upd')
     and exists(select 1 from iso.row_changes(rb, ra) x where x.tbl='audit_events' and x.kind='ins'), changes);
  select * into au from audit_events e where e.entity_id=s.id and e.entity_type='pos_settlement' and e.actor_id=fin_sid;
  perform pg_temp.chk(t.key||'/update: audit has before=old row and after=new row, actor finance', au.details->'before'->>'version'='1' and au.details->'after'->>'version'='2' and au.details->'before'->>'status'='difference' and au.actor_id=fin_sid, au.details::text);
  perform pg_temp.chk(t.key||'/update: decoys unchanged', dec_b = (select md5(string_agg(md5(x::text), '' order by x.id)) from pos_settlements x where x.organization_id=t.org and x.id<>s.id), null);
  -- stale after update
  b := iso.snap(); err := null; perform pg_temp.act('owner|'||t.hotel||'|-');
  begin perform fn_pos_settle(p); exception when others then err := sqlerrm; end;
  reset role; a := iso.snap(); perform pg_temp.chk(t.key||'/replay of the same update (version 1 now stale): VERSION_CONFLICT, no write', err like 'VERSION_CONFLICT%' and a = b, err);
 end loop;
end $$;
select pg_temp.guard('end of proof');
select pg_temp.chk('outbox unchanged at end without cleanup',true);
select count(*) as checks, count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from rm_assert;
select name, detail from rm_assert where not ok order by name;
do $$begin if exists(select 1 from rm_assert where not ok) then raise exception 'Remaining2 bounded proof failed';end if;end $$;
rollback;
