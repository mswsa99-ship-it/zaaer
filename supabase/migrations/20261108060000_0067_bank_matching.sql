-- 0067 — A8 of the accounting stage (plan «خطة تصحيح ملاحظات التجربة», stage م٣, phase د: «المطابقة والحركات المعلّقة»):
--   · a movement read from the bank's messages (0066) waits as «بانتظار المطابقة» until the owner matches it with the
--     records of the same bank account that explain it — a transfer voucher, the card-terminal vouchers a deposit
--     covers (a day's, or the ones he ticks), an expense, a platform payout — or turns it into its own voucher (money
--     out: an expense of the category chosen, or the bank's fees; money in: other income); the system lists the records
--     of that account around its day, the same amount first, with what each day's closing says the terminal took;
--   · a movement is used once and a record is matched once (unique while active); a total that differs from the movement
--     needs a reason and the difference is booked (fees 57 or other income 49); undoing a match, or cancelling one of
--     its records, lets the movement wait again (released, never erased);
--   · a waiting movement is a reconciliation item, not an entry (an entry would count a transfer already received by
--     voucher twice);
--   · the ledger of a box or bank account shows the entries that have no voucher of their own (a match's difference, a
--     movement turned into fees or income, a closing's cash difference), so it ends where the journal stands;
--   · a voucher reversed by a correction leaves its match as a cancelled one does, and a reversal pair is never offered;
--   · what matching books is never dated before the account's opening day (the ledger starts there);
--   · the movements, their matches and their messages are read, and a movement assigned, only in the branches one works
--     in (the unassigned ones by who manages the bank).

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
      ('57',   'رسوم وفروق المطابقة البنكية',  'expense',   '5',   true,  'bank_fees'),
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
-- 3. The matches: one movement with the records that explain it (each record used once), or the movement turned
--    into its own voucher. Released (never erased) when the owner undoes it or one of its records is cancelled.
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists bank_matches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  movement_id uuid not null references bank_movements(id),
  kind text not null,                            -- link (existing records) | convert (made from the movement) | set_aside (kept
                                                 -- for setting a duplicate aside: no function writes it yet, the owner decides)
  difference_halalas bigint not null default 0,  -- the movement's amount less its records' total (booked as fees or income)
  reason text,
  active boolean not null default true,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  released_at timestamptz,
  released_by uuid references staff_profiles(id),
  release_reason text,
  constraint bank_match_kind_valid check (kind in ('link', 'convert', 'set_aside'))
);
-- a movement is used once
create unique index if not exists uniq_bank_match_movement on bank_matches(movement_id) where active;
alter table bank_matches enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_matches' and policyname = 'bank_matches_read') then
    create policy "bank_matches_read" on bank_matches for select to authenticated
      using (organization_id = fn_user_org_id() and movement_id in (select id from bank_movements));
  end if;
end $$;
-- the movements (0066) are read in the branches one works in; the unassigned ones by who manages the bank
alter policy "bank_movements_read" on bank_movements
  using (organization_id = fn_user_org_id() and (fn_can('bank.view') or fn_can('bank.manage'))
         and (branch_id in (select fn_user_branch_ids()) or (branch_id is null and fn_can('bank.manage'))));
revoke all on bank_matches from anon, authenticated;
grant select on bank_matches to authenticated;

-- the records of a match: a transfer voucher, the card-terminal vouchers a deposit covers, an expense, a platform
-- payout; or the entry a conversion made
create table if not exists bank_match_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  match_id uuid not null references bank_matches(id),
  target_type text not null,                     -- voucher | expense | platform_payout | journal
  target_id uuid not null,
  amount_halalas bigint not null,                -- what the record counts for in the movement's direction (a card refund inside a terminal deposit: below zero)
  active boolean not null default true,
  constraint bank_match_item_target_valid check (target_type in ('voucher', 'expense', 'platform_payout', 'journal'))
);
-- a record is matched once
create unique index if not exists uniq_bank_match_item_target on bank_match_items(target_type, target_id) where active;
create index if not exists idx_bank_match_items_match on bank_match_items(match_id);
alter table bank_match_items enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_match_items' and policyname = 'bank_match_items_read') then
    create policy "bank_match_items_read" on bank_match_items for select to authenticated
      using (organization_id = fn_user_org_id() and match_id in (select id from bank_matches));
  end if;
end $$;
revoke all on bank_match_items from anon, authenticated;
grant select on bank_match_items to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. The books: a waiting movement is not an entry — it is a reconciliation item («بانتظار المطابقة»), the gap between
--    what the hotel recorded on the bank account and what the bank says. (Booking it bank against suspense as well
--    would count a transfer already received by voucher twice until it is matched.) Only what matching adds is booked:
--    a difference, or the fees or income a movement is turned into. Their date is the movement's day while its month
--    is open, otherwise today (a locked month is never written); reversals are dated today.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_gl_open_date(p_org uuid, p_branch uuid, p_date date) returns date
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from accounting_periods where organization_id = p_org and month = date_trunc('month', p_date)::date and locked)
              then fn_branch_today(p_branch) else p_date end
$$;
revoke all on function fn_gl_open_date(uuid, uuid, date) from public, anon, authenticated;

-- the day what matching books for a movement is dated: the movement's day, not before its account's opening day (the
-- ledger starts there), and today when that month is locked
create or replace function fn_bank_entry_date(p_movement uuid) returns date
language sql stable security definer set search_path = public as $$
  select fn_gl_open_date(v.organization_id, v.branch_id,
                         greatest(fn_branch_date(v.branch_id, v.occurred_at), coalesce(a.opening_on, '-infinity'::date)))
  from bank_movements v left join cash_accounts a on a.id = v.cash_account_id where v.id = p_movement
$$;
revoke all on function fn_bank_entry_date(uuid) from public, anon, authenticated;

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
-- 5. What a movement can be matched with: the records of the same bank account, not matched yet
-- ---------------------------------------------------------------------------------------------------------------
-- one record as a candidate: {type, id, number, label, amount_halalas, signed_halalas, at, day, method}; null when it is
-- not one for this movement. signed_halalas is what it counts for in the movement's direction: a record that moved money
-- the other way counts below zero, and only a card-terminal one may (the card refunds inside a day's terminal deposit).
create or replace function fn_bank_target(p_movement uuid, p_type text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v bank_movements%rowtype; r jsonb;
begin
  select * into v from bank_movements where id = p_movement;
  if p_type = 'voucher' then
    select jsonb_build_object('type', 'voucher', 'id', f.id, 'number', f.number, 'amount_halalas', f.amount_halalas,
                              'signed_halalas', case when (f.kind::text in ('receipt', 'deposit')) = (v.direction = 'in') then f.amount_halalas else -f.amount_halalas end,
                              'at', f.occurred_at, 'day', fn_branch_date(f.branch_id, f.occurred_at), 'method', f.method::text,
                              'label', case f.kind::text when 'receipt' then 'سند قبض' when 'deposit' then 'قبض تأمين' when 'refund' then 'رد مبلغ' else 'رد تأمين' end
                                       || case f.method::text when 'pos' then ' (شبكة)' else ' (تحويل)' end)
      into r from financial_vouchers f
     where f.id = p_id and f.account_id = v.cash_account_id and f.status = 'approved' and f.method::text in ('bank_transfer', 'pos')
       -- a reversal pair (a correction of a settled day) moved no money: neither half is offered
       and f.reversal_of is null and not exists (select 1 from financial_vouchers x where x.reversal_of = f.id and x.status = 'approved')
       and f.kind::text in ('receipt', 'deposit', 'refund', 'deposit_refund')
       and ((f.kind::text in ('receipt', 'deposit')) = (v.direction = 'in') or f.method::text = 'pos');
  elsif p_type = 'expense' then
    select jsonb_build_object('type', 'expense', 'id', x.id, 'number', x.number, 'amount_halalas', x.amount_halalas, 'signed_halalas', x.amount_halalas,
                              'at', x.occurred_at, 'day', fn_branch_date(x.branch_id, x.occurred_at), 'method', null, 'label', 'سند صرف: ' || x.description)
      into r from expense_vouchers x where x.id = p_id and x.account_id = v.cash_account_id and x.status = 'approved' and v.direction = 'out';
  elsif p_type = 'platform_payout' then
    select jsonb_build_object('type', 'platform_payout', 'id', p.id, 'number', p.reference, 'amount_halalas', p.received_halalas, 'signed_halalas', p.received_halalas,
                              'at', p.received_on::timestamptz, 'day', p.received_on, 'method', null,
                              'label', 'دفعة منصة ' || coalesce((select name from booking_sources where id = p.source_id), ''))
      into r from platform_payouts p where p.id = p_id and p.account_id = v.cash_account_id and p.status = 'confirmed' and v.direction = 'in';
  end if;
  return r;
end $$;
revoke all on function fn_bank_target(uuid, text, uuid) from public, anon, authenticated;

-- the suggestions for a movement: the records within a week of it not matched to another movement, the same amount
-- first; and what each sent closing of those days says the card terminal took (to read the day's vouchers against)
create or replace function fn_bank_candidates(p_movement uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v bank_movements%rowtype; d date;
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.cash_account_id is null then return jsonb_build_object('records', '[]'::jsonb, 'pos_closings', '[]'::jsonb); end if;
  perform fn_require_branch(v.branch_id);
  d := fn_branch_date(v.branch_id, v.occurred_at);
  return jsonb_build_object(
    'records', coalesce((select jsonb_agg(c || jsonb_build_object('exact', (c->>'signed_halalas')::bigint = v.amount_halalas)
                                          order by abs((c->>'signed_halalas')::bigint - v.amount_halalas), abs(extract(epoch from (c->>'at')::timestamptz - v.occurred_at)), c->>'number')
                         from (select fn_bank_target(v.id, t.type, t.id) as c from (
                                 select 'voucher' as type, f.id from financial_vouchers f where f.account_id = v.cash_account_id and fn_branch_date(f.branch_id, f.occurred_at) between d - 7 and d + 1
                                 union all select 'expense', x.id from expense_vouchers x where x.account_id = v.cash_account_id and fn_branch_date(x.branch_id, x.occurred_at) between d - 7 and d + 1
                                 union all select 'platform_payout', p.id from platform_payouts p where p.account_id = v.cash_account_id and p.received_on between d - 7 and d + 1) t
                               where not exists (select 1 from bank_match_items i where i.active and i.target_type = t.type and i.target_id = t.id)) q
                         where c is not null), '[]'::jsonb),
    'pos_closings', coalesce((select jsonb_agg(jsonb_build_object('day', dc.business_date, 'entered_halalas', l.entered_halalas, 'system_halalas', l.system_halalas,
                                                                   'state', fn_day_closing_state(dc.status, dc.edit_until)) order by dc.business_date)
                              from day_closings dc join day_closing_lines l on l.closing_id = dc.id and l.line_key = 'pos'
                             where dc.branch_id = v.branch_id and dc.status = 'submitted' and l.account_id = v.cash_account_id
                               and dc.business_date between d - 7 and d + 1), '[]'::jsonb));
end $$;
revoke all on function fn_bank_candidates(uuid) from public, anon;
grant execute on function fn_bank_candidates(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Matching, undoing it, turning a movement into a voucher
-- ---------------------------------------------------------------------------------------------------------------
-- the owner matches a pending movement with the records that explain it: p_targets = [{type, id}, …]. Their total (in
-- the movement's direction) must be above zero; a total that differs from the movement needs a reason, and the
-- difference is booked: money in short of the records → the bank's fees (57); more → other income (49); money out the
-- other way round
create or replace function fn_bank_match(p_movement uuid, p_targets jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bank_movements%rowtype; t jsonb; r record; net bigint := 0; diff bigint; n int := 0; first_no text;
        v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); acc uuid; m uuid := gen_random_uuid(); d date;
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.status <> 'pending' then raise exception 'VALIDATION: movement_used'; end if;
  if v.cash_account_id is null then raise exception 'VALIDATION: movement_unassigned'; end if;
  perform fn_require_branch(v.branch_id);
  if p_targets is null or jsonb_typeof(p_targets) <> 'array' or jsonb_array_length(p_targets) not between 1 and 200 then raise exception 'VALIDATION: targets'; end if;
  if exists (select 1 from jsonb_array_elements(p_targets) e where jsonb_typeof(e) <> 'object' or coalesce(e->>'type', '') not in ('voucher', 'expense', 'platform_payout')) then
    raise exception 'VALIDATION: target_type';
  end if;
  if exists (select 1 from jsonb_array_elements(p_targets) e where coalesce(e->>'id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') then
    raise exception 'VALIDATION: target';
  end if;
  if v_reason is not null and char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  insert into bank_matches(id, organization_id, movement_id, kind, reason, created_by) values (m, v.organization_id, v.id, 'link', v_reason, fn_staff_id());
  -- every record in one order (type, id), so two matches never wait on each other
  for r in select distinct e->>'type' as type, (e->>'id')::uuid as id from jsonb_array_elements(p_targets) e order by 1, 2 loop
    -- the record is held while it is matched: a cancellation waits, then sees the match (and lets it go)
    if r.type = 'voucher' then perform 1 from financial_vouchers where id = r.id for share;
    elsif r.type = 'expense' then perform 1 from expense_vouchers where id = r.id for share;
    else perform 1 from platform_payouts where id = r.id for share;
    end if;
    perform pg_advisory_xact_lock(hashtext('bank_target:' || r.type || ':' || r.id::text));
    t := fn_bank_target(v.id, r.type, r.id);
    if t is null then raise exception 'VALIDATION: target'; end if;
    if exists (select 1 from bank_match_items where active and target_type = r.type and target_id = r.id) then raise exception 'VALIDATION: target_used'; end if;
    insert into bank_match_items(organization_id, match_id, target_type, target_id, amount_halalas)
    values (v.organization_id, m, r.type, r.id, (t->>'signed_halalas')::bigint);
    net := net + (t->>'signed_halalas')::bigint; n := n + 1; first_no := coalesce(first_no, t->>'number');
  end loop;
  if net <= 0 then raise exception 'VALIDATION: target_total'; end if;
  diff := v.amount_halalas - net;
  if diff <> 0 and v_reason is null then raise exception 'VALIDATION: difference_reason'; end if;
  update bank_matches set difference_halalas = diff where id = m;
  update bank_movements set status = 'matched' where id = v.id;
  if diff <> 0 then
    acc := fn_gl_for_cash(v.cash_account_id); d := fn_bank_entry_date(v.id);
    -- the bank moved diff more (+) or less (−) than the records booked: the bank account takes the difference
    perform fn_gl_post(v.organization_id, v.branch_id, d, 'bank_movement', v.id, 'diff:' || m::text,
                       'فرق مطابقة ' || first_no || case when n > 1 then ' وسجلات أخرى' else '' end || ': ' || v_reason,
                       case when (v.direction = 'in') = (diff > 0) then
                         jsonb_build_array(jsonb_build_object('account_id', acc, 'debit', abs(diff)), jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'other_income'), 'credit', abs(diff)))
                       else
                         jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'bank_fees'), 'debit', abs(diff)), jsonb_build_object('account_id', acc, 'credit', abs(diff))) end);
  end if;
  perform fn_audit_change(v.branch_id, 'bank_movement.matched', 'bank_movement', v.id, null,
                          jsonb_build_object('first', first_no, 'records', n, 'amount_halalas', v.amount_halalas, 'difference_halalas', diff), v_reason);
  return jsonb_build_object('ok', true, 'match_id', m, 'records', n, 'difference_halalas', diff);
end $$;
revoke all on function fn_bank_match(uuid, jsonb, text) from public, anon;
grant execute on function fn_bank_match(uuid, jsonb, text) to authenticated;

-- the release of a movement's match (by the owner, or because one of its records was cancelled): its records are free
-- again, what it booked is reversed, and the movement waits again
create or replace function fn_bank_release(p_match uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare m bank_matches%rowtype; v bank_movements%rowtype; mv uuid;
begin
  -- the movement first, then its match (the order matching and undoing take too); false when it was released already
  select movement_id into mv from bank_matches where id = p_match;
  if not found then return false; end if;
  select * into v from bank_movements where id = mv for update;
  select * into m from bank_matches where id = p_match and active for update;
  if not found then return false; end if;
  update bank_matches set active = false, released_at = now(), released_by = fn_staff_id(), release_reason = left(p_reason, 300) where id = m.id;
  update bank_match_items set active = false where match_id = m.id and active;
  perform fn_gl_reverse_live(v.id, 'diff:' || m.id::text, fn_branch_today(v.branch_id), p_reason);
  perform fn_gl_reverse_live(v.id, 'convert:' || m.id::text, fn_branch_today(v.branch_id), p_reason);
  update bank_movements set status = 'pending' where id = v.id;
  return true;
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
  if m.kind = 'convert' and exists (select 1 from bank_match_items where match_id = m.id and target_type = 'expense') then raise exception 'VALIDATION: cancel_the_expense'; end if;
  perform fn_bank_release(m.id, v_reason);
  perform fn_audit_change(v.branch_id, 'bank_movement.unmatched', 'bank_movement', v.id, jsonb_build_object('kind', m.kind, 'difference_halalas', m.difference_halalas), null, v_reason);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_bank_unmatch(uuid, text) from public, anon;
grant execute on function fn_bank_unmatch(uuid, text) to authenticated;

-- the owner turns a pending movement into its own voucher (p.as):
--   money out → 'expense': an expense voucher of the category chosen (its receipt is the bank's message), or
--               'fees': the bank's fees (57) against the bank account;
--   money in  → 'income': other income (49) against the bank account, with a description
create or replace function fn_bank_convert(p_movement uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bank_movements%rowtype; cat expense_categories%rowtype; v_desc text := nullif(btrim(coalesce(p->>'description', '')), ''); x expense_vouchers%rowtype;
        v_as text; m uuid := gen_random_uuid(); je uuid; d date; d0 date; acc uuid;
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.status <> 'pending' then raise exception 'VALIDATION: movement_used'; end if;
  if v.cash_account_id is null then raise exception 'VALIDATION: movement_unassigned'; end if;
  perform fn_require_branch(v.branch_id);
  if exists (select 1 from cash_accounts where id = v.cash_account_id and archived_at is not null) then raise exception 'VALIDATION: account_archived'; end if;
  v_as := coalesce(nullif(p->>'as', ''), case when v.direction = 'out' then 'expense' else 'income' end);
  if not ((v.direction = 'out' and v_as in ('expense', 'fees')) or (v.direction = 'in' and v_as = 'income')) then raise exception 'VALIDATION: convert_as'; end if;
  -- fees say what they are; an expense and an income are described
  if v_desc is null and v_as = 'fees' then v_desc := case when v.kind = 'pos_fee' then 'رسوم نقاط البيع' else 'رسوم بنكية' end; end if;
  if v_desc is null or char_length(v_desc) > 300 then raise exception 'VALIDATION: description'; end if;
  -- the movement's day while its month is open, otherwise today
  d0 := fn_branch_date(v.branch_id, v.occurred_at); d := fn_bank_entry_date(v.id);
  insert into bank_matches(id, organization_id, movement_id, kind, reason, created_by) values (m, v.organization_id, v.id, 'convert', v_desc, fn_staff_id());
  update bank_movements set status = 'converted' where id = v.id;
  if v_as = 'expense' then
    if coalesce(p->>'category_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'VALIDATION: category'; end if;
    select * into cat from expense_categories where id = (p->>'category_id')::uuid and organization_id = v.organization_id and is_active;
    if not found then raise exception 'VALIDATION: category'; end if;
    insert into expense_vouchers(organization_id, branch_id, number, account_id, category_id, amount_halalas, occurred_at, payee, description, reference, created_by)
    values (v.organization_id, v.branch_id, fn_next_document_number(v.organization_id, 'expense', 'EXP'), v.cash_account_id, cat.id, v.amount_halalas,
            case when d = d0 then v.occurred_at when d = fn_branch_today(v.branch_id) then now()
                 else (d::timestamp + interval '12 hours') at time zone coalesce((select timezone from branches where id = v.branch_id), 'Asia/Riyadh') end,
            null, v_desc, coalesce(v.reference, 'حركة بنكية'), fn_staff_id())
    returning * into x;
    insert into bank_match_items(organization_id, match_id, target_type, target_id, amount_halalas) values (v.organization_id, m, 'expense', x.id, v.amount_halalas);
    perform fn_audit_change(v.branch_id, 'expense.created', 'expense_voucher', x.id, null, jsonb_build_object('number', x.number, 'amount_halalas', x.amount_halalas, 'from', 'bank_movement'), v_desc);
  else
    acc := fn_gl_for_cash(v.cash_account_id);
    je := fn_gl_post(v.organization_id, v.branch_id, d, 'bank_movement', v.id, 'convert:' || m::text,
                     case when v_as = 'fees' then 'رسوم بنكية من حركة: ' else 'إيراد من حركة بنكية: ' end || v_desc,
                     case when v_as = 'fees' then
                       jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'bank_fees'), 'debit', v.amount_halalas),
                                         jsonb_build_object('account_id', acc, 'credit', v.amount_halalas))
                     else
                       jsonb_build_array(jsonb_build_object('account_id', acc, 'debit', v.amount_halalas),
                                         jsonb_build_object('account_id', fn_gl_system(v.organization_id, 'other_income'), 'credit', v.amount_halalas)) end);
    insert into bank_match_items(organization_id, match_id, target_type, target_id, amount_halalas) values (v.organization_id, m, 'journal', je, v.amount_halalas);
  end if;
  perform fn_audit_change(v.branch_id, 'bank_movement.converted', 'bank_movement', v.id, null,
                          jsonb_build_object('as', v_as, 'direction', v.direction, 'amount_halalas', v.amount_halalas, 'expense', x.number), v_desc);
  return jsonb_build_object('ok', true, 'match_id', m, 'as', v_as, 'expense_id', x.id, 'expense_number', x.number);
end $$;
revoke all on function fn_bank_convert(uuid, jsonb) from public, anon;
grant execute on function fn_bank_convert(uuid, jsonb) to authenticated;

-- a record that is cancelled, or a voucher reversed by a correction (a settled day keeps the original and adds its
-- reversal), lets its movement go: the whole match is released (its other records are free again) and the movement
-- waits again
create or replace function fn_trg_bank_release_target() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; t text := case tg_table_name when 'financial_vouchers' then 'voucher' when 'expense_vouchers' then 'expense' else 'platform_payout' end;
        tid uuid; why text;
begin
  if tg_op = 'INSERT' then
    if new.reversal_of is null or new.status <> 'approved' then return null; end if;
    tid := new.reversal_of; why := 'عُكس سند من المطابقة';
  elsif new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    tid := new.id; why := 'أُلغي سجل من المطابقة';
  else
    return null;
  end if;
  for r in select i.match_id, bm.movement_id, bv.branch_id from bank_match_items i join bank_matches bm on bm.id = i.match_id join bank_movements bv on bv.id = bm.movement_id
            where i.active and i.target_type = t and i.target_id = tid loop
    if fn_bank_release(r.match_id, why) then
      perform fn_audit_change(r.branch_id, 'bank_movement.unmatched', 'bank_movement', r.movement_id,
                              jsonb_build_object('by', case when tg_op = 'INSERT' then 'record_reversed' else 'record_cancelled' end, 'type', t), null, why);
    end if;
  end loop;
  return null;
end $$;
revoke all on function fn_trg_bank_release_target() from public, anon, authenticated;
create or replace trigger trg_bank_release_voucher after update of status on financial_vouchers for each row execute function fn_trg_bank_release_target();
create or replace trigger trg_bank_release_reversal after insert on financial_vouchers for each row when (new.reversal_of is not null) execute function fn_trg_bank_release_target();
create or replace trigger trg_bank_release_expense after update of status on expense_vouchers for each row execute function fn_trg_bank_release_target();
create or replace trigger trg_bank_release_payout after update of status on platform_payouts for each row execute function fn_trg_bank_release_target();

-- ---------------------------------------------------------------------------------------------------------------
-- 7. The movements list carries what each one is matched with
-- ---------------------------------------------------------------------------------------------------------------
-- a matched record's label (whatever its state now)
create or replace function fn_bank_target_label(p_type text, p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case p_type
    when 'voucher' then (select 'سند ' || number from financial_vouchers where id = p_id)
    when 'expense' then (select 'سند صرف ' || number || ': ' || description from expense_vouchers where id = p_id)
    when 'platform_payout' then (select 'دفعة منصة ' || reference from platform_payouts where id = p_id)
  end
$$;
revoke all on function fn_bank_target_label(text, uuid) from public, anon, authenticated;

-- what a match says in one line: its record, its records (the first six numbers), or what the movement was turned into
create or replace function fn_bank_match_label(p_match uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from bank_match_items i where i.match_id = m.id and i.target_type = 'journal')
      then case when v.direction = 'in' then 'إيراد آخر: ' else 'رسوم بنكية: ' end || coalesce(m.reason, '')
    when (select count(*) from bank_match_items i where i.match_id = m.id) = 1
      then coalesce((select fn_bank_target_label(i.target_type, i.target_id) from bank_match_items i where i.match_id = m.id), '')
    else 'السجلات (' || (select count(*) from bank_match_items i where i.match_id = m.id) || '): '
         || coalesce((select string_agg(x.n, '، ' order by x.n) from (
               select case i.target_type when 'voucher' then (select number from financial_vouchers where id = i.target_id)
                                         when 'expense' then (select number from expense_vouchers where id = i.target_id)
                                         else (select reference from platform_payouts where id = i.target_id) end as n
                 from bank_match_items i where i.match_id = m.id order by 1 limit 6) x), '')
         || case when (select count(*) from bank_match_items i where i.match_id = m.id) > 6 then '…' else '' end
  end
  from bank_matches m join bank_movements v on v.id = m.movement_id where m.id = p_match
$$;
revoke all on function fn_bank_match_label(uuid) from public, anon, authenticated;

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
                                                       'match', (select jsonb_build_object('kind', x.kind, 'difference_halalas', x.difference_halalas, 'reason', x.reason,
                                                                                           'type', (select min(i.target_type) from bank_match_items i where i.match_id = x.id),
                                                                                           'records', (select count(*) from bank_match_items i where i.match_id = x.id),
                                                                                           'label', fn_bank_match_label(x.id))
                                                                 from bank_matches x where x.movement_id = v.id and x.active)) order by v.occurred_at desc, v.created_at desc)
                   from bank_movements v join bank_messages m on m.id = v.message_id
                   left join branches b on b.id = v.branch_id left join cash_accounts a on a.id = v.cash_account_id
                   where v.organization_id = fn_user_org_id() and fn_branch_date(v.branch_id, v.occurred_at) between p_from and p_to
                     and (case when p_branch is null then true else v.branch_id = p_branch end)
                     -- only the branches one works in; the unassigned ones (no branch yet) for who manages the bank
                     and (v.branch_id in (select fn_user_branch_ids()) or v.branch_id is null)), '[]'::jsonb);
end $$;
revoke all on function fn_bank_movements(uuid, date, date) from public, anon;
grant execute on function fn_bank_movements(uuid, date, date) to authenticated;

-- the messages (0066) of a movement in a branch one does not work in stay unseen; one with no movement, or of a movement
-- not assigned yet, is seen by who manages the bank
alter policy "bank_messages_read" on bank_messages
  using (organization_id = fn_user_org_id() and fn_can('bank.manage')
         and (movement_id is null or movement_id in (select id from bank_movements)));
create or replace function fn_bank_messages(p_status text default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('bank.manage');
  if p_status is not null and p_status not in ('received', 'rejected', 'unparsed', 'parsed', 'duplicate_movement') then raise exception 'VALIDATION: status'; end if;
  return coalesce((select jsonb_agg(x order by x->>'received_at' desc) from (
    select jsonb_build_object('id', m.id, 'received_at', m.received_at, 'mail_from', m.mail_from, 'sms_sender', m.sms_sender, 'channel', m.channel,
                              'sms_received_at', m.sms_received_at, 'text', coalesce(m.sms_text, left(m.raw_body, 2000)), 'status', m.status,
                              'reason', m.reject_reason, 'movement_id', m.movement_id) as x
    from bank_messages m left join bank_movements v on v.id = m.movement_id
    where m.organization_id = fn_user_org_id() and (p_status is null or m.status = p_status)
      and (v.id is null or v.branch_id is null or v.branch_id in (select fn_user_branch_ids()))
    order by m.received_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) q), '[]'::jsonb);
end $$;
revoke all on function fn_bank_messages(text, int) from public, anon;
grant execute on function fn_bank_messages(text, int) to authenticated;

-- a movement is assigned only to the bank account of a branch one works in
create or replace function fn_bank_assign_account(p_movement uuid, p_account uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bank_movements%rowtype; a cash_accounts%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.cash_account_id is not null then raise exception 'VALIDATION: movement_assigned'; end if;
  if v_reason is null or char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  select * into a from cash_accounts where id = p_account and organization_id = v.organization_id and kind = 'bank_account' and archived_at is null;
  if not found then raise exception 'VALIDATION: account'; end if;
  perform fn_require_branch(a.branch_id);
  update bank_movements set cash_account_id = a.id, branch_id = a.branch_id where id = v.id;
  perform fn_audit_change(a.branch_id, 'bank_movement.assigned', 'bank_movement', v.id, null, jsonb_build_object('account', a.name, 'amount_halalas', v.amount_halalas), v_reason);
  return jsonb_build_object('ok', true, 'branch_id', a.branch_id);
end $$;
revoke all on function fn_bank_assign_account(uuid, uuid, text) from public, anon;
grant execute on function fn_bank_assign_account(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 8. The ledger of a box or a bank account (0064) shows what the books hold: besides its vouchers, payouts and
--    expenses, the entries that have no voucher of their own are lines of it too — a match's difference, a movement
--    turned into fees or income, a closing's cash difference (0065), and their reversals. So the ledger ends where the
--    journal stands, and a bank account matched to the bank's messages ends where the bank says.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_account_movements(p_account uuid) returns table(at timestamptz, kind text, number text, description text, in_halalas bigint, out_halalas bigint, ref_id uuid)
language sql stable security definer set search_path = public as $$
  select fv.occurred_at, fv.kind::text, fv.number, coalesce(fv.reference, ''),
         case when fv.kind in ('receipt', 'deposit') then fv.amount_halalas else 0 end,
         case when fv.kind in ('refund', 'deposit_refund') then fv.amount_halalas else 0 end, fv.id
  from financial_vouchers fv where fv.account_id = p_account and fv.status = 'approved' and fv.kind in ('receipt', 'deposit', 'refund', 'deposit_refund')
  union all
  select (pp.received_on::timestamp + interval '12 hours') at time zone coalesce((select timezone from branches where id = pp.branch_id), 'Asia/Riyadh'),
         'platform_payout', pp.reference, 'دفعة منصة', pp.received_halalas, 0, pp.id
  from platform_payouts pp where pp.account_id = p_account and pp.status = 'confirmed'
  union all
  select ev.occurred_at, 'expense', ev.number, ev.description, 0, ev.amount_halalas, ev.id
  from expense_vouchers ev where ev.account_id = p_account and ev.status = 'approved'
  union all
  -- an entry of a bank movement stands at the movement's time when it is dated on its day, otherwise when it was written;
  -- a closing's difference stands at the end of its day
  -- (moved to its account's opening day, or written on another day: noon of its date; a reversal: when it was written)
  select case when je.source_type = 'bank_movement'
              then coalesce((select bm.occurred_at from bank_movements bm
                              where bm.id = je.source_id and je.reversal_of is null and je.entry_date = fn_branch_date(bm.branch_id, bm.occurred_at)),
                            case when je.entry_date = fn_branch_date(je.branch_id, je.created_at) then je.created_at
                                 else (je.entry_date::timestamp + interval '12 hours') at time zone coalesce((select timezone from branches where id = je.branch_id), 'Asia/Riyadh') end)
              else ((je.entry_date + 1)::timestamp at time zone coalesce((select timezone from branches where id = je.branch_id), 'Asia/Riyadh')) - interval '1 second' end,
         case je.source_type when 'bank_movement' then 'bank_adjustment' else 'closing_difference' end,
         je.number, je.description, jl.debit_halalas, jl.credit_halalas, je.id
  from journal_lines jl join journal_entries je on je.id = jl.entry_id
  where jl.account_id in (select g.id from gl_accounts g where g.cash_account_id = p_account)
    and je.source_type in ('bank_movement', 'day_closing')
$$;
revoke all on function fn_account_movements(uuid) from public, anon, authenticated;
