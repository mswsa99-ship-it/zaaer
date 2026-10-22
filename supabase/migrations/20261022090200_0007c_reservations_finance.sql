/*
# 0007c — Reservation core + financial ledger

Source of truth:
  * reservation_allocations  — WHICH room for WHICH period. EXCLUDE constraint prevents
                               any two active allocations of the same room overlapping
                               (half-open [from,to)), even under concurrent requests (G05).
  * reservation_charges      — WHAT is owed (rent / addon / discount / penalty / tax / adjustment),
                               snapshotted (catalogue edits never reprice history, G27).
  * financial_vouchers       — WHAT was collected / refunded. receipt + refund settle the stay;
                               deposit + deposit_refund + deposit_apply form a separate ledger (G11).
                               Idempotency key + content hash (G13). Cancelling reverses, never deletes (G15).
  * invoices                 — issued documents, snapshots; lines can only be invoiced once (F13).

reservations.total_halalas / paid_halalas / payment_status are DERIVED caches recomputed
inside the same transaction by fn_recompute_reservation_finance (never written by the UI).
payment_transactions stays as the provider/integration record (webhooks, links); a verified
provider payment produces exactly one receipt voucher.
*/

-- =====================================================================
-- 1. Schema
-- =====================================================================
alter table reservations add column if not exists version int not null default 1;
alter table reservations add column if not exists rate_type text not null default 'daily';        -- daily | monthly | hourly (daily implemented)
alter table reservations add column if not exists nightly_rate_halalas bigint not null default 0;
alter table reservations add column if not exists cancelled_at timestamptz;
alter table reservations add column if not exists cancel_reason text;
alter table reservations add column if not exists cancel_source text;                              -- staff | ota | guest
alter table reservations add column if not exists no_show_at timestamptz;
alter table reservations add column if not exists deposit_balance_halalas bigint not null default 0;
alter table reservations add column if not exists refunded_halalas bigint not null default 0;
alter table reservations add column if not exists balance_due_halalas bigint not null default 0;

alter table guest_profiles add column if not exists organization_id uuid references organizations(id) on delete cascade;
alter table guest_profiles add column if not exists email text;
alter table guest_profiles add column if not exists notes text;
alter table guest_profiles add column if not exists updated_at timestamptz default now();
update guest_profiles set organization_id = '00000000-0000-0000-0000-000000000001' where organization_id is null;
create index if not exists idx_guest_profiles_org_phone on guest_profiles(organization_id, phone);

create table if not exists reservation_allocations (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references reservations(id) on delete cascade,
  room_id uuid not null references rooms(id) on delete restrict,
  branch_id uuid not null references branches(id) on delete restrict,
  from_date date not null,
  to_date date not null,
  status text not null default 'active',            -- active | closed | cancelled
  reason text,
  created_by uuid,
  created_at timestamptz default now(),
  closed_at timestamptz,
  constraint alloc_dates_valid check (to_date > from_date),
  constraint alloc_status_valid check (status in ('active','closed','cancelled')),
  constraint alloc_no_overlap exclude using gist (room_id with =, daterange(from_date, to_date, '[)') with &&) where (status = 'active')
);
create index if not exists idx_alloc_reservation on reservation_allocations(reservation_id, status);
create index if not exists idx_alloc_room_dates on reservation_allocations(room_id, from_date, to_date) where status = 'active';

-- the legacy whole-reservation constraint is superseded by allocations (room switch mid-stay needs period-level checks)
alter table reservations drop constraint if exists reservations_no_overlap;

create table if not exists reservation_charges (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  reservation_id uuid not null references reservations(id) on delete cascade,
  kind text not null,                                -- rent | addon | discount | penalty | tax | adjustment
  description text not null,
  quantity numeric(12,3) not null default 1,
  unit_price_halalas bigint not null default 0,
  total_halalas bigint not null,                     -- signed: discount is negative
  taxable boolean not null default true,
  service_definition_id uuid references service_definitions(id) on delete set null,
  invoice_id uuid,
  reason text,
  created_by uuid,
  created_at timestamptz default now(),
  constraint charge_kind_valid check (kind in ('rent','addon','discount','penalty','tax','adjustment')),
  constraint charge_sign_valid check ((kind = 'discount' and total_halalas <= 0) or (kind <> 'discount'))
);
create index if not exists idx_charges_reservation on reservation_charges(reservation_id);

create table if not exists financial_vouchers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  reservation_id uuid not null references reservations(id) on delete restrict,
  number text not null,
  kind text not null,                                -- receipt | refund | deposit | deposit_refund | deposit_apply
  amount_halalas bigint not null,
  method payment_method not null,
  status text not null default 'approved',           -- approved | cancelled | pending
  reference text,
  note text,
  reason text,
  original_voucher_id uuid references financial_vouchers(id),
  payment_transaction_id uuid references payment_transactions(id),
  idempotency_key text not null,
  content_hash text not null,
  occurred_at timestamptz not null default now(),
  created_by uuid,
  created_at timestamptz default now(),
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancel_reason text,
  constraint voucher_kind_valid check (kind in ('receipt','refund','deposit','deposit_refund','deposit_apply')),
  constraint voucher_amount_positive check (amount_halalas > 0),
  constraint voucher_status_valid check (status in ('approved','cancelled','pending'))
);
create unique index if not exists uniq_voucher_idem on financial_vouchers(organization_id, idempotency_key);
create unique index if not exists uniq_voucher_number on financial_vouchers(organization_id, number);
create index if not exists idx_vouchers_reservation on financial_vouchers(reservation_id, kind, status);
create index if not exists idx_vouchers_branch_time on financial_vouchers(branch_id, occurred_at);

create table if not exists invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  reservation_id uuid not null references reservations(id) on delete restrict,
  number text not null,
  period_from date,
  period_to date,
  status text not null default 'issued',             -- issued | cancelled
  snapshot jsonb not null,                           -- property + guest + lines at issue time
  subtotal_halalas bigint not null,
  tax_halalas bigint not null,
  total_halalas bigint not null,
  issued_by uuid,
  issued_at timestamptz default now(),
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancel_reason text,
  unique (organization_id, number)
);
create index if not exists idx_invoices_reservation on invoices(reservation_id);
alter table reservation_charges drop constraint if exists reservation_charges_invoice_fk;
alter table reservation_charges add constraint reservation_charges_invoice_fk foreign key (invoice_id) references invoices(id) on delete set null;

create table if not exists integration_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  source text not null,                              -- booking_com | ota | payment_provider | whatsapp
  external_event_id text not null,
  kind text not null,                                -- reservation.cancelled | payment.succeeded | ...
  reference text,
  state text not null default 'received',            -- received | processed | duplicate | rejected | quarantined
  payload_redacted jsonb,
  result jsonb,
  attempts int not null default 1,
  created_at timestamptz default now(),
  processed_at timestamptz,
  unique (organization_id, source, external_event_id)
);

create table if not exists document_sequences (
  organization_id uuid not null references organizations(id) on delete cascade,
  kind text not null,
  year int not null,
  last_value bigint not null default 0,
  primary key (organization_id, kind, year)
);

create or replace function fn_next_document_number(p_org uuid, p_kind text, p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare v bigint; y int := extract(year from now())::int;
begin
  insert into document_sequences(organization_id, kind, year, last_value) values (p_org, p_kind, y, 1)
  on conflict (organization_id, kind, year) do update set last_value = document_sequences.last_value + 1
  returning last_value into v;
  return p_prefix || '-' || y || '-' || lpad(v::text, 6, '0');
end $$;
revoke all on function fn_next_document_number(uuid, text, text) from public, anon, authenticated;

-- RLS ---------------------------------------------------------------------
alter table reservation_allocations enable row level security;
alter table reservation_charges enable row level security;
alter table financial_vouchers enable row level security;
alter table invoices enable row level security;
alter table integration_events enable row level security;
alter table document_sequences enable row level security;
create policy "staff_alloc_select" on reservation_allocations for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "staff_charges_select" on reservation_charges for select to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager','supervisor','finance'));
create policy "staff_vouchers_select" on financial_vouchers for select to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager','supervisor','finance'));
create policy "staff_invoices_select" on invoices for select to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager','supervisor','finance'));
create policy "mgr_integration_select" on integration_events for select to authenticated using (organization_id = fn_user_org_id() and fn_has_role('owner','manager'));
-- reservations: no more direct writes from the client for anyone (RPC only)
drop policy if exists "mgr_res_write" on reservations;
drop policy if exists "mgr_res_update" on reservations;
drop policy if exists "mgr_guests_write" on guest_profiles;

-- =====================================================================
-- 2. Derived finance (single place that computes money state) — G10/G11/G14
-- =====================================================================
create or replace function fn_reservation_finance_internal(p_reservation uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (
    select coalesce(sum(total_halalas) filter (where kind = 'rent'), 0) as rent,
           coalesce(sum(total_halalas) filter (where kind = 'addon'), 0) as addons,
           coalesce(sum(total_halalas) filter (where kind = 'discount'), 0) as discounts,
           coalesce(sum(total_halalas) filter (where kind = 'penalty'), 0) as penalties,
           coalesce(sum(total_halalas) filter (where kind = 'adjustment'), 0) as adjustments,
           coalesce(sum(total_halalas) filter (where kind = 'tax'), 0) as tax,
           coalesce(sum(total_halalas), 0) as total
    from reservation_charges where reservation_id = p_reservation
  ), v as (
    select coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0) as received,
           coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0) as refunded,
           coalesce(sum(amount_halalas) filter (where kind = 'deposit'), 0) as deposit_received,
           coalesce(sum(amount_halalas) filter (where kind = 'deposit_refund'), 0) as deposit_refunded,
           coalesce(sum(amount_halalas) filter (where kind = 'deposit_apply'), 0) as deposit_applied
    from financial_vouchers where reservation_id = p_reservation and status = 'approved'
  )
  select jsonb_build_object(
    'rent', c.rent, 'addons', c.addons, 'discounts', c.discounts, 'penalties', c.penalties, 'adjustments', c.adjustments, 'tax', c.tax,
    'total', c.total,
    'received', v.received, 'refunded', v.refunded, 'deposit_applied', v.deposit_applied,
    'net_collected', v.received - v.refunded + v.deposit_applied,
    'balance_due', greatest(c.total - (v.received - v.refunded + v.deposit_applied), 0),
    'credit', greatest((v.received - v.refunded + v.deposit_applied) - c.total, 0),
    'deposit_received', v.deposit_received, 'deposit_refunded', v.deposit_refunded,
    'deposit_balance', v.deposit_received - v.deposit_refunded - v.deposit_applied,
    'payment_status', case when c.total <= 0 and (v.received - v.refunded) = 0 then 'pending'
                           when (v.received - v.refunded + v.deposit_applied) = 0 then 'pending'
                           when (v.received - v.refunded + v.deposit_applied) < c.total then 'partially_paid'
                           else 'paid' end   -- over-collection is exposed as `credit`, the stay itself counts as paid (gates keep working)
  ) from c, v;
$$;
revoke all on function fn_reservation_finance_internal(uuid) from public, anon, authenticated;

-- Public, branch-scoped view of the same computation (UI and the assistant use this one)
create or replace function fn_reservation_finance(p_reservation uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when fn_has_role('owner','manager','supervisor','finance')
               and exists (select 1 from reservations r where r.id = p_reservation and r.branch_id in (select fn_user_branch_ids()))
         then fn_reservation_finance_internal(p_reservation) end;
$$;
grant execute on function fn_reservation_finance(uuid) to authenticated;

create or replace function fn_recompute_reservation_finance(p_reservation uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f jsonb;
begin
  f := fn_reservation_finance_internal(p_reservation);
  update reservations set
    total_halalas = (f->>'total')::bigint,
    rent_amount_halalas = (f->>'rent')::bigint,
    discount_halalas = -(f->>'discounts')::bigint,
    addons_halalas = (f->>'addons')::bigint + (f->>'penalties')::bigint + (f->>'adjustments')::bigint,
    taxes_halalas = (f->>'tax')::bigint,
    paid_halalas = (f->>'net_collected')::bigint,
    refunded_halalas = (f->>'refunded')::bigint,
    balance_due_halalas = (f->>'balance_due')::bigint,
    deposit_balance_halalas = (f->>'deposit_balance')::bigint,
    payment_status = (f->>'payment_status')::payment_status,
    updated_at = now()
  where id = p_reservation;
  return f;
end $$;
revoke all on function fn_recompute_reservation_finance(uuid) from public, anon, authenticated;

-- Tax computation per branch policy. Returns (net, tax) for a gross-or-net amount. Half-up rounding at the line level.
create or replace function fn_apply_tax(p_branch uuid, p_amount bigint, p_taxable boolean) returns table(net_halalas bigint, tax_halalas bigint)
language plpgsql stable security definer set search_path = public as $$
declare rate int; incl boolean;
begin
  select tax_rate_bp, prices_include_tax into rate, incl from branches where id = p_branch;
  if not p_taxable or coalesce(rate,0) = 0 then return query select p_amount, 0::bigint; return; end if;
  if incl then
    -- amount is gross: tax = amount - amount/(1+rate)
    tax_halalas := p_amount - round(p_amount::numeric * 10000 / (10000 + rate));
    return query select p_amount - tax_halalas, tax_halalas;
  else
    tax_halalas := round(p_amount::numeric * rate / 10000);
    return query select p_amount, tax_halalas;
  end if;
end $$;
grant execute on function fn_apply_tax(uuid, bigint, boolean) to authenticated;

-- Adds a charge line (+ its tax line) and recomputes. Internal.
create or replace function fn_add_charge(p_reservation uuid, p_kind text, p_description text, p_quantity numeric, p_unit_price bigint, p_taxable boolean, p_reason text, p_service uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; gross bigint; net bigint; tax bigint; cid uuid;
begin
  select * into r from reservations where id = p_reservation;
  gross := round(p_quantity * p_unit_price);
  if p_kind = 'discount' then gross := -abs(gross); end if;
  select * into net, tax from fn_apply_tax(r.branch_id, gross, p_taxable);
  insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, service_definition_id, reason, created_by)
  values (r.organization_id, r.branch_id, r.id, p_kind, p_description, p_quantity, p_unit_price, net, p_taxable, p_service, p_reason, fn_staff_id()) returning id into cid;
  if tax <> 0 then
    insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason, created_by)
    values (r.organization_id, r.branch_id, r.id, 'tax', 'ضريبة القيمة المضافة — ' || p_description, 1, tax, tax, false, p_reason, fn_staff_id());
  end if;
  return cid;
end $$;
revoke all on function fn_add_charge(uuid, text, text, numeric, bigint, boolean, text, uuid) from public, anon, authenticated;

-- =====================================================================
-- 3. Backfill existing reservations → charges / vouchers / allocations
-- =====================================================================
do $$
declare r record; v int := 0;
begin
  for r in select * from reservations loop
    if not exists (select 1 from reservation_charges where reservation_id = r.id) then
      if r.rent_amount_halalas > 0 then
        insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason)
        values (r.organization_id, r.branch_id, r.id, 'rent', 'إيجار الإقامة (ترحيل)', greatest(r.check_out - r.check_in, 1), r.rent_amount_halalas / greatest(r.check_out - r.check_in, 1), r.rent_amount_halalas, true, 'migration_0007');
      end if;
      if coalesce(r.addons_halalas,0) > 0 then
        insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason)
        values (r.organization_id, r.branch_id, r.id, 'addon', 'إضافات (ترحيل)', 1, r.addons_halalas, r.addons_halalas, true, 'migration_0007');
      end if;
      if coalesce(r.discount_halalas,0) > 0 then
        insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason)
        values (r.organization_id, r.branch_id, r.id, 'discount', 'خصم (ترحيل)', 1, r.discount_halalas, -r.discount_halalas, true, 'migration_0007');
      end if;
      if coalesce(r.taxes_halalas,0) > 0 then
        insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason)
        values (r.organization_id, r.branch_id, r.id, 'tax', 'ضريبة القيمة المضافة (ترحيل)', 1, r.taxes_halalas, r.taxes_halalas, false, 'migration_0007');
      end if;
    end if;
    -- verified provider/pos payments become receipt vouchers (one per transaction)
    insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, status, reference, payment_transaction_id, idempotency_key, content_hash, occurred_at, created_by)
    select r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', 'RCP'), 'receipt', p.amount_halalas, p.method, 'approved',
           coalesce(p.provider_ref, p.pos_ref), p.id, 'pt:' || p.id::text, md5(p.id::text || p.amount_halalas::text), coalesce(p.verified_at, p.created_at), p.verified_by
    from payment_transactions p where p.reservation_id = r.id and p.status = 'paid'
      and not exists (select 1 from financial_vouchers fv where fv.payment_transaction_id = p.id);
    -- current room → active allocation for the whole stay
    if r.room_id is not null and r.status in ('confirmed','checked_in','pending_verification')
       and not exists (select 1 from reservation_allocations a where a.reservation_id = r.id) then
      insert into reservation_allocations(reservation_id, room_id, branch_id, from_date, to_date, status, reason)
      values (r.id, r.room_id, r.branch_id, r.check_in, r.check_out, 'active', 'migration_0007');
    elsif r.room_id is not null and not exists (select 1 from reservation_allocations a where a.reservation_id = r.id) then
      insert into reservation_allocations(reservation_id, room_id, branch_id, from_date, to_date, status, reason, closed_at)
      values (r.id, r.room_id, r.branch_id, r.check_in, r.check_out, case when r.status in ('cancelled','rejected','no_show') then 'cancelled' else 'closed' end, 'migration_0007', now());
    end if;
    update reservations set nightly_rate_halalas = case when (check_out - check_in) > 0 then rent_amount_halalas / (check_out - check_in) else 0 end where id = r.id;
    perform fn_recompute_reservation_finance(r.id);
    v := v + 1;
  end loop;
  raise notice 'migration_0007: % reservations backfilled', v;
end $$;

-- =====================================================================
-- 4. Allocation helpers (all room/period changes go through here — no fast path)
-- =====================================================================
create or replace function fn_room_available(p_room uuid, p_from date, p_to date, p_exclude_reservation uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from rooms rm where rm.id = p_room and rm.branch_id in (select fn_user_branch_ids()))
     and not exists (
    select 1 from reservation_allocations a
    where a.room_id = p_room and a.status = 'active'
      and daterange(a.from_date, a.to_date, '[)') && daterange(p_from, p_to, '[)')
      and (p_exclude_reservation is null or a.reservation_id <> p_exclude_reservation));
$$;
grant execute on function fn_room_available(uuid, date, date, uuid) to authenticated;

-- rooms of a category free for [from,to) in a branch (active, not archived, not blocked/out of service/maintenance)
create or replace function fn_available_rooms(p_branch uuid, p_from date, p_to date, p_category uuid default null, p_exclude_reservation uuid default null)
returns table(room_id uuid, room_number text, category_id uuid, category_name text, status room_status, cleanliness text, block_name text, floor_name text)
language sql stable security definer set search_path = public as $$
  select r.id, r.room_number, r.category_id, c.name_ar, r.status, r.cleanliness, b.name, f.name
  from rooms r join room_categories c on c.id = r.category_id
  left join blocks b on b.id = r.block_id left join floors f on f.id = r.floor_id
  where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
    and r.is_active and r.archived_at is null
    and r.status not in ('blocked','out_of_service','maintenance')
    and (p_category is null or r.category_id = p_category)
    and fn_room_available(r.id, p_from, p_to, p_exclude_reservation)
  order by c.sort_order, r.room_number;
$$;
grant execute on function fn_available_rooms(uuid, date, date, uuid, uuid) to authenticated;

create or replace function fn_allocate(p_reservation uuid, p_room uuid, p_from date, p_to date, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; rm rooms%rowtype; aid uuid;
begin
  select * into r from reservations where id = p_reservation;
  select * into rm from rooms where id = p_room for update;
  if not found or rm.branch_id <> r.branch_id then raise exception 'ROOM_NOT_FOUND'; end if;
  if not rm.is_active or rm.archived_at is not null or rm.status in ('blocked','out_of_service','maintenance') then raise exception 'ROOM_NOT_AVAILABLE'; end if;
  if r.room_category_id is not null and rm.category_id <> r.room_category_id then raise exception 'ROOM_CATEGORY_MISMATCH'; end if;
  begin
    insert into reservation_allocations(reservation_id, room_id, branch_id, from_date, to_date, status, reason, created_by)
    values (r.id, p_room, r.branch_id, p_from, p_to, 'active', p_reason, fn_staff_id()) returning id into aid;
  exception when exclusion_violation then
    raise exception 'ALLOCATION_CONFLICT: room % is allocated during part of %–%', rm.room_number, p_from, p_to using errcode = '23P01';
  end;
  update reservations set room_id = p_room, updated_at = now() where id = r.id;
  -- 'reserved' is an operational flag for a stay that starts today or already started; future allocations keep the room sellable/cleanable today
  if rm.status in ('available','ready','cleaning') and r.status in ('confirmed','pending_verification') and p_from <= fn_branch_today(r.branch_id) then
    update rooms set status = 'reserved' where id = p_room;
  else
    perform fn_recompute_room_ready(p_room);   -- never leave a stale 'available': readiness is computed (ready / cleaning / maintenance)
  end if;
  return aid;
end $$;
revoke all on function fn_allocate(uuid, uuid, date, date, text) from public, anon, authenticated;

-- Releases every active allocation of a reservation (cancel / no-show / checkout) and recomputes room status
create or replace function fn_release_allocations(p_reservation uuid, p_mode text) returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  for a in select * from reservation_allocations where reservation_id = p_reservation and status = 'active' for update loop
    update reservation_allocations set status = case when p_mode = 'cancel' then 'cancelled' else 'closed' end, closed_at = now() where id = a.id;
    -- only an allocation covering today owns the room's 'reserved' flag; a future one must not disturb the current guest's room state
    if daterange(a.from_date, a.to_date, '[)') @> fn_branch_today(a.branch_id) then
      update rooms set status = 'available' where id = a.room_id and status = 'reserved';
      if p_mode = 'cancel' then perform fn_recompute_room_ready(a.room_id); end if;
    end if;
  end loop;
end $$;
revoke all on function fn_release_allocations(uuid, text) from public, anon, authenticated;

-- Legacy assign_room now goes through allocations
create or replace function fn_staff_assign_room(p_reservation uuid, p_room uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('confirmed','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if exists (select 1 from reservation_allocations where reservation_id = r.id and status = 'active') then
    raise exception 'ALREADY_ALLOCATED: use switch_room';
  end if;
  if not fn_room_available(p_room, r.check_in, r.check_out) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
  perform fn_allocate(r.id, p_room, r.check_in, r.check_out, 'assign');
  update reservations set version = version + 1 where id = r.id;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'assign_room', 'reservation', r.id, jsonb_build_object('room_id', p_room));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_assign_room(uuid, uuid) to authenticated;

-- =====================================================================
-- 5. Quote + create reservation (staff / direct / manual external import)
-- =====================================================================
create or replace function fn_staff_quote(p_branch uuid, p_category uuid, p_check_in date, p_check_out date, p_nightly_override bigint default null, p_discount_halalas bigint default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare nights int; rate bigint; rent bigint; rent_net bigint; rent_tax bigint; disc bigint; disc_net bigint; disc_tax bigint; cat room_categories%rowtype;
begin
  perform fn_require_branch(p_branch);
  if p_check_out <= p_check_in then raise exception 'VALIDATION: dates'; end if;
  nights := p_check_out - p_check_in;
  select * into cat from room_categories where id = p_category and branch_id = p_branch;
  if not found then raise exception 'BRANCH_MISMATCH: category'; end if;
  rate := coalesce(p_nightly_override, cat.base_price_halalas);
  if rate < 0 or coalesce(p_discount_halalas,0) < 0 then raise exception 'VALIDATION: amount'; end if;
  rent := rate * nights;
  select * into rent_net, rent_tax from fn_apply_tax(p_branch, rent, true);
  disc := -coalesce(p_discount_halalas,0);
  select * into disc_net, disc_tax from fn_apply_tax(p_branch, disc, true);
  return jsonb_build_object('nights', nights, 'nightly_rate', rate, 'rent', rent_net, 'discount', disc_net, 'tax', rent_tax + disc_tax,
                            'total', rent_net + disc_net + rent_tax + disc_tax, 'tax_rate_bp', (select tax_rate_bp from branches where id = p_branch),
                            'prices_include_tax', (select prices_include_tax from branches where id = p_branch));
end $$;
grant execute on function fn_staff_quote(uuid, uuid, date, date, bigint, bigint) to authenticated;

create or replace function fn_staff_create_reservation(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; v_room uuid := (p->>'room_id')::uuid;
        ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date; src booking_sources%rowtype; q jsonb; r reservations%rowtype;
        gp guest_profiles%rowtype; v_phone text := nullif(trim(p->>'guest_phone'),''); v_name text := trim(p->>'guest_name'); v_status reservation_status; ext text := nullif(trim(p->>'external_ref'),'');
        v_adults int := coalesce((p->>'adults')::int, 1); v_comp int := coalesce((p->>'companions')::int, 0); cap int;
begin
  perform fn_require_role('owner','manager','supervisor');
  perform fn_require_branch(v_branch);
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if coalesce(v_name,'') = '' then raise exception 'VALIDATION: guest_name'; end if;
  if v_adults < 1 or v_comp < 0 then raise exception 'VALIDATION: guests'; end if;
  select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id() and is_active;
  if not found then raise exception 'VALIDATION: source'; end if;
  if src.external_reference_required and ext is null then raise exception 'VALIDATION: external_ref_required'; end if;
  select max_capacity into cap from room_categories where id = v_cat and branch_id = v_branch and archived_at is null;
  if cap is null then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_adults + v_comp > cap then raise exception 'CAPACITY_EXCEEDED'; end if;
  if (p->>'discount_halalas')::bigint > 0 and not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: discount requires manager'; end if;
  if (p->>'nightly_rate_halalas') is not null and (p->>'nightly_rate_halalas')::bigint < (select base_price_halalas from room_categories where id = v_cat) and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: rate below base price requires manager';
  end if;

  q := fn_staff_quote(v_branch, v_cat, ci, co, (p->>'nightly_rate_halalas')::bigint, coalesce((p->>'discount_halalas')::bigint, 0));
  v_status := case when coalesce((p->>'confirm')::boolean, true) then 'confirmed' else 'pending_verification' end;

  -- guest profile: reuse by phone within org, never merge by name only
  if v_phone is not null then select * into gp from guest_profiles where organization_id = fn_user_org_id() and phone = v_phone limit 1; end if;
  if gp.id is null then
    insert into guest_profiles(organization_id, full_name, phone, nationality) values (fn_user_org_id(), v_name, v_phone, p->>'nationality') returning * into gp;
  end if;

  insert into reservations(organization_id, branch_id, external_ref, source_id, status, booking_type, company_name, visit_purpose, check_in, check_out, adults, companions,
                           room_category_id, nightly_rate_halalas, notes, created_by, identity_status, payment_status)
  values (fn_user_org_id(), v_branch, ext, src.id, v_status, coalesce(p->>'booking_type','individual'), p->>'company_name', p->>'visit_purpose', ci, co, v_adults, v_comp,
          v_cat, (q->>'nightly_rate')::bigint, p->>'notes', fn_staff_id(), 'not_started', 'pending') returning * into r;

  insert into reservation_guests(reservation_id, guest_profile_id, is_primary, full_name, phone, nationality) values (r.id, gp.id, true, v_name, v_phone, p->>'nationality');

  perform fn_add_charge(r.id, 'rent', 'إيجار ' || (q->>'nights') || ' ليلة × ' || ((q->>'nightly_rate')::bigint/100.0) || ' ر.س', (q->>'nights')::numeric, (q->>'nightly_rate')::bigint, true, null);
  if coalesce((p->>'discount_halalas')::bigint, 0) > 0 then
    perform fn_add_charge(r.id, 'discount', coalesce(nullif(p->>'discount_reason',''), 'خصم'), 1, (p->>'discount_halalas')::bigint, true, p->>'discount_reason');
  end if;
  if v_room is not null then
    if not fn_room_available(v_room, ci, co) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    perform fn_allocate(r.id, v_room, ci, co, 'create');
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.created', 'reservation', r.id, null, jsonb_build_object('internal_ref', r.internal_ref, 'source', src.code, 'external_ref', ext, 'check_in', ci, 'check_out', co, 'room_id', v_room, 'quote', q));
  return jsonb_build_object('ok', true, 'id', r.id, 'internal_ref', r.internal_ref, 'quote', q);
exception when unique_violation then
  raise exception 'DUPLICATE_EXTERNAL_REF';
end $$;
grant execute on function fn_staff_create_reservation(jsonb) to authenticated;

-- =====================================================================
-- 6. Amend stay (extend / shorten) — time, allocation and price change together (G06)
-- =====================================================================
create or replace function fn_staff_amend_stay(p_reservation uuid, p_new_check_out date, p_pricing_mode text, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; a reservation_allocations%rowtype; delta int; rate bigint; cat room_categories%rowtype; before jsonb; ch uuid;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_pricing_mode not in ('keep_rate','reprice') then raise exception 'VALIDATION: pricing_mode'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_new_check_out <= r.check_in then raise exception 'VALIDATION: dates'; end if;
  if r.status = 'checked_in' and p_new_check_out <= fn_branch_today(r.branch_id) and p_new_check_out < r.check_out then raise exception 'VALIDATION: checkout_in_past'; end if;
  delta := p_new_check_out - r.check_out;
  if delta = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  before := jsonb_build_object('check_out', r.check_out, 'total_halalas', r.total_halalas);

  select * into cat from room_categories where id = r.room_category_id;
  rate := case when p_pricing_mode = 'keep_rate' then r.nightly_rate_halalas else cat.base_price_halalas end;

  -- allocation: extend the current active allocation (exclusion constraint guards the added period)
  select * into a from reservation_allocations where reservation_id = r.id and status = 'active' order by to_date desc limit 1 for update;
  if found then
    if a.to_date <> r.check_out then raise exception 'ALLOCATION_MISMATCH: active allocation does not end at check_out'; end if;
    if a.to_date = r.check_out then
      if p_new_check_out <= a.from_date then raise exception 'VALIDATION: dates'; end if;
      begin
        update reservation_allocations set to_date = p_new_check_out where id = a.id;
      exception when exclusion_violation then
        raise exception 'ALLOCATION_CONFLICT: room is allocated during the added period' using errcode = '23P01';
      end;
    end if;
  end if;

  if delta > 0 then
    ch := fn_add_charge(r.id, 'rent', 'تمديد ' || delta || ' ليلة × ' || (rate/100.0) || ' ر.س', delta, rate, true, p_reason);
  else
    ch := fn_add_charge(r.id, 'adjustment', 'تقصير الإقامة ' || abs(delta) || ' ليلة', 1, -(abs(delta) * r.nightly_rate_halalas), true, p_reason);
  end if;
  update reservations set check_out = p_new_check_out, nightly_rate_halalas = case when p_pricing_mode = 'reprice' then rate else nightly_rate_halalas end, version = version + 1, updated_at = now() where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.departure_changed', 'reservation', r.id, before,
    jsonb_build_object('check_out', p_new_check_out, 'total_halalas', (select total_halalas from reservations where id = r.id), 'delta_nights', delta, 'pricing_mode', p_pricing_mode), p_reason);
  return jsonb_build_object('ok', true, 'delta_nights', delta, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_amend_stay(uuid, date, text, text, int) to authenticated;

-- =====================================================================
-- 7. Switch room (history preserved: old allocation closed, new one opened) — G07
-- =====================================================================
create or replace function fn_staff_switch_room(p_reservation uuid, p_room uuid, p_effective date, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; old reservation_allocations%rowtype; eff date; old_room uuid; new_rm rooms%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  eff := coalesce(p_effective, greatest(fn_branch_today(r.branch_id), r.check_in));
  if eff < r.check_in or eff >= r.check_out then raise exception 'VALIDATION: effective_date'; end if;
  if r.status = 'checked_in' and eff > fn_branch_today(r.branch_id) then raise exception 'VALIDATION: effective_date'; end if;   -- a resident moves now, not in the future
  select * into new_rm from rooms where id = p_room;
  if not found or new_rm.branch_id <> r.branch_id then raise exception 'ROOM_NOT_FOUND'; end if;            -- R06
  if r.room_id = p_room then raise exception 'SAME_ROOM'; end if;
  if r.status = 'checked_in' and new_rm.cleanliness <> 'clean' then raise exception 'ROOM_NOT_CLEAN'; end if;
  if r.adults + r.companions > (select max_capacity from room_categories where id = new_rm.category_id) then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- lock rooms in a fixed order to avoid deadlocks when two switches cross
  perform 1 from rooms where id in (p_room, r.room_id) order by id for update;

  select * into old from reservation_allocations where reservation_id = r.id and status = 'active' and daterange(from_date, to_date, '[)') @> eff for update;
  if found then
    if old.room_id = p_room then raise exception 'SAME_ROOM'; end if;
    old_room := old.room_id;
    if old.from_date = eff then
      update reservation_allocations set status = 'cancelled', closed_at = now(), reason = coalesce(reason,'') || ' | switched' where id = old.id;
    else
      update reservation_allocations set to_date = eff, status = case when eff <= current_date and r.status = 'checked_in' then 'closed' else 'active' end,
             closed_at = case when eff <= current_date and r.status = 'checked_in' then now() end where id = old.id;
    end if;
    if r.status = 'checked_in' then
      update rooms set status = 'cleaning', cleanliness = 'dirty' where id = old_room;
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      select r.organization_id, r.branch_id, old_room, t.id, t.name, r.id, 'high', 'تبديل وحدة', fn_staff_id() from task_types t where t.id = fn_room_cleaning_type(r.branch_id);
      update keyboxes set code_status = 'needs_change', field_tested = false where room_id = old_room;
    else
      update rooms set status = 'available' where id = old_room and status = 'reserved';
    end if;
  end if;

  -- category may differ on switch (upgrade/downgrade): price difference is a separate explicit adjustment
  update reservations set room_category_id = new_rm.category_id where id = r.id and r.room_category_id <> new_rm.category_id;
  perform fn_allocate(r.id, p_room, eff, r.check_out, 'switch: ' || p_reason);
  if r.status = 'checked_in' then
    update rooms set status = 'occupied' where id = p_room;
    update keyboxes set last_reservation_id = r.id where room_id = p_room;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, 'reservation.room_switched', 'reservation', r.id, jsonb_build_object('room_id', old_room), jsonb_build_object('room_id', p_room, 'effective', eff), p_reason);
  return jsonb_build_object('ok', true, 'from_room', old_room, 'to_room', p_room, 'effective', eff,
                            'entry_code_review_required', r.status = 'checked_in');
end $$;
grant execute on function fn_staff_switch_room(uuid, uuid, date, text, int) to authenticated;

-- =====================================================================
-- 8. Price adjustments, services, cancel, no-show
-- =====================================================================
create or replace function fn_staff_adjust_price(p_reservation uuid, p_kind text, p_amount_halalas bigint, p_description text, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; before jsonb;
begin
  if p_kind not in ('discount','adjustment','penalty','addon') then raise exception 'VALIDATION: kind'; end if;
  if p_kind in ('discount','adjustment') then perform fn_require_role('owner','manager'); else perform fn_require_role('owner','manager','supervisor'); end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_amount_halalas = 0 or (p_kind in ('discount','penalty','addon') and p_amount_halalas < 0) then raise exception 'VALIDATION: amount'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version(r.version, p_expected_version);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.status in ('checked_in','checked_out') and p_kind = 'discount' and not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: post-arrival discount'; end if;
  before := jsonb_build_object('total_halalas', r.total_halalas);
  perform fn_add_charge(r.id, p_kind, coalesce(nullif(trim(p_description),''), p_kind), 1, p_amount_halalas, true, p_reason);
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.total_changed', 'reservation', r.id, before, jsonb_build_object('total_halalas', (select total_halalas from reservations where id = r.id), 'kind', p_kind, 'amount_halalas', p_amount_halalas), p_reason);
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_adjust_price(uuid, text, bigint, text, text, int) to authenticated;

create or replace function fn_staff_add_service(p_reservation uuid, p_service uuid, p_quantity numeric default 1, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; s service_definitions%rowtype; qty numeric; price bigint;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  select * into s from service_definitions where id = p_service and branch_id = r.branch_id and archived_at is null and is_active;
  if not found then raise exception 'SERVICE_NOT_AVAILABLE'; end if;
  qty := case s.billing_unit when 'night' then (r.check_out - r.check_in) when 'person' then (r.adults + r.companions) when 'quantity' then coalesce(p_quantity,1) else 1 end;
  if qty <= 0 then raise exception 'VALIDATION: quantity'; end if;
  price := case when s.is_free then 0 else s.price_halalas end;
  -- snapshot name/price/tax at the time of adding (G27)
  perform fn_add_charge(r.id, 'addon', s.name_ar || case when p_note is not null then ' — ' || p_note else '' end, qty, price, s.taxable, null, s.id);
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.service_added', 'reservation', r.id, null, jsonb_build_object('service_id', s.id, 'name', s.name_ar, 'quantity', qty, 'unit_price', price));
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_add_service(uuid, uuid, numeric, text) to authenticated;

-- Cancellation: frees allocations, NEVER refunds automatically; idempotent for external events (R11/R12/G13)
create or replace function fn_staff_cancel_reservation(p_reservation uuid, p_reason text, p_source text default 'staff', p_external_event_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; ev integration_events%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if p_external_event_id is not null then
    insert into integration_events(organization_id, source, external_event_id, kind, reference, state)
    values (r.organization_id, coalesce(p_source,'ota'), p_external_event_id, 'reservation.cancelled', r.external_ref, 'received')
    on conflict (organization_id, source, external_event_id) do nothing;
    select * into ev from integration_events where organization_id = r.organization_id and source = coalesce(p_source,'ota') and external_event_id = p_external_event_id;
    if ev.state = 'processed' then
      update integration_events set attempts = attempts + 1 where id = ev.id;
      return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status);
    end if;
  end if;
  if r.status in ('cancelled','rejected','no_show') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status); end if;
  if r.status in ('checked_in','checked_out','closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  perform fn_release_allocations(r.id, 'cancel');
  update reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason, cancel_source = p_source, access_status = 'locked', version = version + 1, updated_at = now() where id = r.id;
  if ev.id is not null then update integration_events set state = 'processed', processed_at = now(), result = jsonb_build_object('reservation_id', r.id) where id = ev.id; end if;
  perform fn_audit_change(r.branch_id, 'reservation.cancelled', 'reservation', r.id, jsonb_build_object('status', r.status), jsonb_build_object('status', 'cancelled', 'source', p_source, 'external_event_id', p_external_event_id), p_reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'status', 'cancelled', 'refund_required_separately', (select (fn_reservation_finance_internal(r.id)->>'net_collected')::bigint > 0 or (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint > 0));
end $$;
grant execute on function fn_staff_cancel_reservation(uuid, text, text, text) to authenticated;

create or replace function fn_staff_no_show(p_reservation uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('confirmed','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;   -- R10
  if r.check_in > fn_branch_today(r.branch_id) then raise exception 'VALIDATION: arrival_not_due'; end if;
  perform fn_release_allocations(r.id, 'cancel');
  update reservations set status = 'no_show', no_show_at = now(), cancel_reason = p_reason, access_status = 'locked', version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, 'reservation.no_show', 'reservation', r.id, jsonb_build_object('status', r.status), jsonb_build_object('status', 'no_show'), p_reason);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_staff_no_show(uuid, text) to authenticated;

-- =====================================================================
-- 9. Vouchers: receipts, deposits, refunds, cancellation
-- =====================================================================
create or replace function fn_create_voucher(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint := (p->>'amount_halalas')::bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; prefix text;
begin
  if kind not in ('receipt','deposit') then raise exception 'VALIDATION: kind'; end if;
  perform fn_require_role('owner','manager','supervisor','finance');
  if amt is null or amt <= 0 then raise exception 'VALIDATION: amount'; end if;
  if coalesce(trim(key),'') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  if (p->>'method') is null then raise exception 'VALIDATION: method'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- serialises money ops per reservation
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled','rejected','no_show') and kind = 'deposit' then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  h := md5(r.id::text || kind || amt::text || (p->>'method') || coalesce(p->>'reference',''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;   -- F08
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  prefix := case kind when 'receipt' then 'RCP' else 'DEP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, status, reference, note, reason, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, (p->>'method')::payment_method, 'approved',
          p->>'reference', p->>'note', p->>'reason', key, h, coalesce((p->>'occurred_at')::timestamptz, now()), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null, jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', v.method, 'reference', v.reference, 'reservation_id', r.id));
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_create_voucher(jsonb) to authenticated;

-- Refund (stay) or deposit refund: never exceeds the available balance, even under concurrency (row lock on reservation) — G12/F05/F06/X02
create or replace function fn_refund(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint := (p->>'amount_halalas')::bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; f jsonb; available bigint; prefix text;
begin
  if kind not in ('refund','deposit_refund','deposit_apply') then raise exception 'VALIDATION: kind'; end if;
  perform fn_require_role('owner','manager','finance');
  if amt is null or amt <= 0 then raise exception 'VALIDATION: amount'; end if;
  if coalesce(trim(p->>'reason'),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if coalesce(trim(key),'') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- lock: concurrent refunds are serialised here
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  h := md5(r.id::text || kind || amt::text || coalesce(p->>'method','') || coalesce(p->>'reference',''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  f := fn_reservation_finance_internal(r.id);
  available := case kind when 'refund' then (f->>'received')::bigint - (f->>'refunded')::bigint else (f->>'deposit_balance')::bigint end;
  if amt > available then raise exception 'REFUND_EXCEEDS_AVAILABLE: available % halalas', available; end if;
  if kind = 'deposit_apply' and amt > (f->>'balance_due')::bigint then raise exception 'REFUND_EXCEEDS_AVAILABLE: nothing due'; end if;
  prefix := case kind when 'refund' then 'RFD' when 'deposit_refund' then 'DRF' else 'DAP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, status, reference, note, reason, original_voucher_id, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt,
          coalesce((p->>'method')::payment_method, 'cash'), 'approved', p->>'reference', p->>'note', p->>'reason', (p->>'original_voucher_id')::uuid, key, h, now(), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null, jsonb_build_object('number', v.number, 'amount_halalas', amt, 'reservation_id', r.id, 'available_before', available), p->>'reason');
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_refund(jsonb) to authenticated;

-- Cancel a voucher: reverses its effect, keeps history; cannot leave the deposit ledger negative (F11)
create or replace function fn_cancel_voucher(p_voucher uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v financial_vouchers%rowtype; r reservations%rowtype; f jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into v from financial_vouchers where id = p_voucher for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = v.reservation_id for update;
  perform fn_require_branch(v.branch_id);
  if v.status <> 'approved' then raise exception 'VOUCHER_STATUS_INVALID'; end if;
  update financial_vouchers set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = p_reason where id = v.id;
  f := fn_reservation_finance_internal(r.id);
  if (f->>'deposit_balance')::bigint < 0 or ((f->>'received')::bigint - (f->>'refunded')::bigint) < 0 then
    raise exception 'CANCEL_WOULD_GO_NEGATIVE';
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(v.branch_id, 'voucher.cancelled', 'voucher', v.id, jsonb_build_object('status', 'approved'), jsonb_build_object('status', 'cancelled', 'number', v.number, 'amount_halalas', v.amount_halalas), p_reason);
  return jsonb_build_object('ok', true, 'finance', f, 'provider_refund_note', 'إلغاء السند محلي؛ لا يعني أن مزود الدفع ردّ المبلغ.');
end $$;
grant execute on function fn_cancel_voucher(uuid, text) to authenticated;

-- Legacy payment confirmation now produces a receipt voucher (single ledger)
create or replace function fn_staff_confirm_payment(p_reservation uuid, p_method payment_method, p_amount_halalas bigint,
  p_reference text, p_idempotency_key text, p_provider text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; existing payment_transactions%rowtype; pt uuid; res jsonb;
begin
  perform fn_require_role('owner','manager','supervisor','finance');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if p_amount_halalas <= 0 then raise exception 'VALIDATION: amount'; end if;
  if coalesce(trim(p_reference),'') = '' then raise exception 'VALIDATION: reference_required'; end if;
  if coalesce(trim(p_idempotency_key),'') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into existing from payment_transactions where idempotency_key = p_idempotency_key;
  if found then
    if existing.reservation_id <> r.id then raise exception 'IDEMPOTENCY_CONFLICT: key already used for another reservation'; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', existing.id, 'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas);
  end if;
  insert into payment_transactions(reservation_id, method, amount_halalas, status, provider, provider_ref, pos_ref, verified_by, verified_at, idempotency_key)
  values (r.id, p_method, p_amount_halalas, 'paid', p_provider, case when p_method <> 'pos' then p_reference end, case when p_method = 'pos' then p_reference end, fn_staff_id(), now(), p_idempotency_key)
  returning id into pt;
  res := fn_create_voucher(jsonb_build_object('reservation_id', r.id, 'kind', 'receipt', 'amount_halalas', p_amount_halalas, 'method', p_method, 'reference', p_reference, 'idempotency_key', p_idempotency_key));
  update financial_vouchers set payment_transaction_id = pt where id = (res->>'voucher_id')::uuid;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'confirm_payment', 'reservation', r.id, jsonb_build_object('method', p_method, 'amount_halalas', p_amount_halalas, 'reference', p_reference));
  select * into r from reservations where id = r.id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas, 'voucher', res->>'number');
end $$;
grant execute on function fn_staff_confirm_payment(uuid, payment_method, bigint, text, text, text) to authenticated;

-- =====================================================================
-- 10. Invoices (snapshot, no silent edits, no double invoicing) — F12/F13/G15
-- =====================================================================
create or replace function fn_create_invoice(p_reservation uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; inv invoices%rowtype; lines jsonb; sub bigint; tax bigint; b branches%rowtype; g record; n int;
begin
  perform fn_require_role('owner','manager','supervisor','finance');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select count(*) into n from reservation_charges where reservation_id = r.id and invoice_id is null;
  if n = 0 then raise exception 'NOTHING_TO_INVOICE'; end if;
  select * into b from branches where id = r.branch_id;
  select full_name, nationality into g from reservation_guests where reservation_id = r.id and is_primary limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'description', description, 'quantity', quantity, 'unit_price_halalas', unit_price_halalas, 'total_halalas', total_halalas) order by created_at), '[]'::jsonb),
         coalesce(sum(total_halalas) filter (where kind <> 'tax'), 0), coalesce(sum(total_halalas) filter (where kind = 'tax'), 0)
    into lines, sub, tax from reservation_charges where reservation_id = r.id and invoice_id is null;
  insert into invoices(organization_id, branch_id, reservation_id, number, period_from, period_to, snapshot, subtotal_halalas, tax_halalas, total_halalas, issued_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'invoice', 'INV'), coalesce(p_from, r.check_in), coalesce(p_to, r.check_out),
          jsonb_build_object('property', jsonb_build_object('name', b.name_ar, 'tax_number', b.tax_number, 'commercial_register', b.commercial_register, 'address', b.address),
                             'guest', jsonb_build_object('name', g.full_name), 'reservation', jsonb_build_object('internal_ref', r.internal_ref, 'check_in', r.check_in, 'check_out', r.check_out),
                             'lines', lines, 'tax_rate_bp', b.tax_rate_bp),
          sub, tax, sub + tax, fn_staff_id()) returning * into inv;
  update reservation_charges set invoice_id = inv.id where reservation_id = r.id and invoice_id is null;
  perform fn_audit_change(r.branch_id, 'invoice.issued', 'invoice', inv.id, null, jsonb_build_object('number', inv.number, 'total_halalas', inv.total_halalas, 'reservation_id', r.id));
  return jsonb_build_object('ok', true, 'id', inv.id, 'number', inv.number, 'total_halalas', inv.total_halalas);
end $$;
grant execute on function fn_create_invoice(uuid, date, date) to authenticated;

create or replace function fn_cancel_invoice(p_invoice uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(inv.branch_id);
  if inv.status <> 'issued' then raise exception 'INVOICE_STATUS_INVALID'; end if;
  update invoices set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = p_reason where id = inv.id;
  update reservation_charges set invoice_id = null where invoice_id = inv.id;   -- lines become invoiceable again by a corrective document
  perform fn_audit_change(inv.branch_id, 'invoice.cancelled', 'invoice', inv.id, jsonb_build_object('status','issued'), jsonb_build_object('status','cancelled'), p_reason);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_cancel_invoice(uuid, text) to authenticated;

-- =====================================================================
-- 11. Check-out: allocations closed, cleaning task, deposit NOT auto-refunded (R14)
-- =====================================================================
create or replace function fn_staff_checkout(p_reservation uuid, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; f jsonb; remaining bigint; tt uuid; existing_task uuid;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status = 'checked_out' then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  if r.status <> 'checked_in' then raise exception 'NOT_CHECKED_IN'; end if;
  f := fn_recompute_reservation_finance(r.id);
  remaining := (f->>'balance_due')::bigint;
  if remaining > 0 then
    if coalesce(trim(p_override_reason),'') = '' or not fn_has_role('owner','manager') then
      return jsonb_build_object('ok', false, 'reasons', array['يوجد مبلغ متبقٍ ' || round(remaining/100.0, 2)::text || ' ر.س — يلزم السداد أو تجاوز بصلاحية مدير مع سبب']);
    end if;
  end if;
  update reservations set status = 'checked_out', actual_check_out = now(), version = version + 1, updated_at = now() where id = r.id;
  perform fn_release_allocations(r.id, 'close');
  if r.room_id is not null then
    update rooms set status = 'cleaning', cleanliness = 'dirty', updated_at = now() where id = r.room_id;
    tt := fn_room_cleaning_type(r.branch_id);
    select id into existing_task from housekeeping_tasks where room_id = r.room_id and reservation_id = r.id and status in ('pending','in_progress') limit 1;
    if existing_task is null then
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      values (r.organization_id, r.branch_id, r.room_id, tt, 'تنظيف الوحدة وتعقيمها', r.id, 'high', 'تنظيف بعد المغادرة', fn_staff_id());
    end if;
    update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id;
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'مغادرة — تنظيف وتغيير رمز مطلوب', 'غرفة ' || (select room_number from rooms where id = r.room_id), '/staff/housekeeping');
  end if;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'checkout', 'reservation', r.id,
                   jsonb_build_object('remaining_halalas', remaining, 'override_reason', p_override_reason, 'deposit_balance_halalas', (f->>'deposit_balance')::bigint));
  return jsonb_build_object('ok', true, 'deposit_to_settle_halalas', (f->>'deposit_balance')::bigint);
end $$;
grant execute on function fn_staff_checkout(uuid, text) to authenticated;

-- deliver access code must also keep allocations consistent (room occupied); patch: ensure allocation exists
create or replace function fn_ensure_allocation_on_checkin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'checked_in' and old.status <> 'checked_in' and new.room_id is not null
     and not exists (select 1 from reservation_allocations where reservation_id = new.id and status = 'active') then
    insert into reservation_allocations(reservation_id, room_id, branch_id, from_date, to_date, status, reason)
    values (new.id, new.room_id, new.branch_id, new.check_in, new.check_out, 'active', 'auto:checkin');
  end if;
  if new.status in ('cancelled','rejected','no_show') and old.status not in ('cancelled','rejected','no_show') then
    update reservation_allocations set status = 'cancelled', closed_at = now() where reservation_id = new.id and status = 'active';
  end if;
  return new;
end $$;
drop trigger if exists trg_reservation_allocation_sync on reservations;
create trigger trg_reservation_allocation_sync after update of status on reservations for each row execute function fn_ensure_allocation_on_checkin();

-- =====================================================================
-- 12. Operations board & daily summary (feed the UI and the AI ops assistant)
-- =====================================================================
create or replace function fn_ops_units_board(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'room_id', r.id, 'room_number', r.room_number, 'category', c.name_ar, 'block', b.name, 'floor', f.name,
    'is_active', r.is_active, 'status', r.status, 'cleanliness', r.cleanliness,
    'open_tasks', (select count(*) from housekeeping_tasks h where h.room_id = r.id and h.status in ('pending','in_progress')),
    'open_maintenance', (select count(*) from maintenance_tickets m where m.room_id = r.id and m.status <> 'resolved'),
    'keybox_ready', exists (select 1 from keyboxes k where k.room_id = r.id and k.code_status = 'active' and k.field_tested),
    'current', (select jsonb_build_object('reservation_id', rs.id, 'internal_ref', rs.internal_ref, 'status', rs.status, 'check_in', rs.check_in, 'check_out', rs.check_out,
                                          'guest', left(coalesce((select full_name from reservation_guests g where g.reservation_id = rs.id and g.is_primary limit 1), '—'), 40),
                                          'balance_due', rs.balance_due_halalas)
                from reservation_allocations a join reservations rs on rs.id = a.reservation_id
                where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','checked_in','pending_verification')
                  -- a resident stays "current" on departure day and while overstaying, until checkout closes the allocation
                  and a.from_date <= fn_branch_today(p_branch) and (fn_branch_today(p_branch) < a.to_date or rs.status = 'checked_in')
                order by rs.status = 'checked_in' desc limit 1),
    'next', (select jsonb_build_object('internal_ref', rs.internal_ref, 'check_in', rs.check_in)
             from reservation_allocations a join reservations rs on rs.id = a.reservation_id
             where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','pending_verification') and a.from_date > fn_branch_today(p_branch) order by a.from_date limit 1)
  ) order by c.sort_order, r.room_number), '[]'::jsonb)
  from rooms r join room_categories c on c.id = r.category_id left join blocks b on b.id = r.block_id left join floors f on f.id = r.floor_id
  where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids()) and r.archived_at is null;
$$;
grant execute on function fn_ops_units_board(uuid) to authenticated;

create or replace function fn_ops_daily_summary_at(p_branch uuid, p_date date) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p_branch in (select fn_user_branch_ids()) then jsonb_build_object(
    'date', p_date,
    'units', jsonb_build_object(
      'active', (select count(*) from rooms where branch_id = p_branch and is_active and archived_at is null),
      'occupied', (select count(*) from rooms where branch_id = p_branch and status = 'occupied'),
      'reserved', (select count(*) from rooms where branch_id = p_branch and status = 'reserved'),
      'ready', (select count(*) from rooms where branch_id = p_branch and status = 'ready'),
      'dirty', (select count(*) from rooms where branch_id = p_branch and is_active and cleanliness <> 'clean'),
      'maintenance', (select count(*) from rooms where branch_id = p_branch and status = 'maintenance'),
      'out_of_service', (select count(*) from rooms where branch_id = p_branch and (status = 'out_of_service' or not is_active))),
    'occupancy_pct', (select case when count(*) filter (where is_active and archived_at is null) = 0 then 0
                        else round(100.0 * count(*) filter (where status = 'occupied') / count(*) filter (where is_active and archived_at is null), 1) end from rooms where branch_id = p_branch),
    'arrivals', jsonb_build_object(
      'expected', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status in ('confirmed','pending_verification')),
      'arrived', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status = 'checked_in'),
      'pending_identity', (select count(*) from reservations where branch_id = p_branch and check_in <= p_date and check_out > p_date and status in ('confirmed','pending_verification') and identity_status <> 'verified'),
      'unpaid', (select count(*) from reservations where branch_id = p_branch and check_in = p_date and status in ('confirmed','pending_verification') and balance_due_halalas > 0),
      'overdue', (select count(*) from reservations where branch_id = p_branch and check_in < p_date and status in ('confirmed','pending_verification'))),
    'departures', jsonb_build_object(
      'expected', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_in'),
      'done', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_out'),
      'overstay', (select count(*) from reservations where branch_id = p_branch and check_out < p_date and status = 'checked_in'),
      'with_balance', (select count(*) from reservations where branch_id = p_branch and check_out = p_date and status = 'checked_in' and balance_due_halalas > 0)),
    'housekeeping', jsonb_build_object(
      'open', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'pending'),
      'in_progress', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'in_progress'),
      'completed_today', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'completed' and completed_at::date = p_date),
      'unassigned', (select count(*) from housekeeping_tasks where branch_id = p_branch and status = 'pending' and assignee_id is null)),
    'finance', jsonb_build_object(
      'received_today', (select coalesce(sum(amount_halalas),0) from financial_vouchers where branch_id = p_branch and kind = 'receipt' and status = 'approved' and occurred_at::date = p_date),
      'refunded_today', (select coalesce(sum(amount_halalas),0) from financial_vouchers where branch_id = p_branch and kind = 'refund' and status = 'approved' and occurred_at::date = p_date),
      'deposits_held', (select coalesce(sum(deposit_balance_halalas),0) from reservations where branch_id = p_branch and status in ('confirmed','checked_in','checked_out')),
      'outstanding_in_house', (select coalesce(sum(balance_due_halalas),0) from reservations where branch_id = p_branch and status = 'checked_in'),
      'deposit_to_settle_after_checkout', (select coalesce(sum(deposit_balance_halalas),0) from reservations where branch_id = p_branch and status = 'checked_out' and deposit_balance_halalas > 0)),
    'tickets_open', (select count(*) from human_handoff_tickets where branch_id = p_branch and status = 'open'),
    'generated_at', now()
  ) else null end;
$$;
revoke all on function fn_ops_daily_summary_at(uuid, date) from public, anon, authenticated;

create or replace function fn_ops_daily_summary(p_branch uuid, p_date date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select fn_ops_daily_summary_at(p_branch, coalesce(p_date, fn_branch_today(p_branch)));
$$;
grant execute on function fn_ops_daily_summary(uuid, date) to authenticated;

-- Reservation detail bundle for the UI (guests, allocations, charges, vouchers, invoices, finance)
create or replace function fn_reservation_detail(p_reservation uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when r.branch_id in (select fn_user_branch_ids()) then jsonb_build_object(
    'reservation', case when fn_has_role('owner','manager','supervisor','finance') then to_jsonb(r) - 'notes'
                        else to_jsonb(r) - 'notes' - 'total_halalas' - 'paid_halalas' - 'rent_amount_halalas' - 'discount_halalas' - 'addons_halalas' - 'taxes_halalas'
                             - 'balance_due_halalas' - 'deposit_balance_halalas' - 'refunded_halalas' - 'nightly_rate_halalas' - 'payment_status' - 'company_name' - 'gov_registration_ref' end,
    'notes', r.notes,
    'source', (select jsonb_build_object('name', name, 'code', code, 'kind', kind) from booking_sources where id = r.source_id),
    'category', (select name_ar from room_categories where id = r.room_category_id),
    'room', (select jsonb_build_object('id', id, 'room_number', room_number, 'status', status, 'cleanliness', cleanliness) from rooms where id = r.room_id),
    'guests', case when fn_has_role('owner','manager','supervisor','finance') then (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'is_primary', g.is_primary, 'full_name', g.full_name, 'identity_type', g.identity_type, 'identity_number_last4', g.identity_number_last4,
                 'nationality', g.nationality, 'phone', case when fn_has_role('owner','manager','supervisor') then g.phone end, 'verification_status', g.verification_status, 'data_submitted', g.data_submitted) order by g.is_primary desc), '[]'::jsonb)
               from reservation_guests g where g.reservation_id = r.id) end,
    'allocations', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'room_number', rm.room_number, 'from_date', a.from_date, 'to_date', a.to_date, 'status', a.status, 'reason', a.reason, 'created_at', a.created_at) order by a.from_date, a.created_at), '[]'::jsonb)
                    from reservation_allocations a join rooms rm on rm.id = a.room_id where a.reservation_id = r.id),
    'charges', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at), '[]'::jsonb) from reservation_charges c where c.reservation_id = r.id) end,
    'vouchers', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg(to_jsonb(v) - 'content_hash' order by v.occurred_at), '[]'::jsonb) from financial_vouchers v where v.reservation_id = r.id) end,
    'invoices', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number, 'status', i.status, 'total_halalas', i.total_halalas, 'issued_at', i.issued_at, 'period_from', i.period_from, 'period_to', i.period_to) order by i.issued_at), '[]'::jsonb) from invoices i where i.reservation_id = r.id) end,
    'finance', case when fn_has_role('owner','manager','supervisor','finance') then fn_reservation_finance_internal(r.id) end,
    'history', case when fn_has_role('owner','manager','supervisor') then (select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'at', e.created_at, 'actor', (select full_name from staff_profiles where id = e.actor_id), 'details', e.details) order by e.created_at desc), '[]'::jsonb)
                from (select * from audit_events where entity_id = r.id order by created_at desc limit 50) e) end
  ) end
  from reservations r where r.id = p_reservation;
$$;
grant execute on function fn_reservation_detail(uuid) to authenticated;

-- Reservation list with finance columns, filters, and server-side paging (export = same query, G25)
create or replace function fn_reservation_list(p_branch uuid, p_filters jsonb default '{}'::jsonb, p_limit int default 50, p_offset int default 0) returns jsonb
language sql stable security definer set search_path = public as $$
  with base as (
    select r.*, (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1) as guest_name,
           (select room_number from rooms where id = r.room_id) as room_number, (select name from booking_sources where id = r.source_id) as source_name,
           (select name_ar from room_categories where id = r.room_category_id) as category_name
    from reservations r
    where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
      and (coalesce(p_filters->>'status','') = '' or r.status::text = any(string_to_array(p_filters->>'status', ',')))
      and (coalesce(p_filters->>'open_only','false') <> 'true' or r.status in ('pending_verification','confirmed','checked_in'))
      and (p_filters->>'check_in_from' is null or r.check_in >= (p_filters->>'check_in_from')::date)
      and (p_filters->>'check_in_to' is null or r.check_in <= (p_filters->>'check_in_to')::date)
      and (p_filters->>'check_out_from' is null or r.check_out >= (p_filters->>'check_out_from')::date)
      and (p_filters->>'check_out_to' is null or r.check_out <= (p_filters->>'check_out_to')::date)
      and (p_filters->>'source_id' is null or r.source_id = (p_filters->>'source_id')::uuid)
      and (coalesce(p_filters->>'has_balance','false') <> 'true' or r.balance_due_halalas > 0)
      and (coalesce(p_filters->>'q','') = '' or r.internal_ref ilike '%' || (p_filters->>'q') || '%' or coalesce(r.external_ref,'') ilike '%' || (p_filters->>'q') || '%'
           or exists (select 1 from reservation_guests g where g.reservation_id = r.id and (g.full_name ilike '%' || (p_filters->>'q') || '%' or g.phone like '%' || (p_filters->>'q') || '%')))
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'status', status, 'check_in', check_in, 'check_out', check_out,
               'nights', check_out - check_in, 'guest_name', guest_name, 'room_number', room_number, 'source_name', source_name, 'category_name', category_name,
               'total_halalas', total_halalas, 'paid_halalas', paid_halalas, 'balance_due_halalas', balance_due_halalas, 'deposit_balance_halalas', deposit_balance_halalas,
               'payment_status', payment_status, 'identity_status', identity_status, 'access_status', access_status, 'created_at', created_at) order by check_in desc, created_at desc), '[]'::jsonb)
             from (select * from base order by check_in desc, created_at desc limit p_limit offset p_offset) b));
$$;
grant execute on function fn_reservation_list(uuid, jsonb, int, int) to authenticated;
