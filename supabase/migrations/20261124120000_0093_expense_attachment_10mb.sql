-- =====================================================================
-- 0086 (proposed number; the integrator renumbers) - plan 4.3 (M3) attachment limit fragment.
--
--  The plan allows an expense receipt image or PDF up to 10 MB; 0064 enforced 2 MB. This migration raises the
--  server limit to 10 MB: the table constraint and the fn_expense_create guard (the function is otherwise
--  identical to 0064). The role limit and the approval path of 4.3 belong to that item's worker and are not
--  here. The demo store mirrors the same 10 MB (src/demo/expenses.ts).
-- =====================================================================

alter table expense_attachments drop constraint if exists expense_attachment_size_valid;
alter table expense_attachments add constraint expense_attachment_size_valid check (size_bytes between 1 and 10485760);

-- fn_expense_create, identical to 0064 except the receipt limit: 10 MB each, images or PDF, 1 to 5 files
create or replace function fn_expense_create(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_branch uuid := (p->>'branch_id')::uuid; a cash_accounts%rowtype; cat expense_categories%rowtype; e expense_vouchers%rowtype;
        v_amount bigint; v_day date; v_today date; v_desc text := trim(coalesce(p->>'description', ''));
        v_payee text := nullif(trim(coalesce(p->>'payee', '')), ''); v_ref text := nullif(upper(trim(coalesce(p->>'reference', ''))), '');
        v_key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); f jsonb; raw text; bin bytea; v_mime text; n int := 0;
        v_name text; tz text;
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
      return jsonb_build_object('ok', true, 'id', e.id, 'number', e.number, 'replayed', true);
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
  -- the receipt is required: 1 to 5 files, images or PDF, 10 MB each
  if coalesce(jsonb_typeof(p->'attachments'), '') <> 'array' or jsonb_array_length(p->'attachments') = 0 then raise exception 'VALIDATION: attachment_required'; end if;
  if jsonb_array_length(p->'attachments') > 5 then raise exception 'VALIDATION: attachments_count'; end if;
  tz := coalesce((select timezone from branches where id = v_branch), 'Asia/Riyadh');
  insert into expense_vouchers(organization_id, branch_id, number, account_id, category_id, amount_halalas, occurred_at, payee, description, reference, idempotency_key, created_by)
  values (a.organization_id, v_branch, fn_next_document_number(a.organization_id, 'expense', 'EXP'), a.id, cat.id, v_amount,
          case when v_day = v_today then now() else (v_day::timestamp + interval '12 hours') at time zone tz end,
          v_payee, v_desc, v_ref, v_key, fn_staff_id())
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
                       'occurred_at', e.occurred_at, 'attachments', n));
  if a.kind = 'cash_box' and exists (select 1 from day_closings where branch_id = v_branch and business_date = v_day and status = 'submitted') then
    perform fn_add_review_item(v_branch, 'expense_after_closing', 'expense_voucher', e.id, null,
                               'سند صرف ' || e.number || ' على يوم أُرسل إقفاله', v_desc, jsonb_build_object('business_date', v_day, 'amount_halalas', v_amount));
  end if;
  return jsonb_build_object('ok', true, 'id', e.id, 'number', e.number);
end $$;
revoke all on function fn_expense_create(jsonb) from public, anon;
grant execute on function fn_expense_create(jsonb) to authenticated;
