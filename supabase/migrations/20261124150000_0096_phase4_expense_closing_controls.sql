-- 0085 — Phase 4 money controls: the expense (4.3) and the blind day count (4.4). Proposed file; the integrator renumbers.
--
-- 4.3 (M3 المصروف):
--   * a limit per role; above it the expense is created «بانتظار اعتماد» (status 'pending'): it does not move the box
--     and does not enter the day closing or the ledger (both count status = 'approved' only), and a review item names it.
--     Default limits until the per-hotel control settings of plan 4.12 land (another worker): supervisor 5,000 SAR,
--     finance 20,000 SAR, any other role the matrix lets create expenses 1,000 SAR; owner and manager have no limit.
--   * fn_expense_approve: the management (expense.cancel, owner/manager by default) approves a pending expense; the
--     cash-box floor is re-checked at approval time.
--   * the cash box never goes below zero: a cash expense larger than the box's balance (opening + movements to now)
--     is refused with CASH_BOX_NEGATIVE.
--   * the receipt file: image or PDF up to 10 MB (was 2 MB; the plan allows up to 10 ميجابايت).
--
-- 4.4 (M4 العدّ الأعمى): fn_day_closing_get no longer returns the system figure before the closing is sent — while
--   the day is uncounted or a draft, the boxes carry no system_halalas, the matrix is empty, and the stored lines
--   carry neither system_halalas nor difference_halalas (the entered counts and their reasons stay). After sending,
--   everything is returned as before. fn_day_closing_review still reveals the figures at the mandatory review, which
--   is the intended reveal point (the counts are already written).

-- --------------------------------------------------------------------------- 4.3 shapes
alter table expense_vouchers drop constraint if exists expense_status_valid;
alter table expense_vouchers add constraint expense_status_valid check (status in ('approved', 'pending', 'cancelled'));
alter table expense_vouchers drop constraint if exists expense_cancel_shape;
alter table expense_vouchers add constraint expense_cancel_shape check (status <> 'cancelled' or (cancel_reason is not null and cancelled_at is not null));
alter table expense_attachments drop constraint if exists expense_attachment_size_valid;
alter table expense_attachments add constraint expense_attachment_size_valid check (size_bytes between 1 and 10485760);

-- the balance of a box or a bank account right now: its opening plus every movement to now (same source as the ledger)
create or replace function fn_cash_account_balance(p_account uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select a.opening_balance_halalas + coalesce(sum(m.in_halalas - m.out_halalas), 0)
  from cash_accounts a left join fn_account_movements(a.id) m
    on m.at >= coalesce(a.opening_on::timestamp at time zone coalesce((select timezone from branches where id = a.branch_id), 'Asia/Riyadh'), '-infinity'::timestamptz)
   and m.at <= now()
  where a.id = p_account
  group by a.opening_balance_halalas
$$;
revoke all on function fn_cash_account_balance(uuid) from public, anon, authenticated;

-- the expense voucher: re-created from 0064 with the role limit («بانتظار اعتماد»), the cash floor and the 10 MB receipt
create or replace function fn_expense_create(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_branch uuid := (p->>'branch_id')::uuid; a cash_accounts%rowtype; cat expense_categories%rowtype; e expense_vouchers%rowtype;
        v_amount bigint; v_day date; v_today date; v_desc text := trim(coalesce(p->>'description', ''));
        v_payee text := nullif(trim(coalesce(p->>'payee', '')), ''); v_ref text := nullif(upper(trim(coalesce(p->>'reference', ''))), '');
        v_key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); f jsonb; raw text; bin bytea; v_mime text; n int := 0;
        v_name text; tz text;
        v_pending boolean := false; v_limit bigint; v_balance bigint;
begin
  perform fn_require_cap('expense.create');
  perform fn_require_branch(v_branch);
  -- one write per key: the lock comes before the lookup, so a double click replays instead of failing; a key is the
  -- branch's own (another branch's voucher is never returned)
  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext('expense:' || fn_user_org_id()::text || ':' || v_key));
    select * into e from expense_vouchers where organization_id = fn_user_org_id() and idempotency_key = v_key;
    if found then
      if e.branch_id <> v_branch then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return jsonb_build_object('ok', true, 'id', e.id, 'number', e.number, 'replayed', true, 'status', e.status);
    end if;
  end if;
  select * into a from cash_accounts where id = (p->>'account_id')::uuid;
  if not found then raise exception 'VALIDATION: account_required'; end if;
  if a.branch_id <> v_branch then raise exception 'BRANCH_MISMATCH: account'; end if;
  if a.archived_at is not null or not a.is_active then raise exception 'VALIDATION: account_archived'; end if;
  select * into cat from expense_categories where id = (p->>'category_id')::uuid and organization_id = fn_user_org_id();
  if not found or not cat.is_active then raise exception 'VALIDATION: category'; end if;
  if coalesce(p->>'amount_halalas', '') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: amount'; end if;
  v_amount := (p->>'amount_halalas')::bigint;
  if v_amount <= 0 or v_amount > 100000000000 then raise exception 'VALIDATION: amount'; end if;
  if v_desc = '' or char_length(v_desc) > 500 then raise exception 'VALIDATION: description'; end if;
  if v_payee is not null and char_length(v_payee) > 120 then raise exception 'VALIDATION: payee'; end if;
  if v_ref is not null and (char_length(v_ref) > 60 or v_ref !~ '^[A-Z0-9/_.-]+$') then raise exception 'VALIDATION: reference'; end if;
  -- the day of the expense: today, or one of the last 31 days of the branch
  v_today := fn_branch_today(v_branch);
  if coalesce(p->>'occurred_on', '') <> '' and (p->>'occurred_on') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'VALIDATION: occurred_on'; end if;
  v_day := coalesce(nullif(p->>'occurred_on', '')::date, v_today);
  if v_day > v_today or v_day < v_today - 31 then raise exception 'VALIDATION: occurred_on'; end if;
  -- a cash expense dated on a day whose closing was sent would change a settled count: only the management may, and it
  -- is sent for review
  if a.kind = 'cash_box' and exists (select 1 from day_closings where branch_id = v_branch and business_date = v_day and status = 'submitted')
     and not fn_can('day.close.approve') then
    raise exception 'CLOSING_SENT_DAY';
  end if;
  -- 4.3: a limit per role; above it the expense waits «بانتظار اعتماد» and does not spend yet
  if fn_current_role() not in ('owner', 'manager') then
    v_limit := case fn_current_role()::text when 'supervisor' then 500000 when 'finance' then 2000000 else 100000 end;
    if v_amount > v_limit then v_pending := true; end if;
  end if;
  -- 4.3: the cash box never goes below zero (a pending expense spends only when approved; the floor is re-checked then)
  if a.kind = 'cash_box' and not v_pending then
    v_balance := fn_cash_account_balance(a.id);
    if v_amount > v_balance then raise exception 'CASH_BOX_NEGATIVE: balance % halalas', v_balance; end if;
  end if;
  -- the receipt is required: 1 to 5 files, images or PDF, 10 MB each
  if coalesce(jsonb_typeof(p->'attachments'), '') <> 'array' or jsonb_array_length(p->'attachments') = 0 then raise exception 'VALIDATION: attachment_required'; end if;
  if jsonb_array_length(p->'attachments') > 5 then raise exception 'VALIDATION: attachments_count'; end if;
  tz := coalesce((select timezone from branches where id = v_branch), 'Asia/Riyadh');
  insert into expense_vouchers(organization_id, branch_id, number, account_id, category_id, amount_halalas, occurred_at, payee, description, reference, idempotency_key, created_by, status)
  values (a.organization_id, v_branch, fn_next_document_number(a.organization_id, 'expense', 'EXP'), a.id, cat.id, v_amount,
          case when v_day = v_today then now() else (v_day::timestamp + interval '12 hours') at time zone tz end,
          v_payee, v_desc, v_ref, v_key, fn_staff_id(), case when v_pending then 'pending' else 'approved' end)
  returning * into e;
  for f in select * from jsonb_array_elements(p->'attachments') loop
    raw := regexp_replace(coalesce(f->>'data_base64', ''), '^data:[^,]*,', '');
    begin bin := decode(regexp_replace(raw, '\s', '', 'g'), 'base64'); exception when others then raise exception 'VALIDATION: attachment'; end;
    if bin is null or length(bin) = 0 then raise exception 'VALIDATION: attachment'; end if;
    if length(bin) > 10485760 then raise exception 'VALIDATION: attachment_too_large'; end if;
    v_mime := case when substring(bin from 1 for 8) = '\x89504e470d0a1a0a'::bytea then 'image/png'
                   when substring(bin from 1 for 3) = '\xffd8ff'::bytea then 'image/jpeg'
                   when substring(bin from 1 for 4) = '\x52494646'::bytea and substring(bin from 9 for 4) = '\x57454250'::bytea then 'image/webp'
                   when substring(bin from 1 for 4) = '\x25504446'::bytea then 'application/pdf' end;
    if v_mime is null then raise exception 'VALIDATION: attachment_type'; end if;
    v_name := nullif(left(trim(coalesce(f->>'file_name', '')), 120), '');
    insert into expense_attachments(expense_id, branch_id, mime, bytes, size_bytes, sha256, file_name, created_by)
    values (e.id, v_branch, v_mime, bin, length(bin), encode(digest(bin, 'sha256'), 'hex'), v_name, fn_staff_id());
    n := n + 1;
  end loop;
  perform fn_audit_change(v_branch, 'expense.created', 'expense_voucher', e.id, null,
    jsonb_build_object('number', e.number, 'amount_halalas', e.amount_halalas, 'account_id', e.account_id, 'category', cat.name,
                       'occurred_at', e.occurred_at, 'attachments', n, 'status', e.status, 'role_limit_halalas', v_limit));
  if a.kind = 'cash_box' and exists (select 1 from day_closings where branch_id = v_branch and business_date = v_day and status = 'submitted') then
    perform fn_add_review_item(v_branch, 'expense_after_closing', 'expense_voucher', e.id, null,
                               'سند صرف ' || e.number || ' على يوم أُرسل إقفاله', v_desc, jsonb_build_object('business_date', v_day, 'amount_halalas', v_amount));
  end if;
  if v_pending then
    perform fn_add_review_item(v_branch, 'expense_pending_approval', 'expense_voucher', e.id, null,
                               'سند صرف ' || e.number || ' بمبلغ ' || fn_sar_text(v_amount) || ' فوق حد الدور — بانتظار اعتماد', v_desc,
                               jsonb_build_object('number', e.number, 'amount_halalas', v_amount, 'role', fn_current_role()::text, 'role_limit_halalas', v_limit));
  end if;
  return jsonb_build_object('ok', true, 'id', e.id, 'number', e.number, 'status', e.status, 'pending_approval', v_pending);
end $$;
revoke all on function fn_expense_create(jsonb) from public, anon;
grant execute on function fn_expense_create(jsonb) to authenticated;

-- the management approves a pending expense; the cash floor is re-checked now
create or replace function fn_expense_approve(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e expense_vouchers%rowtype; a cash_accounts%rowtype; v_balance bigint;
begin
  perform fn_require_cap('expense.cancel');   -- the management (owner, manager by default)
  select * into e from expense_vouchers where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(e.branch_id);
  if e.status = 'approved' then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  if e.status <> 'pending' then raise exception 'EXPENSE_NOT_PENDING'; end if;
  select * into a from cash_accounts where id = e.account_id;
  if a.kind = 'cash_box' then
    v_balance := fn_cash_account_balance(a.id);
    if e.amount_halalas > v_balance then raise exception 'CASH_BOX_NEGATIVE: balance % halalas', v_balance; end if;
  end if;
  update expense_vouchers set status = 'approved' where id = e.id;
  perform fn_audit_change(e.branch_id, 'expense.approved', 'expense_voucher', e.id, jsonb_build_object('status', 'pending'),
                          jsonb_build_object('status', 'approved', 'number', e.number, 'amount_halalas', e.amount_halalas));
  return jsonb_build_object('ok', true, 'id', e.id, 'number', e.number, 'status', 'approved');
end $$;
revoke all on function fn_expense_approve(uuid) from public, anon;
grant execute on function fn_expense_approve(uuid) to authenticated;

-- --------------------------------------------------------------------------- 4.4 the blind count
-- the closing of a day as a person sees it: re-created from 0063 so the system figure is not returned before sending
create or replace function fn_day_closing_get(p_branch uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c day_closings%rowtype; live jsonb; v_state text; v_blind boolean;
begin
  if not (fn_can('day.close') or fn_can('day.close.approve')) then raise exception 'FORBIDDEN: day.close' using errcode = '42501'; end if;
  perform fn_require_branch(p_branch);
  if p_date is null or p_date > fn_branch_today(p_branch) then raise exception 'VALIDATION: business_date'; end if;
  live := fn_day_closing_compute(p_branch, p_date);
  select * into c from day_closings where branch_id = p_branch and business_date = p_date;
  -- 4.4: before the closing is sent the count is blind — no system figure, no source matrix, no difference
  v_blind := c.id is null or c.status <> 'submitted';
  if v_blind then
    live := jsonb_build_object('business_date', live->'business_date', 'rooms', live->'rooms', 'matrix', '[]'::jsonb,
              'boxes', coalesce((select jsonb_agg(b - 'system_halalas' order by b->>'sort', b->>'label') from jsonb_array_elements(live->'boxes') b), '[]'::jsonb),
              'expenses', live->'expenses');
  end if;
  if c.id is null then
    return jsonb_build_object('closing', null, 'state', 'none', 'live', live, 'lines', '[]'::jsonb, 'requests', '[]'::jsonb,
                              'edit_minutes', (select day_close_edit_minutes from branches where id = p_branch), 'changed_since_sent', false);
  end if;
  v_state := fn_day_closing_state(c.status, c.edit_until);
  return jsonb_build_object(
    'closing', jsonb_build_object('id', c.id, 'status', c.status, 'version', c.version, 'note', c.note, 'submitted_at', c.submitted_at,
                                  'submitted_by', (select full_name from staff_profiles where id = c.submitted_by), 'edit_until', c.edit_until,
                                  'figures', c.figures),
    'state', v_state, 'live', live,
    'lines', case when v_blind then coalesce((select jsonb_agg(l - 'system_halalas' - 'difference_halalas' order by l->>'key')
                                              from jsonb_array_elements(fn_day_closing_lines_json(c.id)) l), '[]'::jsonb)
                  else fn_day_closing_lines_json(c.id) end,
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'reason', r.reason, 'requested_at', r.requested_at,
                                                              'requested_by', (select full_name from staff_profiles where id = r.requested_by),
                                                              'decided_at', r.decided_at, 'decision_note', r.decision_note,
                                                              'decided_by', (select full_name from staff_profiles where id = r.decided_by)) order by r.requested_at desc)
                          from day_closing_requests r where r.closing_id = c.id), '[]'::jsonb),
    'edit_minutes', (select day_close_edit_minutes from branches where id = p_branch),
    -- a voucher of that day changed after sending: the frozen figures and today's differ (the owner sees it)
    'changed_since_sent', c.status = 'submitted'
      and (select coalesce(jsonb_agg(jsonb_build_array(b->>'key', b->'system_halalas') order by b->>'key'), '[]'::jsonb) from jsonb_array_elements(c.figures->'boxes') b)
          is distinct from (select coalesce(jsonb_agg(jsonb_build_array(b->>'key', b->'system_halalas') order by b->>'key'), '[]'::jsonb) from jsonb_array_elements(live->'boxes') b));
end $$;
revoke all on function fn_day_closing_get(uuid, date) from public, anon;
grant execute on function fn_day_closing_get(uuid, date) to authenticated;
