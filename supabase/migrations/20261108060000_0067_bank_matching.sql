-- 0067 — A8 of the accounting stage (plan «خطة تصحيح ملاحظات التجربة», stage م٣, phase د: «المطابقة والحركات المعلّقة»):
--   · a movement read from the bank's messages (0066) waits as «بانتظار المطابقة» until the owner matches it with one
--     record of the same bank account — a receipt or refund by transfer or terminal, an expense, the day's terminal
--     settlement, a platform payout — or turns it into its own voucher (money out: an expense of the category chosen;
--     money in: other income); the system suggests the records of the same account and amount around its day;
--   · a movement is used once and a record is matched once (unique while active); a different amount needs a reason and
--     the difference is booked (fees 57 or other income 49); undoing a match, or cancelling its record, lets the movement
--     wait again (released, never erased);
--   · a waiting movement is a reconciliation item, not an entry (an entry would count a transfer already received by
--     voucher twice); the day's terminal money is matched either as the settlement or voucher by voucher, never both.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The log lines
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_audit_accounting_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select case p_action
      when 'day_closing.created' then 'بدء إقفال يوم'
      when 'day_closing.submitted' then 'إرسال إقفال يوم'
      when 'day_closing.amended' then 'تعديل إقفال يوم خلال المهلة'
      when 'day_closing.edit_requested' then 'طلب تعديل إقفال بعد المهلة'
      when 'day_closing.edit_approved' then 'الموافقة على تعديل إقفال'
      when 'day_closing.edit_rejected' then 'رفض تعديل إقفال'
      when 'branch.day_close_rules_changed' then 'تغيير مهلة تعديل الإقفال'
      when 'expense.created' then 'إصدار سند صرف'
      when 'expense.cancelled' then 'إلغاء سند صرف'
      when 'expense_category.created' then 'إضافة تصنيف مصروف'
      when 'expense_category.updated' then 'تعديل تصنيف مصروف'
      when 'cash_account.opening_set' then 'تحديد الرصيد الافتتاحي'
      when 'accounting.month_locked' then 'قفل شهر محاسبي'
      when 'accounting.month_opened' then 'فتح شهر محاسبي'
      when 'bank_mail.settings_changed' then 'تعديل بريد البنك'
      when 'bank_rule.created' then 'إضافة قاعدة قراءة رسائل البنك'
      when 'bank_rule.updated' then 'تعديل قاعدة قراءة رسائل البنك'
      when 'bank_message.reparsed' then 'إعادة قراءة رسالة بنكية'
      when 'bank_movement.assigned' then 'نسبة حركة بنكية لحساب فرع'
      when 'bank_movement.matched' then 'مطابقة حركة بنكية'
      when 'bank_movement.unmatched' then 'فك مطابقة حركة بنكية'
      when 'bank_movement.converted' then 'تحويل حركة بنكية إلى سند'
      else null
    end;
$$;
revoke all on function fn_audit_accounting_label(text) from public, anon;
grant execute on function fn_audit_accounting_label(text) to authenticated, service_role;
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$when 'bank_movement' then 'حركة بنكية' end$a$;
        new_e constant text := $b$when 'bank_movement' then 'حركة بنكية' when 'bank_match' then 'مطابقة بنكية' end$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_entity_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0067: the closing line of fn_audit_entity_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The chart: the account of the bank's fees (57), for what a matched movement differs from its voucher
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_gl_seed(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_parent uuid;
begin
  perform pg_advisory_xact_lock(hashtext('gl_seed:' || p_org::text));
  for r in select * from (values
      ('1',    'الأصول',                     'asset',     null,  false, 'assets'),
      ('11',   'النقد وما في حكمه',           'asset',     '1',   false, 'cash_group'),
      ('111',  'صناديق الفروع',              'asset',     '11',  false, 'cash_parent'),
      ('112',  'الحسابات البنكية',            'asset',     '11',  false, 'bank_parent'),
      ('12',   'الذمم المدينة',              'asset',     '1',   false, 'receivables'),
      ('121',  'مستحقات المنصات',            'asset',     '12',  false, 'platform_parent'),
      ('129',  'حساب معلّق',                 'asset',     '12',  true,  'suspense'),
      ('2',    'الالتزامات',                 'liability', null,  false, 'liabilities'),
      ('21',   'تأمينات الضيوف',             'liability', '2',   true,  'deposits'),
      ('3',    'حقوق الملكية',               'equity',    null,  false, 'equity'),
      ('31',   'الأرصدة الافتتاحية',          'equity',    '3',   true,  'opening'),
      ('4',    'الإيرادات',                  'revenue',   null,  false, 'revenue'),
      ('41',   'إيراد الإيجار',               'revenue',   '4',   true,  'rent_revenue'),
      ('42',   'مردودات الإيجار',             'revenue',   '4',   true,  'rent_returns'),
      ('49',   'إيرادات أخرى وزيادات',        'revenue',   '4',   true,  'other_income'),
      ('5',    'المصروفات',                  'expense',   null,  false, 'expenses'),
      ('51',   'المصروفات التشغيلية',         'expense',   '5',   false, 'expense_parent'),
      ('57',   'رسوم بنكية ونقاط البيع',      'expense',   '5',   true,  'bank_fees'),
      ('58',   'عمولات المنصات',             'expense',   '5',   true,  'platform_commission'),
      ('59',   'عجز الصندوق',                'expense',   '5',   true,  'cash_shortage')
    ) t(code, name, type, parent, postable, key)
  loop
    if not exists (select 1 from gl_accounts where organization_id = p_org and system_key = r.key) then
      select id into v_parent from gl_accounts where organization_id = p_org and code = r.parent;
      insert into gl_accounts(organization_id, code, name, type, parent_id, is_postable, system_key)
      values (p_org, r.code, r.name, r.type, v_parent, r.postable, r.key);
    end if;
  end loop;
end $$;
revoke all on function fn_gl_seed(uuid) from public, anon, authenticated;
select fn_gl_seed(id) from organizations;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The matches: one movement with one voucher (or settlement, payout, expense), each used once; or the movement
--    turned into its own voucher. Released (never erased) when the owner undoes it or the voucher is cancelled.
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists bank_matches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  movement_id uuid not null references bank_movements(id),
  target_type text not null,                     -- voucher | expense | pos_settlement | platform_payout | journal
  target_id uuid not null,
  kind text not null,                            -- link (an existing record) | convert (made from the movement)
  difference_halalas bigint not null default 0,  -- the movement's amount less the record's (booked as fees or income)
  reason text,
  active boolean not null default true,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  released_at timestamptz,
  released_by uuid references staff_profiles(id),
  release_reason text,
  constraint bank_match_target_valid check (target_type in ('voucher', 'expense', 'pos_settlement', 'platform_payout', 'journal')),
  constraint bank_match_kind_valid check (kind in ('link', 'convert'))
);
-- a movement is used once, and a voucher is matched once
create unique index if not exists uniq_bank_match_movement on bank_matches(movement_id) where active;
create unique index if not exists uniq_bank_match_target on bank_matches(target_type, target_id) where active;
alter table bank_matches enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_matches' and policyname = 'bank_matches_read') then
    create policy "bank_matches_read" on bank_matches for select to authenticated
      using (organization_id = fn_user_org_id() and (fn_can('bank.manage') or (fn_can('bank.view') and movement_id in (select id from bank_movements))));
  end if;
end $$;
revoke all on bank_matches from anon, authenticated;
grant select on bank_matches to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. The books: a waiting movement is not an entry — it is a reconciliation item («بانتظار المطابقة»), the gap between
--    what the hotel recorded on the bank account and what the bank says. (Booking it bank against suspense as well
--    would count a transfer already received by voucher twice until it is matched.) Only what matching adds is booked:
--    a difference, or the income a movement is turned into. Their date is the movement's day while its month is open,
--    otherwise today (a locked month is never written); reversals are dated today.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_gl_open_date(p_org uuid, p_branch uuid, p_date date) returns date
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from accounting_periods where organization_id = p_org and month = date_trunc('month', p_date)::date and locked)
              then fn_branch_today(p_branch) else p_date end
$$;
revoke all on function fn_gl_open_date(uuid, uuid, date) from public, anon, authenticated;

-- the reversal of the live entries of a movement whose posting starts with p_prefix (diff / convert)
create or replace function fn_gl_reverse_live(p_movement uuid, p_prefix text, p_date date, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare e journal_entries%rowtype;
begin
  for e in select * from journal_entries je where je.source_type = 'bank_movement' and je.source_id = p_movement and je.posting like p_prefix || '%'
            and je.reversal_of is null and not exists (select 1 from journal_entries r where r.reversal_of = je.id) order by je.created_at loop
    perform fn_gl_post(e.organization_id, e.branch_id, p_date, e.source_type, e.source_id, 'reverse:' || e.id::text,
                       'عكس ' || e.number || ': ' || coalesce(p_reason, ''),
                       (select jsonb_agg(jsonb_build_object('account_id', account_id, 'debit', credit_halalas, 'credit', debit_halalas, 'memo', memo))
                          from journal_lines where entry_id = e.id), e.id);
  end loop;
end $$;
revoke all on function fn_gl_reverse_live(uuid, text, date, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. What a movement can be matched with: the records of the same bank account, the right direction, not matched yet
-- ---------------------------------------------------------------------------------------------------------------
-- one record as a candidate: {type, id, number, label, amount_halalas, at}; null when it is not one for this movement
create or replace function fn_bank_target(p_movement uuid, p_type text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v bank_movements%rowtype; r jsonb;
begin
  select * into v from bank_movements where id = p_movement;
  if p_type = 'voucher' then
    select jsonb_build_object('type', 'voucher', 'id', f.id, 'number', f.number, 'amount_halalas', f.amount_halalas, 'at', f.occurred_at,
                              'label', case f.kind when 'receipt' then 'سند قبض' when 'deposit' then 'قبض تأمين' when 'refund' then 'رد مبلغ' when 'deposit_refund' then 'رد تأمين' else f.kind end
                                       || case f.method::text when 'pos' then ' (شبكة)' when 'bank_transfer' then ' (تحويل)' else '' end)
      into r from financial_vouchers f
     where f.id = p_id and f.account_id = v.cash_account_id and f.status = 'approved' and f.method::text in ('bank_transfer', 'pos')
       and ((v.direction = 'in' and f.kind in ('receipt', 'deposit')) or (v.direction = 'out' and f.kind in ('refund', 'deposit_refund')))
       -- the day's terminal money is matched as its settlement or voucher by voucher, never both
       and not (f.method::text = 'pos' and exists (select 1 from bank_matches bm join pos_settlements s on s.id = bm.target_id
                                                    where bm.active and bm.target_type = 'pos_settlement' and s.account_id = f.account_id
                                                      and s.business_date = fn_branch_date(f.branch_id, f.occurred_at)));
  elsif p_type = 'expense' then
    select jsonb_build_object('type', 'expense', 'id', x.id, 'number', x.number, 'amount_halalas', x.amount_halalas, 'at', x.occurred_at, 'label', 'سند صرف: ' || x.description)
      into r from expense_vouchers x where x.id = p_id and x.account_id = v.cash_account_id and x.status = 'approved' and v.direction = 'out';
  elsif p_type = 'pos_settlement' then
    -- its amount is what the books hold for that day: the terminal vouchers' total now (not the terminal's own figure)
    select jsonb_build_object('type', 'pos_settlement', 'id', s.id, 'number', 'تسوية ' || to_char(s.business_date, 'YYYY-MM-DD'),
                              'amount_halalas', (fn_pos_day_total(s.branch_id, s.account_id, s.business_date)->>'system_total_halalas')::bigint,
                              'at', s.business_date::timestamptz, 'label', 'تسوية الشبكة ليوم ' || to_char(s.business_date, 'YYYY-MM-DD'))
      into r from pos_settlements s where s.id = p_id and s.account_id = v.cash_account_id and v.direction = 'in'
       and not exists (select 1 from bank_matches bm join financial_vouchers f on f.id = bm.target_id
                        where bm.active and bm.target_type = 'voucher' and f.method::text = 'pos' and f.account_id = s.account_id
                          and fn_branch_date(f.branch_id, f.occurred_at) = s.business_date);
    if r is not null and (r->>'amount_halalas')::bigint <= 0 then r := null; end if;
  elsif p_type = 'platform_payout' then
    select jsonb_build_object('type', 'platform_payout', 'id', p.id, 'number', p.reference, 'amount_halalas', p.received_halalas, 'at', p.received_on::timestamptz,
                              'label', 'دفعة منصة ' || coalesce((select name from booking_sources where id = p.source_id), ''))
      into r from platform_payouts p where p.id = p_id and p.account_id = v.cash_account_id and p.status = 'confirmed' and v.direction = 'in';
  end if;
  return r;
end $$;
revoke all on function fn_bank_target(uuid, text, uuid) from public, anon, authenticated;

-- the suggestions for a movement: within a week of it, not matched to another movement; the same amount first
create or replace function fn_bank_candidates(p_movement uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v bank_movements%rowtype; d date;
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.cash_account_id is null then return '[]'::jsonb; end if;
  perform fn_require_branch(v.branch_id);
  d := fn_branch_date(v.branch_id, v.occurred_at);
  return coalesce((select jsonb_agg(c || jsonb_build_object('exact', (c->>'amount_halalas')::bigint = v.amount_halalas)
                                    order by abs((c->>'amount_halalas')::bigint - v.amount_halalas), abs(extract(epoch from (c->>'at')::timestamptz - v.occurred_at)))
                   from (select fn_bank_target(v.id, t.type, t.id) as c from (
                           select 'voucher' as type, f.id from financial_vouchers f where f.account_id = v.cash_account_id and fn_branch_date(f.branch_id, f.occurred_at) between d - 7 and d + 1
                           union all select 'expense', x.id from expense_vouchers x where x.account_id = v.cash_account_id and fn_branch_date(x.branch_id, x.occurred_at) between d - 7 and d + 1
                           union all select 'pos_settlement', s.id from pos_settlements s where s.account_id = v.cash_account_id and s.business_date between d - 7 and d + 1
                           union all select 'platform_payout', p.id from platform_payouts p where p.account_id = v.cash_account_id and p.received_on between d - 7 and d + 1) t
                         where not exists (select 1 from bank_matches m where m.active and m.target_type = t.type and m.target_id = t.id)) q
                   where c is not null), '[]'::jsonb);
end $$;
revoke all on function fn_bank_candidates(uuid) from public, anon;
grant execute on function fn_bank_candidates(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Matching, undoing it, turning a movement into a voucher
-- ---------------------------------------------------------------------------------------------------------------
-- the owner matches a pending movement with one record. A different amount needs a reason; the difference is booked:
-- money in short of the record → the bank's fees (57); more → other income (49); money out the other way round
create or replace function fn_bank_match(p_movement uuid, p_type text, p_target uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bank_movements%rowtype; t jsonb; diff bigint; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); acc uuid; m uuid; d date;
        pos_acc uuid; pos_day date;
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.status <> 'pending' then raise exception 'VALIDATION: movement_used'; end if;
  if v.cash_account_id is null then raise exception 'VALIDATION: movement_unassigned'; end if;
  perform fn_require_branch(v.branch_id);
  if p_type not in ('voucher', 'expense', 'pos_settlement', 'platform_payout') then raise exception 'VALIDATION: target_type'; end if;
  -- the record is held while it is matched: a cancellation (or a settlement's new figures) waits, then sees the match.
  -- Taken before the day's lock, in the order a cancellation takes them (its row, then the day's lock in its trigger)
  if p_type = 'voucher' then perform 1 from financial_vouchers where id = p_target for share;
  elsif p_type = 'expense' then perform 1 from expense_vouchers where id = p_target for share;
  elsif p_type = 'pos_settlement' then perform 1 from pos_settlements where id = p_target for share;
  else perform 1 from platform_payouts where id = p_target for share;
  end if;
  -- a day's terminal money (its settlement, its terminal vouchers) is matched by one at a time
  if p_type = 'voucher' then
    select account_id, fn_branch_date(branch_id, occurred_at) into pos_acc, pos_day from financial_vouchers where id = p_target and method::text = 'pos';
  elsif p_type = 'pos_settlement' then
    select account_id, business_date into pos_acc, pos_day from pos_settlements where id = p_target;
  end if;
  if pos_acc is not null then perform pg_advisory_xact_lock(hashtext('bank_pos_day:' || pos_acc::text || ':' || pos_day::text)); end if;
  perform pg_advisory_xact_lock(hashtext('bank_target:' || p_type || ':' || p_target::text));
  t := fn_bank_target(v.id, p_type, p_target);
  if t is null then raise exception 'VALIDATION: target'; end if;
  if exists (select 1 from bank_matches where active and target_type = p_type and target_id = p_target) then raise exception 'VALIDATION: target_used'; end if;
  diff := v.amount_halalas - (t->>'amount_halalas')::bigint;
  if diff <> 0 and (v_reason is null or char_length(v_reason) > 300) then raise exception 'VALIDATION: difference_reason'; end if;
  if v_reason is not null and char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  insert into bank_matches(organization_id, movement_id, target_type, target_id, kind, difference_halalas, reason, created_by)
  values (v.organization_id, v.id, p_type, p_target, 'link', diff, v_reason, fn_staff_id()) returning id into m;
  update bank_movements set status = 'matched' where id = v.id;
  if diff <> 0 then
    acc := fn_gl_for_cash(v.cash_account_id); d := fn_gl_open_date(v.organization_id, v.branch_id, fn_branch_date(v.branch_id, v.occurred_at));
    -- the bank moved diff more (+) or less (−) than the record booked: the bank account takes the difference
    perform fn_gl_post(v.organization_id, v.branch_id, d, 'bank_movement', v.id, 'diff:' || m::text,
                       'فرق مطابقة ' || (t->>'number') || ': ' || v_reason,
                       case when (v.direction = 'in') = (diff > 0) then
                         jsonb_build_array(jsonb_build_object('account_id', acc, 'debit', abs(diff)), jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'other_income'), 'credit', abs(diff)))
                       else
                         jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'bank_fees'), 'debit', abs(diff)), jsonb_build_object('account_id', acc, 'credit', abs(diff))) end);
  end if;
  perform fn_audit_change(v.branch_id, 'bank_movement.matched', 'bank_movement', v.id, null,
                          jsonb_build_object('target', t->>'number', 'type', p_type, 'amount_halalas', v.amount_halalas, 'difference_halalas', diff), v_reason);
  return jsonb_build_object('ok', true, 'match_id', m, 'difference_halalas', diff);
end $$;
revoke all on function fn_bank_match(uuid, text, uuid, text) from public, anon;
grant execute on function fn_bank_match(uuid, text, uuid, text) to authenticated;

-- the release of a movement's match (by the owner, or because its record was cancelled): the movement waits again
create or replace function fn_bank_release(p_match uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare m bank_matches%rowtype; v bank_movements%rowtype; mv uuid;
begin
  -- the movement first, then its match (the order matching and undoing take too)
  select movement_id into mv from bank_matches where id = p_match;
  if not found then return; end if;
  select * into v from bank_movements where id = mv for update;
  select * into m from bank_matches where id = p_match and active for update;
  if not found then return; end if;
  update bank_matches set active = false, released_at = now(), released_by = fn_staff_id(), release_reason = left(p_reason, 300) where id = m.id;
  perform fn_gl_reverse_live(v.id, 'diff:' || m.id::text, fn_branch_today(v.branch_id), p_reason);
  if m.target_type = 'journal' then perform fn_gl_reverse_live(v.id, 'convert:' || m.id::text, fn_branch_today(v.branch_id), p_reason); end if;
  update bank_movements set status = 'pending' where id = v.id;
end $$;
revoke all on function fn_bank_release(uuid, text) from public, anon, authenticated;

create or replace function fn_bank_unmatch(p_movement uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bank_movements%rowtype; m bank_matches%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.branch_id is not null then perform fn_require_branch(v.branch_id); end if;
  if v_reason is null or char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  select * into m from bank_matches where movement_id = v.id and active;
  if not found then raise exception 'VALIDATION: movement_not_matched'; end if;
  -- an expense made from the movement is undone by cancelling that expense (with its reason), which releases it
  if m.target_type = 'expense' and m.kind = 'convert' then raise exception 'VALIDATION: cancel_the_expense'; end if;
  perform fn_bank_release(m.id, v_reason);
  perform fn_audit_change(v.branch_id, 'bank_movement.unmatched', 'bank_movement', v.id, jsonb_build_object('type', m.target_type, 'kind', m.kind), null, v_reason);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_bank_unmatch(uuid, text) from public, anon;
grant execute on function fn_bank_unmatch(uuid, text) to authenticated;

-- the owner turns a pending movement into its own voucher: money out → an expense voucher of the category chosen (its
-- receipt is the bank's message); money in → an income entry (bank against other income, 49), with a description
create or replace function fn_bank_convert(p_movement uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bank_movements%rowtype; cat expense_categories%rowtype; v_desc text := nullif(btrim(coalesce(p->>'description', '')), ''); x expense_vouchers%rowtype;
        m uuid := gen_random_uuid(); je uuid; d date; d0 date;
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.status <> 'pending' then raise exception 'VALIDATION: movement_used'; end if;
  if v.cash_account_id is null then raise exception 'VALIDATION: movement_unassigned'; end if;
  perform fn_require_branch(v.branch_id);
  if exists (select 1 from cash_accounts where id = v.cash_account_id and archived_at is not null) then raise exception 'VALIDATION: account_archived'; end if;
  if v_desc is null or char_length(v_desc) > 300 then raise exception 'VALIDATION: description'; end if;
  -- the movement's day while its month is open, otherwise today
  d0 := fn_branch_date(v.branch_id, v.occurred_at); d := fn_gl_open_date(v.organization_id, v.branch_id, d0);
  if v.direction = 'out' then
    select * into cat from expense_categories where id = (p->>'category_id')::uuid and organization_id = v.organization_id and is_active;
    if not found then raise exception 'VALIDATION: category'; end if;
    update bank_movements set status = 'converted' where id = v.id;
    insert into expense_vouchers(organization_id, branch_id, number, account_id, category_id, amount_halalas, occurred_at, payee, description, reference, created_by)
    values (v.organization_id, v.branch_id, fn_next_document_number(v.organization_id, 'expense', 'EXP'), v.cash_account_id, cat.id, v.amount_halalas,
            case when d = d0 then v.occurred_at else now() end,
            null, v_desc, coalesce(v.reference, 'حركة بنكية'), fn_staff_id())
    returning * into x;
    insert into bank_matches(id, organization_id, movement_id, target_type, target_id, kind, reason, created_by)
    values (m, v.organization_id, v.id, 'expense', x.id, 'convert', v_desc, fn_staff_id());
    perform fn_audit_change(v.branch_id, 'expense.created', 'expense_voucher', x.id, null, jsonb_build_object('number', x.number, 'amount_halalas', x.amount_halalas, 'from', 'bank_movement'), v_desc);
  else
    update bank_movements set status = 'converted' where id = v.id;
    je := fn_gl_post(v.organization_id, v.branch_id, d, 'bank_movement', v.id, 'convert:' || m::text,
                     'إيراد من حركة بنكية: ' || v_desc,
                     jsonb_build_array(jsonb_build_object('account_id', fn_gl_for_cash(v.cash_account_id), 'debit', v.amount_halalas),
                                       jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'other_income'), 'credit', v.amount_halalas)));
    insert into bank_matches(id, organization_id, movement_id, target_type, target_id, kind, reason, created_by)
    values (m, v.organization_id, v.id, 'journal', je, 'convert', v_desc, fn_staff_id());
  end if;
  perform fn_audit_change(v.branch_id, 'bank_movement.converted', 'bank_movement', v.id, null,
                          jsonb_build_object('direction', v.direction, 'amount_halalas', v.amount_halalas, 'expense', x.number), v_desc);
  return jsonb_build_object('ok', true, 'match_id', m, 'expense_id', x.id, 'expense_number', x.number);
end $$;
revoke all on function fn_bank_convert(uuid, jsonb) from public, anon;
grant execute on function fn_bank_convert(uuid, jsonb) to authenticated;

-- a record that is cancelled lets its movement go: the match is released and the movement waits again
create or replace function fn_trg_bank_release_target() returns trigger
language plpgsql security definer set search_path = public as $$
declare m bank_matches%rowtype; t text := case tg_table_name when 'financial_vouchers' then 'voucher' when 'expense_vouchers' then 'expense' else 'platform_payout' end;
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    for m in select * from bank_matches where active and target_type = t and target_id = new.id loop
      perform fn_bank_release(m.id, 'أُلغي السجل المطابق');
    end loop;
  end if;
  return null;
end $$;
revoke all on function fn_trg_bank_release_target() from public, anon, authenticated;
create or replace trigger trg_bank_release_voucher after update of status on financial_vouchers for each row execute function fn_trg_bank_release_target();
create or replace trigger trg_bank_release_expense after update of status on expense_vouchers for each row execute function fn_trg_bank_release_target();
create or replace trigger trg_bank_release_payout after update of status on platform_payouts for each row execute function fn_trg_bank_release_target();

-- a terminal voucher added to or cancelled from a day whose settlement is matched changes what the books hold for that
-- day: the settlement's match is released, and the owner matches it again at the new total
create or replace function fn_trg_bank_pos_day() returns trigger
language plpgsql security definer set search_path = public as $$
declare m uuid; d record;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status and new.occurred_at is not distinct from old.occurred_at
     and new.account_id is not distinct from old.account_id and new.method is not distinct from old.method then return null; end if;
  -- the day (or days, when a correction moves the voucher) whose terminal total changes
  for d in select distinct x.acc, x.day from (
             select new.account_id as acc, fn_branch_date(new.branch_id, new.occurred_at) as day where new.method::text = 'pos'
             union all
             select old.account_id, fn_branch_date(old.branch_id, old.occurred_at) where tg_op = 'UPDATE' and old.method::text = 'pos') x
           where x.acc is not null order by 1, 2 loop
    -- waits for a match of that day in progress, then sees it
    perform pg_advisory_xact_lock(hashtext('bank_pos_day:' || d.acc::text || ':' || d.day::text));
    for m in select bm.id from bank_matches bm join pos_settlements s on s.id = bm.target_id
              where bm.active and bm.target_type = 'pos_settlement' and s.account_id = d.acc and s.business_date = d.day loop
      perform fn_bank_release(m, 'تغيّرت سندات الشبكة لذلك اليوم');
    end loop;
  end loop;
  return null;
end $$;
revoke all on function fn_trg_bank_pos_day() from public, anon, authenticated;
create or replace trigger trg_bank_pos_day after insert or update of status, occurred_at, account_id, method on financial_vouchers for each row execute function fn_trg_bank_pos_day();

-- a matched settlement keeps its figures: the match is undone first
create or replace function fn_trg_bank_settlement_matched() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from bank_matches where active and target_type = 'pos_settlement' and target_id = old.id) then
    raise exception 'VALIDATION: settlement_matched';
  end if;
  return new;
end $$;
revoke all on function fn_trg_bank_settlement_matched() from public, anon, authenticated;
create or replace trigger trg_bank_settlement_matched before update on pos_settlements for each row execute function fn_trg_bank_settlement_matched();

-- the movements list carries what each one is matched with
create or replace function fn_bank_movements(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (fn_can('bank.view') or fn_can('bank.manage')) then raise exception 'FORBIDDEN: bank.view' using errcode = '42501'; end if;
  if p_branch is not null then perform fn_require_branch(p_branch); elsif not fn_can('bank.manage') then raise exception 'FORBIDDEN: bank.manage' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'branch_id', v.branch_id, 'branch', b.name_ar, 'account', a.name, 'kind', v.kind, 'direction', v.direction,
                                                       'amount_halalas', v.amount_halalas, 'occurred_at', v.occurred_at, 'reference', v.reference,
                                                       'balance_halalas', v.balance_halalas, 'account_hint', v.account_hint, 'status', v.status,
                                                       'text', m.sms_text, 'channel', m.channel,
                                                       'match', (select jsonb_build_object('type', x.target_type, 'kind', x.kind, 'difference_halalas', x.difference_halalas, 'reason', x.reason,
                                                                                           'label', case when x.target_type = 'journal' then 'إيراد: ' || coalesce(x.reason, '')
                                                                                                         else coalesce(fn_bank_target_label(x.target_type, x.target_id), '') end)
                                                                 from bank_matches x where x.movement_id = v.id and x.active)) order by v.occurred_at desc, v.created_at desc)
                   from bank_movements v join bank_messages m on m.id = v.message_id
                   left join branches b on b.id = v.branch_id left join cash_accounts a on a.id = v.cash_account_id
                   where v.organization_id = fn_user_org_id() and fn_branch_date(v.branch_id, v.occurred_at) between p_from and p_to
                     and (case when p_branch is null then true else v.branch_id = p_branch end)), '[]'::jsonb);
end $$;
revoke all on function fn_bank_movements(uuid, date, date) from public, anon;
grant execute on function fn_bank_movements(uuid, date, date) to authenticated;

-- a matched record's label (whatever its state now)
create or replace function fn_bank_target_label(p_type text, p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case p_type
    when 'voucher' then (select 'سند ' || number from financial_vouchers where id = p_id)
    when 'expense' then (select 'سند صرف ' || number || ': ' || description from expense_vouchers where id = p_id)
    when 'pos_settlement' then (select 'تسوية الشبكة ليوم ' || to_char(business_date, 'YYYY-MM-DD') from pos_settlements where id = p_id)
    when 'platform_payout' then (select 'دفعة منصة ' || reference from platform_payouts where id = p_id)
  end
$$;
revoke all on function fn_bank_target_label(text, uuid) from public, anon, authenticated;
