-- 0099: explicit settings overrides. No implicit adoption of proposed expense caps.
-- Existing execution fallback remains 5000/20000/1000 SAR pending owner policy decision.
-- Legacy 0092 values are retained for compatibility but are NOT effective expense caps.
alter table finance_control_settings add column operational_refund_threshold_halalas bigint check(operational_refund_threshold_halalas>0);
alter table finance_control_settings add column operational_closing_diff_alert_halalas bigint check(operational_closing_diff_alert_halalas>0);
alter table finance_control_settings add column expense_role_limits jsonb not null default '{}'::jsonb;
alter table finance_control_settings add constraint finance_role_limits_object check(jsonb_typeof(expense_role_limits) = 'object');

create or replace function fn_finance_expense_limit(p_org uuid, p_role text) returns bigint
language sql stable security definer set search_path = public as $$
 select coalesce((select (expense_role_limits->>p_role)::bigint from finance_control_settings where organization_id=p_org),
 case p_role when 'owner' then null when 'manager' then null when 'supervisor' then 500000 when 'finance' then 2000000 else 100000 end)
$$;
revoke all on function fn_finance_expense_limit(uuid,text) from public,anon,authenticated;

create or replace function fn_finance_controls_legacy_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s finance_control_settings%rowtype; before_row finance_control_settings%rowtype; k text; v bigint;
        keys text[] := array['expense_limit_supervisor_halalas', 'expense_limit_finance_halalas', 'discount_threshold_halalas',
                             'refund_threshold_halalas', 'closing_diff_alert_halalas'];
begin
  perform fn_require_role('owner');
  perform fn_user_org_id();
  insert into finance_control_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  select * into before_row from finance_control_settings where organization_id = fn_user_org_id() for update;
  s := before_row;
  for k in select e.key from jsonb_each(p) e loop
    if not (k = any(keys)) then raise exception 'VALIDATION: unknown_key'; end if;
    if coalesce(p->>k, '') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: %', k; end if;
    v := (p->>k)::bigint;
    if v <= 0 then raise exception 'VALIDATION: %', k; end if;
    if k = 'expense_limit_supervisor_halalas' then s.expense_limit_supervisor_halalas := v;
    elsif k = 'expense_limit_finance_halalas' then s.expense_limit_finance_halalas := v;
    elsif k = 'discount_threshold_halalas' then s.discount_threshold_halalas := v;
    elsif k = 'refund_threshold_halalas' then s.refund_threshold_halalas := v;
    else s.closing_diff_alert_halalas := v; end if;
  end loop;
  update finance_control_settings set
    expense_limit_supervisor_halalas = s.expense_limit_supervisor_halalas,
    expense_limit_finance_halalas = s.expense_limit_finance_halalas,
    discount_threshold_halalas = s.discount_threshold_halalas,
    refund_threshold_halalas = s.refund_threshold_halalas,
    closing_diff_alert_halalas = s.closing_diff_alert_halalas,
    updated_at = now(), updated_by = fn_staff_id()
  where organization_id = fn_user_org_id();
  perform fn_audit_change(null, 'security.control_thresholds_updated', 'finance_control_settings', fn_user_org_id(),
    jsonb_build_object('expense_limit_supervisor_halalas', before_row.expense_limit_supervisor_halalas,
                       'expense_limit_finance_halalas', before_row.expense_limit_finance_halalas,
                       'discount_threshold_halalas', before_row.discount_threshold_halalas,
                       'refund_threshold_halalas', before_row.refund_threshold_halalas,
                       'closing_diff_alert_halalas', before_row.closing_diff_alert_halalas),
    jsonb_build_object('expense_limit_supervisor_halalas', s.expense_limit_supervisor_halalas,
                       'expense_limit_finance_halalas', s.expense_limit_finance_halalas,
                       'discount_threshold_halalas', s.discount_threshold_halalas,
                       'refund_threshold_halalas', s.refund_threshold_halalas,
                       'closing_diff_alert_halalas', s.closing_diff_alert_halalas));
  return fn_finance_controls_get();
end $$;
revoke all on function fn_finance_controls_legacy_set(jsonb) from public, anon;
revoke all on function fn_finance_controls_legacy_set(jsonb) from authenticated;

create or replace function fn_finance_controls_get() returns jsonb
language plpgsql security definer set search_path=public as $$
declare f finance_control_settings%rowtype; s system_settings%rowtype; effective jsonb;
begin
 if fn_user_org_id() is null then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 insert into finance_control_settings(organization_id) values(fn_user_org_id()) on conflict do nothing;
 select * into f from finance_control_settings where organization_id=fn_user_org_id();
 select * into s from system_settings where organization_id=fn_user_org_id();
 select jsonb_object_agg(r,fn_finance_expense_limit(fn_user_org_id(),r)) into effective
 from unnest(array['owner','manager','supervisor','finance','housekeeping']) r;
 return to_jsonb(f) || jsonb_build_object('effective_expense_limits',effective,
 'discount_review_threshold_bp',s.discount_review_threshold_bp,
 'anomaly_receipt_threshold_halalas',s.anomaly_receipt_threshold_halalas,
 'anomaly_expense_threshold_halalas',s.anomaly_expense_threshold_halalas,
 'policy_status','expense_defaults_undecided',
 'refund_enforcement','opt_in','closing_alert_enforcement','opt_in');
end $$;
revoke all on function fn_finance_controls_get() from public,anon;
grant execute on function fn_finance_controls_get() to authenticated;

create or replace function fn_finance_controls_set(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare before_row jsonb; after_row jsonb; k text; v jsonb; r text; limits jsonb; legacy jsonb := '{}'::jsonb;
begin
 perform fn_require_role('owner');
 if p is null or jsonb_typeof(p)<>'object' or p='{}'::jsonb then raise exception 'VALIDATION: object_required'; end if;
 perform pg_advisory_xact_lock(hashtext('finance_settings:'||fn_user_org_id()::text));
 before_row:=fn_finance_controls_get();
 for k,v in select * from jsonb_each(p) loop
  if k='expense_role_limits' then
   if jsonb_typeof(v)<>'object' then raise exception 'VALIDATION: expense_role_limits'; end if;
   for r in select jsonb_object_keys(v) loop
    if r not in ('supervisor','finance','housekeeping') then raise exception 'VALIDATION: expense_role'; end if;
    if v->r <> 'null'::jsonb and (coalesce(v->>r,'') !~ '^[0-9]{1,12}$' or (v->>r)::bigint<=0) then raise exception 'VALIDATION: expense_limit'; end if;
   end loop;
   select expense_role_limits into limits from finance_control_settings where organization_id=fn_user_org_id();
   limits:=limits||v;
   select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) into limits from jsonb_each(limits) where value<>'null'::jsonb;
   update finance_control_settings set expense_role_limits=limits where organization_id=fn_user_org_id();
  elsif k in ('operational_refund_threshold_halalas','operational_closing_diff_alert_halalas') then
   if v<>'null'::jsonb and (coalesce(p->>k,'') !~ '^[0-9]{1,12}$' or (p->>k)::bigint<=0) then raise exception 'VALIDATION: threshold'; end if;
   if k='operational_refund_threshold_halalas' then
    update finance_control_settings set operational_refund_threshold_halalas=(p->>k)::bigint where organization_id=fn_user_org_id();
   else
    update finance_control_settings set operational_closing_diff_alert_halalas=(p->>k)::bigint where organization_id=fn_user_org_id();
   end if;
  elsif k in ('discount_review_threshold_bp','anomaly_receipt_threshold_halalas','anomaly_expense_threshold_halalas') then
   if v <> 'null'::jsonb and (coalesce(p->>k,'') !~ '^[0-9]{1,12}$') then raise exception 'VALIDATION: threshold'; end if;
   if k='discount_review_threshold_bp' then
    if v <> 'null'::jsonb and (p->>k)::bigint>10000 then raise exception 'VALIDATION: discount_basis_points'; end if;
    update system_settings set discount_review_threshold_bp=(p->>k)::int where organization_id=fn_user_org_id();
   else
    if v='null'::jsonb or (p->>k)::bigint<=0 then raise exception 'VALIDATION: anomaly_threshold'; end if;
    if k='anomaly_receipt_threshold_halalas' then
     update system_settings set anomaly_receipt_threshold_halalas=(p->>k)::bigint where organization_id=fn_user_org_id();
    else
     update system_settings set anomaly_expense_threshold_halalas=(p->>k)::bigint where organization_id=fn_user_org_id();
    end if;
   end if;
  elsif k in ('expense_limit_supervisor_halalas','expense_limit_finance_halalas','discount_threshold_halalas','refund_threshold_halalas','closing_diff_alert_halalas') then
   -- Compatibility only: deprecated fields remain stored, never silently become operational policy.
   legacy:=legacy||jsonb_build_object(k,v);
  else raise exception 'VALIDATION: unknown_key'; end if;
 end loop;
 if legacy<>'{}'::jsonb then perform fn_finance_controls_legacy_set(legacy); end if;
 update finance_control_settings set updated_at=now(),updated_by=fn_staff_id() where organization_id=fn_user_org_id();
 after_row:=fn_finance_controls_get();
 perform fn_audit_change(null,'security.finance_execution_thresholds_updated','finance_control_settings',fn_user_org_id(),before_row,after_row);
 return after_row;
end $$;
revoke all on function fn_finance_controls_set(jsonb) from public,anon;
grant execute on function fn_finance_controls_set(jsonb) to authenticated;

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
    v_limit := fn_finance_expense_limit(fn_user_org_id(), fn_current_role()::text);
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


-- Optional owner-approved refund amount gate. Existing receipt/deposit/method rules stay intact.
create table finance_refund_approvals(
 id uuid primary key default extensions.gen_random_uuid(),
 organization_id uuid not null references organizations(id),
 branch_id uuid not null references branches(id),
 reservation_id uuid not null references reservations(id) on delete cascade,
 amount_halalas bigint not null check(amount_halalas>0),
 reason text not null check(length(trim(reason)) between 1 and 500),
 approved_by uuid not null references staff_profiles(id),
 created_at timestamptz not null default now(), used_at timestamptz
);
create index finance_refund_approvals_unused on finance_refund_approvals(organization_id,reservation_id,amount_halalas,created_at,id) where used_at is null;
alter table finance_refund_approvals enable row level security;
revoke all on finance_refund_approvals from public,anon,authenticated;
grant select on finance_refund_approvals to authenticated;
create policy refund_approvals_owner_read on finance_refund_approvals for select to authenticated
 using(organization_id=(select fn_user_org_id()) and fn_has_role('owner'));
create trigger zz_hotel_pointers after insert or update on finance_refund_approvals for each row
 execute function fn_hotel_pointers('reservation_id','reservations','approved_by','staff_profiles','branch_id','branches');

create function fn_finance_approve_refund(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r reservations%rowtype; a uuid; n bigint; why text:=trim(coalesce(p->>'reason',''));
begin
 perform fn_require_role('owner');
 n:=fn_parse_halalas(p->>'amount_halalas');
 if n<=0 or length(why) not between 1 and 500 then raise exception 'VALIDATION: refund_approval'; end if;
 select * into r from reservations where id=(p->>'reservation_id')::uuid;
 if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
 perform fn_require_branch(r.branch_id);
 insert into finance_refund_approvals(organization_id,branch_id,reservation_id,amount_halalas,reason,approved_by)
 values(r.organization_id,r.branch_id,r.id,n,why,fn_staff_id()) returning id into a;
 perform fn_audit_change(r.branch_id,'refund.prior_approval','refund_approval',a,null,jsonb_build_object('reservation_id',r.id,'amount_halalas',n),why);
 return jsonb_build_object('ok',true,'approval_id',a);
end $$;
revoke all on function fn_finance_approve_refund(jsonb) from public,anon;
grant execute on function fn_finance_approve_refund(jsonb) to authenticated;

create function fn_trg_finance_refund_gate() returns trigger
language plpgsql security definer set search_path=public as $$
declare threshold bigint; approval uuid;
begin
 if new.kind<>'refund' or new.status<>'approved' then return new; end if;
 select operational_refund_threshold_halalas into threshold from finance_control_settings where organization_id=new.organization_id;
 if threshold is null or new.amount_halalas<=threshold then return new; end if;
 select id into approval from finance_refund_approvals where organization_id=new.organization_id
 and reservation_id=new.reservation_id and amount_halalas=new.amount_halalas and used_at is null order by created_at,id limit 1 for update;
 if approval is null then raise exception 'REFUND_APPROVAL_REQUIRED'; end if;
 update finance_refund_approvals set used_at=now() where id=approval;
 perform fn_phase4_flag(new.branch_id,'refund_over_threshold','voucher',new.id,new.reservation_id,
 'استرداد فوق عتبة الفندق باعتماد مسبق',new.reason,jsonb_build_object('amount_halalas',new.amount_halalas,'approval_id',approval,'threshold_halalas',threshold));
 return new;
end $$;
revoke all on function fn_trg_finance_refund_gate() from public,anon,authenticated;
create trigger trg_finance_refund_gate before insert on financial_vouchers for each row execute function fn_trg_finance_refund_gate();

create function fn_trg_finance_closing_alert() returns trigger
language plpgsql security definer set search_path=public as $$
declare threshold bigint; diff bigint;
begin
 if new.status<>'submitted' then return null; end if;
 select operational_closing_diff_alert_halalas into threshold from finance_control_settings where organization_id=new.organization_id;
 if threshold is null then return null; end if;
 select coalesce(max(abs((l->>'difference_halalas')::bigint)),0) into diff from jsonb_array_elements(fn_day_closing_lines_json(new.id)) l;
 if diff>threshold then
  perform fn_phase4_flag(new.branch_id,'closing_difference_over_threshold','day_closing',new.id,null,
   'فرق إقفال فوق عتبة الفندق',new.note,jsonb_build_object('difference_halalas',diff,'threshold_halalas',threshold));
 end if;
 return null;
end $$;
revoke all on function fn_trg_finance_closing_alert() from public,anon,authenticated;
create trigger trg_finance_closing_alert after update of status on day_closings for each row execute function fn_trg_finance_closing_alert();
