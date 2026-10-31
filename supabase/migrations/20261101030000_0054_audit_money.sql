-- 0054 — the money findings of the 31 October review, as the owner decided them (1 November 2026).
--
-- MONEY-01: a correction moved a voucher's money to today, out of a day already settled. Owner's decision: a voucher
--   whose day is settled is never touched — its correction is a reversing voucher (the opposite kind, same method,
--   account and reference, today) and the correct voucher (today); both name the original. A voucher not settled is
--   still cancelled and re-issued, and the replacement now keeps the original's business date.
-- MONEY-02: a POS settlement with a difference said «تظهر للمالك» but raised nothing. It now raises a review item
--   («فرق تسوية الشبكة»), and again when a re-settlement changes the difference.
-- MONEY-03: the same terminal or transfer number could be recorded on two stays. Owner's decision «تحذير بدل رفض»:
--   a number already on an approved voucher of the branch (same method) is refused with DUPLICATE_REFERENCE naming the
--   other booking, until the operator confirms it (duplicate_reference_ok); a confirmed duplicate raises a review item.
-- MONEY-04: «استخدام التأمين لتغطية رسوم» was booked as cash. Owner's decision: it carries the method and account of the
--   deposit it draws on (the one named, else the stay's latest deposit).
-- MONEY-05: platform payouts never reached the money figures. Owner's decision «قيد عند الاستلام + تسوية»: the period's
--   payouts are reported by account and source — received, commission, difference — next to what the platforms still
--   owe (fn_reports_platforms), and a payout with a difference raises a review item.
-- MONEY-06: a refund defaulted to cash whatever the payment was. Owner's decision: the refund goes back by the method of
--   the payment; another method takes a written reason (method_reason) and raises a review item.
-- MONEY-07: the printed invoice read the property name from the code. fn_organization_info gives the staff the
--   organisation's own name (the owner's settings screen follows in Phase 2).

alter table financial_vouchers add column if not exists reversal_of uuid references financial_vouchers(id);
create index if not exists idx_vouchers_reversal_of on financial_vouchers(reversal_of) where reversal_of is not null;
create index if not exists idx_vouchers_branch_reference on financial_vouchers(branch_id, method, upper(reference)) where reference is not null and status = 'approved';

-- ---------------------------------------------------------------------------------------------- MONEY-03 (and the voucher itself)
create or replace function fn_create_voucher(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; prefix text; m text := p->>'method'; ref text; acc uuid; dup_number text; dup_ref text;
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
  prefix := case kind when 'receipt' then 'RCP' else 'DEP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc, 'approved',
          ref, p->>'note', p->>'reason', key, h, coalesce((p->>'occurred_at')::timestamptz, now()), fn_staff_id()) returning * into v;
  if dup_number is not null and not coalesce((p->>'internal_reuse')::boolean, false) then
    perform fn_add_review_item(r.branch_id, 'voucher_duplicate_reference', 'voucher', v.id, r.id,
      'رقم العملية ' || ref || ' مسجّل أيضًا في ' || dup_ref || ' (' || dup_number || ')', null,
      jsonb_build_object('reference', ref, 'method', m, 'other_reservation', dup_ref, 'other_voucher', dup_number, 'amount_halalas', amt));
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', v.method, 'account_id', acc, 'reference', v.reference, 'reservation_id', r.id));
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $$;

-- ---------------------------------------------------------------------------------------------- MONEY-04, MONEY-06
create or replace function fn_refund(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; f jsonb; available bigint; prefix text; m text; ref text; acc uuid; orig uuid; inv_no text;
        src financial_vouchers%rowtype; v_paid text[]; v_paid_kind text; v_method_reason text := nullif(trim(coalesce(p->>'method_reason', '')), '');
begin
  if kind is null or kind not in ('refund', 'deposit_refund', 'deposit_apply') then raise exception 'VALIDATION: kind'; end if;
  if kind = 'refund' then perform fn_require_cap('voucher.refund');
  elsif kind = 'deposit_apply' then perform fn_require_cap('deposit.apply');
  else perform fn_require_cap('deposit.refund'); end if;
  amt := fn_parse_halalas(p->>'amount_halalas');
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'VALIDATION: reason'; end if;
  if coalesce(trim(key), '') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- concurrent refunds are serialised here
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  orig := nullif(p->>'original_voucher_id', '')::uuid;
  if orig is not null and not exists (select 1 from financial_vouchers where id = orig and reservation_id = r.id) then raise exception 'VALIDATION: original_voucher'; end if;
  -- MONEY-04: applying the deposit carries the method and account of the deposit it draws on
  if kind = 'deposit_apply' then
    select * into src from financial_vouchers d where d.id = orig and d.kind = 'deposit' and d.status = 'approved';
    if not found then
      select * into src from financial_vouchers d where d.reservation_id = r.id and d.kind = 'deposit' and d.status = 'approved' order by d.occurred_at desc limit 1;
    end if;
    m := coalesce(src.method::text, 'cash');
  else
    m := p->>'method';
  end if;
  if m is null then raise exception 'VALIDATION: method'; end if;
  h := md5(r.id::text || kind || amt::text || coalesce(p->>'method', '') || coalesce(p->>'reference', '') || coalesce(p->>'account_id', ''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if kind = 'deposit_refund' and (r.actual_check_in is not null or r.status in ('checked_in', 'checked_out', 'closed')) then
    if r.status not in ('checked_out', 'closed') then raise exception 'VALIDATION: deposit_refund_before_checkout'; end if;
    if not exists (select 1 from checkout_inspections i where i.reservation_id = r.id and i.status = 'active') then
      raise exception 'INSPECTION_REQUIRED: record the check-out inspection first';
    end if;
  end if;
  if kind <> 'deposit_apply' then
    if not fn_payment_method_active(m) then raise exception 'VALIDATION: method_retired'; end if;
    if kind = 'deposit_refund' and m = 'ota_deferred' then raise exception 'VALIDATION: deposit_method'; end if;
    ref := fn_check_payment_reference(m, p->>'reference');
    acc := fn_voucher_account(r.branch_id, m, (p->>'account_id')::uuid);
    -- MONEY-06: a stay refund goes back by the method of the payment (the receipt named, else the stay's approved receipts)
    v_paid_kind := case when kind = 'refund' then 'receipt' else 'deposit' end;
    select coalesce(array_agg(distinct fv.method::text), '{}') into v_paid from financial_vouchers fv
    where fv.reservation_id = r.id and fv.status = 'approved' and fv.kind = v_paid_kind
      and (orig is null or fv.id = orig);
    if kind = 'refund' and cardinality(v_paid) > 0 and not (m = any (v_paid)) and v_method_reason is null then
      raise exception 'REFUND_METHOD_DIFFERS: %', array_to_string(v_paid, ',');
    end if;
  else
    acc := src.account_id;
  end if;
  f := fn_reservation_finance_internal(r.id);
  available := case kind when 'refund' then (f->>'received')::bigint - (f->>'refunded')::bigint else (f->>'deposit_balance')::bigint end;
  if amt > available then raise exception 'REFUND_EXCEEDS_AVAILABLE: available % halalas', available; end if;
  if kind = 'deposit_apply' and amt > (f->>'balance_due')::bigint then raise exception 'REFUND_EXCEEDS_AVAILABLE: nothing due'; end if;
  prefix := case kind when 'refund' then 'RFD' when 'deposit_refund' then 'DRF' else 'DAP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, original_voucher_id, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc,
          'approved', ref, p->>'note', p->>'reason', orig, key, h, now(), fn_staff_id()) returning * into v;
  if kind = 'refund' and cardinality(v_paid) > 0 and not (m = any (v_paid)) then
    perform fn_add_review_item(r.branch_id, 'refund_other_method', 'voucher', v.id, r.id,
      'رُدّ ' || fn_sar_text(amt) || ' بطريقة غير طريقة الدفع (' || array_to_string(v_paid, '، ') || ' ← ' || m || ')', v_method_reason,
      jsonb_build_object('paid_methods', to_jsonb(v_paid), 'method', m, 'amount_halalas', amt, 'number', v.number));
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', m, 'account_id', acc, 'reservation_id', r.id, 'available_before', available,
                       'method_reason', v_method_reason), p->>'reason');
  if kind in ('deposit_refund', 'deposit_apply') and r.status in ('checked_out', 'closed')
     and (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint = 0 then
    inv_no := fn_auto_invoice(r.id, 'deposit_settled');
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id), 'invoice', inv_no);
end $$;

-- ---------------------------------------------------------------------------------------------- MONEY-01
-- a POS voucher is settled when its account's day has a settlement
create or replace function fn_voucher_settled(p_voucher uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from financial_vouchers v join branches b on b.id = v.branch_id
                 join pos_settlements s on s.account_id = v.account_id and s.business_date = (v.occurred_at at time zone coalesce(b.timezone, 'Asia/Riyadh'))::date
                 where v.id = p_voucher and v.method = 'pos' and v.account_id is not null);
$$;
revoke all on function fn_voucher_settled(uuid) from public, anon;
grant execute on function fn_voucher_settled(uuid) to authenticated;

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
                                                  'duplicate_reference_ok', true, 'internal_reuse', true, 'method_reason', 'تصحيح السند ' || v.number));
  if v.kind in ('receipt', 'deposit') then res := fn_create_voucher(payload); else res := fn_refund(payload); end if;
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

-- ---------------------------------------------------------------------------------------------- MONEY-02
create or replace function fn_trg_pos_difference_review() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.difference_halalas <> 0 and (tg_op = 'INSERT' or new.difference_halalas is distinct from old.difference_halalas) then
    perform fn_add_review_item(new.branch_id, 'pos_difference', 'pos_settlement', new.id, null,
      'فرق تسوية الشبكة ' || to_char(new.business_date, 'YYYY-MM-DD') || ': ' || fn_sar_text(new.difference_halalas)
        || ' (' || coalesce((select name from cash_accounts where id = new.account_id), '—') || ')', new.note,
      jsonb_build_object('business_date', new.business_date, 'terminal_halalas', new.terminal_total_halalas, 'system_halalas', new.system_total_halalas,
                         'difference_halalas', new.difference_halalas, 'account_id', new.account_id));
  end if;
  return new;
end $$;
revoke all on function fn_trg_pos_difference_review() from public, anon, authenticated;
create or replace trigger trg_pos_difference_review after insert or update of difference_halalas on pos_settlements
  for each row execute function fn_trg_pos_difference_review();

-- ---------------------------------------------------------------------------------------------- MONEY-05
create or replace function fn_trg_payout_difference_review() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'confirmed' and new.difference_halalas <> 0 then
    perform fn_add_review_item(new.branch_id, 'platform_payout_difference', 'platform_payout', new.id, null,
      'فرق إيداع ' || coalesce((select name from booking_sources where id = new.source_id), 'منصة') || ': ' || fn_sar_text(new.difference_halalas)
        || ' (المرجع ' || new.reference || ')', new.note,
      jsonb_build_object('expected_halalas', new.expected_halalas, 'commission_halalas', new.commission_halalas, 'received_halalas', new.received_halalas,
                         'difference_halalas', new.difference_halalas, 'received_on', new.received_on));
  end if;
  return new;
end $$;
revoke all on function fn_trg_payout_difference_review() from public, anon, authenticated;
create or replace trigger trg_payout_difference_review after insert on platform_payouts
  for each row execute function fn_trg_payout_difference_review();

-- the platforms in the money figures: what came into each account from each source in the period, its commission and
-- its difference, and what the platforms still owe (not yet paid out)
create or replace function fn_reports_platforms(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (fn_can('reports.finance') or fn_can('platform.payouts') or fn_current_role() = 'owner') then raise exception 'FORBIDDEN: reports.finance'; end if;
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from then raise exception 'VALIDATION: period'; end if;
  select jsonb_build_object(
    'received_halalas', coalesce(sum(received_halalas), 0), 'expected_halalas', coalesce(sum(expected_halalas), 0),
    'commission_halalas', coalesce(sum(commission_halalas), 0), 'difference_halalas', coalesce(sum(difference_halalas), 0), 'payouts', count(*),
    'by_source', coalesce((select jsonb_agg(x order by x->>'source') from (
        select jsonb_build_object('source', coalesce(bs.name, '—'), 'account', coalesce(ca.name, '—'), 'payouts', count(*),
                                  'expected_halalas', sum(pp.expected_halalas), 'commission_halalas', sum(pp.commission_halalas),
                                  'received_halalas', sum(pp.received_halalas), 'difference_halalas', sum(pp.difference_halalas)) as x
        from platform_payouts pp left join booking_sources bs on bs.id = pp.source_id left join cash_accounts ca on ca.id = pp.account_id
        where pp.branch_id = p_branch and pp.status = 'confirmed' and pp.received_on between p_from and p_to
        group by bs.name, ca.name) s), '[]'::jsonb),
    'still_owed_halalas', (select coalesce(sum(amount_halalas), 0) from financial_vouchers
                           where branch_id = p_branch and status = 'approved' and method = 'ota_deferred' and kind = 'receipt' and payout_id is null))
  into v
  from platform_payouts where branch_id = p_branch and status = 'confirmed' and received_on between p_from and p_to;
  return v;
end $$;
revoke all on function fn_reports_platforms(uuid, date, date) from public, anon;
grant execute on function fn_reports_platforms(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------------------------- MONEY-07
create or replace function fn_organization_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('name_ar', o.name_ar, 'name_en', o.name_en, 'license_number', o.license_number)
  from organizations o where o.id = fn_user_org_id();
$$;
revoke all on function fn_organization_info() from public, anon;
grant execute on function fn_organization_info() to authenticated;
