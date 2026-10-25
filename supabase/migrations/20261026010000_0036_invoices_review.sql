-- =====================================================================
-- 0036 — invoices and the owner's review list (Phase 4): decisions 11, 26, 27, and «بحاجة لمراجعة وتدقيق».
--   1. An invoice carries a SHARE of each line of the stay, kept in its snapshot (charge, amount). A line is fully
--      invoiced when its shares in issued invoices add up to its total; reservation_charges.invoice_id now marks that
--      (the invoice that completed it), so the screens and the closing keep reading one column.
--   2. A partial invoice (decision 27) is for a period [from, to]: the nights of the period at their saved price; the
--      discount (and any stay-wide adjustment) in the same proportion as the period's rent; a tax line follows its own
--      line; a one-off line (a service, a fee, a damage) when its day is in the period. Shares are cumulative, so any
--      set of periods adds up to each line's total to the halala, whatever the rounding (half away from zero, 47).
--      Two period invoices of a stay never overlap; what no invoice carries stays for a later one.
--   3. The automatic invoice: at check-out, everything not yet invoiced, in the same operation; after the departure,
--      when the deposit is settled (a damage, a late fee), the same. None when nothing positive is left: a stay whose
--      invoices already carry more than its lines is corrected by editing the invoice (no credit notes, decision 26).
--   4. An invoice is edited with a reason (decision 26): its bill-to details, its period, and its amounts, which follow
--      the stay's lines as they stand (never typed). The version before is kept in the invoice and never erased; the
--      edit waits in the owner's review list. Cancelling stays with the owner and the manager.
--   5. «مغلق» (decision 59) now asks that the stay's value be invoiced: its lines add up to its issued invoices.
--   6. «تصحيح سند» (decision 11): the voucher is cancelled and its replacement issued in one step, with a reason, through
--      the same checks as any new voucher, and linked to the original. The supervisor corrects the vouchers they issued
--      within 24 hours; after that, and for others, the owner or a manager. Every correction and cancellation of a
--      voucher, and every edit and cancellation of an invoice, waits in the review list.
--   7. The review list: the owner reads it and marks what they reviewed (§16).
-- Applied through the SQL tools, so it only adds and updates.
-- =====================================================================
select set_config('app.source', 'migration', true);

-- ---------------------------------------------------------------- 1. columns
alter table invoices add column if not exists scope text;
alter table invoices add column if not exists origin text;
alter table invoices add column if not exists version int not null default 1;
alter table invoices add column if not exists versions jsonb not null default '[]'::jsonb;
alter table invoices add column if not exists bill_to jsonb not null default '{}'::jsonb;
alter table invoices add column if not exists updated_at timestamptz;
alter table invoices add column if not exists updated_by uuid references staff_profiles(id);

-- the invoices issued so far: one asked for a period is a period invoice, the others took everything left
update invoices set scope = case when coalesce((snapshot->'period'->>'requested')::boolean, false) then 'period' else 'remaining' end where scope is null;
update invoices set origin = 'manual' where origin is null;
alter table invoices alter column scope set default 'remaining';
alter table invoices alter column scope set not null;
alter table invoices alter column origin set default 'manual';
alter table invoices alter column origin set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_scope_chk') then
    alter table invoices add constraint invoices_scope_chk check (scope in ('period', 'remaining'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'invoices_origin_chk') then
    alter table invoices add constraint invoices_origin_chk check (origin in ('manual', 'checkout', 'deposit_settled'));
  end if;
end $$;

-- their lines carried whole charges: each line's share is its total
update invoices i set snapshot = jsonb_set(i.snapshot, '{lines}', (
    select coalesce(jsonb_agg(l.value || jsonb_build_object('charge_id', coalesce(l.value->>'charge_id', l.value->>'id'),
                                                            'amount_halalas', coalesce(l.value->'amount_halalas', l.value->'total_halalas'))
                              order by l.ordinality), '[]'::jsonb)
    from jsonb_array_elements(i.snapshot->'lines') with ordinality l))
 where jsonb_typeof(i.snapshot->'lines') = 'array'
   and exists (select 1 from jsonb_array_elements(i.snapshot->'lines') x where not (x ? 'amount_halalas'));
update invoices set bill_to = jsonb_build_object('name', snapshot->'guest'->>'name') where bill_to = '{}'::jsonb and snapshot->'guest'->>'name' is not null;

-- a tax line knows its line (it follows that line's proportion in a partial invoice); no foreign key: both go with their stay
alter table reservation_charges add column if not exists base_charge_id uuid;
update reservation_charges t set base_charge_id = b.id
  from reservation_charges b
 where t.kind = 'tax' and t.base_charge_id is null and b.reservation_id = t.reservation_id and b.kind <> 'tax'
   and b.created_at = t.created_at and b.service_from = t.service_from and b.service_to = t.service_to
   and t.description = 'ضريبة القيمة المضافة — ' || b.description;
-- the stays carried over by 0007 («(ترحيل)»): their rent and its tax were written together over the same nights, under
-- other names; a tax line is linked only when exactly one line of its stay matches it
update reservation_charges t set base_charge_id = (select b.id from reservation_charges b
                                                    where b.reservation_id = t.reservation_id and b.kind <> 'tax' and b.created_at = t.created_at
                                                      and b.service_from = t.service_from and b.service_to = t.service_to)
 where t.kind = 'tax' and t.base_charge_id is null
   and (select count(*) from reservation_charges b
         where b.reservation_id = t.reservation_id and b.kind <> 'tax' and b.created_at = t.created_at
           and b.service_from = t.service_from and b.service_to = t.service_to) = 1;

-- identical to 0028, and the tax line records its line
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
    insert into reservation_charges(organization_id, branch_id, reservation_id, kind, description, quantity, unit_price_halalas, total_halalas, taxable, reason, created_by, service_from, service_to, base_charge_id)
    values (r.organization_id, r.branch_id, r.id, 'tax', 'ضريبة القيمة المضافة — ' || p_description, 1, tax, tax, false, p_reason, fn_staff_id(), sf, st, cid);
  end if;
  return cid;
end $$;
revoke all on function fn_add_charge(uuid, text, text, numeric, bigint, boolean, text, uuid, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- 2. the share of each line in a period
-- n / d in whole halalas, half away from zero (decision 47), exactly: the integer quotient, never a rounded fraction
create or replace function fn_round_div(p_n numeric, p_d numeric) returns bigint
language sql immutable set search_path = public as $$
  select (sign(p_n) * sign(p_d) * div(2 * abs(p_n) + abs(p_d), 2 * abs(p_d)))::bigint
$$;
revoke all on function fn_round_div(numeric, numeric) from public, anon, authenticated;

-- The part of a line's total that falls before a day, in halalas. A line over nights: the nights before that day, out
-- of its nights; a discount or a stay-wide adjustment: the rent of the stay's active nights before that day, out of the
-- rent of its nights (by count when it has no rent). Multiplied before it is divided, so a half is a half.
create or replace function fn_charge_part(p_reservation uuid, p_total bigint, p_weighted boolean, p_from date, p_to date, p_at date) returns bigint
language plpgsql stable security definer set search_path = public as $$
declare w_all numeric; w_before numeric;
begin
  if p_at <= p_from then return 0; end if;
  if p_at >= p_to then return p_total; end if;
  if p_weighted then
    select coalesce(sum(price_halalas), 0), coalesce(sum(price_halalas) filter (where night < p_at), 0) into w_all, w_before
      from reservation_nights where reservation_id = p_reservation and status = 'active' and night >= p_from and night < p_to;
    if w_all > 0 then return fn_round_div(p_total * w_before, w_all); end if;
  end if;
  return fn_round_div(p_total::numeric * (p_at - p_from), p_to - p_from);
end $$;
revoke all on function fn_charge_part(uuid, bigint, boolean, date, date, date) from public, anon, authenticated;

-- What an invoice for [p_from, p_to] would carry of each line (nights from..to-1, one-off days from..to); with no
-- period, all that no issued invoice carries yet. p_exclude: an invoice being edited (its own shares count as free).
create or replace function fn_invoice_shares(p_reservation uuid, p_from date, p_to date, p_exclude uuid default null)
returns table(charge_id uuid, kind text, description text, quantity numeric, unit_price_halalas bigint, total_halalas bigint,
              invoiced_halalas bigint, share_halalas bigint, service_from date, service_to date, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare c record; lft bigint; s bigint; k text; sf date; st date; weighted boolean;
begin
  for c in
    select rc.id, rc.kind, rc.description, rc.quantity, rc.unit_price_halalas, rc.total_halalas, rc.service_from, rc.service_to, rc.created_at,
           coalesce(x.amt, 0) as invoiced, b.kind as base_kind, b.service_from as base_from, b.service_to as base_to
      from reservation_charges rc
      left join (select (l->>'charge_id')::uuid as cid, sum((l->>'amount_halalas')::bigint) as amt
                   from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
                  where i.reservation_id = p_reservation and i.status = 'issued' and (p_exclude is null or i.id <> p_exclude)
                  group by 1) x on x.cid = rc.id
      left join reservation_charges b on b.id = rc.base_charge_id
     where rc.reservation_id = p_reservation and rc.total_halalas <> 0
     order by rc.created_at, rc.kind = 'tax', rc.id
  loop
    lft := c.total_halalas - c.invoiced;
    if lft = 0 then continue; end if;
    if p_from is null then
      s := lft;
    else
      -- a tax line follows its line's kind and period
      k := coalesce(c.base_kind, c.kind); sf := coalesce(c.base_from, c.service_from); st := coalesce(c.base_to, c.service_to);
      if sf = st then
        s := case when sf >= p_from and sf <= p_to then lft else 0 end;
      else
        weighted := k in ('discount', 'adjustment');
        s := fn_charge_part(p_reservation, c.total_halalas, weighted, sf, st, p_to)
           - fn_charge_part(p_reservation, c.total_halalas, weighted, sf, st, p_from);
        if c.total_halalas > 0 then s := greatest(0, least(s, lft)); else s := least(0, greatest(s, lft)); end if;
      end if;
    end if;
    if s = 0 then continue; end if;
    charge_id := c.id; kind := c.kind; description := c.description; quantity := c.quantity; unit_price_halalas := c.unit_price_halalas;
    total_halalas := c.total_halalas; invoiced_halalas := c.invoiced; share_halalas := s; service_from := c.service_from; service_to := c.service_to;
    created_at := c.created_at;
    return next;
  end loop;
end $$;
revoke all on function fn_invoice_shares(uuid, date, date, uuid) from public, anon, authenticated;

-- the stay's value not yet carried by an issued invoice (negative: the invoices carry more than its lines)
create or replace function fn_uninvoiced_value(p_reservation uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select (select coalesce(sum(total_halalas), 0) from reservation_charges where reservation_id = p_reservation)
       - (select coalesce(sum(total_halalas), 0) from invoices where reservation_id = p_reservation and status = 'issued');
$$;
revoke all on function fn_uninvoiced_value(uuid) from public, anon, authenticated;

-- reservation_charges.invoice_id = the issued invoice that completed the line, or nothing
create or replace function fn_sync_invoice_markers(p_reservation uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update reservation_charges rc set invoice_id = m.done
    from (select c.id,
                 case when c.total_halalas <> 0 and coalesce(x.amt, 0) = c.total_halalas then x.last_invoice end as done
            from reservation_charges c
            left join (select (l->>'charge_id')::uuid as cid, sum((l->>'amount_halalas')::bigint) as amt,
                              (array_agg(i.id order by coalesce(i.updated_at, i.issued_at) desc, i.id desc))[1] as last_invoice
                         from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
                        where i.reservation_id = p_reservation and i.status = 'issued'
                        group by 1) x on x.cid = c.id
           where c.reservation_id = p_reservation) m
   where rc.id = m.id and rc.invoice_id is distinct from m.done;
end $$;
revoke all on function fn_sync_invoice_markers(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. issuing (decision 27)
-- The caller holds the stay's row lock and has checked the role and the branch. A period invoice is refused when it
-- overlaps another; returns null when the period (or the stay) has nothing left to carry.
create or replace function fn_issue_invoice(p_reservation uuid, p_scope text, p_from date, p_to date, p_origin text, p_bill_to jsonb default null)
returns invoices
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; b branches%rowtype; gname text; inv invoices%rowtype; lines jsonb; sub bigint; tax bigint; n int; pf date; pt date; bt jsonb;
begin
  if p_scope not in ('period', 'remaining') then raise exception 'VALIDATION: scope'; end if;
  select * into r from reservations where id = p_reservation;
  if p_scope = 'period' then
    if p_from is null or p_to is null or p_to <= p_from then raise exception 'VALIDATION: period'; end if;
    if exists (select 1 from invoices i where i.reservation_id = r.id and i.status = 'issued' and i.scope = 'period'
                                         and i.period_from < p_to and p_from < i.period_to) then
      raise exception 'INVOICE_PERIOD_OVERLAP: another invoice of this stay covers part of the period';
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('charge_id', s.charge_id, 'kind', s.kind, 'description', s.description, 'quantity', s.quantity,
                                               'unit_price_halalas', s.unit_price_halalas, 'total_halalas', s.total_halalas,
                                               'amount_halalas', s.share_halalas, 'service_from', s.service_from, 'service_to', s.service_to)
                            order by s.created_at, s.kind = 'tax', s.charge_id), '[]'::jsonb),
         coalesce(sum(s.share_halalas) filter (where s.kind <> 'tax'), 0), coalesce(sum(s.share_halalas) filter (where s.kind = 'tax'), 0),
         count(*), min(s.service_from), max(s.service_to)
    into lines, sub, tax, n, pf, pt
    from fn_invoice_shares(r.id, case when p_scope = 'period' then p_from end, case when p_scope = 'period' then p_to end) s;
  if n = 0 then return null; end if;
  -- a period invoice keeps its period; the rest of a stay is dated by the lines it carries
  if p_scope = 'period' then pf := p_from; pt := p_to; end if;
  select * into b from branches where id = r.branch_id;
  select full_name into gname from reservation_guests where reservation_id = r.id and is_primary limit 1;
  bt := jsonb_strip_nulls(jsonb_build_object('name', coalesce(nullif(trim(coalesce(p_bill_to->>'name', '')), ''), gname),
                                             'note', nullif(trim(coalesce(p_bill_to->>'note', '')), '')));
  insert into invoices(organization_id, branch_id, reservation_id, number, period_from, period_to, scope, origin, bill_to, snapshot,
                       subtotal_halalas, tax_halalas, total_halalas, issued_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'invoice', 'INV'), pf, pt, p_scope, p_origin, bt,
          jsonb_build_object('property', jsonb_build_object('name', b.name_ar, 'tax_number', b.tax_number, 'commercial_register', b.commercial_register, 'address', b.address),
                             'guest', jsonb_build_object('name', gname), 'bill_to', bt,
                             'reservation', jsonb_build_object('internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'check_in', r.check_in, 'check_out', r.check_out,
                                                               'room', (select room_number from rooms where id = r.room_id)),
                             'period', jsonb_build_object('from', pf, 'to', pt, 'scope', p_scope, 'requested', p_scope = 'period'),
                             'origin', p_origin, 'charge_ids', (select coalesce(jsonb_agg(x->'charge_id'), '[]'::jsonb) from jsonb_array_elements(lines) x),
                             'lines', lines, 'tax_rate_bp', coalesce(r.tax_rate_bp, b.tax_rate_bp)),
          sub, tax, sub + tax, fn_staff_id())
  returning * into inv;
  perform fn_sync_invoice_markers(r.id);
  perform fn_audit_change(r.branch_id, 'invoice.issued', 'invoice', inv.id, null,
    jsonb_build_object('number', inv.number, 'total_halalas', inv.total_halalas, 'reservation_id', r.id, 'scope', p_scope, 'origin', p_origin,
                       'period_from', pf, 'period_to', pt, 'line_count', n));
  return inv;
end $$;
revoke all on function fn_issue_invoice(uuid, text, date, date, text, jsonb) from public, anon, authenticated;

-- the automatic invoice: everything not yet invoiced, only when something positive is left
create or replace function fn_auto_invoice(p_reservation uuid, p_origin text) returns text
language plpgsql security definer set search_path = public as $$
declare left_total bigint; inv invoices%rowtype;
begin
  select coalesce(sum(share_halalas), 0) into left_total from fn_invoice_shares(p_reservation, null, null);
  if left_total <= 0 then return null; end if;
  inv := fn_issue_invoice(p_reservation, 'remaining', null, null, p_origin, null);
  return inv.number;
end $$;
revoke all on function fn_auto_invoice(uuid, text) from public, anon, authenticated;

-- «إصدار فاتورة»: with a period, a partial invoice; without, everything left. Refused when nothing positive is left
create or replace function fn_staff_issue_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; pf date := nullif(p->>'from', '')::date; pt date := nullif(p->>'to', '')::date; inv invoices%rowtype;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  if (pf is null) <> (pt is null) then raise exception 'VALIDATION: period'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  -- a period that overlaps another invoice is the first thing to say
  if pf is not null then
    if pt <= pf then raise exception 'VALIDATION: period'; end if;
    if exists (select 1 from invoices i where i.reservation_id = r.id and i.status = 'issued' and i.scope = 'period' and i.period_from < pt and pf < i.period_to) then
      raise exception 'INVOICE_PERIOD_OVERLAP: another invoice of this stay covers part of the period';
    end if;
  end if;
  if pf is not null and (select coalesce(sum(share_halalas), 0) from fn_invoice_shares(r.id, pf, pt)) <= 0
     or pf is null and (select coalesce(sum(share_halalas), 0) from fn_invoice_shares(r.id, null, null)) <= 0 then
    -- nothing, or only lines that lower the bill: those go into an existing invoice by editing it
    if exists (select 1 from fn_invoice_shares(r.id, pf, pt)) then raise exception 'INVOICE_NOT_POSITIVE'; end if;
    raise exception 'NOTHING_TO_INVOICE';
  end if;
  inv := fn_issue_invoice(r.id, case when pf is null then 'remaining' else 'period' end, pf, pt, 'manual', p->'bill_to');
  return jsonb_build_object('ok', true, 'id', inv.id, 'number', inv.number, 'total_halalas', inv.total_halalas, 'period_from', inv.period_from,
                            'period_to', inv.period_to, 'scope', inv.scope, 'line_count', jsonb_array_length(inv.snapshot->'lines'),
                            'charge_count', jsonb_array_length(inv.snapshot->'lines'));
end $$;
grant execute on function fn_staff_issue_invoice(jsonb) to authenticated;

-- the former entry point: a period gives a partial invoice, no period everything left
create or replace function fn_create_invoice(p_reservation uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return fn_staff_issue_invoice(jsonb_build_object('reservation_id', p_reservation, 'from', p_from, 'to', p_to));
end $$;
grant execute on function fn_create_invoice(uuid, date, date) to authenticated;

-- what an invoice would carry, before «إنشاء» (or an edit, with invoice_id): the lines, the totals, and what stops it
create or replace function fn_invoice_preview(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; inv invoices%rowtype; pf date := nullif(p->>'from', '')::date; pt date := nullif(p->>'to', '')::date;
        lines jsonb; sub bigint; tax bigint; n int; problems text[] := '{}'; scope text; gname text;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  if p ? 'invoice_id' and nullif(p->>'invoice_id', '') is not null then
    select * into inv from invoices where id = (p->>'invoice_id')::uuid;
    if not found then raise exception 'NOT_FOUND'; end if;
    select * into r from reservations where id = inv.reservation_id;
    scope := inv.scope;
    if scope = 'period' then pf := coalesce(pf, inv.period_from); pt := coalesce(pt, inv.period_to); else pf := null; pt := null; end if;
  else
    select * into r from reservations where id = (p->>'reservation_id')::uuid;
    if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
    if (pf is null) <> (pt is null) then raise exception 'VALIDATION: period'; end if;
    scope := case when pf is null then 'remaining' else 'period' end;
  end if;
  perform fn_require_branch(r.branch_id);
  if scope = 'period' then
    if pt <= pf then problems := array_append(problems, 'نهاية الفترة يجب أن تكون بعد بدايتها');
    elsif exists (select 1 from invoices i where i.reservation_id = r.id and i.status = 'issued' and i.scope = 'period'
                                           and (inv.id is null or i.id <> inv.id) and i.period_from < pt and pf < i.period_to) then
      problems := array_append(problems, 'فاتورة أخرى لهذا الحجز تغطي جزءًا من الفترة');
    end if;
  end if;
  if coalesce(array_length(problems, 1), 0) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object('charge_id', s.charge_id, 'kind', s.kind, 'description', s.description, 'quantity', s.quantity,
                                                 'unit_price_halalas', s.unit_price_halalas, 'total_halalas', s.total_halalas,
                                                 'invoiced_halalas', s.invoiced_halalas, 'amount_halalas', s.share_halalas,
                                                 'service_from', s.service_from, 'service_to', s.service_to) order by s.created_at, s.kind = 'tax', s.charge_id), '[]'::jsonb),
           coalesce(sum(s.share_halalas) filter (where s.kind <> 'tax'), 0), coalesce(sum(s.share_halalas) filter (where s.kind = 'tax'), 0), count(*)
      into lines, sub, tax, n
      from fn_invoice_shares(r.id, case when scope = 'period' then pf end, case when scope = 'period' then pt end, inv.id) s;
    if n = 0 then problems := array_append(problems, 'لا شيء لم يُفوتر في هذه الفترة');
    elsif sub + tax <= 0 then problems := array_append(problems, 'ما بقي يخفّض الفاتورة فقط؛ يُضاف إلى فاتورة صادرة بتعديلها'); end if;
  end if;
  select full_name into gname from reservation_guests where reservation_id = r.id and is_primary limit 1;
  return jsonb_build_object('ok', coalesce(array_length(problems, 1), 0) = 0, 'problems', to_jsonb(problems), 'scope', scope, 'from', pf, 'to', pt,
                            'lines', coalesce(lines, '[]'::jsonb), 'subtotal_halalas', coalesce(sub, 0), 'tax_halalas', coalesce(tax, 0),
                            'total_halalas', coalesce(sub, 0) + coalesce(tax, 0),
                            'reservation', jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'guest', gname,
                                                              'check_in', r.check_in, 'check_out', r.check_out, 'status', r.status),
                            'uninvoiced_halalas', fn_uninvoiced_value(r.id));
end $$;
grant execute on function fn_invoice_preview(jsonb) to authenticated;

-- ---------------------------------------------------------------- 4. editing and cancelling (decision 26)
-- With a reason: the bill-to details, the period (a period invoice), and the amounts, which follow the stay's lines as
-- they stand. The version before is kept in the invoice; the edit waits in the owner's review list.
create or replace function fn_staff_edit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); pf date; pt date; bt jsonb;
        lines jsonb; sub bigint; tax bigint; n int; prev jsonb; old_lines jsonb; new_lines jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into inv from invoices where id = (p->>'invoice_id')::uuid;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = inv.reservation_id for update;      -- the stay first, as every money operation
  perform fn_require_branch(inv.branch_id);
  select * into inv from invoices where id = inv.id for update;
  if inv.status <> 'issued' then raise exception 'INVOICE_STATUS_INVALID'; end if;
  if inv.scope = 'period' then
    pf := coalesce(nullif(p->>'from', '')::date, inv.period_from); pt := coalesce(nullif(p->>'to', '')::date, inv.period_to);
    if pt <= pf then raise exception 'VALIDATION: period'; end if;
    if exists (select 1 from invoices i where i.reservation_id = r.id and i.status = 'issued' and i.scope = 'period' and i.id <> inv.id
                                         and i.period_from < pt and pf < i.period_to) then
      raise exception 'INVOICE_PERIOD_OVERLAP: another invoice of this stay covers part of the period';
    end if;
  end if;
  bt := inv.bill_to;
  if jsonb_typeof(p->'bill_to') = 'object' then
    -- a key sent empty is cleared (merged as null, then stripped)
    if p->'bill_to' ? 'name' then bt := bt || jsonb_build_object('name', nullif(trim(coalesce(p->'bill_to'->>'name', '')), '')); end if;
    if p->'bill_to' ? 'note' then bt := bt || jsonb_build_object('note', nullif(trim(coalesce(p->'bill_to'->>'note', '')), '')); end if;
    bt := jsonb_strip_nulls(bt);
    if coalesce(bt->>'name', '') = '' then raise exception 'VALIDATION: bill_to_name'; end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('charge_id', s.charge_id, 'kind', s.kind, 'description', s.description, 'quantity', s.quantity,
                                               'unit_price_halalas', s.unit_price_halalas, 'total_halalas', s.total_halalas,
                                               'amount_halalas', s.share_halalas, 'service_from', s.service_from, 'service_to', s.service_to)
                            order by s.created_at, s.kind = 'tax', s.charge_id), '[]'::jsonb),
         coalesce(sum(s.share_halalas) filter (where s.kind <> 'tax'), 0), coalesce(sum(s.share_halalas) filter (where s.kind = 'tax'), 0), count(*)
    into lines, sub, tax, n
    from fn_invoice_shares(r.id, case when inv.scope = 'period' then pf end, case when inv.scope = 'period' then pt end, inv.id) s;
  if n = 0 then raise exception 'NOTHING_TO_INVOICE'; end if;
  if sub + tax <= 0 then raise exception 'INVOICE_NOT_POSITIVE'; end if;
  if inv.scope = 'remaining' then pf := inv.period_from; pt := inv.period_to; end if;
  -- unchanged: the same shares, the same period and the same bill-to
  select coalesce(jsonb_agg(jsonb_build_array(x->>'charge_id', x->>'amount_halalas') order by x->>'charge_id'), '[]'::jsonb) into old_lines from jsonb_array_elements(inv.snapshot->'lines') x;
  select coalesce(jsonb_agg(jsonb_build_array(x->>'charge_id', x->>'amount_halalas') order by x->>'charge_id'), '[]'::jsonb) into new_lines from jsonb_array_elements(lines) x;
  if old_lines = new_lines and pf = inv.period_from and pt = inv.period_to and bt = inv.bill_to then
    return jsonb_build_object('ok', true, 'unchanged', true, 'id', inv.id, 'number', inv.number, 'version', inv.version);
  end if;
  prev := jsonb_build_object('version', inv.version, 'period_from', inv.period_from, 'period_to', inv.period_to, 'bill_to', inv.bill_to,
                             'subtotal_halalas', inv.subtotal_halalas, 'tax_halalas', inv.tax_halalas, 'total_halalas', inv.total_halalas,
                             'lines', inv.snapshot->'lines', 'since', coalesce(inv.updated_at, inv.issued_at),
                             'by', (select full_name from staff_profiles where id = coalesce(inv.updated_by, inv.issued_by)),
                             'replaced_at', now(), 'replaced_by', (select full_name from staff_profiles where id = fn_staff_id()), 'reason', reason);
  update invoices set versions = versions || jsonb_build_array(prev), version = version + 1, period_from = pf, period_to = pt, bill_to = bt,
         snapshot = snapshot || jsonb_build_object('lines', lines, 'bill_to', bt,
                                                   'period', jsonb_build_object('from', pf, 'to', pt, 'scope', inv.scope, 'requested', inv.scope = 'period'),
                                                   'charge_ids', (select coalesce(jsonb_agg(x->'charge_id'), '[]'::jsonb) from jsonb_array_elements(lines) x)),
         subtotal_halalas = sub, tax_halalas = tax, total_halalas = sub + tax, updated_at = now(), updated_by = fn_staff_id()
   where id = inv.id
   returning * into inv;
  perform fn_sync_invoice_markers(r.id);
  perform fn_add_review_item(inv.branch_id, 'invoice_edited', 'invoice', inv.id, r.id, 'تعديل الفاتورة ' || inv.number || ' (الإصدار ' || inv.version || ')', reason,
    jsonb_build_object('number', inv.number, 'version', inv.version, 'before_total_halalas', (prev->>'total_halalas')::bigint, 'after_total_halalas', inv.total_halalas,
                       'before_period', jsonb_build_array(prev->>'period_from', prev->>'period_to'), 'after_period', jsonb_build_array(pf, pt)));
  perform fn_audit_change(inv.branch_id, 'invoice.edited', 'invoice', inv.id,
    jsonb_build_object('version', (prev->>'version')::int, 'total_halalas', (prev->>'total_halalas')::bigint, 'period_from', prev->>'period_from', 'period_to', prev->>'period_to', 'bill_to', prev->'bill_to'),
    jsonb_build_object('version', inv.version, 'total_halalas', inv.total_halalas, 'period_from', pf, 'period_to', pt, 'bill_to', bt), reason);
  return jsonb_build_object('ok', true, 'unchanged', false, 'id', inv.id, 'number', inv.number, 'version', inv.version, 'total_halalas', inv.total_halalas);
end $$;
grant execute on function fn_staff_edit_invoice(jsonb) to authenticated;

-- cancelling: the owner or a manager, with a reason; its shares become invoiceable again; it waits in the review list
create or replace function fn_cancel_invoice(p_invoice uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; r reservations%rowtype;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into inv from invoices where id = p_invoice;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = inv.reservation_id for update;
  perform fn_require_branch(inv.branch_id);
  select * into inv from invoices where id = inv.id for update;
  if inv.status <> 'issued' then raise exception 'INVOICE_STATUS_INVALID'; end if;
  update invoices set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = p_reason where id = inv.id;
  perform fn_sync_invoice_markers(r.id);
  perform fn_add_review_item(inv.branch_id, 'invoice_cancelled', 'invoice', inv.id, r.id, 'إلغاء الفاتورة ' || inv.number, p_reason,
    jsonb_build_object('number', inv.number, 'total_halalas', inv.total_halalas));
  perform fn_audit_change(inv.branch_id, 'invoice.cancelled', 'invoice', inv.id, jsonb_build_object('status', 'issued'), jsonb_build_object('status', 'cancelled'), p_reason);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_cancel_invoice(uuid, text) to authenticated;

-- ---------------------------------------------------------------- 5. «مغلق» asks for the stay's value invoiced (decision 59)
create or replace function fn_closure_missing(p_reservation uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare f jsonb; v text[] := '{}'; u bigint;
begin
  f := fn_reservation_finance_internal(p_reservation);
  if (f->>'balance_due')::bigint > 0 then v := array_append(v, 'مبلغ مستحق ' || fn_sar_text((f->>'balance_due')::bigint)); end if;
  if (f->>'credit')::bigint > 0 then v := array_append(v, 'رصيد للضيف لم يُرد ' || fn_sar_text((f->>'credit')::bigint)); end if;
  if (f->>'deposit_balance')::bigint <> 0 then v := array_append(v, 'تأمين لم يُسوَّ ' || fn_sar_text((f->>'deposit_balance')::bigint)); end if;
  u := fn_uninvoiced_value(p_reservation);
  if u > 0 then v := array_append(v, 'قيمة لم تُفوتر ' || fn_sar_text(u));
  elsif u < 0 then v := array_append(v, 'الفواتير تزيد على قيمة الإقامة ' || fn_sar_text(-u) || '؛ عدّل الفاتورة');
  end if;
  return v;
end $$;
revoke all on function fn_closure_missing(uuid) from public, anon, authenticated;

-- an invoice issued, edited or cancelled re-checks the closing, whichever function made it
create or replace function fn_trg_invoice_sync_closed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform fn_sync_closed(new.reservation_id);
  return null;
end $$;
revoke all on function fn_trg_invoice_sync_closed() from public, anon, authenticated;
create or replace trigger trg_invoices_sync_closed after insert or update of status, total_halalas on invoices
  for each row execute function fn_trg_invoice_sync_closed();

-- ---------------------------------------------------------------- 6. the automatic invoice at the departure and at the deposit's settlement (decision 27)
-- check-out: identical to 0033, and everything not yet invoiced is invoiced in the same operation
create or replace function fn_staff_check_out(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; f jsonb; tt uuid; existing_task uuid; has_kb boolean; st text; inv_no text;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('checked_out', 'closed') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status); end if;   -- R14
  if r.status <> 'checked_in' then raise exception 'NOT_CHECKED_IN'; end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  f := fn_recompute_reservation_finance(r.id);
  -- nothing owed, for anyone: no override (decision 8)
  if (f->>'balance_due')::bigint > 0 then
    return jsonb_build_object('ok', false, 'balance_due', (f->>'balance_due')::bigint, 'reasons', jsonb_build_array(
      'على الحجز مبلغ مستحق ' || fn_sar_text((f->>'balance_due')::bigint)
      || '. يُصفَّر بسند قبض، أو بالخصم من التأمين بسبب، أو بتسوية سعر من المالك أو المدير بسبب.'));
  end if;
  update reservations set status = 'checked_out', actual_check_out = now(), checked_out_by = fn_staff_id(), version = version + 1, updated_at = now() where id = r.id;
  perform fn_release_allocations(r.id, 'close');
  if r.room_id is not null then
    update rooms set status = 'cleaning', cleanliness = 'dirty', updated_at = now() where id = r.room_id;
    tt := fn_room_cleaning_type(r.branch_id);
    select id into existing_task from housekeeping_tasks where room_id = r.room_id and reservation_id = r.id and status in ('pending', 'in_progress') limit 1;
    if existing_task is null then
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      values (r.organization_id, r.branch_id, r.room_id, tt, 'تنظيف الوحدة وتعقيمها', r.id, 'high', 'تنظيف بعد المغادرة', fn_staff_id());
    end if;
    has_kb := exists (select 1 from keyboxes where room_id = r.room_id);
    update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id;
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', case when has_kb then 'مغادرة — تنظيف وتغيير رمز مطلوب' else 'مغادرة — تنظيف مطلوب' end,
            'غرفة ' || (select room_number from rooms where id = r.room_id), '/staff/housekeeping');
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.checked_out', 'reservation', r.id, jsonb_build_object('status', 'checked_in'),
    jsonb_build_object('status', 'checked_out', 'deposit_balance_halalas', (f->>'deposit_balance')::bigint, 'credit_halalas', (f->>'credit')::bigint));
  inv_no := fn_auto_invoice(r.id, 'checkout');
  st := fn_sync_closed(r.id);
  return jsonb_build_object('ok', true, 'duplicate', false, 'status', st, 'deposit_to_settle_halalas', (f->>'deposit_balance')::bigint,
                            'credit_halalas', (f->>'credit')::bigint, 'invoice', inv_no, 'missing', to_jsonb(fn_closure_missing(r.id)));
end $$;
grant execute on function fn_staff_check_out(jsonb) to authenticated;

-- refunds: identical to 0033, except that a link to an original voucher must be a voucher of the same stay, and that the
-- deposit settled after the departure invoices what is left (a damage, a late fee)
create or replace function fn_refund(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; f jsonb; available bigint; prefix text; m text; ref text; acc uuid; orig uuid; inv_no text;
begin
  if kind is null or kind not in ('refund', 'deposit_refund', 'deposit_apply') then raise exception 'VALIDATION: kind'; end if;
  if kind = 'refund' then perform fn_require_role('owner', 'manager', 'finance');
  else perform fn_require_role('owner', 'manager', 'supervisor', 'finance'); end if;
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
  orig := nullif(p->>'original_voucher_id', '')::uuid;
  if orig is not null and not exists (select 1 from financial_vouchers where id = orig and reservation_id = r.id) then raise exception 'VALIDATION: original_voucher'; end if;
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
  end if;
  f := fn_reservation_finance_internal(r.id);
  available := case kind when 'refund' then (f->>'received')::bigint - (f->>'refunded')::bigint else (f->>'deposit_balance')::bigint end;
  if amt > available then raise exception 'REFUND_EXCEEDS_AVAILABLE: available % halalas', available; end if;
  if kind = 'deposit_apply' and amt > (f->>'balance_due')::bigint then raise exception 'REFUND_EXCEEDS_AVAILABLE: nothing due'; end if;
  prefix := case kind when 'refund' then 'RFD' when 'deposit_refund' then 'DRF' else 'DAP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, original_voucher_id, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc,
          'approved', ref, p->>'note', p->>'reason', orig, key, h, now(), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', case when kind = 'deposit_apply' then null else m end, 'account_id', acc, 'reservation_id', r.id, 'available_before', available), p->>'reason');
  if kind in ('deposit_refund', 'deposit_apply') and r.status in ('checked_out', 'closed')
     and (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint = 0 then
    inv_no := fn_auto_invoice(r.id, 'deposit_settled');
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id), 'invoice', inv_no);
end $$;
grant execute on function fn_refund(jsonb) to authenticated;

-- «رسم ضرر»: identical to 0033, and after the departure, a deposit left at nothing invoices the damage at once
create or replace function fn_staff_add_damage(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; amt bigint; key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); descr text := nullif(trim(coalesce(p->>'description', '')), '');
        reason text := nullif(trim(coalesce(p->>'reason', '')), ''); cid uuid; f jsonb; apply_amt bigint := 0; v jsonb; existing uuid; inv_no text;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  amt := fn_parse_halalas(p->>'amount_halalas');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  if key is null then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select id into existing from reservation_charges where reservation_id = r.id and idempotency_key = key;
  if existing is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'charge_id', existing, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if r.status not in ('checked_in', 'checked_out', 'closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  cid := fn_add_charge(r.id, 'penalty', 'رسم ضرر — ' || coalesce(descr, reason), 1, amt, false, reason);
  update reservation_charges set purpose = 'damage', idempotency_key = key where id = cid;
  if coalesce((p->>'apply_deposit')::boolean, true) then
    f := fn_reservation_finance_internal(r.id);
    apply_amt := least(amt, (f->>'deposit_balance')::bigint, (f->>'balance_due')::bigint);
    if apply_amt > 0 then
      v := fn_refund(jsonb_build_object('reservation_id', r.id, 'kind', 'deposit_apply', 'amount_halalas', apply_amt,
                                        'reason', 'رسم ضرر: ' || reason, 'idempotency_key', key || ':apply'));
    end if;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  if r.status in ('checked_out', 'closed') and (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint = 0 then
    inv_no := coalesce(v->>'invoice', fn_auto_invoice(r.id, 'deposit_settled'));
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.damage_charged', 'reservation', r.id, null,
    jsonb_build_object('amount_halalas', amt, 'description', descr, 'from_deposit_halalas', apply_amt, 'voucher', v->>'number', 'invoice', inv_no), reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'charge_id', cid, 'from_deposit_halalas', apply_amt, 'invoice', inv_no,
                            'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_add_damage(jsonb) to authenticated;

-- ---------------------------------------------------------------- 7. «تصحيح سند» (decision 11)
-- The original is cancelled and its replacement issued in one step, through the same checks as any new voucher,
-- linked to it. The supervisor: vouchers they issued, within 24 hours; the owner and the manager: any. A voucher already
-- in a platform payout is corrected by correcting the payout first.
create or replace function fn_staff_correct_voucher(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v financial_vouchers%rowtype; r reservations%rowtype; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); existing financial_vouchers%rowtype; payload jsonb; res jsonb;
        nv financial_vouchers%rowtype; f jsonb; amt text; m text; ref text; acc text; note text;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
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
  if not fn_has_role('owner', 'manager') then
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
  update financial_vouchers set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = 'تصحيح: ' || v_reason where id = v.id;
  payload := jsonb_strip_nulls(jsonb_build_object('reservation_id', r.id, 'kind', v.kind, 'idempotency_key', key, 'amount_halalas', amt,
                                                  'method', m, 'reference', ref, 'account_id', acc, 'note', note,
                                                  'reason', coalesce(v.reason, 'تصحيح السند ' || v.number), 'original_voucher_id', v.id));
  if v.kind in ('receipt', 'deposit') then res := fn_create_voucher(payload); else res := fn_refund(payload); end if;
  update financial_vouchers set original_voucher_id = v.id where id = (res->>'voucher_id')::uuid and original_voucher_id is null;
  select * into nv from financial_vouchers where id = (res->>'voucher_id')::uuid;
  f := fn_reservation_finance_internal(r.id);
  if (f->>'deposit_balance')::bigint < 0 or ((f->>'received')::bigint - (f->>'refunded')::bigint) < 0 then
    raise exception 'CANCEL_WOULD_GO_NEGATIVE';
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(v.branch_id, 'voucher_corrected', 'voucher', nv.id, r.id, 'تصحيح السند ' || v.number || ' بالسند ' || nv.number, v_reason,
    jsonb_build_object('original', v.number, 'replacement', nv.number, 'kind', v.kind,
                       'before', jsonb_build_object('amount_halalas', v.amount_halalas, 'method', v.method, 'reference', v.reference, 'account_id', v.account_id),
                       'after', jsonb_build_object('amount_halalas', nv.amount_halalas, 'method', nv.method, 'reference', nv.reference, 'account_id', nv.account_id),
                       'issued_by_self', v.created_by is not distinct from fn_staff_id()));
  perform fn_audit_change(v.branch_id, 'voucher.corrected', 'voucher', nv.id,
    jsonb_build_object('number', v.number, 'amount_halalas', v.amount_halalas, 'method', v.method, 'reference', v.reference, 'account_id', v.account_id),
    jsonb_build_object('number', nv.number, 'amount_halalas', nv.amount_halalas, 'method', nv.method, 'reference', nv.reference, 'account_id', nv.account_id,
                       'original_voucher_id', v.id), v_reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', nv.id, 'number', nv.number, 'original_number', v.number,
                            'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_correct_voucher(jsonb) to authenticated;

-- cancelling a voucher: identical to 0007c, the stay locked first, a voucher in a platform payout refused, and the
-- cancellation waits in the owner's review list
create or replace function fn_cancel_voucher(p_voucher uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v financial_vouchers%rowtype; r reservations%rowtype; f jsonb;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into v from financial_vouchers where id = p_voucher;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = v.reservation_id for update;
  perform fn_require_branch(v.branch_id);
  select * into v from financial_vouchers where id = v.id for update;
  if v.status <> 'approved' then raise exception 'VOUCHER_STATUS_INVALID'; end if;
  if v.payout_id is not null then raise exception 'VOUCHER_IN_PAYOUT'; end if;
  update financial_vouchers set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = p_reason where id = v.id;
  f := fn_reservation_finance_internal(r.id);
  if (f->>'deposit_balance')::bigint < 0 or ((f->>'received')::bigint - (f->>'refunded')::bigint) < 0 then
    raise exception 'CANCEL_WOULD_GO_NEGATIVE';
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(v.branch_id, 'voucher_cancelled', 'voucher', v.id, r.id, 'إلغاء السند ' || v.number, p_reason,
    jsonb_build_object('number', v.number, 'kind', v.kind, 'amount_halalas', v.amount_halalas, 'method', v.method));
  perform fn_audit_change(v.branch_id, 'voucher.cancelled', 'voucher', v.id, jsonb_build_object('status', 'approved'),
    jsonb_build_object('status', 'cancelled', 'number', v.number, 'amount_halalas', v.amount_halalas), p_reason);
  return jsonb_build_object('ok', true, 'finance', f, 'provider_refund_note', 'إلغاء السند محلي؛ لا يعني أن مزود الدفع ردّ المبلغ.');
end $$;
grant execute on function fn_cancel_voucher(uuid, text) to authenticated;

-- ---------------------------------------------------------------- 8. «بحاجة لمراجعة وتدقيق»: the owner reads and marks (§16)
create or replace function fn_review_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare st text := coalesce(nullif(p->>'status', ''), 'open'); lim int := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500); items jsonb;
begin
  perform fn_require_role('owner');
  if st not in ('open', 'reviewed', 'all') then raise exception 'VALIDATION: status'; end if;
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) into items from (
    select jsonb_build_object('id', ri.id, 'kind', ri.kind, 'entity_type', ri.entity_type, 'entity_id', ri.entity_id, 'reservation_id', ri.reservation_id,
             'internal_ref', (select internal_ref from reservations where id = ri.reservation_id),
             'branch_id', ri.branch_id, 'branch_name', (select name_ar from branches where id = ri.branch_id),
             'summary', ri.summary, 'reason', ri.reason, 'details', ri.details,
             'created_at', ri.created_at, 'created_by', (select full_name from staff_profiles where id = ri.created_by),
             'reviewed_at', ri.reviewed_at, 'reviewed_by', (select full_name from staff_profiles where id = ri.reviewed_by), 'review_note', ri.review_note) as x
      from review_items ri
     where ri.organization_id = fn_user_org_id()
       and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))
       and (st = 'all' or (st = 'open') = (ri.reviewed_at is null))
       and (nullif(p->>'kind', '') is null or ri.kind = p->>'kind' or (p->>'kind' = 'monitor' and ri.kind like 'monitor:%'))
       and (nullif(p->>'branch_id', '') is null or ri.branch_id = (p->>'branch_id')::uuid)
       and (nullif(p->>'before', '') is null or ri.created_at < (p->>'before')::timestamptz)
     order by ri.created_at desc
     limit lim) s;
  return jsonb_build_object('items', items, 'open_count',
    (select count(*) from review_items ri where ri.organization_id = fn_user_org_id() and ri.reviewed_at is null
        and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))));
end $$;
grant execute on function fn_review_list(jsonb) to authenticated;

create or replace function fn_review_mark(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ids uuid[]; note text := nullif(trim(coalesce(p->>'note', '')), ''); n int;
begin
  perform fn_require_role('owner');
  select coalesce(array_agg(x::uuid), '{}') into ids
    from jsonb_array_elements_text(case when jsonb_typeof(p->'ids') = 'array' then p->'ids' else '[]'::jsonb end) x;
  if coalesce(array_length(ids, 1), 0) = 0 then raise exception 'VALIDATION: ids'; end if;
  update review_items set reviewed_at = now(), reviewed_by = fn_staff_id(), review_note = note
   where id = any(ids) and reviewed_at is null and organization_id = fn_user_org_id()
     and (branch_id is null or branch_id in (select fn_user_branch_ids()));
  get diagnostics n = row_count;
  perform fn_audit_change(null, 'review.marked', 'review_items', null, null, jsonb_build_object('count', n, 'ids', to_jsonb(ids)), note);
  return jsonb_build_object('ok', true, 'marked', n);
end $$;
grant execute on function fn_review_mark(jsonb) to authenticated;

-- the owner's banner: how many wait, by kind (anyone else: nothing)
create or replace function fn_review_summary() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when fn_has_role('owner') then (
    select jsonb_build_object('open', count(*), 'oldest_at', min(ri.created_at),
                              'monitors', count(*) filter (where ri.kind like 'monitor:%'),
                              'by_kind', coalesce((select jsonb_object_agg(k, c) from (select kind as k, count(*) as c from review_items
                                                    where organization_id = fn_user_org_id() and reviewed_at is null
                                                      and (branch_id is null or branch_id in (select fn_user_branch_ids())) group by kind) g), '{}'::jsonb))
      from review_items ri
     where ri.organization_id = fn_user_org_id() and ri.reviewed_at is null
       and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))) end;
$$;
grant execute on function fn_review_summary() to authenticated;

-- ---------------------------------------------------------------- 9. the reservation page
-- identical to 0007c, plus: each line's invoiced share, each invoice's scope, origin, version, bill-to, lines and
-- earlier versions, the stay's value not yet invoiced, and each voucher's correction links
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
                 (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('invoiced_halalas', coalesce((
                      select sum((l->>'amount_halalas')::bigint) from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
                       where i.reservation_id = r.id and i.status = 'issued' and (l->>'charge_id')::uuid = c.id), 0)) order by c.created_at), '[]'::jsonb)
                    from reservation_charges c where c.reservation_id = r.id) end,
    'vouchers', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg((to_jsonb(v) - 'content_hash') || jsonb_build_object(
                      'created_by_name', (select full_name from staff_profiles where id = v.created_by),
                      'original_number', (select number from financial_vouchers o where o.id = v.original_voucher_id),
                      'replaced_by_number', (select x.number from financial_vouchers x where x.original_voucher_id = v.id order by x.created_at desc limit 1))
                    order by v.occurred_at), '[]'::jsonb) from financial_vouchers v where v.reservation_id = r.id) end,
    'invoices', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number, 'status', i.status, 'scope', i.scope, 'origin', i.origin, 'version', i.version,
                      'subtotal_halalas', i.subtotal_halalas, 'tax_halalas', i.tax_halalas, 'total_halalas', i.total_halalas,
                      'issued_at', i.issued_at, 'issued_by', (select full_name from staff_profiles where id = i.issued_by),
                      'updated_at', i.updated_at, 'updated_by', (select full_name from staff_profiles where id = i.updated_by),
                      'cancelled_at', i.cancelled_at, 'cancel_reason', i.cancel_reason,
                      'period_from', i.period_from, 'period_to', i.period_to, 'bill_to', i.bill_to, 'lines', i.snapshot->'lines', 'versions', i.versions)
                    order by i.issued_at), '[]'::jsonb) from invoices i where i.reservation_id = r.id) end,
    'invoicing', case when fn_has_role('owner','manager','supervisor','finance') then jsonb_build_object('uninvoiced_halalas', fn_uninvoiced_value(r.id)) end,
    'finance', case when fn_has_role('owner','manager','supervisor','finance') then fn_reservation_finance_internal(r.id) end,
    'history', case when fn_has_role('owner','manager','supervisor') then (select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'at', e.created_at, 'actor', (select full_name from staff_profiles where id = e.actor_id), 'details', e.details) order by e.created_at desc), '[]'::jsonb)
                from (select * from audit_events where entity_id = r.id order by created_at desc limit 50) e) end
  ) end
  from reservations r where r.id = p_reservation;
$$;
grant execute on function fn_reservation_detail(uuid) to authenticated;

-- ---------------------------------------------------------------- 10. the data as it stands
-- the markers follow the shares (identical for the invoices issued so far, which carried whole lines)
do $$ declare x record; begin
  for x in select distinct reservation_id from invoices loop perform fn_sync_invoice_markers(x.reservation_id); end loop;
end $$;
