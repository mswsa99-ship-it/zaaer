-- 0084 — Phase 4 money controls, the voucher half (4.1 server rules and 4.2). Proposed file; the integrator renumbers.
--
-- 4.1 (M1 الوصول): no receipt voucher without an explicit «استلمت» confirmation (received_confirmed), refused for
--   every role; «الآجل باعتماد المدير فقط» — a deferred receipt (ota_deferred on a stay the platform does NOT collect)
--   is refused for anyone below the management, and when the management records it, it lands in «بحاجة لمراجعة».
-- 4.2 (M2/M12 سقف القبض): a receipt never exceeds what the stay still owes (balance_due). An excess is refused;
--   it passes only as «دفعة مقدمة» (advance_ok) with a written reason, and then a review item is raised.
--   The plan's test: a voucher of 99,999 on a booking worth 75 is refused.
--
-- What is exempt (the automatic postings, so the existing flows keep working):
--   * internal replacement postings of a voucher correction (fn_staff_correct_voucher),
--   * the product-order receipt (fn_product_* sets fivehours.product_order; the order screen collects explicitly),
--   * an assistant proposal the staff member executed (fn_ai_ops_execute_proposal; the execution IS the confirmation),
--   * the platform's own automatic receipt posted by fn_staff_update_platform, and any ota_deferred receipt on a
--     reservation whose platform_collects is true.
-- SECURITY (review fix): the exemption is signalled ONLY by transaction-local settings written inside those trusted
-- SECURITY DEFINER functions themselves (fivehours.internal_voucher, fivehours.product_order) — never by caller JSON
-- (a posted internal_reuse flag is ignored) and never by request state (app.source, x-client-source and other client
-- headers are ignored): an authorized receipt caller cannot exempt itself from «استلمت», the remaining-due cap or
-- «الآجل باعتماد المدير». fn_staff_correct_voucher and fn_ai_ops_execute_proposal are re-created below so the internal
-- flows keep working under the internal signal.
-- fn_staff_confirm_payment is re-created to pass received_confirmed itself: that function IS the staff member's
-- explicit confirmation that a payment was received and verified (verified_by/verified_at).
--
-- Signatures, RLS, hotel and branch isolation are unchanged: the same row lock on the reservation, the same
-- fn_require_branch, the same capability gate (voucher.receipt), the same idempotency and audit behaviour.

create or replace function fn_create_voucher(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; prefix text; m text := p->>'method'; ref text; acc uuid; dup_number text; dup_ref text;
        v_due bigint; v_advance boolean := false; v_deferred boolean := false; v_auto boolean; v_internal boolean;
begin
  if kind not in ('receipt', 'deposit') then raise exception 'VALIDATION: kind'; end if;
  perform fn_require_cap('voucher.receipt');
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
  -- MONEY-03: a terminal or transfer number already on an approved voucher of the branch is a warning to confirm
  if ref is not null and m in ('pos', 'bank_transfer') then
    select fv.number, rs.internal_ref into dup_number, dup_ref from financial_vouchers fv join reservations rs on rs.id = fv.reservation_id
    where fv.branch_id = r.branch_id and fv.status = 'approved' and fv.method::text = m and fv.kind in ('receipt', 'deposit')
      and upper(fv.reference) = upper(ref)
    order by fv.occurred_at desc limit 1;
    if dup_number is not null and not coalesce((p->>'duplicate_reference_ok')::boolean, false) then
      raise exception 'DUPLICATE_REFERENCE: % %', dup_ref, dup_number;
    end if;
  end if;
  acc := fn_voucher_account(r.branch_id, m, (p->>'account_id')::uuid);
  -- Phase 4 (4.1/4.2): the interactive receipt controls. Automatic postings are exempt (header).
  -- Internal-only signals: a transaction-local setting a trusted SECURITY DEFINER function writes around its own
  -- call. Caller JSON (internal_reuse) and request state (app.source / client headers) are NOT read here on purpose.
  v_internal := coalesce(current_setting('fivehours.internal_voucher', true), '') <> '';
  v_auto := v_internal
         or coalesce(current_setting('fivehours.product_order', true), '') <> ''
         or (m = 'ota_deferred' and r.platform_collects is true);
  if kind = 'receipt' and not v_auto then
    -- 4.1: no voucher without an explicit «استلمت المبلغ فعلًا», refused for every role
    if not coalesce((p->>'received_confirmed')::boolean, false) then raise exception 'VALIDATION: received_confirm'; end if;
    -- 4.2: the voucher never exceeds what the stay still owes; the excess is «دفعة مقدمة» with a reason
    v_due := (fn_reservation_finance_internal(r.id)->>'balance_due')::bigint;
    if amt > v_due then
      if coalesce((p->>'advance_ok')::boolean, false) and nullif(trim(coalesce(p->>'reason', '')), '') is not null then
        v_advance := true;
      else
        raise exception 'VALIDATION: amount_exceeds_short';
      end if;
    end if;
    -- 4.1: «الآجل باعتماد المدير فقط»
    if m = 'ota_deferred' then
      if fn_current_role() not in ('owner', 'manager') then raise exception 'FORBIDDEN: deferred_manager_only' using errcode = '42501'; end if;
      v_deferred := true;
    end if;
  end if;
  prefix := case kind when 'receipt' then 'RCP' else 'DEP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc, 'approved',
          ref, p->>'note', p->>'reason', key, h, coalesce((p->>'occurred_at')::timestamptz, now()), fn_staff_id()) returning * into v;
  if dup_number is not null and not v_internal then
    perform fn_add_review_item(r.branch_id, 'voucher_duplicate_reference', 'voucher', v.id, r.id,
      'رقم العملية ' || ref || ' مسجّل أيضًا في ' || dup_ref || ' (' || dup_number || ')', null,
      jsonb_build_object('reference', ref, 'method', m, 'other_reservation', dup_ref, 'other_voucher', dup_number, 'amount_halalas', amt));
  end if;
  if v_advance then
    perform fn_add_review_item(r.branch_id, 'voucher_advance_payment', 'voucher', v.id, r.id,
      'دفعة مقدمة ' || fn_sar_text(amt - v_due) || ' فوق المستحق في السند ' || v.number, p->>'reason',
      jsonb_build_object('number', v.number, 'amount_halalas', amt, 'balance_due_before', v_due, 'advance_halalas', amt - v_due, 'reason', p->>'reason'));
  end if;
  if v_deferred then
    perform fn_add_review_item(r.branch_id, 'voucher_deferred_manager', 'voucher', v.id, r.id,
      'سند آجل ' || v.number || ' بمبلغ ' || fn_sar_text(amt) || ' باعتماد الإدارة', null,
      jsonb_build_object('number', v.number, 'amount_halalas', amt, 'approved_by_role', fn_current_role()::text));
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', v.method, 'account_id', acc, 'reference', v.reference, 'reservation_id', r.id,
                       'received_confirmed', kind <> 'receipt' or v_auto or coalesce((p->>'received_confirmed')::boolean, false),
                       'advance', v_advance, 'deferred', v_deferred));
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $$;

-- fn_staff_confirm_payment is the staff member's own explicit confirmation that a payment arrived and was verified
-- (it stores verified_by/verified_at): it passes received_confirmed itself. Body as 0043, one line added.
CREATE OR REPLACE FUNCTION public.fn_staff_confirm_payment(p_reservation uuid, p_method payment_method, p_amount_halalas bigint, p_reference text, p_idempotency_key text, p_provider text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype; existing payment_transactions%rowtype; ev financial_vouchers%rowtype; pt uuid; res jsonb; h text;
begin
  perform fn_require_cap('voucher.receipt');
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
                              'reference', coalesce(existing.provider_ref, existing.pos_ref),
                              'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas);
  end if;
  insert into payment_transactions(reservation_id, method, amount_halalas, status, provider, provider_ref, pos_ref, verified_by, verified_at, idempotency_key)
  values (r.id, p_method, p_amount_halalas, 'paid', p_provider, case when p_method <> 'pos' then p_reference end, case when p_method = 'pos' then p_reference end, fn_staff_id(), now(), p_idempotency_key)
  returning id into pt;
  res := fn_create_voucher(jsonb_build_object('reservation_id', r.id, 'kind', 'receipt', 'amount_halalas', p_amount_halalas, 'method', p_method, 'reference', p_reference,
                                              'received_confirmed', true,   -- this function IS the explicit receipt confirmation
                                              'idempotency_key', p_idempotency_key));
  update financial_vouchers set payment_transaction_id = pt where id = (res->>'voucher_id')::uuid;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'confirm_payment', 'reservation', r.id,
                   jsonb_build_object('method', p_method, 'amount_halalas', p_amount_halalas, 'reference', p_reference, 'voucher', res->>'number'));
  select * into r from reservations where id = r.id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'transaction_id', pt, 'voucher_id', (res->>'voucher_id')::uuid, 'voucher', res->>'number',
                            'amount_halalas', p_amount_halalas, 'method', p_method, 'reference', p_reference, 'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas);
end $function$;
-- re-created from 0048: the platform's deferred receipt on «المنصة قبضت» is an automatic posting: the platform
-- collected the money, so the interactive «استلمت»/cap/آجل rules do not apply to it. The exemption is signalled the
-- internal way — this trusted SECURITY DEFINER function sets fivehours.internal_voucher around its own posting —
-- never by a caller-supplied flag (review fix).
create or replace function fn_staff_update_platform(p_reservation uuid, p jsonb, p_reason text, p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; u reservations%rowtype; src booking_sources%rowtype; nsrc booking_sources%rowtype; f jsonb; vch jsonb;
        v_ext text; v_booked date; v_collects boolean; n int := 0; v_vouchers jsonb := '[]'::jsonb; owed bigint; vv record; v_con text;
        v_src_changed boolean := false; v_runs jsonb; v_old_sum bigint; v_new_sum bigint; v_repriced jsonb := '[]'::jsonb;
begin
  perform fn_require_cap('res.create');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  select * into src from booking_sources where id = r.source_id;
  if not found or src.kind <> 'external' then raise exception 'VALIDATION: not_platform'; end if;
  if r.status not in ('confirmed', 'pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.platform_verified_at is not null then raise exception 'PLATFORM_VERIFIED'; end if;

  -- the platform itself: another active platform of the organisation
  nsrc := src;
  if p ? 'source_id' and nullif(p->>'source_id', '') is not null and (p->>'source_id')::uuid <> r.source_id then
    select * into nsrc from booking_sources where id = (p->>'source_id')::uuid and organization_id = r.organization_id and is_active;
    if not found or nsrc.kind <> 'external' then raise exception 'VALIDATION: source'; end if;
    v_src_changed := true;
    perform fn_require_money();                                                    -- the stay is re-priced
  end if;
  v_ext := case when p ? 'external_ref' then nullif(btrim(fn_latin_digits(p->>'external_ref')), '') else r.external_ref end;
  if nsrc.external_reference_required and v_ext is null then raise exception 'VALIDATION: external_ref_required'; end if;
  begin v_booked := case when p ? 'platform_booked_on' then nullif(p->>'platform_booked_on', '')::date else r.platform_booked_on end;
  exception when others then raise exception 'VALIDATION: platform_booked_on'; end;
  if v_booked is null or v_booked > fn_branch_today(r.branch_id) or v_booked < r.check_in - 730 then raise exception 'VALIDATION: platform_booked_on'; end if;
  v_collects := case when p ? 'platform_collects' then (p->>'platform_collects')::boolean else r.platform_collects end;
  if v_collects is null then raise exception 'VALIDATION: platform_collects'; end if;
  -- decision 69: one platform number per booking or group
  if v_ext is not null and exists (select 1 from reservations x where x.organization_id = r.organization_id and x.source_id = nsrc.id and x.external_ref = v_ext
                                     and coalesce(x.group_ref, x.id::text) <> coalesce(r.group_ref, r.id::text)) then
    raise exception 'DUPLICATE_EXTERNAL_REF';
  end if;

  for u in select * from reservations where id = r.id or (r.group_ref is not null and group_ref = r.group_ref and organization_id = r.organization_id)
           order by id for update loop
    perform fn_require_branch(u.branch_id);
    if u.id <> r.id and u.status not in ('confirmed', 'pending_verification', 'cancelled', 'no_show') then raise exception 'GROUP_UNIT_IN_HOUSE'; end if;
    if u.id <> r.id and u.status in ('cancelled', 'no_show') then
      if u.external_ref is distinct from v_ext or u.source_id <> nsrc.id then             -- the group keeps one platform and number
        update reservations set external_ref = v_ext, source_id = nsrc.id, version = version + 1, updated_at = now() where id = u.id;
        perform fn_audit_change(u.branch_id, 'reservation.platform_updated', 'reservation', u.id, jsonb_build_object('external_ref', u.external_ref, 'source_id', u.source_id),
          jsonb_build_object('external_ref', v_ext, 'source_id', nsrc.id), p_reason);
      end if;
      continue;
    end if;
    -- who collects changed: the deferred receipt follows (money moves, so the caller must see money)
    if coalesce(u.platform_collects, false) <> v_collects then perform fn_require_money(); end if;
    if coalesce(u.platform_collects, false) and not v_collects then
      -- the deferred refunds go first, so the receipt's cancellation never leaves the stay below zero
      for vv in select id from financial_vouchers where reservation_id = u.id and kind in ('refund', 'receipt') and method = 'ota_deferred' and status = 'approved'
                order by (kind = 'receipt'), created_at loop
        perform fn_cancel_voucher_internal(vv.id, 'تغيير من يقبض: المنشأة عند الوصول — ' || p_reason);
      end loop;
    elsif not coalesce(u.platform_collects, false) and v_collects then
      f := fn_reservation_finance_internal(u.id);
      owed := (f->>'total')::bigint - ((f->>'received')::bigint - (f->>'refunded')::bigint);
      if owed > 0 then
        perform set_config('fivehours.internal_voucher', 'on', true);   -- internal automatic posting (review fix)
        vch := fn_create_voucher(jsonb_build_object('kind', 'receipt', 'reservation_id', u.id, 'amount_halalas', owed, 'method', 'ota_deferred',
                                                    'reference', v_ext, 'note', 'قبضته المنصة عند الحجز', 'reason', p_reason,
                                                    'idempotency_key', 'platform-collect:' || u.id || ':' || u.version));
        perform set_config('fivehours.internal_voucher', '', true);
        v_vouchers := v_vouchers || jsonb_build_array(vch->>'number');
      end if;
    end if;
    -- another platform: the whole stay (not begun) is re-priced by the new platform's prices
    v_old_sum := null; v_new_sum := null;
    if v_src_changed then
      perform fn_ensure_nights(u.id);
      select coalesce(sum(price_halalas), 0) into v_old_sum from reservation_nights where reservation_id = u.id and status = 'active';
      update reservation_nights set status = 'removed', removed_at = now(), removed_by = fn_staff_id(), removed_reason = 'تغيير المنصة: ' || p_reason
      where reservation_id = u.id and status = 'active';
      if v_old_sum <> 0 then
        perform fn_add_charge(u.id, 'adjustment', 'تغيير المنصة: إلغاء سعر المنصة السابقة', 1, -v_old_sum, true, p_reason, null, u.check_in, u.check_out);
      end if;
      v_runs := fn_stay_runs(u.room_category_id, u.check_in, u.check_out, true, null, true);
      v_new_sum := fn_book_nights(u.id, v_runs, 'تغيير المنصة', p_reason);
      if coalesce((select sum(-total_halalas) from reservation_charges where reservation_id = u.id and kind = 'discount'), 0) > v_new_sum then
        raise exception 'VALIDATION: discount_exceeds_rent';
      end if;
      update reservations set nightly_rate_halalas = coalesce((select round(avg(price_halalas))::bigint from reservation_nights where reservation_id = u.id and status = 'active'), nightly_rate_halalas),
             price_basis = case when exists (select 1 from jsonb_array_elements(v_runs) x where x->>'basis' = 'monthly') then 'monthly'
                                when exists (select 1 from jsonb_array_elements(v_runs) x where x->>'basis' = 'weekly') then 'weekly' else 'daily' end
      where id = u.id;
      v_repriced := v_repriced || jsonb_build_array(jsonb_build_object('reservation_id', u.id, 'old_nights_halalas', v_old_sum, 'new_nights_halalas', v_new_sum));
    end if;
    update reservations set external_ref = v_ext, source_id = nsrc.id, platform_booked_on = v_booked, platform_collects = v_collects,
           version = version + 1, updated_at = now() where id = u.id;
    perform fn_recompute_reservation_finance(u.id);
    perform fn_audit_change(u.branch_id, 'reservation.platform_updated', 'reservation', u.id,
      jsonb_build_object('external_ref', u.external_ref, 'source_id', u.source_id, 'platform_booked_on', u.platform_booked_on, 'platform_collects', u.platform_collects, 'total_halalas', u.total_halalas),
      jsonb_build_object('external_ref', v_ext, 'source_id', nsrc.id, 'platform_booked_on', v_booked, 'platform_collects', v_collects, 'vouchers', v_vouchers,
                         'old_nights_halalas', v_old_sum, 'new_nights_halalas', v_new_sum, 'total_halalas', (select total_halalas from reservations where id = u.id)), p_reason);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'units', n, 'vouchers', v_vouchers, 'repriced', v_repriced, 'finance', fn_reservation_finance_internal(r.id));
exception when unique_violation or exclusion_violation then
  get stacked diagnostics v_con = constraint_name;
  if v_con in ('uniq_reservation_source_ref', 'excl_reservation_source_ref') then raise exception 'DUPLICATE_EXTERNAL_REF'; end if;
  raise;
end $$;


-- ---------------------------------------------------------------------------------------------- review fix
-- The two internal callers that used to exempt their postings through caller-visible state are re-created so the
-- exemption comes only from inside the trusted function: a transaction-local fivehours.internal_voucher setting the
-- function writes around its own posting. Bodies otherwise unchanged (fn_staff_correct_voucher as 0054,
-- fn_ai_ops_execute_proposal as 0040); signatures, RLS, hotel and branch isolation unchanged.
-- fn_staff_correct_voucher: the guest confirmed the original voucher; its replacement is an internal posting.
create or replace function fn_staff_correct_voucher(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v financial_vouchers%rowtype; r reservations%rowtype; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); existing financial_vouchers%rowtype; payload jsonb; res jsonb;
        nv financial_vouchers%rowtype; rv financial_vouchers%rowtype; f jsonb; amt text; m text; ref text; acc text; note text;
        settled boolean; rev_kind text;
begin
  perform fn_require_cap('voucher.correct');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  if key is null then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into v from financial_vouchers where id = (p->>'voucher_id')::uuid;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = v.reservation_id for update;      -- money operations on a stay are serialised here
  perform fn_require_branch(v.branch_id);
  select * into v from financial_vouchers where id = v.id for update;
  -- the same correction again answers with its replacement
  select * into existing from financial_vouchers where organization_id = v.organization_id and idempotency_key = key;
  if found then
    if existing.original_voucher_id is distinct from v.id then raise exception 'IDEMPOTENCY_CONFLICT: key already used'; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'original_number', v.number,
                              'finance', fn_reservation_finance_internal(r.id));
  end if;
  if v.status <> 'approved' then raise exception 'VOUCHER_STATUS_INVALID'; end if;
  if v.payout_id is not null then raise exception 'VOUCHER_IN_PAYOUT'; end if;
  if v.reversal_of is not null or exists (select 1 from financial_vouchers x where x.reversal_of = v.id and x.status = 'approved') then
    raise exception 'VOUCHER_ALREADY_REVERSED';
  end if;
  if not fn_cap_full('voucher.correct') then
    if v.created_by is distinct from fn_staff_id() then raise exception 'FORBIDDEN: a supervisor corrects only the vouchers they issued'; end if;
    if v.created_at < now() - interval '24 hours' then raise exception 'CORRECTION_WINDOW_PASSED: after 24 hours a voucher is corrected by a manager'; end if;
  end if;
  amt := coalesce(nullif(p->>'amount_halalas', ''), v.amount_halalas::text);
  m := coalesce(nullif(p->>'method', ''), v.method::text);
  ref := case when p ? 'reference' then nullif(trim(coalesce(p->>'reference', '')), '') else v.reference end;
  -- another method takes its own account: the one given, or that method's default
  acc := case when p ? 'account_id' then nullif(p->>'account_id', '') when m <> v.method::text then null else v.account_id::text end;
  note := case when p ? 'note' then nullif(trim(coalesce(p->>'note', '')), '') else v.note end;
  if amt = v.amount_halalas::text and (v.kind = 'deposit_apply' or m = v.method::text) and ref is not distinct from v.reference
     and acc is not distinct from v.account_id::text and note is not distinct from v.note then
    raise exception 'VALIDATION: nothing_changed';
  end if;
  settled := v.kind <> 'deposit_apply' and fn_voucher_settled(v.id);

  if settled then
    -- the original stays as it is: a reversing voucher today, then the correct one today
    rev_kind := case v.kind when 'receipt' then 'refund' when 'deposit' then 'deposit_refund' when 'refund' then 'receipt' else 'deposit' end;
    insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason,
                                   original_voucher_id, reversal_of, idempotency_key, content_hash, occurred_at, created_by)
    values (v.organization_id, v.branch_id, v.reservation_id,
            fn_next_document_number(v.organization_id, 'voucher', case rev_kind when 'receipt' then 'RCP' when 'deposit' then 'DEP' when 'refund' then 'RFD' else 'DRF' end),
            rev_kind, v.amount_halalas, v.method, v.account_id, 'approved', v.reference, null, 'عكس السند ' || v.number || ': ' || v_reason,
            v.id, v.id, key || ':reverse', md5(v.id::text || 'reverse'), now(), fn_staff_id())
    returning * into rv;
  else
    update financial_vouchers set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = 'تصحيح: ' || v_reason where id = v.id;
  end if;
  payload := jsonb_strip_nulls(jsonb_build_object('reservation_id', r.id, 'kind', v.kind, 'idempotency_key', key, 'amount_halalas', amt,
                                                  'method', m, 'reference', ref, 'account_id', acc, 'note', note,
                                                  'reason', coalesce(v.reason, 'تصحيح السند ' || v.number), 'original_voucher_id', v.id,
                                                  'duplicate_reference_ok', true, 'method_reason', 'تصحيح السند ' || v.number));
  perform set_config('fivehours.internal_voucher', 'on', true);   -- internal replacement posting (review fix 0084)
  if v.kind in ('receipt', 'deposit') then res := fn_create_voucher(payload); else res := fn_refund(payload); end if;
  perform set_config('fivehours.internal_voucher', '', true);
  update financial_vouchers set original_voucher_id = v.id,
         occurred_at = case when settled then occurred_at else v.occurred_at end   -- not settled: the replacement keeps the business date
  where id = (res->>'voucher_id')::uuid;
  select * into nv from financial_vouchers where id = (res->>'voucher_id')::uuid;
  f := fn_reservation_finance_internal(r.id);
  if (f->>'deposit_balance')::bigint < 0 or ((f->>'received')::bigint - (f->>'refunded')::bigint) < 0 then
    raise exception 'CANCEL_WOULD_GO_NEGATIVE';
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(v.branch_id, case when settled then 'voucher_reversed' else 'voucher_corrected' end, 'voucher', nv.id, r.id,
    case when settled then 'عكس السند ' || v.number || ' بالسند ' || rv.number || ' وإصدار ' || nv.number || ' (يوم السند مُسوّى)'
         else 'تصحيح السند ' || v.number || ' بالسند ' || nv.number end, v_reason,
    jsonb_build_object('original', v.number, 'replacement', nv.number, 'reversal', rv.number, 'kind', v.kind, 'settled', settled,
                       'before', jsonb_build_object('amount_halalas', v.amount_halalas, 'method', v.method, 'reference', v.reference, 'account_id', v.account_id),
                       'after', jsonb_build_object('amount_halalas', nv.amount_halalas, 'method', nv.method, 'reference', nv.reference, 'account_id', nv.account_id),
                       'issued_by_self', v.created_by is not distinct from fn_staff_id()));
  perform fn_audit_change(v.branch_id, 'voucher.corrected', 'voucher', nv.id,
    jsonb_build_object('number', v.number, 'amount_halalas', v.amount_halalas, 'method', v.method, 'reference', v.reference, 'account_id', v.account_id),
    jsonb_build_object('number', nv.number, 'amount_halalas', nv.amount_halalas, 'method', nv.method, 'reference', nv.reference, 'account_id', nv.account_id,
                       'original_voucher_id', v.id, 'reversal', rv.number, 'settled', settled), v_reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', nv.id, 'number', nv.number, 'original_number', v.number,
                            'reversal_number', rv.number, 'settled', settled, 'finance', fn_reservation_finance_internal(r.id));
end $$;

-- fn_ai_ops_execute_proposal: the staff member's execution of the proposal IS the confirmation; its receipt posting
-- is internal. The setting is cleared on every path, including the recorded-failure path.
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
  perform set_config('app.source', 'ops_assistant', true);
  perform set_config('fivehours.internal_voucher', 'on', true);   -- the executed proposal's money postings are internal (review fix 0084)
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
    perform set_config('app.source', '', true);
  perform set_config('fivehours.internal_voucher', '', true);
    update ai_action_proposals set status = 'failed', error = left(sqlerrm, 300), decided_at = now(), decided_by = fn_staff_id() where id = p.id;
    return jsonb_build_object('ok', false, 'error', left(sqlerrm, 300));
  end;
  update ai_action_proposals set status = 'executed', result = res, decided_at = now(), decided_by = fn_staff_id() where id = p.id;
  perform fn_audit_change(p.branch_id, 'ai_proposal.executed', 'ai_action_proposal', p.id, null, jsonb_build_object('action', p.action, 'summary', p.summary, 'result', res));
  perform set_config('app.source', '', true);
  perform set_config('fivehours.internal_voucher', '', true);
  return jsonb_build_object('ok', true, 'result', res);
end $$;
