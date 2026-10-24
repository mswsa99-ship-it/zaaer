-- =====================================================================
-- 0028 — Core money (Phase 1)
--
--  · Four payment methods for new receipts and refunds: cash, card terminal ("pos", شبكة), bank transfer, and
--    deferred via the booking platform. Older methods stay on the vouchers that used them (decisions 24, 48).
--  · Cash boxes and bank accounts per branch, with a default for each kind. Every receipt or refund carries one:
--    cash → a cash box; terminal and transfer → a bank account; the platform → none. Used ones are archived,
--    never removed. Entries only: no running balance, no bank deposits of cash, no stock-taking, no ledger (25).
--  · The transaction number is required for terminal and transfer payments (13).
--  · The daily card-terminal settlement: what the terminal says against the terminal vouchers; a difference is
--    recorded with its explanation for the owner's review (13).
--  · The monthly platform payout matching: deferred platform payments are confirmed against what the platform
--    paid into the bank (24).
--  · Tax zero in every branch, changed by the owner only, and a tax snapshot on each reservation so a later change
--    only affects new reservations (68). The deposit default is 50 SAR, per unit (33, 69).
--  · Amounts are whole halalas; anything else is refused with a clear validation error (47, F09).
--
-- This file only adds and updates; it never removes data (it is applied through the SQL tools, which refuse that).
-- =====================================================================

select set_config('app.source', 'migration', true);

-- ---------------------------------------------------------------- 1. cash boxes and bank accounts
create table if not exists cash_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  kind text not null,
  name text not null,
  bank_name text,
  account_last4 text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  archived_at timestamptz,
  archived_by uuid,
  archive_reason text,
  version int not null default 1,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cash_account_kind_valid check (kind in ('cash_box', 'bank_account')),
  constraint cash_account_last4_valid check (account_last4 is null or account_last4 ~ '^[0-9]{4}$'),
  constraint cash_account_bank_only check (kind = 'bank_account' or (bank_name is null and account_last4 is null))
);
create unique index if not exists uniq_cash_account_name on cash_accounts(branch_id, lower(name)) where archived_at is null;
create unique index if not exists uniq_cash_account_default on cash_accounts(branch_id, kind) where is_default and archived_at is null;
alter table cash_accounts enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'cash_accounts' and policyname = 'money_staff_cash_accounts_read') then
    create policy "money_staff_cash_accounts_read" on cash_accounts for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner', 'manager', 'supervisor', 'finance'));
  end if;
end $$;
revoke insert, update on cash_accounts from anon, authenticated;

-- every branch starts with a cash box and a bank account it can rename (new branches get them in fn_admin_upsert_branch)
create or replace function fn_bootstrap_cash_accounts(p_branch uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; a cash_accounts%rowtype;
begin
  select * into b from branches where id = p_branch;
  if not found then return; end if;
  if not exists (select 1 from cash_accounts where branch_id = b.id and kind = 'cash_box') then
    insert into cash_accounts(organization_id, branch_id, kind, name, is_default) values (b.organization_id, b.id, 'cash_box', 'الصندوق الرئيسي', true) returning * into a;
    perform fn_audit_change(b.id, 'cash_account.created', 'cash_account', a.id, null, to_jsonb(a), 'حساب أولي للفرع');
  end if;
  if not exists (select 1 from cash_accounts where branch_id = b.id and kind = 'bank_account') then
    insert into cash_accounts(organization_id, branch_id, kind, name, is_default) values (b.organization_id, b.id, 'bank_account', 'الحساب البنكي الرئيسي', true) returning * into a;
    perform fn_audit_change(b.id, 'cash_account.created', 'cash_account', a.id, null, to_jsonb(a), 'حساب أولي للفرع');
  end if;
end $$;
revoke all on function fn_bootstrap_cash_accounts(uuid) from public, anon, authenticated;
select fn_bootstrap_cash_accounts(id) from branches;
-- however a branch is created (the admin screen, a seed, an import), it has its two accounts from the start
create or replace function fn_branch_bootstrap_accounts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform fn_bootstrap_cash_accounts(new.id);
  return new;
end $$;
create or replace trigger trg_branch_bootstrap_accounts after insert on branches for each row execute function fn_branch_bootstrap_accounts();

-- the owner or manager defines them; a default per kind; name changes keep the vouchers that used the account
create or replace function fn_admin_upsert_cash_account(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
        v_kind text := p->>'kind'; v_name text := trim(coalesce(p->>'name', '')); v_default boolean := coalesce((p->>'is_default')::boolean, false);
        v_last4 text := nullif(trim(coalesce(p->>'account_last4', '')), ''); v_bank text := nullif(trim(coalesce(p->>'bank_name', '')), '');
begin
  perform fn_require_role('owner', 'manager');
  if v_name = '' or length(v_name) > 60 then raise exception 'VALIDATION: name'; end if;
  if v_last4 is not null and v_last4 !~ '^[0-9]{4}$' then raise exception 'VALIDATION: account_last4'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    if v_kind not in ('cash_box', 'bank_account') then raise exception 'VALIDATION: kind'; end if;
    if v_kind = 'cash_box' then v_last4 := null; v_bank := null; end if;
    if exists (select 1 from cash_accounts where branch_id = v_branch and lower(name) = lower(v_name) and archived_at is null) then raise exception 'DUPLICATE_NAME'; end if;
    if v_default then update cash_accounts set is_default = false, version = version + 1, updated_at = now() where branch_id = v_branch and kind = v_kind and is_default and archived_at is null; end if;
    insert into cash_accounts(organization_id, branch_id, kind, name, bank_name, account_last4, is_default, created_by)
    values ((select organization_id from branches where id = v_branch), v_branch, v_kind, v_name, v_bank, v_last4,
            v_default or not exists (select 1 from cash_accounts where branch_id = v_branch and kind = v_kind and is_default and archived_at is null), fn_staff_id())
    returning * into a;
    perform fn_audit_change(a.branch_id, 'cash_account.created', 'cash_account', a.id, null, to_jsonb(a));
  else
    select * into a from cash_accounts where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(a.branch_id);
    perform fn_check_version_strict(a.version, (p->>'version')::int);
    if a.archived_at is not null then raise exception 'VALIDATION: account_archived'; end if;
    if exists (select 1 from cash_accounts where branch_id = a.branch_id and lower(name) = lower(v_name) and archived_at is null and id <> a.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(a);
    if v_default and not a.is_default then
      update cash_accounts set is_default = false, version = version + 1, updated_at = now() where branch_id = a.branch_id and kind = a.kind and is_default and archived_at is null;
    end if;
    update cash_accounts set name = v_name,
      bank_name = case when kind = 'bank_account' then v_bank end, account_last4 = case when kind = 'bank_account' then v_last4 end,
      is_default = case when v_default then true when (p ? 'is_default') then false else is_default end,
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = a.id returning * into a;
    perform fn_audit_change(a.branch_id, 'cash_account.updated', 'cash_account', a.id, before, to_jsonb(a));
  end if;
  return jsonb_build_object('ok', true, 'id', a.id, 'version', a.version);
end $$;
revoke all on function fn_admin_upsert_cash_account(jsonb) from public, anon;
grant execute on function fn_admin_upsert_cash_account(jsonb) to authenticated;

-- archive / restore (a used account keeps its vouchers; an archived one is never offered again)
create or replace function fn_admin_archive_cash_account(p_id uuid, p_archive boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; before jsonb; used int;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into a from cash_accounts where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(a.branch_id);
  before := to_jsonb(a);
  select count(*) into used from financial_vouchers where account_id = a.id;
  if p_archive then
    if a.archived_at is not null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update cash_accounts set archived_at = now(), archived_by = fn_staff_id(), archive_reason = p_reason, is_default = false,
                             version = version + 1, updated_at = now() where id = a.id returning * into a;
  else
    if a.archived_at is null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    if exists (select 1 from cash_accounts where branch_id = a.branch_id and lower(name) = lower(a.name) and archived_at is null and id <> a.id) then raise exception 'DUPLICATE_NAME'; end if;
    update cash_accounts set archived_at = null, archived_by = null, archive_reason = null, version = version + 1, updated_at = now() where id = a.id returning * into a;
  end if;
  perform fn_audit_change(a.branch_id, case when p_archive then 'cash_account.archived' else 'cash_account.restored' end, 'cash_account', a.id, before, to_jsonb(a), p_reason);
  return jsonb_build_object('ok', true, 'used_by_vouchers', used,
    'default_missing', not exists (select 1 from cash_accounts where branch_id = a.branch_id and kind = a.kind and is_default and archived_at is null));
end $$;
revoke all on function fn_admin_archive_cash_account(uuid, boolean, text) from public, anon;
grant execute on function fn_admin_archive_cash_account(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------- 2. vouchers carry their account
alter table financial_vouchers add column if not exists account_id uuid references cash_accounts(id);
create index if not exists idx_vouchers_account_time on financial_vouchers(account_id, occurred_at) where account_id is not null;

-- the four methods a new receipt or refund may use (older ones stay readable on their vouchers)
create or replace function fn_payment_method_active(p_method text) returns boolean
language sql immutable set search_path = public as $$ select p_method in ('cash', 'pos', 'bank_transfer', 'ota_deferred') $$;

-- which account a voucher of this method uses: the one given (checked) or the branch default of its kind
create or replace function fn_voucher_account(p_branch uuid, p_method text, p_account uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare want text; a cash_accounts%rowtype;
begin
  want := case p_method when 'cash' then 'cash_box' when 'pos' then 'bank_account' when 'bank_transfer' then 'bank_account' end;
  if want is null then
    if p_account is not null then raise exception 'VALIDATION: account_not_allowed'; end if;
    return null;
  end if;
  if p_account is not null then
    select * into a from cash_accounts where id = p_account;
    if not found or a.branch_id <> p_branch then raise exception 'BRANCH_MISMATCH: account'; end if;
    if a.kind <> want then raise exception 'VALIDATION: account_kind'; end if;
    if a.archived_at is not null or not a.is_active then raise exception 'VALIDATION: account_archived'; end if;
    return a.id;
  end if;
  select * into a from cash_accounts where branch_id = p_branch and kind = want and is_default and archived_at is null and is_active;
  if not found then raise exception 'VALIDATION: account_required'; end if;
  return a.id;
end $$;
revoke all on function fn_voucher_account(uuid, text, uuid) from public, anon, authenticated;

-- a whole, positive number of halalas (F09: zero, negative, fractions and text are refused with one clear error)
create or replace function fn_parse_halalas(p_value text) returns bigint
language plpgsql immutable set search_path = public as $$
begin
  if p_value is null or p_value !~ '^[0-9]{1,15}$' then raise exception 'VALIDATION: amount'; end if;
  if p_value::bigint <= 0 then raise exception 'VALIDATION: amount'; end if;
  return p_value::bigint;
end $$;

-- the transaction number of a terminal or transfer payment (decision 13)
create or replace function fn_check_payment_reference(p_method text, p_reference text) returns text
language plpgsql immutable set search_path = public as $$
declare ref text := nullif(trim(coalesce(p_reference, '')), '');
begin
  if p_method in ('pos', 'bank_transfer') then
    if ref is null then raise exception 'VALIDATION: reference_required'; end if;
    if length(ref) < 3 or length(ref) > 60 then raise exception 'VALIDATION: reference'; end if;
  end if;
  return ref;
end $$;

-- receipts and deposits (G10, G11, G13; decisions 13, 24, 25)
create or replace function fn_create_voucher(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; prefix text; m text := p->>'method'; ref text; acc uuid;
begin
  if kind not in ('receipt', 'deposit') then raise exception 'VALIDATION: kind'; end if;
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  amt := fn_parse_halalas(p->>'amount_halalas');
  if coalesce(trim(key), '') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  if m is null then raise exception 'VALIDATION: method'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- serialises money ops per reservation
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  -- the requested content (a replay with the same key must ask for exactly the same thing)
  h := md5(r.id::text || kind || amt::text || m || coalesce(p->>'reference', '') || coalesce(p->>'account_id', ''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;   -- F08
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if not fn_payment_method_active(m) then raise exception 'VALIDATION: method_retired'; end if;
  -- the deposit is held and returned by the property itself; a platform never collects it (decisions 24, 33)
  if kind = 'deposit' and m = 'ota_deferred' then raise exception 'VALIDATION: deposit_method'; end if;
  if r.status in ('cancelled', 'rejected', 'no_show') and kind = 'deposit' then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  ref := fn_check_payment_reference(m, p->>'reference');
  acc := fn_voucher_account(r.branch_id, m, (p->>'account_id')::uuid);
  prefix := case kind when 'receipt' then 'RCP' else 'DEP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc, 'approved',
          ref, p->>'note', p->>'reason', key, h, coalesce((p->>'occurred_at')::timestamptz, now()), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', v.method, 'account_id', acc, 'reference', v.reference, 'reservation_id', r.id));
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_create_voucher(jsonb) to authenticated;

-- refunds: never above what is available, even under concurrency (G12/F05/F06/X02); a refund leaves through an account too
create or replace function fn_refund(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; f jsonb; available bigint; prefix text; m text; ref text; acc uuid;
begin
  if kind not in ('refund', 'deposit_refund', 'deposit_apply') then raise exception 'VALIDATION: kind'; end if;
  perform fn_require_role('owner', 'manager', 'finance');
  amt := fn_parse_halalas(p->>'amount_halalas');
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'VALIDATION: reason'; end if;
  if coalesce(trim(key), '') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  -- applying the deposit to the stay moves money between two balances of the same guest: no method, no account
  m := case when kind = 'deposit_apply' then 'cash' else p->>'method' end;
  if m is null then raise exception 'VALIDATION: method'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- concurrent refunds are serialised here
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  h := md5(r.id::text || kind || amt::text || coalesce(p->>'method', '') || coalesce(p->>'reference', '') || coalesce(p->>'account_id', ''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if kind <> 'deposit_apply' then
    if not fn_payment_method_active(m) then raise exception 'VALIDATION: method_retired'; end if;
    if kind = 'deposit_refund' and m = 'ota_deferred' then raise exception 'VALIDATION: deposit_method'; end if;
    ref := fn_check_payment_reference(m, p->>'reference');
    acc := fn_voucher_account(r.branch_id, m, (p->>'account_id')::uuid);
  end if;
  f := fn_reservation_finance_internal(r.id);
  available := case kind when 'refund' then (f->>'received')::bigint - (f->>'refunded')::bigint else (f->>'deposit_balance')::bigint end;
  if amt > available then raise exception 'REFUND_EXCEEDS_AVAILABLE: available % halalas', available; end if;
  if kind = 'deposit_apply' and amt > (f->>'balance_due')::bigint then raise exception 'REFUND_EXCEEDS_AVAILABLE: nothing due'; end if;
  prefix := case kind when 'refund' then 'RFD' when 'deposit_refund' then 'DRF' else 'DAP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, original_voucher_id, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc,
          'approved', ref, p->>'note', p->>'reason', (p->>'original_voucher_id')::uuid, key, h, now(), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', case when kind = 'deposit_apply' then null else m end, 'account_id', acc, 'reservation_id', r.id, 'available_before', available), p->>'reason');
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_refund(jsonb) to authenticated;

-- ---------------------------------------------------------------- 3. the daily card-terminal settlement (decision 13)
create table if not exists pos_settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  account_id uuid not null references cash_accounts(id),
  business_date date not null,
  terminal_total_halalas bigint not null,
  system_total_halalas bigint not null,
  difference_halalas bigint not null,
  voucher_count int not null default 0,
  status text not null,
  note text,
  version int not null default 1,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint pos_settlement_status_valid check (status in ('matched', 'difference'))
);
create unique index if not exists uniq_pos_settlement_day on pos_settlements(account_id, business_date);
create index if not exists idx_pos_settlement_branch_day on pos_settlements(branch_id, business_date desc);
alter table pos_settlements enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'pos_settlements' and policyname = 'money_staff_pos_settlements_read') then
    create policy "money_staff_pos_settlements_read" on pos_settlements for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner', 'manager', 'supervisor', 'finance'));
  end if;
end $$;
revoke insert, update on pos_settlements from anon, authenticated;

-- what the terminal vouchers of one account add up to on one branch-local day: taken in, minus paid back
create or replace function fn_pos_day_total(p_branch uuid, p_account uuid, p_date date) returns jsonb
language sql stable security definer set search_path = public as $$
  with day as (
    select (p_date::timestamp at time zone tz) as t0, ((p_date + 1)::timestamp at time zone tz) as t1
    from (select coalesce(timezone, 'Asia/Riyadh') as tz from branches where id = p_branch) b
  ), v as (
    select fv.* from financial_vouchers fv, day
    where fv.branch_id = p_branch and fv.account_id = p_account and fv.method = 'pos' and fv.status = 'approved'
      and fv.occurred_at >= day.t0 and fv.occurred_at < day.t1
  )
  select jsonb_build_object(
    'in_halalas', coalesce((select sum(amount_halalas) from v where kind in ('receipt', 'deposit')), 0),
    'out_halalas', coalesce((select sum(amount_halalas) from v where kind in ('refund', 'deposit_refund')), 0),
    'system_total_halalas', coalesce((select sum(case when kind in ('receipt', 'deposit') then amount_halalas else -amount_halalas end) from v where kind <> 'deposit_apply'), 0),
    'voucher_count', (select count(*) from v where kind <> 'deposit_apply'),
    'vouchers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', number, 'kind', kind, 'amount_halalas', amount_halalas, 'reference', reference, 'occurred_at', occurred_at) order by occurred_at)
                          from v where kind <> 'deposit_apply'), '[]'::jsonb));
$$;
revoke all on function fn_pos_day_total(uuid, uuid, date) from public, anon, authenticated;

create or replace function fn_pos_settlement_preview(p_branch uuid, p_account uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a cash_accounts%rowtype; s pos_settlements%rowtype;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  perform fn_require_branch(p_branch);
  select * into a from cash_accounts where id = p_account and branch_id = p_branch and kind = 'bank_account';
  if not found then raise exception 'BRANCH_MISMATCH: account'; end if;
  select * into s from pos_settlements where account_id = p_account and business_date = p_date;
  return fn_pos_day_total(p_branch, p_account, p_date) || jsonb_build_object('settlement', case when s.id is null then null else to_jsonb(s) end);
end $$;
revoke all on function fn_pos_settlement_preview(uuid, uuid, date) from public, anon;
grant execute on function fn_pos_settlement_preview(uuid, uuid, date) to authenticated;

create or replace function fn_pos_settle(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_account uuid := (p->>'account_id')::uuid; v_date date := (p->>'business_date')::date;
        a cash_accounts%rowtype; s pos_settlements%rowtype; t jsonb; terminal bigint; sys bigint; diff bigint; v_note text := nullif(trim(coalesce(p->>'note', '')), ''); before jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  perform fn_require_branch(v_branch);
  select * into a from cash_accounts where id = v_account and branch_id = v_branch and kind = 'bank_account';
  if not found then raise exception 'BRANCH_MISMATCH: account'; end if;
  if v_date is null or v_date > fn_branch_today(v_branch) then raise exception 'VALIDATION: business_date'; end if;
  if (p->>'terminal_total_halalas') is null or (p->>'terminal_total_halalas') !~ '^-?[0-9]{1,15}$' then raise exception 'VALIDATION: amount'; end if;
  terminal := (p->>'terminal_total_halalas')::bigint;
  t := fn_pos_day_total(v_branch, v_account, v_date);
  sys := (t->>'system_total_halalas')::bigint;
  diff := terminal - sys;
  if diff <> 0 and v_note is null then raise exception 'VALIDATION: note_required'; end if;   -- a difference is always explained
  select * into s from pos_settlements where account_id = v_account and business_date = v_date for update;
  if found then
    perform fn_check_version_strict(s.version, (p->>'version')::int);
    before := to_jsonb(s);
    update pos_settlements set terminal_total_halalas = terminal, system_total_halalas = sys, difference_halalas = diff,
      voucher_count = (t->>'voucher_count')::int, status = case when diff = 0 then 'matched' else 'difference' end, note = v_note,
      version = version + 1, updated_by = fn_staff_id(), updated_at = now()
    where id = s.id returning * into s;
  else
    insert into pos_settlements(organization_id, branch_id, account_id, business_date, terminal_total_halalas, system_total_halalas, difference_halalas, voucher_count, status, note, created_by, updated_by)
    values (a.organization_id, v_branch, v_account, v_date, terminal, sys, diff, (t->>'voucher_count')::int, case when diff = 0 then 'matched' else 'difference' end, v_note, fn_staff_id(), fn_staff_id())
    returning * into s;
  end if;
  perform fn_audit_change(v_branch, 'pos.settled', 'pos_settlement', s.id, before, to_jsonb(s), v_note);
  return jsonb_build_object('ok', true, 'settlement', to_jsonb(s));
end $$;
revoke all on function fn_pos_settle(jsonb) from public, anon;
grant execute on function fn_pos_settle(jsonb) to authenticated;

-- ---------------------------------------------------------------- 4. the monthly platform payout matching (decision 24)
create table if not exists platform_payouts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  source_id uuid not null references booking_sources(id),
  account_id uuid not null references cash_accounts(id),
  expected_halalas bigint not null,
  received_halalas bigint not null,
  difference_halalas bigint not null,
  voucher_count int not null,
  received_on date not null,
  reference text not null,
  note text,
  status text not null default 'confirmed',
  created_by uuid,
  created_at timestamptz not null default now(),
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancel_reason text,
  constraint platform_payout_status_valid check (status in ('confirmed', 'cancelled')),
  constraint platform_payout_received_valid check (received_halalas >= 0)
);
create index if not exists idx_platform_payouts_branch on platform_payouts(branch_id, received_on desc);
alter table platform_payouts enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'platform_payouts' and policyname = 'money_platform_payouts_read') then
    create policy "money_platform_payouts_read" on platform_payouts for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner', 'manager', 'finance'));
  end if;
end $$;
revoke insert, update on platform_payouts from anon, authenticated;
alter table financial_vouchers add column if not exists payout_id uuid references platform_payouts(id);
create index if not exists idx_vouchers_unsettled_platform on financial_vouchers(branch_id, occurred_at) where method = 'ota_deferred' and payout_id is null;

-- deferred platform payments not yet matched to a payout (receipts in, refunds out)
create or replace function fn_platform_unsettled(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_role('owner', 'manager', 'finance');
  perform fn_require_branch(p_branch);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', v.id, 'number', v.number, 'kind', v.kind, 'amount_halalas', v.amount_halalas,
                                        'signed_halalas', case when v.kind = 'receipt' then v.amount_halalas else -v.amount_halalas end,
                                        'occurred_at', v.occurred_at, 'reservation_id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref,
                                        'check_in', r.check_in, 'source_id', r.source_id, 'source_name', s.name) order by s.name, v.occurred_at)
    from financial_vouchers v join reservations r on r.id = v.reservation_id left join booking_sources s on s.id = r.source_id
    where v.branch_id = p_branch and v.method = 'ota_deferred' and v.status = 'approved' and v.payout_id is null and v.kind in ('receipt', 'refund')), '[]'::jsonb);
end $$;
revoke all on function fn_platform_unsettled(uuid) from public, anon;
grant execute on function fn_platform_unsettled(uuid) to authenticated;

create or replace function fn_platform_payout_confirm(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_source uuid := (p->>'source_id')::uuid; ids uuid[]; n int; good int; expected bigint; received bigint;
        acc uuid; pay platform_payouts%rowtype; v_note text := nullif(trim(coalesce(p->>'note', '')), ''); v_ref text := nullif(trim(coalesce(p->>'reference', '')), '');
begin
  perform fn_require_role('owner', 'manager', 'finance');
  perform fn_require_branch(v_branch);
  ids := array(select (x)::uuid from jsonb_array_elements_text(coalesce(p->'voucher_ids', '[]'::jsonb)) x);
  n := coalesce(array_length(ids, 1), 0);
  if n = 0 then raise exception 'VALIDATION: vouchers'; end if;
  received := fn_parse_halalas(p->>'received_halalas');
  if v_ref is null then raise exception 'VALIDATION: reference_required'; end if;
  if (p->>'received_on') is null or (p->>'received_on')::date > fn_branch_today(v_branch) then raise exception 'VALIDATION: received_on'; end if;
  acc := fn_voucher_account(v_branch, 'bank_transfer', (p->>'account_id')::uuid);
  -- lock the vouchers; every one must be an unmatched deferred payment of this branch and platform
  perform 1 from financial_vouchers where id = any(ids) for update;
  select count(*), coalesce(sum(case when v.kind = 'receipt' then v.amount_halalas else -v.amount_halalas end), 0) into good, expected
  from financial_vouchers v join reservations r on r.id = v.reservation_id
  where v.id = any(ids) and v.branch_id = v_branch and v.method = 'ota_deferred' and v.status = 'approved' and v.payout_id is null
    and v.kind in ('receipt', 'refund') and r.source_id = v_source;
  if good <> n then raise exception 'VALIDATION: payout_vouchers'; end if;
  if received <> expected and v_note is null then raise exception 'VALIDATION: note_required'; end if;   -- e.g. the platform's commission
  insert into platform_payouts(organization_id, branch_id, source_id, account_id, expected_halalas, received_halalas, difference_halalas, voucher_count, received_on, reference, note, created_by)
  values ((select organization_id from branches where id = v_branch), v_branch, v_source, acc, expected, received, received - expected, n, (p->>'received_on')::date, v_ref, v_note, fn_staff_id())
  returning * into pay;
  update financial_vouchers set payout_id = pay.id where id = any(ids);
  perform fn_audit_change(v_branch, 'platform.payout_confirmed', 'platform_payout', pay.id, null, to_jsonb(pay), v_note);
  return jsonb_build_object('ok', true, 'payout', to_jsonb(pay));
end $$;
revoke all on function fn_platform_payout_confirm(jsonb) from public, anon;
grant execute on function fn_platform_payout_confirm(jsonb) to authenticated;

create or replace function fn_platform_payout_cancel(p_payout uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay platform_payouts%rowtype; before jsonb;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into pay from platform_payouts where id = p_payout for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(pay.branch_id);
  if pay.status <> 'confirmed' then raise exception 'VALIDATION: payout_status'; end if;
  before := to_jsonb(pay);
  update financial_vouchers set payout_id = null where payout_id = pay.id;
  update platform_payouts set status = 'cancelled', cancelled_by = fn_staff_id(), cancelled_at = now(), cancel_reason = p_reason where id = pay.id returning * into pay;
  perform fn_audit_change(pay.branch_id, 'platform.payout_cancelled', 'platform_payout', pay.id, before, to_jsonb(pay), p_reason);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_platform_payout_cancel(uuid, text) from public, anon;
grant execute on function fn_platform_payout_cancel(uuid, text) to authenticated;

-- ---------------------------------------------------------------- 5. tax zero, owner only, snapshot per reservation (decision 68)
alter table reservations add column if not exists tax_rate_bp int;
alter table reservations add column if not exists prices_include_tax boolean;
-- from now on there is no tax: reservations already made keep the tax lines they have, and what is added to them
-- later carries no tax (decision 68: «لا بنود ضريبة»)
update reservations set tax_rate_bp = 0, prices_include_tax = false where tax_rate_bp is null;

create or replace function fn_reservation_tax_snapshot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tax_rate_bp is null or new.prices_include_tax is null then
    select coalesce(new.tax_rate_bp, b.tax_rate_bp), coalesce(new.prices_include_tax, b.prices_include_tax)
      into new.tax_rate_bp, new.prices_include_tax from branches b where b.id = new.branch_id;
  end if;
  return new;
end $$;
create or replace trigger trg_reservation_tax_snapshot before insert on reservations for each row execute function fn_reservation_tax_snapshot();

-- the tax of an amount on a reservation, by the policy the reservation was made under (half up at the line)
create or replace function fn_reservation_tax(p_reservation uuid, p_amount bigint, p_taxable boolean) returns table(net_halalas bigint, tax_halalas bigint)
language plpgsql stable security definer set search_path = public as $$
declare rate int; incl boolean;
begin
  select coalesce(r.tax_rate_bp, b.tax_rate_bp), coalesce(r.prices_include_tax, b.prices_include_tax) into rate, incl
  from reservations r join branches b on b.id = r.branch_id where r.id = p_reservation;
  if not p_taxable or coalesce(rate, 0) = 0 then return query select p_amount, 0::bigint; return; end if;
  if incl then
    tax_halalas := p_amount - round(p_amount::numeric * 10000 / (10000 + rate));
    return query select p_amount - tax_halalas, tax_halalas;
  else
    tax_halalas := round(p_amount::numeric * rate / 10000);
    return query select p_amount, tax_halalas;
  end if;
end $$;
revoke all on function fn_reservation_tax(uuid, bigint, boolean) from public, anon, authenticated;

create or replace function fn_add_charge(p_reservation uuid, p_kind text, p_description text, p_quantity numeric, p_unit_price bigint, p_taxable boolean, p_reason text,
                                         p_service uuid default null, p_service_from date default null, p_service_to date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; gross bigint; net bigint; tax bigint; cid uuid; sf date; st date; today date;
begin
  select * into r from reservations where id = p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  gross := round(p_quantity * p_unit_price);                      -- whole halalas, half up (decision 47)
  if p_kind = 'discount' then gross := -abs(gross); end if;
  select * into net, tax from fn_reservation_tax(r.id, gross, p_taxable);
  today := fn_branch_today(r.branch_id);
  sf := coalesce(p_service_from, case when p_kind in ('rent', 'discount', 'adjustment') then r.check_in else today end);
  st := coalesce(p_service_to,   case when p_kind in ('rent', 'discount', 'adjustment') then r.check_out else today end);
  if st < sf then raise exception 'VALIDATION: service_period'; end if;
  insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, service_definition_id, reason, created_by, service_from, service_to)
  values (r.organization_id, r.branch_id, r.id, p_kind, p_description, p_quantity, p_unit_price, net, p_taxable, p_service, p_reason, fn_staff_id(), sf, st) returning id into cid;
  if tax <> 0 then
    insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason, created_by, service_from, service_to)
    values (r.organization_id, r.branch_id, r.id, 'tax', 'ضريبة القيمة المضافة — ' || p_description, 1, tax, tax, false, p_reason, fn_staff_id(), sf, st);
  end if;
  return cid;
end $$;
revoke all on function fn_add_charge(uuid, text, text, numeric, bigint, boolean, text, uuid, date, date) from public, anon, authenticated;

alter table branches alter column tax_rate_bp set default 0;
alter table branches alter column default_deposit_halalas set default 5000;
do $$ declare b branches%rowtype; after jsonb; begin
  for b in select * from branches where tax_rate_bp <> 0 or default_deposit_halalas <> 5000 loop
    update branches set tax_rate_bp = 0, default_deposit_halalas = 5000, version = version + 1, updated_at = now() where id = b.id;
    after := jsonb_build_object('tax_rate_bp', 0, 'default_deposit_halalas', 5000);
    perform fn_audit_change(b.id, 'branch.money_defaults', 'branch', b.id,
      jsonb_build_object('tax_rate_bp', b.tax_rate_bp, 'default_deposit_halalas', b.default_deposit_halalas), after,
      'القرار 68: الضريبة صفر؛ القراران 33 و69: التأمين 50 ريالًا لكل وحدة');
  end loop;
end $$;

-- branch settings: the tax policy belongs to the owner alone; new branches start at zero tax, a 50 SAR deposit,
-- their system cleaning task type and a cash box and a bank account
create or replace function fn_admin_upsert_branch(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb; tax_changed boolean;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p->>'name_ar'), '') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if p ? 'timezone' then
    begin perform now() at time zone (p->>'timezone'); exception when others then raise exception 'VALIDATION: timezone'; end;
  end if;
  if (p->>'tax_rate_bp') is not null and ((p->>'tax_rate_bp') !~ '^[0-9]{1,4}$' or (p->>'tax_rate_bp')::int > 10000) then raise exception 'VALIDATION: tax_rate'; end if;
  if (p->>'default_deposit_halalas') is not null and (p->>'default_deposit_halalas') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: amount'; end if;
  if v_id is null then
    perform fn_require_role('owner');
    insert into branches(organization_id, name_ar, name_en, city, address, map_url, phone, email, check_in_time, check_out_time, timezone, tax_rate_bp, prices_include_tax, default_deposit_halalas, tax_number, commercial_register, is_active)
    values (fn_user_org_id(), p->>'name_ar', p->>'name_en', p->>'city', p->>'address', p->>'map_url', p->>'phone', p->>'email',
            coalesce((p->>'check_in_time')::time, '16:00'), coalesce((p->>'check_out_time')::time, '12:00'),
            coalesce(p->>'timezone', 'Asia/Riyadh'), coalesce((p->>'tax_rate_bp')::int, 0), coalesce((p->>'prices_include_tax')::boolean, false),
            coalesce((p->>'default_deposit_halalas')::bigint, 5000), nullif(trim(coalesce(p->>'tax_number', '')), ''), p->>'commercial_register', coalesce((p->>'is_active')::boolean, true))
    returning * into b;
    perform fn_room_cleaning_type(b.id);   -- (its cash box and bank account come from trg_branch_bootstrap_accounts)
    perform fn_audit_change(b.id, 'branch.created', 'branch', b.id, null, to_jsonb(b));
  else
    select * into b from branches where id = v_id and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.id);
    perform fn_check_version(b.version, (p->>'version')::int);
    tax_changed := ((p->>'tax_rate_bp') is not null and (p->>'tax_rate_bp')::int is distinct from b.tax_rate_bp)
                or ((p->>'prices_include_tax') is not null and (p->>'prices_include_tax')::boolean is distinct from b.prices_include_tax)
                or ((p ? 'tax_number') and nullif(trim(coalesce(p->>'tax_number', '')), '') is distinct from b.tax_number);
    if tax_changed and not fn_has_role('owner') then raise exception 'FORBIDDEN: tax settings are the owner''s'; end if;
    before := to_jsonb(b);
    update branches set
      name_ar = p->>'name_ar', name_en = coalesce(p->>'name_en', name_en), city = coalesce(p->>'city', city), address = coalesce(p->>'address', address),
      map_url = coalesce(p->>'map_url', map_url), phone = coalesce(p->>'phone', phone), email = coalesce(p->>'email', email),
      check_in_time = coalesce((p->>'check_in_time')::time, check_in_time), check_out_time = coalesce((p->>'check_out_time')::time, check_out_time),
      timezone = coalesce(p->>'timezone', timezone), tax_rate_bp = coalesce((p->>'tax_rate_bp')::int, tax_rate_bp),
      prices_include_tax = coalesce((p->>'prices_include_tax')::boolean, prices_include_tax),
      default_deposit_halalas = coalesce((p->>'default_deposit_halalas')::bigint, default_deposit_halalas),
      tax_number = case when p ? 'tax_number' then nullif(trim(coalesce(p->>'tax_number', '')), '') else tax_number end,
      commercial_register = coalesce(p->>'commercial_register', commercial_register),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = b.id returning * into b;
    perform fn_audit_change(b.id, 'branch.updated', 'branch', b.id, before, to_jsonb(b));
    if tax_changed then
      perform fn_audit_change(b.id, 'branch.tax_changed', 'branch', b.id,
        jsonb_build_object('tax_rate_bp', before->'tax_rate_bp', 'prices_include_tax', before->'prices_include_tax', 'tax_number', before->'tax_number'),
        jsonb_build_object('tax_rate_bp', b.tax_rate_bp, 'prices_include_tax', b.prices_include_tax, 'tax_number', b.tax_number),
        'يسري على الحجوزات الجديدة فقط');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
end $$;
grant execute on function fn_admin_upsert_branch(jsonb) to authenticated;
