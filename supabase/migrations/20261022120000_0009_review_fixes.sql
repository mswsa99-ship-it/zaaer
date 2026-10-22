/*
# 0009 — Review fixes (external review findings A03 / A04 / A05 / A06 / A09 + money column gate)

Nothing in earlier migrations is edited; every change below is a new definition that replaces the
previous one (create or replace / drop policy + create policy / revoke + grant).

  A06  fn_check_version_strict: the critical update RPCs now REQUIRE the expected version
       (VERSION_REQUIRED when it is missing, VERSION_CONFLICT when it differs). Enforced for the
       definition upserts when `id` is present (block / floor / room category / room / facility /
       task type / service), fn_staff_adjust_price, fn_staff_amend_stay, fn_staff_switch_room and
       fn_hk_complete_task. Every UI caller already sends the version (verified in src/lib/api.ts,
       src/pages, src/components before enforcing). Internal callers:
         * fn_staff_complete_cleaning (legacy wrapper, no version in its signature) resolves the
           current version under the row lock before delegating.
         * AI proposals capture the target's version at proposal time (fn_ai_ops_propose) and the
           executor passes it on, so a record that changed between proposal and confirmation is
           rejected with VERSION_CONFLICT and the proposal is marked failed — never silently applied.
  A04  reservation_charges.service_from / service_to: every charge carries the period it is for.
       Backfill rules (existing rows):
         * rows written by the 0007 migration (reason = 'migration_0007')  → the stay (check_in..check_out)
         * rent rows → reconstructed cumulatively per reservation from their night quantities,
           in creation order: [check_in, check_in + q1), [check_in + q1, check_in + q1 + q2) …
           (an extension row therefore carries the extended nights, not the whole stay)
         * discount / adjustment rows → the stay (they modify the price of the stay, not of a day)
         * tax rows → the period of the line they were computed from (same reservation, same instant,
           matching description); orphan tax rows → the day they were recorded
         * everything else (addon, penalty) → the day they were recorded (branch calendar)
       New rows: fn_add_charge defaults rent/discount/adjustment to the stay and everything else to the
       branch's current day; fn_staff_amend_stay passes the extended (or removed) nights explicitly;
       fn_staff_add_service passes the stay for per-night services.
       fn_create_invoice with a period includes only uninvoiced charges whose [service_from, service_to]
       lies within [p_from, p_to]; without a period it includes every uninvoiced charge and derives the
       period from them. The snapshot stores the included charge ids and each line's period.
  A03  fn_staff_confirm_payment: a replayed idempotency key is compared by content hash
       (reservation, method, amount, reference). Same key + different content → IDEMPOTENCY_CONFLICT;
       same content → duplicate response built from the STORED voucher / transaction. The key space is
       shared with fn_create_voucher (financial_vouchers(organization_id, idempotency_key) is unique),
       so the two paths can never record the same key twice.
  A09  owner_memberships_write: the staff being assigned AND the branch must both belong to the
       owner's organization.
  gate reservations money columns (rent/discount/addons/taxes/total/paid/nightly rate/deposit balance/
       refunded/balance due) are no longer selectable through the table by the API roles; they are
       exposed only by the role-gated RPCs fn_reservation_detail, fn_reservation_list (money roles only),
       fn_reservation_finance and fn_reports_finance. payment_status stays readable.
  A05  fn_reports_finance(p_branch, p_from, p_to): ledger-based finance report (owner/manager/finance,
       branch-gated). Revenue = approved vouchers by occurred_at; deposits are never revenue.
*/

-- =====================================================================
-- 1. A06 — strict optimistic locking
-- =====================================================================
create or replace function fn_check_version_strict(p_current int, p_expected int) returns void
language plpgsql immutable as $$
begin
  if p_expected is null then
    raise exception 'VERSION_REQUIRED: expected version must be supplied' using errcode = '22004';
  end if;
  if p_current <> p_expected then
    raise exception 'VERSION_CONFLICT: record changed by another user' using errcode = '40001';
  end if;
end $$;

-- Definition upserts: identical to 0007b except that an update (id present) now requires the version.
create or replace function fn_admin_upsert_block(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b blocks%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into blocks(organization_id, branch_id, name, description, sort_order, created_by)
    values (fn_user_org_id(), v_branch, trim(p->>'name'), p->>'description', coalesce((p->>'sort_order')::int,0), fn_staff_id()) returning * into b;
    perform fn_audit_change(b.branch_id, 'block.created', 'block', b.id, null, to_jsonb(b));
  else
    select * into b from blocks where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.branch_id);
    perform fn_check_version_strict(b.version, (p->>'version')::int);
    before := to_jsonb(b);
    update blocks set name = trim(p->>'name'), description = p->>'description', sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = b.id returning * into b;
    perform fn_audit_change(b.branch_id, 'block.updated', 'block', b.id, before, to_jsonb(b));
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_block(jsonb) to authenticated;

create or replace function fn_admin_upsert_floor(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f floors%rowtype; blk blocks%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    select * into blk from blocks where id = (p->>'block_id')::uuid;
    if not found then raise exception 'NOT_FOUND: block'; end if;
    perform fn_require_branch(blk.branch_id);
    insert into floors(organization_id, branch_id, block_id, name, sort_order)
    values (blk.organization_id, blk.branch_id, blk.id, trim(p->>'name'), coalesce((p->>'sort_order')::int,0)) returning * into f;
    perform fn_audit_change(f.branch_id, 'floor.created', 'floor', f.id, null, to_jsonb(f));
  else
    select * into f from floors where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(f.branch_id);
    perform fn_check_version_strict(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update floors set name = trim(p->>'name'), sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'floor.updated', 'floor', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_floor(jsonb) to authenticated;

create or replace function fn_admin_upsert_room_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c room_categories%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'base_price_halalas') and (p->>'base_price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into room_categories(organization_id, branch_id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, amenities, is_public, sort_order)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', coalesce((p->>'base_capacity')::int,2), coalesce((p->>'max_capacity')::int,4),
            coalesce((p->>'base_price_halalas')::bigint, 0), coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'amenities','[]'::jsonb)) x), '{}'),
            coalesce((p->>'is_public')::boolean, true), coalesce((p->>'sort_order')::int, 0)) returning * into c;
    perform fn_audit_change(c.branch_id, 'room_category.created', 'room_category', c.id, null, to_jsonb(c));
  else
    select * into c from room_categories where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(c.branch_id);
    perform fn_check_version_strict(c.version, (p->>'version')::int);
    before := to_jsonb(c);
    -- changing base price never reprices existing reservations (charges are snapshots)
    update room_categories set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      base_capacity = coalesce((p->>'base_capacity')::int, base_capacity), max_capacity = coalesce((p->>'max_capacity')::int, max_capacity),
      base_price_halalas = coalesce((p->>'base_price_halalas')::bigint, base_price_halalas),
      amenities = case when p ? 'amenities' then (select array_agg(x) from jsonb_array_elements_text(p->'amenities') x) else amenities end,
      is_public = coalesce((p->>'is_public')::boolean, is_public), is_active = coalesce((p->>'is_active')::boolean, is_active),
      sort_order = coalesce((p->>'sort_order')::int, sort_order), version = version + 1, updated_at = now()
    where id = c.id returning * into c;
    if c.max_capacity < c.base_capacity then raise exception 'VALIDATION: capacity'; end if;
    perform fn_audit_change(c.branch_id, 'room_category.updated', 'room_category', c.id, before, to_jsonb(c));
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version);
end $$;
grant execute on function fn_admin_upsert_room_category(jsonb) to authenticated;

create or replace function fn_admin_upsert_room(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rooms%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid;
        v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; before jsonb; future_count int;
begin
  perform fn_require_role('owner','manager');
  if v_id is not null then
    select * into r from rooms where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := r.branch_id;
    v_block := coalesce(v_block, r.block_id); v_floor := coalesce(v_floor, r.floor_id); v_cat := coalesce(v_cat, r.category_id);
  end if;
  perform fn_require_branch(v_branch);
  if coalesce(trim(p->>'room_number'),'') = '' and v_id is null then raise exception 'VALIDATION: room_number'; end if;
  -- cross-relation consistency: every parent must belong to the same branch (A02)
  if v_cat is null or not exists (select 1 from room_categories where id = v_cat and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_block is not null and not exists (select 1 from blocks where id = v_block and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if v_floor is not null and not exists (select 1 from floors where id = v_floor and branch_id = v_branch and (v_block is null or block_id = v_block)) then raise exception 'BRANCH_MISMATCH: floor'; end if;

  if v_id is null then
    insert into rooms(organization_id, branch_id, category_id, block_id, floor_id, room_number, floor, status, notes, is_active)
    values (fn_user_org_id(), v_branch, v_cat, v_block, v_floor, trim(p->>'room_number'), coalesce((p->>'floor')::int,1), 'available', p->>'notes', coalesce((p->>'is_active')::boolean, true))
    returning * into r;
    perform fn_audit_change(r.branch_id, 'room.created', 'room', r.id, null, to_jsonb(r));
  else
    perform fn_check_version_strict(r.version, (p->>'version')::int);
    before := to_jsonb(r);
    -- deactivating a room with future/active commitments is blocked until they are resolved (A09 / G17)
    if (p->>'is_active')::boolean is false and r.is_active then
      select count(*) into future_count from reservation_allocations a join reservations rs on rs.id = a.reservation_id
        where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(r.branch_id);
      if future_count > 0 then
        raise exception 'HAS_FUTURE_COMMITMENTS: % allocation(s)', future_count;
      end if;
    end if;
    update rooms set room_number = coalesce(nullif(trim(p->>'room_number'),''), room_number), category_id = v_cat, block_id = v_block, floor_id = v_floor,
      floor = coalesce((p->>'floor')::int, floor), notes = coalesce(p->>'notes', notes), is_active = coalesce((p->>'is_active')::boolean, is_active),
      status = case when coalesce((p->>'is_active')::boolean, is_active) = false then 'out_of_service'
                    when coalesce((p->>'is_active')::boolean, is_active) and status = 'out_of_service' then 'available' else status end,
      version = version + 1, updated_at = now()
    where id = r.id returning * into r;
    perform fn_audit_change(r.branch_id, 'room.updated', 'room', r.id, before, to_jsonb(r));
  end if;
  return jsonb_build_object('ok', true, 'id', r.id, 'version', r.version);
exception when unique_violation then raise exception 'DUPLICATE_ROOM_NUMBER';
end $$;
grant execute on function fn_admin_upsert_room(jsonb) to authenticated;

create or replace function fn_admin_upsert_facility(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f facilities%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is not null then
    select * into f from facilities where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := f.branch_id;
    if p ? 'block_id' then v_block := (p->>'block_id')::uuid; else v_block := f.block_id; end if;
    if p ? 'floor_id' then v_floor := (p->>'floor_id')::uuid; else v_floor := f.floor_id; end if;
  end if;
  perform fn_require_branch(v_branch);
  if v_block is not null and not exists (select 1 from blocks where id = v_block and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if v_floor is not null and not exists (select 1 from floors where id = v_floor and branch_id = v_branch and (v_block is null or block_id = v_block)) then raise exception 'BRANCH_MISMATCH: floor'; end if;
  if v_id is null then
    insert into facilities(organization_id, branch_id, block_id, floor_id, name, description, images, created_by)
    values (fn_user_org_id(), v_branch, v_block, v_floor, trim(p->>'name'), p->>'description', coalesce(p->'images','[]'::jsonb), fn_staff_id()) returning * into f;
    perform fn_audit_change(f.branch_id, 'facility.created', 'facility', f.id, null, to_jsonb(f));
  else
    perform fn_check_version_strict(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update facilities set name = trim(p->>'name'), description = p->>'description', block_id = v_block, floor_id = v_floor,
      images = coalesce(p->'images', images), is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'facility.updated', 'facility', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_facility(jsonb) to authenticated;

create or replace function fn_admin_upsert_task_type(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t task_types%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into task_types(organization_id, branch_id, name, description) values (fn_user_org_id(), v_branch, trim(p->>'name'), p->>'description') returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.created', 'task_type', t.id, null, to_jsonb(t));
  else
    select * into t from task_types where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(t.branch_id);
    perform fn_check_version_strict(t.version, (p->>'version')::int);
    before := to_jsonb(t);
    -- renaming never rewrites task_type_name_snapshot on historical tasks
    update task_types set name = trim(p->>'name'), description = p->>'description', is_active = coalesce((p->>'is_active')::boolean, is_active),
      version = version + 1, updated_at = now() where id = t.id returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.updated', 'task_type', t.id, before, to_jsonb(t));
  end if;
  return jsonb_build_object('ok', true, 'id', t.id, 'version', t.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_task_type(jsonb) to authenticated;

create or replace function fn_admin_upsert_service(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s service_definitions%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_tt uuid := (p->>'task_type_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'price_halalas') and (p->>'price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  if v_id is not null then
    select * into s from service_definitions where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := s.branch_id;
    if not (p ? 'task_type_id') then v_tt := s.task_type_id; end if;
  end if;
  perform fn_require_branch(v_branch);
  if v_tt is not null and not exists (select 1 from task_types where id = v_tt and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: task_type'; end if;
  if v_id is null then
    insert into service_definitions(organization_id, branch_id, name_ar, name_en, description, billing_unit, price_halalas, is_free, taxable, task_type_id)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', coalesce(p->>'billing_unit','once'),
            coalesce((p->>'price_halalas')::bigint,0), coalesce((p->>'is_free')::boolean,false), coalesce((p->>'taxable')::boolean,true), v_tt) returning * into s;
    perform fn_audit_change(s.branch_id, 'service.created', 'service', s.id, null, to_jsonb(s));
  else
    perform fn_check_version_strict(s.version, (p->>'version')::int);
    before := to_jsonb(s);
    -- catalogue edits never touch historical reservation_charges (snapshots) — G27
    update service_definitions set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      billing_unit = coalesce(p->>'billing_unit', billing_unit), price_halalas = coalesce((p->>'price_halalas')::bigint, price_halalas),
      is_free = coalesce((p->>'is_free')::boolean, is_free), taxable = coalesce((p->>'taxable')::boolean, taxable), task_type_id = v_tt,
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = s.id returning * into s;
    perform fn_audit_change(s.branch_id, 'service.updated', 'service', s.id, before, to_jsonb(s));
  end if;
  return jsonb_build_object('ok', true, 'id', s.id, 'version', s.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_service(jsonb) to authenticated;

-- =====================================================================
-- 2. A04 — charges carry their service period; invoices are truthful about it
-- =====================================================================
alter table reservation_charges add column if not exists service_from date;
alter table reservation_charges add column if not exists service_to date;

-- 2a. backfill (rules in the header)
update reservation_charges c set service_from = r.check_in, service_to = r.check_out
  from reservations r where r.id = c.reservation_id and c.service_from is null and c.reason = 'migration_0007';

with rent as (
  select c.id, r.check_in, c.quantity,
         sum(c.quantity) over (partition by c.reservation_id order by c.created_at, c.id rows between unbounded preceding and current row) as cum
  from reservation_charges c join reservations r on r.id = c.reservation_id
  where c.kind = 'rent' and c.service_from is null)
update reservation_charges c set service_from = rent.check_in + (rent.cum - rent.quantity)::int, service_to = rent.check_in + rent.cum::int
  from rent where rent.id = c.id;

update reservation_charges c set service_from = r.check_in, service_to = r.check_out
  from reservations r where r.id = c.reservation_id and c.service_from is null and c.kind in ('discount','adjustment');

update reservation_charges t set service_from = p.service_from, service_to = p.service_to
  from reservation_charges p
  where t.kind = 'tax' and t.service_from is null and p.kind <> 'tax' and p.service_from is not null
    and p.reservation_id = t.reservation_id and p.created_at = t.created_at and t.description = 'ضريبة القيمة المضافة — ' || p.description;

update reservation_charges c set service_from = (c.created_at at time zone coalesce(b.timezone, 'Asia/Riyadh'))::date,
                                service_to   = (c.created_at at time zone coalesce(b.timezone, 'Asia/Riyadh'))::date
  from branches b where b.id = c.branch_id and c.service_from is null;

-- any charge whose reconstruction produced an inverted period (defensive; never expected) collapses to its start day
update reservation_charges set service_to = service_from where service_to < service_from;

alter table reservation_charges alter column service_from set not null;
alter table reservation_charges alter column service_to set not null;
alter table reservation_charges drop constraint if exists charge_service_period_valid;
alter table reservation_charges add constraint charge_service_period_valid check (service_to >= service_from);
create index if not exists idx_charges_uninvoiced_period on reservation_charges(reservation_id, service_from, service_to) where invoice_id is null;

-- 2b. fn_add_charge now records the service period (explicit, or defaulted per kind). The previous
--     signature is dropped so the 7/8-argument calls in existing RPCs resolve to this one unambiguously.
drop function if exists fn_add_charge(uuid, text, text, numeric, bigint, boolean, text, uuid);
create or replace function fn_add_charge(p_reservation uuid, p_kind text, p_description text, p_quantity numeric, p_unit_price bigint, p_taxable boolean, p_reason text,
                                         p_service uuid default null, p_service_from date default null, p_service_to date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; gross bigint; net bigint; tax bigint; cid uuid; sf date; st date; today date;
begin
  select * into r from reservations where id = p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  gross := round(p_quantity * p_unit_price);
  if p_kind = 'discount' then gross := -abs(gross); end if;
  select * into net, tax from fn_apply_tax(r.branch_id, gross, p_taxable);
  -- service period (A04): rent and stay-price modifications default to the stay, everything else to the branch's current day
  today := fn_branch_today(r.branch_id);
  sf := coalesce(p_service_from, case when p_kind in ('rent','discount','adjustment') then r.check_in else today end);
  st := coalesce(p_service_to,   case when p_kind in ('rent','discount','adjustment') then r.check_out else today end);
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

-- 2c. Invoices: a period selects the charges; no period = every uninvoiced charge, period derived from them.
--     The snapshot keeps the included charge ids and each line's service period (F12/F13 unchanged:
--     a line is invoiced once; fn_cancel_invoice releases the lines of that invoice only).
create or replace function fn_create_invoice(p_reservation uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; inv invoices%rowtype; lines jsonb; ids uuid[]; sub bigint; tax bigint; b branches%rowtype; g record; n int; pf date; pt date;
begin
  perform fn_require_role('owner','manager','supervisor','finance');
  if (p_from is null) <> (p_to is null) then raise exception 'VALIDATION: period'; end if;
  if p_from is not null and p_to < p_from then raise exception 'VALIDATION: period'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select coalesce(array_agg(id order by created_at, id), '{}'::uuid[]), count(*), min(service_from), max(service_to)
    into ids, n, pf, pt
    from reservation_charges
    where reservation_id = r.id and invoice_id is null
      and (p_from is null or (service_from >= p_from and service_to <= p_to));
  if n = 0 then raise exception 'NOTHING_TO_INVOICE'; end if;
  pf := coalesce(p_from, pf); pt := coalesce(p_to, pt);
  select * into b from branches where id = r.branch_id;
  select full_name, nationality into g from reservation_guests where reservation_id = r.id and is_primary limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'description', description, 'quantity', quantity, 'unit_price_halalas', unit_price_halalas, 'total_halalas', total_halalas,
                                               'service_from', service_from, 'service_to', service_to) order by created_at, id), '[]'::jsonb),
         coalesce(sum(total_halalas) filter (where kind <> 'tax'), 0), coalesce(sum(total_halalas) filter (where kind = 'tax'), 0)
    into lines, sub, tax from reservation_charges where id = any(ids);
  insert into invoices(organization_id, branch_id, reservation_id, number, period_from, period_to, snapshot, subtotal_halalas, tax_halalas, total_halalas, issued_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'invoice', 'INV'), pf, pt,
          jsonb_build_object('property', jsonb_build_object('name', b.name_ar, 'tax_number', b.tax_number, 'commercial_register', b.commercial_register, 'address', b.address),
                             'guest', jsonb_build_object('name', g.full_name), 'reservation', jsonb_build_object('internal_ref', r.internal_ref, 'check_in', r.check_in, 'check_out', r.check_out),
                             'period', jsonb_build_object('from', pf, 'to', pt, 'requested', p_from is not null),
                             'charge_ids', to_jsonb(ids), 'lines', lines, 'tax_rate_bp', b.tax_rate_bp),
          sub, tax, sub + tax, fn_staff_id()) returning * into inv;
  update reservation_charges set invoice_id = inv.id where id = any(ids);
  perform fn_audit_change(r.branch_id, 'invoice.issued', 'invoice', inv.id, null,
    jsonb_build_object('number', inv.number, 'total_halalas', inv.total_halalas, 'reservation_id', r.id, 'period_from', pf, 'period_to', pt, 'charge_count', n));
  return jsonb_build_object('ok', true, 'id', inv.id, 'number', inv.number, 'total_halalas', inv.total_halalas, 'period_from', pf, 'period_to', pt, 'charge_count', n);
end $$;
grant execute on function fn_create_invoice(uuid, date, date) to authenticated;

-- =====================================================================
-- 3. A03 — fn_staff_confirm_payment: content-hashed idempotency, shared key space with fn_create_voucher
-- =====================================================================
create or replace function fn_staff_confirm_payment(p_reservation uuid, p_method payment_method, p_amount_halalas bigint,
  p_reference text, p_idempotency_key text, p_provider text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; existing payment_transactions%rowtype; ev financial_vouchers%rowtype; pt uuid; res jsonb; h text;
begin
  perform fn_require_role('owner','manager','supervisor','finance');
  select * into r from reservations where id = p_reservation for update;      -- serialises replays and races per reservation (X03)
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if p_amount_halalas is null or p_amount_halalas <= 0 then raise exception 'VALIDATION: amount'; end if;
  if coalesce(trim(p_reference),'') = '' then raise exception 'VALIDATION: reference_required'; end if;
  if coalesce(trim(p_idempotency_key),'') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  if p_method is null then raise exception 'VALIDATION: method'; end if;
  -- same formula as fn_create_voucher, so both entry points agree on what "same content" means
  h := md5(r.id::text || 'receipt' || p_amount_halalas::text || p_method::text || coalesce(p_reference,''));
  select * into existing from payment_transactions where idempotency_key = p_idempotency_key;
  select * into ev from financial_vouchers where organization_id = r.organization_id and idempotency_key = p_idempotency_key;
  if existing.id is not null or ev.id is not null then
    if (existing.id is not null and existing.reservation_id <> r.id) or (ev.id is not null and ev.reservation_id <> r.id) then
      raise exception 'IDEMPOTENCY_CONFLICT: key already used for another reservation';
    end if;
    if ev.id is not null then
      if ev.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;
      if ev.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', ev.number; end if;
    elsif existing.amount_halalas <> p_amount_halalas or existing.method <> p_method or coalesce(existing.provider_ref, existing.pos_ref, '') <> p_reference then
      raise exception 'IDEMPOTENCY_CONFLICT: same key, different content';
    end if;
    -- the duplicate answer describes what is STORED, never what was just sent
    return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', existing.id, 'voucher_id', ev.id, 'voucher', ev.number,
                              'amount_halalas', coalesce(ev.amount_halalas, existing.amount_halalas), 'method', coalesce(ev.method, existing.method),
                              'reference', coalesce(ev.reference, existing.provider_ref, existing.pos_ref),
                              'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas);
  end if;
  insert into payment_transactions(reservation_id, method, amount_halalas, status, provider, provider_ref, pos_ref, verified_by, verified_at, idempotency_key)
  values (r.id, p_method, p_amount_halalas, 'paid', p_provider, case when p_method <> 'pos' then p_reference end, case when p_method = 'pos' then p_reference end, fn_staff_id(), now(), p_idempotency_key)
  returning id into pt;
  res := fn_create_voucher(jsonb_build_object('reservation_id', r.id, 'kind', 'receipt', 'amount_halalas', p_amount_halalas, 'method', p_method, 'reference', p_reference, 'idempotency_key', p_idempotency_key));
  update financial_vouchers set payment_transaction_id = pt where id = (res->>'voucher_id')::uuid;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'confirm_payment', 'reservation', r.id,
                   jsonb_build_object('method', p_method, 'amount_halalas', p_amount_halalas, 'reference', p_reference, 'voucher', res->>'number'));
  select * into r from reservations where id = r.id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'transaction_id', pt, 'voucher_id', (res->>'voucher_id')::uuid, 'voucher', res->>'number',
                            'amount_halalas', p_amount_halalas, 'method', p_method, 'reference', p_reference, 'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas);
end $$;
grant execute on function fn_staff_confirm_payment(uuid, payment_method, bigint, text, text, text) to authenticated;

-- =====================================================================
-- 4. A06 — reservation / housekeeping RPCs require the version (+ A04 periods on amendments)
-- =====================================================================
-- Amend stay: identical to 0007c except (A06) strict version and (A04) the rent line of an extension carries
-- the extended nights [old check_out, new check_out] and a shortening adjustment carries the removed nights.
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
  perform fn_check_version_strict(r.version, p_expected_version);
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
    ch := fn_add_charge(r.id, 'rent', 'تمديد ' || delta || ' ليلة × ' || (rate/100.0) || ' ر.س', delta, rate, true, p_reason, null, r.check_out, p_new_check_out);
  else
    ch := fn_add_charge(r.id, 'adjustment', 'تقصير الإقامة ' || abs(delta) || ' ليلة', 1, -(abs(delta) * r.nightly_rate_halalas), true, p_reason, null, p_new_check_out, r.check_out);
  end if;
  update reservations set check_out = p_new_check_out, nightly_rate_halalas = case when p_pricing_mode = 'reprice' then rate else nightly_rate_halalas end, version = version + 1, updated_at = now() where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.departure_changed', 'reservation', r.id, before,
    jsonb_build_object('check_out', p_new_check_out, 'total_halalas', (select total_halalas from reservations where id = r.id), 'delta_nights', delta, 'pricing_mode', p_pricing_mode), p_reason);
  return jsonb_build_object('ok', true, 'delta_nights', delta, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_amend_stay(uuid, date, text, text, int) to authenticated;

create or replace function fn_staff_switch_room(p_reservation uuid, p_room uuid, p_effective date, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; old reservation_allocations%rowtype; eff date; old_room uuid; new_rm rooms%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
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
  perform fn_check_version_strict(r.version, p_expected_version);
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
create or replace function fn_hk_complete_task(p_task uuid, p_note text default null, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype; st room_status; is_cleaning boolean; occ text;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  perform fn_check_version_strict(t.version, p_expected_version);
  if t.status not in ('pending','in_progress') then raise exception 'TASK_STATUS_INVALID'; end if;
  if fn_has_role('housekeeping') and t.assignee_id is not null and t.assignee_id <> fn_staff_id() then raise exception 'FORBIDDEN: not assignee'; end if;
  update housekeeping_tasks set status = 'completed', completed_at = now(), completed_by = fn_staff_id(), assignee_id = coalesce(assignee_id, fn_staff_id()),
    result_note = p_note, version = version + 1, updated_at = now() where id = t.id;
  if t.room_id is not null then
    select (code = 'room_cleaning') into is_cleaning from task_types where id = t.task_type_id;
    if coalesce(is_cleaning, false) then
      update rooms set cleanliness = 'clean', updated_at = now() where id = t.room_id;
    end if;
    st := fn_recompute_room_ready(t.room_id);           -- occupied stays occupied
    select status::text into occ from rooms where id = t.room_id;
  end if;
  perform fn_audit_change(t.branch_id, 'task.completed', 'housekeeping_task', t.id, null, jsonb_build_object('room_status', st, 'note', p_note));
  return jsonb_build_object('ok', true, 'room_status', coalesce(occ, st::text));
end $$;
grant execute on function fn_hk_complete_task(uuid, text, int) to authenticated;

-- Add service: identical to 0007c except (A04) a per-night service is for the whole stay; other billing units are for the day they are added.
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
  perform fn_add_charge(r.id, 'addon', s.name_ar || case when p_note is not null then ' — ' || p_note else '' end, qty, price, s.taxable, null, s.id,
                        case when s.billing_unit = 'night' then r.check_in end, case when s.billing_unit = 'night' then r.check_out end);
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.service_added', 'reservation', r.id, null, jsonb_build_object('service_id', s.id, 'name', s.name_ar, 'quantity', qty, 'unit_price', price));
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_add_service(uuid, uuid, numeric, text) to authenticated;

-- Housekeeping task completion: identical to 0007b except the version is required (A06).

-- Legacy wrapper (kept for src/lib/api.ts staffApi.completeCleaning): it has no version in its signature, so it
-- resolves the task's current version under the row lock and delegates to the strict RPC. New code must call
-- fn_hk_complete_task with the version it displayed.
create or replace function fn_staff_complete_cleaning(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  select version into v from housekeeping_tasks where id = p_task for update;
  if v is null then raise exception 'TASK_NOT_FOUND'; end if;
  return fn_hk_complete_task(p_task, null, v);
end $$;
grant execute on function fn_staff_complete_cleaning(uuid) to authenticated;

-- AI proposals: the version of the target is captured when the proposal is made and verified when a human confirms it.
create or replace function fn_ai_ops_propose(p_conversation uuid, p_action text, p_args jsonb, p_summary text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c ai_ops_conversations%rowtype; pid uuid; a jsonb := coalesce(p_args, '{}'::jsonb); v int;
begin
  if fn_staff_id() is null then raise exception 'FORBIDDEN: staff only' using errcode = '42501'; end if;
  if not (p_action = any(fn_ai_ops_allowed_actions())) then raise exception 'VALIDATION: action'; end if;
  if coalesce(trim(p_summary),'') = '' then raise exception 'VALIDATION: summary'; end if;
  select * into c from ai_ops_conversations where id = p_conversation and staff_id = fn_staff_id();
  if not found then raise exception 'NOT_FOUND: conversation'; end if;
  -- A06: version-checked actions carry the target's version as seen at proposal time (a malformed id is left for the executing RPC to reject)
  if p_action in ('amend_stay','switch_room','complete_task') and not (a ? 'expected_version') then
    begin
      if p_action = 'complete_task' then
        select version into v from housekeeping_tasks where id = (a->>'task_id')::uuid and branch_id = c.branch_id;
      else
        select version into v from reservations where id = (a->>'reservation_id')::uuid and branch_id = c.branch_id;
      end if;
    exception when invalid_text_representation then v := null;
    end;
    if v is not null then a := a || jsonb_build_object('expected_version', v); end if;
  end if;
  insert into ai_action_proposals(organization_id, branch_id, conversation_id, staff_id, action, args, summary)
  values (c.organization_id, c.branch_id, c.id, fn_staff_id(), p_action, a, left(p_summary, 400)) returning id into pid;
  return jsonb_build_object('ok', true, 'proposal_id', pid, 'requires_confirmation', true);
end $$;
grant execute on function fn_ai_ops_propose(uuid, text, jsonb, text) to authenticated;

-- Identical to 0008 except that complete_task / amend_stay / switch_room pass the captured version (null → VERSION_REQUIRED → proposal failed).
create or replace function fn_ai_ops_execute_proposal(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p ai_action_proposals%rowtype; res jsonb; a jsonb; key text;
begin
  select * into p from ai_action_proposals where id = p_id for update;
  if not found or p.staff_id <> fn_staff_id() then raise exception 'FORBIDDEN: not your proposal' using errcode = '42501'; end if;
  if p.status <> 'proposed' then raise exception 'PROPOSAL_STATUS_INVALID'; end if;
  if p.expires_at < now() then
    update ai_action_proposals set status = 'expired', decided_at = now(), decided_by = fn_staff_id() where id = p.id;
    return jsonb_build_object('ok', false, 'error', 'PROPOSAL_EXPIRED');
  end if;
  perform fn_require_branch(p.branch_id);
  a := p.args;
  key := 'ai:' || p.id::text;   -- idempotent money ops keyed by the proposal itself
  begin
    case p.action
      when 'create_task'        then res := fn_hk_create_task(a || jsonb_build_object('description', coalesce(a->>'description','') || ' (اقتراح المساعد)'));
      when 'complete_task'      then res := fn_hk_complete_task((a->>'task_id')::uuid, a->>'note', (a->>'expected_version')::int);
      when 'assign_task'        then res := fn_hk_assign_task((a->>'task_id')::uuid, (a->>'assignee_id')::uuid);
      when 'set_cleanliness'    then res := fn_hk_set_cleanliness((a->>'room_id')::uuid, a->>'state', coalesce(a->>'reason','اقتراح المساعد'));
      when 'amend_stay'         then res := fn_staff_amend_stay((a->>'reservation_id')::uuid, (a->>'new_check_out')::date, coalesce(a->>'pricing_mode','keep_rate'), coalesce(a->>'reason', p.summary), (a->>'expected_version')::int);
      when 'switch_room'        then res := fn_staff_switch_room((a->>'reservation_id')::uuid, (a->>'room_id')::uuid, (a->>'effective')::date, coalesce(a->>'reason', p.summary), (a->>'expected_version')::int);
      when 'cancel_reservation' then res := fn_staff_cancel_reservation((a->>'reservation_id')::uuid, coalesce(a->>'reason', p.summary), 'staff', null);
      when 'no_show'            then res := fn_staff_no_show((a->>'reservation_id')::uuid, coalesce(a->>'reason', p.summary));
      when 'create_receipt'     then res := fn_create_voucher(jsonb_build_object('reservation_id', a->>'reservation_id', 'kind', 'receipt', 'amount_halalas', (a->>'amount_halalas')::bigint, 'method', a->>'method', 'reference', a->>'reference', 'note', 'اقتراح المساعد', 'idempotency_key', key));
      when 'create_deposit'     then res := fn_create_voucher(jsonb_build_object('reservation_id', a->>'reservation_id', 'kind', 'deposit', 'amount_halalas', (a->>'amount_halalas')::bigint, 'method', a->>'method', 'reference', a->>'reference', 'note', 'اقتراح المساعد', 'idempotency_key', key));
      when 'add_service'        then res := fn_staff_add_service((a->>'reservation_id')::uuid, (a->>'service_id')::uuid, coalesce((a->>'quantity')::numeric, 1), null);
      when 'create_invoice'     then res := fn_create_invoice((a->>'reservation_id')::uuid, null, null);
      else raise exception 'VALIDATION: action';
    end case;
  exception when others then
    -- record the failure on the proposal in an autonomous way: the outer transaction rolled back the business effect
    update ai_action_proposals set status = 'failed', error = left(sqlerrm, 300), decided_at = now(), decided_by = fn_staff_id() where id = p.id;
    return jsonb_build_object('ok', false, 'error', left(sqlerrm, 300));
  end;
  update ai_action_proposals set status = 'executed', result = res, decided_at = now(), decided_by = fn_staff_id() where id = p.id;
  perform fn_audit_change(p.branch_id, 'ai_proposal.executed', 'ai_action_proposal', p.id, null, jsonb_build_object('action', p.action, 'summary', p.summary, 'result', res));
  return jsonb_build_object('ok', true, 'result', res);
end $$;
grant execute on function fn_ai_ops_execute_proposal(uuid) to authenticated;

-- =====================================================================
-- 5. A09 — membership writes stay inside the owner's organization (staff AND branch)
-- =====================================================================
drop policy if exists "owner_memberships_write" on branch_memberships;
create policy "owner_memberships_write" on branch_memberships for all to authenticated
  using (fn_has_role('owner')
         and exists (select 1 from staff_profiles sp where sp.id = branch_memberships.staff_id and sp.organization_id = fn_user_org_id())
         and exists (select 1 from branches b where b.id = branch_memberships.branch_id and b.organization_id = fn_user_org_id()))
  with check (fn_has_role('owner')
         and exists (select 1 from staff_profiles sp where sp.id = branch_memberships.staff_id and sp.organization_id = fn_user_org_id())
         and exists (select 1 from branches b where b.id = branch_memberships.branch_id and b.organization_id = fn_user_org_id()));

-- =====================================================================
-- 6. Money column gate on reservations (table-level SELECT revoked, re-granted per column).
--    Money is reachable only through the role-gated SECURITY DEFINER RPCs. Note for future migrations:
--    a new column on reservations must be added to this grant explicitly (column grants do not grow).
-- =====================================================================
revoke select on reservations from authenticated, anon;
grant select (id, organization_id, branch_id, internal_ref, external_ref, source_id, status, booking_type, company_name, visit_purpose,
              check_in, check_out, adults, companions, room_category_id, room_id, payment_status, identity_status, government_registration,
              access_status, keybox_delivered, checkin_approved_by, checkin_approved_at, actual_check_in, actual_check_out, notes, created_at,
              created_by, security_hold, security_hold_reason, gov_registration_ref, gov_registration_by, gov_registration_at, updated_at,
              version, rate_type, cancelled_at, cancel_reason, cancel_source, no_show_at) on reservations to authenticated;

-- Reservation list: identical to 0007c except that the money fields are null for roles without money visibility
-- (housekeeping) and the has_balance filter only applies to roles that may see balances.
create or replace function fn_reservation_list(p_branch uuid, p_filters jsonb default '{}'::jsonb, p_limit int default 50, p_offset int default 0) returns jsonb
language sql stable security definer set search_path = public as $$
  with base as (
    select r.*, (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1) as guest_name,
           (select room_number from rooms where id = r.room_id) as room_number, (select name from booking_sources where id = r.source_id) as source_name,
           (select name_ar from room_categories where id = r.room_category_id) as category_name,
           fn_has_role('owner','manager','supervisor','finance') as money
    from reservations r
    where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
      and (coalesce(p_filters->>'status','') = '' or r.status::text = any(string_to_array(p_filters->>'status', ',')))
      and (coalesce(p_filters->>'open_only','false') <> 'true' or r.status in ('pending_verification','confirmed','checked_in'))
      and (p_filters->>'check_in_from' is null or r.check_in >= (p_filters->>'check_in_from')::date)
      and (p_filters->>'check_in_to' is null or r.check_in <= (p_filters->>'check_in_to')::date)
      and (p_filters->>'check_out_from' is null or r.check_out >= (p_filters->>'check_out_from')::date)
      and (p_filters->>'check_out_to' is null or r.check_out <= (p_filters->>'check_out_to')::date)
      and (p_filters->>'source_id' is null or r.source_id = (p_filters->>'source_id')::uuid)
      and (coalesce(p_filters->>'has_balance','false') <> 'true' or (fn_has_role('owner','manager','supervisor','finance') and r.balance_due_halalas > 0))
      and (coalesce(p_filters->>'q','') = '' or r.internal_ref ilike '%' || (p_filters->>'q') || '%' or coalesce(r.external_ref,'') ilike '%' || (p_filters->>'q') || '%'
           or exists (select 1 from reservation_guests g where g.reservation_id = r.id and (g.full_name ilike '%' || (p_filters->>'q') || '%' or g.phone like '%' || (p_filters->>'q') || '%')))
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'status', status, 'check_in', check_in, 'check_out', check_out,
               'nights', check_out - check_in, 'guest_name', guest_name, 'room_number', room_number, 'source_name', source_name, 'category_name', category_name,
               'total_halalas', case when money then total_halalas end, 'paid_halalas', case when money then paid_halalas end,
               'balance_due_halalas', case when money then balance_due_halalas end, 'deposit_balance_halalas', case when money then deposit_balance_halalas end,
               'payment_status', payment_status, 'identity_status', identity_status, 'access_status', access_status, 'created_at', created_at) order by check_in desc, created_at desc), '[]'::jsonb)
             from (select * from base order by check_in desc, created_at desc limit p_limit offset p_offset) b));
$$;
grant execute on function fn_reservation_list(uuid, jsonb, int, int) to authenticated;

-- =====================================================================
-- 7. A05 — fn_reports_finance: ledger-based finance report (field-for-field the contract of the demo's fn_reports_finance)
--    revenue = approved receipt/refund/deposit_apply vouchers by their branch-local day; deposits are a separate ledger, never revenue;
--    charges = lines of stays overlapping the period, excluding cancelled / rejected / no-show stays.
-- =====================================================================
create or replace function fn_reports_finance(p_branch uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from date; v_to date; tz text; l record; c record; rs record; open_dep bigint; total_charged bigint; net bigint;
begin
  perform fn_require_role('owner','manager','finance');
  perform fn_require_branch(p_branch);
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_from := coalesce(p_from, fn_branch_today(p_branch) - 29);
  v_to   := coalesce(p_to, fn_branch_today(p_branch));
  if v_to < v_from then raise exception 'VALIDATION: period'; end if;

  select coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0)::bigint        as receipts,
         coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint         as refunds,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit'), 0)::bigint        as deposits_received,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_refund'), 0)::bigint as deposits_refunded,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_apply'), 0)::bigint  as deposits_applied
    into l
    from financial_vouchers v
    where v.branch_id = p_branch and v.status = 'approved' and (v.occurred_at at time zone tz)::date between v_from and v_to;
  net := l.receipts - l.refunds + l.deposits_applied;

  select coalesce(sum(total_halalas) filter (where kind = 'rent'), 0)::bigint as rent,
         coalesce(sum(total_halalas) filter (where kind in ('addon','penalty','adjustment')), 0)::bigint as addons,
         coalesce(sum(total_halalas) filter (where kind = 'discount'), 0)::bigint as discounts,
         coalesce(sum(total_halalas) filter (where kind = 'tax'), 0)::bigint as tax
    into c
    from reservation_charges ch
    where ch.branch_id = p_branch and ch.reservation_id in (
      select r.id from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from and r.status not in ('cancelled','rejected','no_show'));
  total_charged := c.rent + c.addons + c.discounts + c.tax;

  select count(*)::bigint as cnt,
         coalesce(sum(greatest(check_out - check_in, 0)) filter (where status not in ('cancelled','rejected','no_show')), 0)::bigint as nights,
         count(*) filter (where status = 'cancelled') as cancelled,
         count(*) filter (where status = 'no_show') as no_show
    into rs
    from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from;

  select coalesce(sum(greatest(deposit_balance_halalas, 0)), 0)::bigint into open_dep from reservations where branch_id = p_branch;

  return jsonb_build_object(
    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'ledger', jsonb_build_object('receipts', l.receipts, 'refunds', l.refunds, 'net_collected', net,
                                 'deposits_received', l.deposits_received, 'deposits_refunded', l.deposits_refunded, 'deposits_applied', l.deposits_applied,
                                 'deposit_balance_open', open_dep),
    'charges', jsonb_build_object('total_charged', total_charged, 'rent', c.rent, 'addons', c.addons, 'discounts', c.discounts, 'tax', c.tax),
    'collection_rate_pct', case when total_charged > 0 then round(net::numeric * 100 / total_charged, 1) end,
    'by_method', (select coalesce(jsonb_agg(jsonb_build_object('method', method, 'amount_halalas', amount) order by amount desc, method), '[]'::jsonb)
                  from (select v.method::text as method, sum(v.amount_halalas)::bigint as amount from financial_vouchers v
                        where v.branch_id = p_branch and v.status = 'approved' and v.kind = 'receipt' and (v.occurred_at at time zone tz)::date between v_from and v_to
                        group by v.method) m),
    'by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'receipts', receipts, 'refunds', refunds) order by day), '[]'::jsonb)
               from (select (v.occurred_at at time zone tz)::date as day,
                            coalesce(sum(v.amount_halalas) filter (where v.kind in ('receipt','deposit_apply')), 0)::bigint as receipts,
                            coalesce(sum(v.amount_halalas) filter (where v.kind = 'refund'), 0)::bigint as refunds
                     from financial_vouchers v
                     where v.branch_id = p_branch and v.status = 'approved' and (v.occurred_at at time zone tz)::date between v_from and v_to
                     group by 1) d),
    'reservations', jsonb_build_object('count', rs.cnt, 'nights', rs.nights, 'cancelled', rs.cancelled, 'no_show', rs.no_show,
      'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'count', cnt, 'total_halalas', total) order by cnt desc, source), '[]'::jsonb)
                    from (select coalesce(bs.name, '—') as source, count(*)::bigint as cnt, coalesce(sum(r.total_halalas), 0)::bigint as total
                          from reservations r left join booking_sources bs on bs.id = r.source_id
                          where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from
                          group by coalesce(bs.name, '—')) s)),
    'definitions', jsonb_build_object(
      'revenue', 'صافي التحصيل = سندات قبض الإقامة − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند. التأمين المقبوض ليس إيرادًا.',
      'collection_rate', 'نسبة التحصيل = صافي التحصيل ÷ إجمالي الرسوم (إيجار + إضافات − خصومات + ضريبة) للإقامات المتقاطعة مع الفترة.')
  );
end $$;
grant execute on function fn_reports_finance(uuid, date, date) to authenticated;
