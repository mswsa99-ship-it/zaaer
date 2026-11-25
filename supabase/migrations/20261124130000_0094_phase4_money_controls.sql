-- 0084 (proposed number; the integrator renumbers — 0082 and 0083 are taken) — Phase 4 money controls, server side.
-- 4.5 (M5 التأمين): one standing deposit per reservation; an increase is «تكملة تأمين» and carries its reason.
-- 4.6 (M6 رصد الشذوذ): the six rules — a negative box, an expense or a receipt over the threshold, a receipt over
--   what is due, a repeated deposit, a zero night price, a large discount; each opens a review item and alerts at once.
-- 4.7 (M7 سعر الليلة): a night costs more than zero for every role; «إقامة مجانية» is an explicit path the owner approves.
-- 4.8 (M8 الخصم): the hotel's threshold lives in its settings; over it the owner's prior approval and a review item
--   with the amount.
-- Author-only proposal: new tables, columns, triggers and functions. No existing function is replaced;
-- fn_create_voucher is untouched (the over-due cap of 4.2 belongs to another worker). The gates below are table
-- triggers, so every write path that already exists (creation, adjustment, correction, refund) keeps its signature
-- and its behaviour except where the plan asks for a refusal or a flag. New tables are registered in
-- supabase/tenancy.json (branch scope). The settings screen that edits the thresholds is item 4.12's.

-- ---------------------------------------------------------------- 0. the hotel's thresholds (its settings row)
alter table system_settings add column if not exists discount_review_threshold_bp int;          -- 4.8: over this share of the rent
alter table system_settings add column if not exists anomaly_receipt_threshold_halalas bigint;  -- 4.6: a receipt over this is flagged
alter table system_settings add column if not exists anomaly_expense_threshold_halalas bigint;  -- 4.6: an expense over this is flagged
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'system_settings_discount_threshold_valid') then
    alter table system_settings add constraint system_settings_discount_threshold_valid
      check (discount_review_threshold_bp is null or discount_review_threshold_bp between 0 and 10000);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'system_settings_anomaly_thresholds_valid') then
    alter table system_settings add constraint system_settings_anomaly_thresholds_valid
      check ((anomaly_receipt_threshold_halalas is null or anomaly_receipt_threshold_halalas > 0)
         and (anomaly_expense_threshold_halalas is null or anomaly_expense_threshold_halalas > 0));
  end if;
end $$;
-- null switches a rule off. The discount gate ships OFF (null): enforcing it by default changes the owner's and the
-- manager's existing discount flows (rates PR06c/PR13d) before 4.12's settings screen exists and the owner picks the
-- value — the gate is live the moment the hotel sets its threshold. The anomaly thresholds only ever ADD review items
-- (they refuse nothing), so they ship with a proposed default of 5,000.00 the owner can tune or null.
update system_settings set anomaly_receipt_threshold_halalas = coalesce(anomaly_receipt_threshold_halalas, 500000),
                           anomaly_expense_threshold_halalas = coalesce(anomaly_expense_threshold_halalas, 500000);
alter table system_settings alter column anomaly_receipt_threshold_halalas set default 500000;
alter table system_settings alter column anomaly_expense_threshold_halalas set default 500000;

-- ---------------------------------------------------------------- 4.6.0 one flag = a review item for the owner plus an alert at once
-- The notifications table has no owner audience; the owner's own surface is the review list (review_items is
-- owner-read), so the flag always opens the review item, and the notification carries it to the branch's managers.
create or replace function fn_phase4_flag(p_branch uuid, p_kind text, p_entity_type text, p_entity_id uuid, p_reservation uuid,
                                          p_summary text, p_reason text, p_details jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  -- one open item per rule per thing: a box that stays negative is flagged once, not on every later movement
  select id into v from review_items
   where kind = p_kind and entity_type = p_entity_type and entity_id = p_entity_id and reviewed_at is null
   limit 1;
  if v is not null then return v; end if;
  v := fn_add_review_item(p_branch, p_kind, p_entity_type, p_entity_id, p_reservation, p_summary, p_reason, p_details);
  insert into notifications(branch_id, audience, title, body, link)
  values (p_branch, 'manager', 'شذوذ مالي: ' || left(p_summary, 110), p_reason,
          case when p_reservation is not null then '/staff/reservations/' || p_reservation end);
  return v;
end $$;
revoke all on function fn_phase4_flag(uuid, text, text, uuid, uuid, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- 4.5 the deposit gate: a second standing deposit is refused; «تكملة تأمين» carries its reason
create or replace function fn_trg_deposit_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_number text;
begin
  if new.kind = 'deposit' and new.status = 'approved' then
    select fv.number into v_number from financial_vouchers fv
     where fv.reservation_id = new.reservation_id and fv.kind = 'deposit' and fv.status = 'approved'
     order by fv.occurred_at limit 1;
    if v_number is not null and nullif(trim(coalesce(new.reason, '')), '') is null then
      raise exception 'DEPOSIT_EXISTS: the stay already holds deposit %; an increase is «تكملة تأمين» and carries its reason', v_number;
    end if;
  end if;
  return new;
end $$;
revoke all on function fn_trg_deposit_gate() from public, anon, authenticated;
drop trigger if exists trg_deposit_gate on financial_vouchers;
create trigger trg_deposit_gate before insert on financial_vouchers
  for each row execute function fn_trg_deposit_gate();

-- 4.6 rule «تأمين مكرر»: the allowed top-up is still flagged. Deferred to the commit so a voucher correction
-- (0054 writes the replacement, then names the original) is recognised and not flagged — it opens its own item.
create or replace function fn_trg_deposit_flag() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_other record;
begin
  if new.kind <> 'deposit' or new.status <> 'approved' then return null; end if;
  if new.original_voucher_id is not null or new.reversal_of is not null then return null; end if;
  -- only the newcomer is flagged, never the standing deposit (both commit together when written in one transaction)
  select fv.id, fv.number, fv.amount_halalas into v_other from financial_vouchers fv
   where fv.reservation_id = new.reservation_id and fv.kind = 'deposit' and fv.status = 'approved' and fv.id <> new.id
     and (fv.occurred_at, fv.number) < (new.occurred_at, new.number)
   order by fv.occurred_at, fv.number limit 1;
  if v_other.id is null then return null; end if;
  perform fn_phase4_flag(new.branch_id, 'deposit_duplicate', 'voucher', new.id, new.reservation_id,
    'تكملة تأمين ' || fn_sar_text(new.amount_halalas) || ' فوق التأمين ' || v_other.number,
    new.reason,
    jsonb_build_object('number', new.number, 'amount_halalas', new.amount_halalas,
                       'first_voucher', v_other.number, 'first_amount_halalas', v_other.amount_halalas));
  return null;
end $$;
revoke all on function fn_trg_deposit_flag() from public, anon, authenticated;
drop trigger if exists trg_deposit_flag on financial_vouchers;
create constraint trigger trg_deposit_flag after insert on financial_vouchers deferrable initially deferred
  for each row execute function fn_trg_deposit_flag();

-- ---------------------------------------------------------------- 4.6 rules «صندوق سالب», «مصروف أو قبض فوق عتبة», «قبض فوق المستحق»
create or replace function fn_trg_voucher_anomaly() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_bal bigint; f jsonb; v_threshold bigint; v_acc_name text;
begin
  if new.status <> 'approved' then return null; end if;
  -- a box or an account under zero (the refusal itself is 4.3's; this flags any path that still reaches it)
  if new.kind in ('refund', 'deposit_refund') and new.account_id is not null then
    select coalesce(sum(in_halalas - out_halalas), 0) into v_bal from fn_account_movements(new.account_id);
    if v_bal < 0 then
      select name into v_acc_name from cash_accounts where id = new.account_id;
      perform fn_phase4_flag(new.branch_id, 'negative_cash_box', 'cash_account', new.account_id, new.reservation_id,
        'الحساب ' || coalesce(v_acc_name, '—') || ' نزل تحت الصفر: ' || fn_sar_text(v_bal), null,
        jsonb_build_object('account_id', new.account_id, 'balance_halalas', v_bal, 'by_voucher', new.number));
    end if;
  end if;
  if new.kind = 'receipt' then
    -- a receipt over the hotel's threshold
    select anomaly_receipt_threshold_halalas into v_threshold from system_settings where organization_id = new.organization_id;
    if v_threshold is not null and new.amount_halalas > v_threshold then
      perform fn_phase4_flag(new.branch_id, 'receipt_over_threshold', 'voucher', new.id, new.reservation_id,
        'سند قبض ' || fn_sar_text(new.amount_halalas) || ' فوق عتبة ' || fn_sar_text(v_threshold), new.reason,
        jsonb_build_object('number', new.number, 'amount_halalas', new.amount_halalas, 'threshold_halalas', v_threshold));
    end if;
    -- a receipt over what the stay is owed (the advance-payment path of 4.2 flags its own; this catches the rest)
    f := fn_reservation_finance_internal(new.reservation_id);
    if (f->>'credit')::bigint > 0 then
      perform fn_phase4_flag(new.branch_id, 'receipt_over_due', 'voucher', new.id, new.reservation_id,
        'قبض فوق المستحق بـ ' || fn_sar_text((f->>'credit')::bigint), new.reason,
        jsonb_build_object('number', new.number, 'amount_halalas', new.amount_halalas, 'credit_halalas', (f->>'credit')::bigint,
                           'total_halalas', (f->>'total')::bigint));
    end if;
  end if;
  return null;
end $$;
revoke all on function fn_trg_voucher_anomaly() from public, anon, authenticated;
drop trigger if exists trg_voucher_anomaly on financial_vouchers;
create trigger trg_voucher_anomaly after insert on financial_vouchers
  for each row execute function fn_trg_voucher_anomaly();

create or replace function fn_trg_expense_anomaly() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_bal bigint; v_threshold bigint; v_acc_name text;
begin
  if new.status <> 'approved' then return null; end if;
  select anomaly_expense_threshold_halalas into v_threshold from system_settings where organization_id = new.organization_id;
  if v_threshold is not null and new.amount_halalas > v_threshold then
    perform fn_phase4_flag(new.branch_id, 'expense_over_threshold', 'expense_voucher', new.id, null,
      'مصروف ' || fn_sar_text(new.amount_halalas) || ' فوق عتبة ' || fn_sar_text(v_threshold) || ': ' || left(new.description, 80), null,
      jsonb_build_object('number', new.number, 'amount_halalas', new.amount_halalas, 'threshold_halalas', v_threshold));
  end if;
  select coalesce(sum(in_halalas - out_halalas), 0) into v_bal from fn_account_movements(new.account_id);
  if v_bal < 0 then
    select name into v_acc_name from cash_accounts where id = new.account_id;
    perform fn_phase4_flag(new.branch_id, 'negative_cash_box', 'cash_account', new.account_id, null,
      'الحساب ' || coalesce(v_acc_name, '—') || ' نزل تحت الصفر: ' || fn_sar_text(v_bal), null,
      jsonb_build_object('account_id', new.account_id, 'balance_halalas', v_bal, 'by_expense', new.number));
  end if;
  return null;
end $$;
revoke all on function fn_trg_expense_anomaly() from public, anon, authenticated;
drop trigger if exists trg_expense_anomaly on expense_vouchers;
create trigger trg_expense_anomaly after insert on expense_vouchers
  for each row execute function fn_trg_expense_anomaly();

-- ---------------------------------------------------------------- 4.7 the nightly price floor, and the explicit free stay
alter table reservations add column if not exists free_stay boolean not null default false;
alter table reservations add column if not exists free_stay_reason text;
alter table reservations add column if not exists free_stay_approved_by uuid references staff_profiles(id);
alter table reservations add column if not exists free_stay_at timestamptz;
-- readable by the staff like the other non-money columns (the 0009/0035 column gate lists the readable ones)
select set_config('app.source', 'migration', true);
do $$ begin
  if has_column_privilege('authenticated', 'public.reservations', 'status', 'SELECT')
     and not has_table_privilege('authenticated', 'public.reservations', 'SELECT')
     and not has_column_privilege('authenticated', 'public.reservations', 'free_stay', 'SELECT') then
    grant select (free_stay, free_stay_reason, free_stay_approved_by, free_stay_at) on public.reservations to authenticated;
  end if;
end $$;

-- a night never costs zero or less, whoever writes it; the one exception is a stay the owner approved as free
-- (fn_staff_create_free_stay below marks its own transaction only)
create or replace function fn_trg_night_price_floor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and coalesce(new.price_halalas, 0) <= 0
     and coalesce(current_setting('app.free_stay_approved', true), '') <> 'on' then
    raise exception 'PRICE_FLOOR: a night costs more than zero; a free stay goes through fn_staff_create_free_stay with the owner''s approval';
  end if;
  return new;
end $$;
revoke all on function fn_trg_night_price_floor() from public, anon, authenticated;
drop trigger if exists trg_night_price_floor on reservation_nights;
create trigger trg_night_price_floor before insert or update of price_halalas, status on reservation_nights
  for each row execute function fn_trg_night_price_floor();

-- 4.6 rule «سعر صفر»: the approved free stay is still flagged, once per stay
create or replace function fn_trg_zero_price_flag() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and coalesce(new.price_halalas, 0) <= 0
     and not exists (select 1 from review_items where kind = 'zero_price' and reservation_id = new.reservation_id and reviewed_at is null) then
    perform fn_phase4_flag(new.branch_id, 'zero_price', 'reservation', new.reservation_id, new.reservation_id,
      'سعر ليلة صفر في الحجز (إقامة مجانية)', null,
      jsonb_build_object('night', new.night, 'basis', new.basis));
  end if;
  return null;
end $$;
revoke all on function fn_trg_zero_price_flag() from public, anon, authenticated;
drop trigger if exists trg_zero_price_flag on reservation_nights;
create trigger trg_zero_price_flag after insert on reservation_nights
  for each row execute function fn_trg_zero_price_flag();

-- «إقامة مجانية»: one unit, the owner alone, a written reason; the stay is marked and the zero-price flag records it
create or replace function fn_staff_create_free_stay(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(trim(coalesce(p->>'reason', '')), ''); res jsonb; rid uuid; v_branch uuid;
begin
  perform fn_require_role('owner');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  perform fn_require_branch((p->>'branch_id')::uuid);
  if p ? 'units' then raise exception 'VALIDATION: free_stay_single_unit'; end if;
  perform set_config('app.free_stay_approved', 'on', true);          -- this transaction only; the floor trigger asks for it
  res := fn_staff_create_reservation((p - 'reason') || jsonb_build_object('nightly_rate_halalas', 0, 'discount_halalas', 0));
  rid := (res->>'id')::uuid;
  update reservations set free_stay = true, free_stay_reason = v_reason, free_stay_approved_by = fn_staff_id(), free_stay_at = now()
   where id = rid returning branch_id into v_branch;
  perform fn_audit_change(v_branch, 'reservation.free_stay', 'reservation', rid, null,
    jsonb_build_object('free_stay', true, 'reason', v_reason, 'internal_ref', res->>'internal_ref'), v_reason);
  return res || jsonb_build_object('free_stay', true);
end $$;
revoke all on function fn_staff_create_free_stay(jsonb) from public, anon;
grant execute on function fn_staff_create_free_stay(jsonb) to authenticated;

-- ---------------------------------------------------------------- 4.8 the discount threshold: the owner's prior approval, then a review item with the amount
create table if not exists discount_approvals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  reservation_id uuid not null references reservations(id) on delete cascade,
  amount_halalas bigint not null check (amount_halalas > 0),       -- covers the stay's cumulative discount
  reason text not null check (trim(reason) <> ''),
  approved_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  used_at timestamptz,
  used_charge_id uuid
);
create index if not exists idx_discount_approvals_reservation on discount_approvals(reservation_id) where used_at is null;
alter table discount_approvals enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'discount_approvals' and policyname = 'discount_approvals_owner_read') then
    create policy "discount_approvals_owner_read" on discount_approvals for select to authenticated
      using (organization_id = (select fn_user_org_id()) and organization_id = fn_user_org_id() and fn_has_role('owner'));
  end if;
end $$;
revoke insert, update, delete on discount_approvals from anon, authenticated;

create or replace function fn_approve_discount(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v_amount bigint; v_reason text := nullif(trim(coalesce(p->>'reason', '')), ''); v_id uuid;
begin
  perform fn_require_role('owner');
  v_amount := fn_parse_halalas(p->>'amount_halalas');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  insert into discount_approvals(organization_id, branch_id, reservation_id, amount_halalas, reason, approved_by)
  values (r.organization_id, r.branch_id, r.id, v_amount, v_reason, fn_staff_id()) returning id into v_id;
  perform fn_audit_change(r.branch_id, 'discount.approved', 'discount_approval', v_id, null,
    jsonb_build_object('reservation_id', r.id, 'amount_halalas', v_amount, 'reason', v_reason), v_reason);
  return jsonb_build_object('ok', true, 'approval_id', v_id);
end $$;
revoke all on function fn_approve_discount(jsonb) from public, anon;
grant execute on function fn_approve_discount(jsonb) to authenticated;

-- the gate: the stay's cumulative discount over the hotel's threshold is refused without a matching prior approval.
-- A discount at booking time is written after the rent lines, so the rent is already there to measure against.
create or replace function fn_trg_discount_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_threshold int; v_rent bigint; v_total bigint; v_appr uuid;
begin
  if new.kind <> 'discount' then return new; end if;
  select discount_review_threshold_bp into v_threshold from system_settings where organization_id = new.organization_id;
  if v_threshold is null then return new; end if;
  select coalesce(sum(total_halalas), 0) into v_rent from reservation_charges where reservation_id = new.reservation_id and kind = 'rent';
  if v_rent <= 0 then return new; end if;      -- a free stay has no rent to measure; its zero-price flag already records it
  select coalesce(sum(-total_halalas), 0) + (-new.total_halalas) into v_total
    from reservation_charges where reservation_id = new.reservation_id and kind = 'discount';
  if v_total * 10000 <= v_rent * v_threshold then return new; end if;
  select a.id into v_appr from discount_approvals a
   where a.reservation_id = new.reservation_id and a.used_at is null and a.amount_halalas >= v_total
   order by a.created_at limit 1 for update;   -- blocks a concurrent discount reaching for the same approval until this one commits
  if v_appr is null then
    raise exception 'DISCOUNT_APPROVAL_REQUIRED: a discount of % halalas is over the hotel''s threshold (% bp of the rent); the owner approves it first',
      v_total, v_threshold;
  end if;
  return new;
end $$;
revoke all on function fn_trg_discount_gate() from public, anon, authenticated;
drop trigger if exists trg_discount_gate on reservation_charges;
create trigger trg_discount_gate before insert on reservation_charges
  for each row execute function fn_trg_discount_gate();

-- the flag: the same approval this transaction locked is consumed and the item carries the amount
create or replace function fn_trg_discount_flag() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_threshold int; v_rent bigint; v_total bigint; v_appr uuid;
begin
  if new.kind <> 'discount' then return null; end if;
  select discount_review_threshold_bp into v_threshold from system_settings where organization_id = new.organization_id;
  if v_threshold is null then return null; end if;
  select coalesce(sum(total_halalas), 0) into v_rent from reservation_charges where reservation_id = new.reservation_id and kind = 'rent';
  if v_rent <= 0 then return null; end if;
  select coalesce(sum(-total_halalas), 0) into v_total from reservation_charges where reservation_id = new.reservation_id and kind = 'discount';
  if v_total * 10000 <= v_rent * v_threshold then return null; end if;
  update discount_approvals set used_at = now(), used_charge_id = new.id
   where id = (select a.id from discount_approvals a
                where a.reservation_id = new.reservation_id and a.used_at is null and a.amount_halalas >= v_total
                order by a.created_at limit 1)
  returning id into v_appr;
  perform fn_phase4_flag(new.branch_id, 'discount_over_threshold', 'charge', new.id, new.reservation_id,
    'خصم ' || fn_sar_text(-new.total_halalas) || ' فوق عتبة الفندق (الإجمالي ' || fn_sar_text(v_total) || ' من إيجار ' || fn_sar_text(v_rent) || ')',
    new.reason,
    jsonb_build_object('amount_halalas', -new.total_halalas, 'cumulative_halalas', v_total, 'rent_halalas', v_rent,
                       'threshold_bp', v_threshold, 'approval_id', v_appr));
  return null;
end $$;
revoke all on function fn_trg_discount_flag() from public, anon, authenticated;
drop trigger if exists trg_discount_flag on reservation_charges;
create trigger trg_discount_flag after insert on reservation_charges
  for each row execute function fn_trg_discount_flag();

create or replace trigger zz_hotel_pointers after insert or update of branch_id, checked_in_by, checked_out_by, deposit_waiver_by, room_category_id, room_id, shomoos_accepted_by, source_id, free_stay_approved_by, organization_id on public.reservations
  for each row execute function fn_hotel_pointers('branch_id', 'branches', 'checked_in_by', 'staff_profiles', 'checked_out_by', 'staff_profiles', 'deposit_waiver_by', 'staff_profiles', 'room_category_id', 'room_categories', 'room_id', 'rooms', 'shomoos_accepted_by', 'staff_profiles', 'source_id', 'booking_sources', 'free_stay_approved_by', 'staff_profiles');
create or replace trigger zz_hotel_pointers after insert or update on discount_approvals for each row execute function fn_hotel_pointers('branch_id', 'branches', 'reservation_id', 'reservations', 'approved_by', 'staff_profiles');
