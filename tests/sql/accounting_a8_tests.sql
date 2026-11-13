-- =====================================================================
-- Accounting stage, task A8 (MT*; migration 0067): matching the bank's movements. A movement waits until the owner
-- matches it with the records that explain it (one transfer voucher, the card-terminal vouchers a deposit covers, an
-- expense, a platform payout) or turns it into a voucher (an expense, the bank's fees, other income); a movement is used
-- once and a record matched once; a total that differs needs a reason and is booked; undoing, or cancelling one of the
-- records, lets it wait again; a waiting movement is a reconciliation item, not an entry; the ledger of an account
-- ends where the journal stands.
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
create or replace function t_movement(p_branch uuid, p_dir text, p_kind text, p_amount bigint, p_ref text, p_assigned boolean default true, p_at timestamptz default now()) returns uuid
language plpgsql security definer as $$
declare m uuid; v uuid; org uuid := (select organization_id from branches where id = p_branch);
begin
  insert into bank_messages(organization_id, raw_body, content_hash, sms_text, status) values (org, 'رسالة اختبار ' || p_ref, md5(p_ref || clock_timestamp()::text), 'رسالة ' || p_ref, 'parsed') returning id into m;
  insert into bank_movements(organization_id, branch_id, cash_account_id, message_id, kind, direction, amount_halalas, occurred_at, reference, account_hint, dedupe_key)
  values (org, case when p_assigned then p_branch end, case when p_assigned then t_accid(p_branch, 'bank_account') end, m, p_kind, p_dir, p_amount, p_at, p_ref, '**999', 'msg:' || m)
  returning id into v;
  update bank_messages set movement_id = v where id = m;
  return v;
end $$;
create or replace function t_bal(p_branch uuid, p_key text) returns bigint language sql security definer as $$
  select coalesce(sum(l.debit_halalas - l.credit_halalas), 0)::bigint from journal_lines l join journal_entries e on e.id = l.entry_id join gl_accounts g on g.id = l.account_id
  where e.branch_id = p_branch and (g.system_key = p_key or (p_key = 'bank' and g.cash_account_id = t_accid(p_branch, 'bank_account'))) $$;
create or replace function t_pos_total(p_branch uuid) returns bigint language sql security definer as $$
  select (fn_pos_day_total(p_branch, t_accid(p_branch, 'bank_account'), fn_branch_today(p_branch))->>'system_total_halalas')::bigint $$;
create or replace function t_mv(p uuid) returns bank_movements language sql security definer as $$ select * from bank_movements where id = p $$;
-- the records a movement is matched with, as the screen sends them: t_tg('voucher', id [, 'voucher', id2 …])
create or replace function t_tg(variadic p text[]) returns jsonb language sql immutable as $$
  select jsonb_agg(jsonb_build_object('type', p[i], 'id', p[i + 1]) order by i) from generate_series(1, array_length(p, 1), 2) i $$;
create or replace function t_match_sql(p_movement uuid, p_targets jsonb, p_reason text default null) returns text language sql immutable as $$
  select format('select fn_bank_match(%L, %L::jsonb, %L)', p_movement, p_targets::text, p_reason) $$;

-- ---------------------------------------------------------------- a branch with a reservation paid by transfer and by card
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
  -- the day's terminal: two card payments and a card refund
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 20000, 'method','pos', 'reference','MT-POS-1', 'idempotency_key','mt-p1'));
  insert into ids values ('p1', (v->>'voucher_id')::uuid);
  v := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind','receipt', 'amount_halalas', 10000, 'method','pos', 'reference','MT-POS-2', 'idempotency_key','mt-p2'));
  insert into ids values ('p2', (v->>'voucher_id')::uuid);
  v := fn_refund(jsonb_build_object('reservation_id', res, 'kind','refund', 'amount_halalas', 3000, 'method','pos', 'reference','MT-POS-R', 'reason','رد جزء من بطاقة', 'idempotency_key','mt-pr'));
  insert into ids values ('pr', (v->>'voucher_id')::uuid);
  -- another branch the manager does not work in
  r := fn_admin_upsert_branch('{"name_ar":"فرع المطابقة الثاني","name_en":"Matching branch two","tax_rate_bp":0}');
  insert into ids values ('b2', (r->>'id')::uuid);
exception when others then perform t_record('MT00 the branch and its vouchers are set up', false, sqlerrm);
end $$;
reset role;
insert into ids select 'm1', t_movement(t_id('b'), 'in', 'transfer_in', 50000, 'MTREF1');
insert into ids select 'm2', t_movement(t_id('b'), 'in', 'transfer_in', 50000, 'MTREF2');
insert into ids select 'm3', t_movement(t_id('b'), 'in', 'transfer_in', 9900, 'MTREF3');
insert into ids select 'm4', t_movement(t_id('b'), 'out', 'fee', 575, 'MTREF4');
insert into ids select 'm5', t_movement(t_id('b'), 'in', 'other_in', 2500, 'MTREF5');
insert into ids select 'm6', t_movement(t_id('b'), 'out', 'pos_fee', 960, 'MTREF6');
insert into ids select 'mu', t_movement(t_id('b'), 'in', 'deposit', 7000, 'MTREFU', false);
insert into ids select 'mp', t_movement(t_id('b'), 'in', 'pos_settlement', 26460, 'MTREFP');
insert into ids select 'mq', t_movement(t_id('b'), 'in', 'pos_settlement', 20000, 'MTREFQ');
insert into ids select 'mx', t_movement(t_id('b2'), 'in', 'transfer_in', 1000, 'MTREFX');
insert into ids select 'mc', t_movement(t_id('b'), 'in', 'pos_settlement', 15000, 'MTREFC');
insert into ids select 'mo', t_movement(t_id('b'), 'out', 'transfer_out', 15000, 'MTREFO');
insert into ids select 'm7', t_movement(t_id('b2'), 'out', 'fee', 700, 'MTREF7', true, now() - interval '3 days');
-- a movement of a month the owner has locked
insert into ids select 'ml', t_movement(t_id('b'), 'in', 'other_in', 3000, 'MTREFL', true, now() - interval '62 days');
insert into accounting_periods(organization_id, month, locked, reason)
  select organization_id, date_trunc('month', fn_branch_date(t_id('b'), now() - interval '62 days'))::date, true, 'اختبار' from branches where id = t_id('b')
  on conflict (organization_id, month) do update set locked = true;

-- ---------------------------------------------------------------- MT01 a waiting movement is not an entry
select t_record('MT01 a waiting movement is a reconciliation item, not an entry: the bank account holds what the hotel recorded (no transfer counted twice), nothing goes to suspense',
  t_count('select count(*) from journal_entries where source_type = ''bank_movement''') = 0
  and t_bal(t_id('b'), 'bank') = 50000 + 10000 + 20000 + 10000 - 3000 and t_bal(t_id('b'), 'suspense') = 0,
  t_bal(t_id('b'), 'bank')::text);

-- ---------------------------------------------------------------- MT02–MT03 match, once
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare c jsonb; r jsonb; used text; again text; bad text; unas text; none text; kind text; begin
  c := fn_bank_candidates(t_id('m1'));
  r := fn_bank_match(t_id('m1'), t_tg('voucher', t_id('v1')::text), null);
  used := t_fails(t_match_sql(t_id('m2'), t_tg('voucher', t_id('v1')::text)), 'VALIDATION: target_used%');
  again := t_fails(t_match_sql(t_id('m1'), t_tg('voucher', t_id('v2')::text)), 'VALIDATION: movement_used%');
  bad := t_fails(t_match_sql(t_id('m4'), t_tg('voucher', t_id('v2')::text)), 'VALIDATION: target%');
  unas := t_fails(t_match_sql(t_id('mu'), t_tg('voucher', t_id('v2')::text)), 'VALIDATION: movement_unassigned%');
  none := t_fails(t_match_sql(t_id('m2'), '[]'::jsonb), 'VALIDATION: targets%');
  kind := t_fails(t_match_sql(t_id('m2'), t_tg('journal', t_id('v2')::text)), 'VALIDATION: target_type%');
  perform t_record('MT02 the candidates of a movement are its account''s records around its day, the same amount first, each with its day and method; the owner matches it; nothing is booked when the amounts agree',
    c->'records'->0->>'id' = t_id('v1')::text and (c->'records'->0->>'exact')::boolean and jsonb_typeof(c->'pos_closings') = 'array'
    and exists (select 1 from jsonb_array_elements(c->'records') e where e->>'id' = t_id('p1')::text and e->>'method' = 'pos' and (e->>'day')::date = t_today(t_id('b')))
    and (r->>'difference_halalas')::bigint = 0 and (r->>'records')::int = 1 and (t_mv(t_id('m1'))).status = 'matched'
    and t_count('select count(*) from journal_entries where source_type = ''bank_movement''') = 0, c::text);
  perform t_record('MT03 a movement is used once and a record matched once; money out is not matched with a transfer receipt; an unassigned movement is not matched; a match names at least one record of a known kind',
    used = 'ok' and again = 'ok' and bad = 'ok' and unas = 'ok' and none = 'ok' and kind = 'ok', concat_ws(' / ', used, again, bad, unas, none, kind));
exception when others then perform t_record('MT02 the candidates of a movement are its account''s records around its day, the same amount first, each with its day and method; the owner matches it; nothing is booked when the amounts agree', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT04 a different amount: a reason, and the difference booked
do $$ declare noreason text; r jsonb; bank0 bigint; begin
  bank0 := t_bal(t_id('b'), 'bank');
  noreason := t_fails(t_match_sql(t_id('m3'), t_tg('voucher', t_id('v2')::text)), 'VALIDATION: difference_reason%');
  r := fn_bank_match(t_id('m3'), t_tg('voucher', t_id('v2')::text), 'رسوم التحويل خُصمت من المبلغ');
  perform t_record('MT04 a movement of another amount than its record needs a reason; the difference is booked to the bank''s fees (57), so the bank account stands at what the bank holds',
    noreason = 'ok' and (r->>'difference_halalas')::bigint = -100 and t_bal(t_id('b'), 'bank_fees') = 100
    and t_bal(t_id('b'), 'bank') = bank0 - 100, concat_ws(' / ', noreason, r::text, t_bal(t_id('b'), 'bank')));
exception when others then perform t_record('MT04 a movement of another amount than its record needs a reason; the difference is booked to the bank''s fees (57), so the bank account stands at what the bank holds', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT05 undo, and a cancelled voucher lets go
do $$ declare nor text; begin
  nor := t_fails(format('select fn_bank_unmatch(%L, %L)', t_id('m3'), ''), 'VALIDATION: reason%');
  perform fn_bank_unmatch(t_id('m3'), 'مطابقة خاطئة');
  perform fn_cancel_voucher(t_id('v1'), 'سند مكرر');
  perform t_record('MT05 the owner undoes a match with a reason (the difference reversed, the movement waits again); cancelling a matched voucher lets its movement wait again, and the log says so; the history stays',
    nor = 'ok' and (t_mv(t_id('m3'))).status = 'pending' and (t_mv(t_id('m1'))).status = 'pending' and t_bal(t_id('b'), 'bank_fees') = 0
    and t_count(format('select count(*) from bank_matches where movement_id in (%L, %L) and not active and release_reason is not null', t_id('m1'), t_id('m3'))) = 2
    and t_count(format('select count(*) from bank_match_items i join bank_matches m on m.id = i.match_id where m.movement_id in (%L, %L) and not i.active', t_id('m1'), t_id('m3'))) = 2
    and t_count(format('select count(*) from audit_events where action = ''bank_movement.unmatched'' and entity_id = %L', t_id('m1'))) = 1, nor);
exception when others then perform t_record('MT05 the owner undoes a match with a reason (the difference reversed, the movement waits again); cancelling a matched voucher lets its movement wait again, and the log says so; the history stays', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT06 turn into a voucher
do $$ declare e jsonb; i jsonb; nocat text; undo text; wrong text; begin
  nocat := t_fails(format('select fn_bank_convert(%L, %L::jsonb)', t_id('m4'), jsonb_build_object('description', 'رسوم')), 'VALIDATION: category%');
  wrong := t_fails(format('select fn_bank_convert(%L, %L::jsonb)', t_id('m5'), jsonb_build_object('as', 'fees')), 'VALIDATION: convert_as%');
  e := fn_bank_convert(t_id('m4'), jsonb_build_object('description', 'رسوم تحويل البنك', 'category_id', (select id from expense_categories where name = 'رسوم بنكية ونقاط بيع' and organization_id = fn_user_org_id())));
  undo := t_fails(format('select fn_bank_unmatch(%L, %L)', t_id('m4'), 'خطأ'), 'VALIDATION: cancel_the_expense%');
  i := fn_bank_convert(t_id('m5'), jsonb_build_object('description', 'فرق عملة من البنك'));
  perform t_record('MT06 the owner turns money out into an expense of its category (the bank''s message is its receipt) and money in into other income; the movements are used; an expense made so is undone by cancelling it; money in is never fees',
    nocat = 'ok' and undo = 'ok' and wrong = 'ok' and e->>'expense_number' like 'EXP-%' and (t_mv(t_id('m4'))).status = 'converted' and (t_mv(t_id('m5'))).status = 'converted'
    and (select amount_halalas from expense_vouchers where id = (e->>'expense_id')::uuid) = 575 and t_bal(t_id('b'), 'other_income') = -2500, concat_ws(' / ', nocat, undo, wrong, e::text));
  perform fn_expense_cancel((e->>'expense_id')::uuid, 'ليست رسومًا');
  perform fn_bank_unmatch(t_id('m5'), 'ليست إيرادًا');
  perform t_record('MT07 cancelling the expense made from a movement, or undoing the income, lets the movement wait again',
    (t_mv(t_id('m4'))).status = 'pending' and (t_mv(t_id('m5'))).status = 'pending' and t_bal(t_id('b'), 'other_income') = 0);
exception when others then perform t_record('MT06 the owner turns money out into an expense of its category (the bank''s message is its receipt) and money in into other income; the movements are used; an expense made so is undone by cancelling it; money in is never fees', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT11–MT12 a terminal deposit against the card vouchers it covers
do $$ declare c jsonb; r jsonb; noreason text; one text; lone text; fees0 bigint; lbl jsonb; again jsonb; begin
  c := fn_bank_candidates(t_id('mp'));
  fees0 := t_bal(t_id('b'), 'bank_fees');
  noreason := t_fails(t_match_sql(t_id('mp'), t_tg('voucher', t_id('p1')::text, 'voucher', t_id('p2')::text, 'voucher', t_id('pr')::text)), 'VALIDATION: difference_reason%');
  -- a card refund alone explains no money in
  lone := t_fails(t_match_sql(t_id('mp'), t_tg('voucher', t_id('pr')::text), 'x'), 'VALIDATION: target_total%');
  r := fn_bank_match(t_id('mp'), t_tg('voucher', t_id('p1')::text, 'voucher', t_id('p2')::text, 'voucher', t_id('pr')::text), 'عمولة الشبكة 2%');
  one := t_fails(t_match_sql(t_id('mq'), t_tg('voucher', t_id('p1')::text)), 'VALIDATION: target_used%');
  select x->'match' into lbl from jsonb_array_elements(fn_bank_movements(t_id('b'), t_today(t_id('b')) - 1, t_today(t_id('b')))) x where x->>'id' = t_id('mp')::text;
  perform t_record('MT11 a terminal deposit is matched with the card vouchers it covers — the day''s two payments less its card refund (270 SAR): the bank''s 264.60 books 5.40 of fees with a reason; a refund alone explains no money in; none of them is matched again',
    exists (select 1 from jsonb_array_elements(c->'records') e where e->>'id' = t_id('pr')::text and (e->>'signed_halalas')::bigint = -3000 and e->>'method' = 'pos')
    and noreason = 'ok' and lone = 'ok' and one = 'ok' and (r->>'difference_halalas')::bigint = -540 and (r->>'records')::int = 3
    and t_bal(t_id('b'), 'bank_fees') = fees0 + 540 and (lbl->>'records')::int = 3 and lbl->>'label' like 'السجلات (3): %',
    concat_ws(' / ', noreason, lone, one, r::text, lbl::text));
  -- one of its vouchers is cancelled: the whole match is let go, and the others are free again
  perform fn_cancel_voucher(t_id('p2'), 'دُفعت مرتين');
  again := fn_bank_match(t_id('mq'), t_tg('voucher', t_id('p1')::text), null);
  perform t_record('MT12 cancelling one voucher of a matched set lets the whole match go: the movement waits again, its difference is reversed, and the other vouchers are matched afresh',
    (t_mv(t_id('mp'))).status = 'pending' and t_bal(t_id('b'), 'bank_fees') = fees0 and (again->>'difference_halalas')::bigint = 0
    and t_count(format('select count(*) from bank_match_items i join bank_matches m on m.id = i.match_id where m.movement_id = %L and i.active', t_id('mp'))) = 0
    and t_count(format('select count(*) from bank_matches where movement_id = %L and not active', t_id('mp'))) = 1, again::text);
exception when others then perform t_record('MT11 a terminal deposit is matched with the card vouchers it covers — the day''s two payments less its card refund (270 SAR): the bank''s 264.60 books 5.40 of fees with a reason; a refund alone explains no money in; none of them is matched again', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT13 a locked month is never written
do $$ declare i jsonb; d date; begin
  i := fn_bank_convert(t_id('ml'), jsonb_build_object('description', 'إيراد شهر مقفل'));
  select e.entry_date into d from journal_entries e where e.source_type = 'bank_movement' and e.source_id = t_id('ml');
  perform t_record('MT13 a movement of a locked month is still turned into income, dated today (the locked month is not written)',
    (t_mv(t_id('ml'))).status = 'converted' and d = t_today(t_id('b')), coalesce(d::text, 'no entry'));
exception when others then perform t_record('MT13 a movement of a locked month is still turned into income, dated today (the locked month is not written)', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- MT15 the bank's fees; MT16–MT17 the ledger ends where the journal stands
do $$ declare f jsonb; fees0 bigint; bank0 bigint; lbl jsonb; led jsonb; begin
  fees0 := t_bal(t_id('b'), 'bank_fees'); bank0 := t_bal(t_id('b'), 'bank');
  f := fn_bank_convert(t_id('m6'), jsonb_build_object('as', 'fees'));
  select x->'match' into lbl from jsonb_array_elements(fn_bank_movements(t_id('b'), t_today(t_id('b')) - 1, t_today(t_id('b')))) x where x->>'id' = t_id('m6')::text;
  perform t_record('MT15 the owner turns money out into the bank''s fees in one step: 57 against the bank account, named by the movement''s kind when he writes nothing',
    f->>'as' = 'fees' and (t_mv(t_id('m6'))).status = 'converted' and t_bal(t_id('b'), 'bank_fees') = fees0 + 960 and t_bal(t_id('b'), 'bank') = bank0 - 960
    and lbl->>'label' = 'رسوم بنكية: رسوم نقاط البيع', concat_ws(' / ', f::text, lbl::text));
  led := fn_account_ledger(t_accid(t_id('b'), 'bank_account'), t_today(t_id('b')) - 7, t_today(t_id('b')));
  perform t_record('MT16 the bank account''s ledger carries what matching booked (the fees, a difference and its reversal) as its own lines, and ends where the journal stands',
    (led->>'closing_halalas')::bigint = t_bal(t_id('b'), 'bank')
    and (select count(*) from jsonb_array_elements(led->'lines') l where l->>'kind' = 'bank_adjustment') >= 3
    and exists (select 1 from jsonb_array_elements(led->'lines') l where l->>'kind' = 'bank_adjustment' and (l->>'out_halalas')::bigint = 960),
    (led->>'closing_halalas') || ' / ' || t_bal(t_id('b'), 'bank'));
exception when others then perform t_record('MT15 the owner turns money out into the bank''s fees in one step: 57 against the bank account, named by the movement''s kind when he writes nothing', false, sqlerrm);
end $$;
do $$ declare a record; led jsonb; bad text := ''; n int := 0; d int := 0; begin
  for a in select c.id, c.branch_id, c.name, c.opening_on, c.opening_balance_halalas from cash_accounts c where c.archived_at is null and c.organization_id = fn_user_org_id() loop
    begin
      led := fn_account_ledger(a.id, t_today(a.branch_id) - 300, t_today(a.branch_id));
      n := n + 1;
      d := d + (select count(*) from jsonb_array_elements(led->'lines') l where l->>'kind' = 'closing_difference');
      -- the journal's side: the opening amount and every entry of the account from its opening day to today (the opening's
      -- own entry stands for what was there before it)
      if (led->>'closing_halalas')::bigint <> (select a.opening_balance_halalas + coalesce(sum(l.debit_halalas - l.credit_halalas), 0)
            from journal_lines l join journal_entries e on e.id = l.entry_id join gl_accounts g on g.id = l.account_id
           where g.cash_account_id = a.id and e.source_type <> 'opening' and e.entry_date <= t_today(a.branch_id) and (a.opening_on is null or e.entry_date >= a.opening_on)) then
        bad := bad || a.name || ' (' || (led->>'closing_halalas') || ') ';
      end if;
    exception when others then bad := bad || a.name || ': ' || sqlerrm || ' ';
    end;
  end loop;
  perform t_record('MT17 every box and bank account written by the suites ends in its ledger where the journal stands; a closing''s cash difference is a line of the box''s ledger',
    bad = '' and n > 0 and d > 0, 'accounts ' || n || ', closing lines ' || d || ' / ' || bad);
end $$;
reset role;

-- ---------------------------------------------------------------- MT08 who matches
insert into branch_memberships(staff_id, branch_id) select s, t_id('b') from unnest(array['10000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000008']::uuid[]) s
  where not exists (select 1 from branch_memberships where staff_id = s and branch_id = t_id('b'));
select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
set role authenticated;
select t_record('MT08 finance and the manager read the movements but match, undo or convert nothing',
  t_fails(t_match_sql(t_id('m2'), t_tg('voucher', t_id('v2')::text)), 'FORBIDDEN%') = 'ok'
  and t_fails(format('select fn_bank_candidates(%L)', t_id('m2')), 'FORBIDDEN%') = 'ok'
  and t_fails(format('select fn_bank_convert(%L, %L::jsonb)', t_id('m2'), '{"description":"x"}'), 'FORBIDDEN%') = 'ok'
  and jsonb_array_length(fn_bank_movements(t_id('b'), t_today(t_id('b')) - 1, t_today(t_id('b')))) >= 5);
reset role;
select t_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
select t_record('MT08b the manager does not match either', t_fails(format('select fn_bank_unmatch(%L, %L)', t_id('m2'), 'x'), 'FORBIDDEN%') = 'ok');
reset role;
-- given the right to match, a manager matches only in the branches they work in
insert into role_permissions(organization_id, capability, role, allowed) select organization_id, 'bank.manage', 'manager', true from branches where id = t_id('b')
  on conflict (organization_id, capability, role) do update set allowed = true;
select t_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
select t_record('MT14 a manager given the right to match sees and matches only their own branches'' movements',
  t_fails(format('select fn_bank_candidates(%L)', t_id('mx')), 'FORBIDDEN: branch%') = 'ok'
  and t_fails(format('select fn_bank_convert(%L, %L::jsonb)', t_id('mx'), '{"description":"x"}'), 'FORBIDDEN: branch%') = 'ok'
  and jsonb_typeof(fn_bank_candidates(t_id('m2'))->'records') = 'array');
reset role;
update role_permissions set allowed = false where capability = 'bank.manage' and role = 'manager';
select t_record('MT09 the books still balance after every match, difference, undo and conversion (the trial balance has no difference)',
  t_count('select count(*) from (select entry_id from journal_lines group by entry_id having sum(debit_halalas) <> sum(credit_halalas)) x') = 0);
select t_record('MT10 the matching''s log lines read in Arabic', fn_audit_action_label('bank_movement.matched') = 'مطابقة حركة بنكية'
  and fn_audit_action_label('bank_movement.converted') = 'تحويل حركة بنكية إلى سند');


-- ---------------------------------------------------------------- MT18 a voucher reversed by a correction leaves its match
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare v jsonb; mc uuid; m jsonb; c jsonb; rv uuid; begin
  v := fn_create_voucher(jsonb_build_object('reservation_id', t_id('res'), 'kind','receipt', 'amount_halalas', 15000, 'method','pos', 'reference','MT-POS-C', 'idempotency_key','mt-pc'));
  insert into ids values ('pc', (v->>'voucher_id')::uuid);
  m := fn_bank_match(t_id('mc'), t_tg('voucher', t_id('pc')::text), null);
  -- the day's terminal is settled, so the correction keeps the original and adds its reversal (no cancellation)
  perform fn_pos_settle(jsonb_build_object('branch_id', t_id('b'), 'account_id', t_accid(t_id('b'), 'bank_account'), 'business_date', t_today(t_id('b')),
     'terminal_total_halalas', t_pos_total(t_id('b'))));
  c := fn_staff_correct_voucher(jsonb_build_object('voucher_id', t_id('pc'), 'reason', 'المبلغ الصحيح 140', 'idempotency_key', 'mt-corr-pc', 'amount_halalas', 14000));
  select id into rv from financial_vouchers where reversal_of = t_id('pc');
  perform t_record('MT18 a card voucher reversed by a correction (its day settled) lets its movement wait again, logged; neither half of the reversal pair is offered',
    (c->>'settled')::boolean and rv is not null and (t_mv(t_id('mc'))).status = 'pending'
    and not exists (select 1 from bank_matches where movement_id = t_id('mc') and active)
    and t_count(format('select count(*) from audit_events where entity_id = %L and action = %L and details->''before''->>''by'' = %L', t_id('mc'), 'bank_movement.unmatched', 'record_reversed')) = 1
    and not exists (select 1 from jsonb_array_elements(fn_bank_candidates(t_id('mo'))->'records') e where (e->>'id')::uuid in (t_id('pc'), rv))
    and not exists (select 1 from jsonb_array_elements(fn_bank_candidates(t_id('mc'))->'records') e where (e->>'id')::uuid in (t_id('pc'), rv))
    and t_fails(t_match_sql(t_id('mc'), t_tg('voucher', t_id('pc')::text)), 'VALIDATION: target') = 'ok',
    concat_ws(' / ', c::text, (t_mv(t_id('mc'))).status));
exception when others then perform t_record('MT18 a card voucher reversed by a correction (its day settled) lets its movement wait again, logged; neither half of the reversal pair is offered', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- MT19 nothing is booked before the account's opening day
update cash_accounts set opening_balance_halalas = 500000, opening_on = fn_branch_today(branch_id) - 1 where id = t_accid(t_id('b2'), 'bank_account');
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare f jsonb; d date; led jsonb; led1 jsonb; begin
  f := fn_bank_convert(t_id('m7'), jsonb_build_object('as', 'fees'));
  -- the ledger of the opening day alone carries the fees too (the line stands on its date, not on the day it was written)
  led1 := fn_account_ledger(t_accid(t_id('b2'), 'bank_account'), t_today(t_id('b2')) - 1, t_today(t_id('b2')) - 1);
  select e.entry_date into d from journal_entries e where e.source_type = 'bank_movement' and e.source_id = t_id('m7');
  led := fn_account_ledger(t_accid(t_id('b2'), 'bank_account'), t_today(t_id('b2')) - 7, t_today(t_id('b2')));
  perform t_record('MT19 fees of a movement older than the account''s opening day are dated on the opening day, so the ledger still ends where the journal stands',
    d = t_today(t_id('b2')) - 1 and (led->>'closing_halalas')::bigint = t_bal(t_id('b2'), 'bank') and t_bal(t_id('b2'), 'bank') = 500000 - 700
    and (led1->>'closing_halalas')::bigint = 500000 - 700,
    concat_ws(' / ', d::text, led->>'closing_halalas', led1->>'closing_halalas', t_bal(t_id('b2'), 'bank')::text));
exception when others then perform t_record('MT19 fees of a movement older than the account''s opening day are dated on the opening day, so the ledger still ends where the journal stands', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- MT24 the movements of a branch one does not work in stay unseen
insert into role_permissions(organization_id, capability, role, allowed) select organization_id, 'bank.manage', 'manager', true from branches where id = t_id('b')
  on conflict (organization_id, capability, role) do update set allowed = true;
select t_login('a0000000-0000-0000-0000-000000000008', 'manager@test.local');
set role authenticated;
select t_record('MT24 a manager who may match reads neither the movements nor the matches of a branch they do not work in; the unassigned ones they do',
  not exists (select 1 from jsonb_array_elements(fn_bank_movements(null, t_today(t_id('b')) - 7, t_today(t_id('b')))) x where x->>'branch_id' = t_id('b2')::text)
  and exists (select 1 from jsonb_array_elements(fn_bank_movements(null, t_today(t_id('b')) - 7, t_today(t_id('b')))) x where x->>'branch_id' is null)
  and exists (select 1 from jsonb_array_elements(fn_bank_movements(null, t_today(t_id('b')) - 7, t_today(t_id('b')))) x where x->>'branch_id' = t_id('b')::text)
  and (select count(*) from bank_movements where branch_id = t_id('b2')) = 0
  and (select count(*) from bank_matches where movement_id = t_id('m7')) = 0
  and (select count(*) from bank_match_items i where i.match_id in (select id from bank_matches x where x.movement_id = t_id('m7'))) = 0
  and (select count(*) from bank_movements where branch_id is null) > 0
  -- nor their raw messages; and an unassigned movement is not given to that branch's account
  and not exists (select 1 from jsonb_array_elements(fn_bank_messages(null, 500)) x where x->>'movement_id' in (t_id('m7')::text, t_id('mx')::text))
  and exists (select 1 from jsonb_array_elements(fn_bank_messages(null, 500)) x where x->>'movement_id' = t_id('mu')::text)
  and (select count(*) from bank_messages where movement_id in (t_id('m7'), t_id('mx'))) = 0
  and t_fails(format('select fn_bank_assign_account(%L, %L, %L)', t_id('mu'), t_accid(t_id('b2'), 'bank_account'), 'x'), 'FORBIDDEN: branch%') = 'ok');
reset role;
update role_permissions set allowed = false where capability = 'bank.manage' and role = 'manager';
select t_record('MT24b the owner still reads every branch''s movements and the match made in the other branch',
  (select count(*) from bank_matches where movement_id = t_id('m7') and active) = 1);

select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),200) as detail from test_results order by ok nulls first, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'ACCOUNTING A8 TESTS FAILED'; end if;
  if (select count(*) from test_results) < 22 then raise exception 'ACCOUNTING A8 TESTS INCOMPLETE: % of 22 checks ran', (select count(*) from test_results); end if;
end $$;
