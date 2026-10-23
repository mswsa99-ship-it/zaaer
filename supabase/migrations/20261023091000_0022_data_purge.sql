-- =====================================================================
-- 0022 — Data purge by period (owner only), from /admin/data-purge.
--
-- The owner picks a branch (or all), a period [from, to] and any of seven kinds of data:
--   conversations  guest chats (web + WhatsApp), handoff tickets, staff-assistant chats, unanswered questions, AI logs
--   reservations   finished stays whose arrival date is in the period (cancelled, no-show, checked out, closed,
--                  rejected, or past their departure without check-in). In-house and upcoming stays are never touched.
--   finance        invoices, vouchers and payments dated in the period (only of stays that are themselves finished)
--   guests         guest profiles no booking refers to any more
--   operations     housekeeping tasks, maintenance tickets, released public-availability slots
--   logs           notifications, integration events, lookup and phone-code attempts, handled WhatsApp message ids
--   audit          the audit log of the period
-- A stay that has money on it is deleted only when "finance" is chosen too (its money goes with it); otherwise it is
-- kept and counted as skipped. Definitions (units, categories, services, task types, prices, staff, settings) are
-- never purged: they are archived, not deleted.
--
-- Three confirmations, all enforced here, not only in the page:
--   1. fn_admin_purge_preview — the exact counts (a dry run of the real deletion, rolled back) and a one-time token
--   2. the typed phrase «احذف نهائيا»
--   3. a fresh sign-in: the session must be less than 10 minutes old (the page asks for the password again)
-- The purge itself is recorded in the audit log after the deletion (so an audit purge never erases its own record),
-- and every request stays in data_purge_requests.
-- =====================================================================

create table if not exists data_purge_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid references branches(id),
  date_from date not null,
  date_to date not null,
  categories text[] not null,
  token_hash text not null,
  requested_by uuid not null references staff_profiles(id),
  preview jsonb,
  result jsonb,
  status text not null default 'pending' check (status in ('pending', 'done')),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  executed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table data_purge_requests enable row level security;
revoke all on data_purge_requests from anon, authenticated;

create or replace function fn_purge_categories() returns text[]
language sql immutable set search_path = public, extensions as $$
  select array['conversations', 'reservations', 'finance', 'guests', 'operations', 'logs', 'audit']
$$;

-- The deletion itself. Called only by the two functions below (preview runs it inside a block that is rolled back).
create or replace function fn_purge_run(p_org uuid, p_branch uuid, p_from date, p_to date, p_cats text[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_branches uuid[];
  v_all boolean := p_branch is null;
  v_tz text;
  v_start timestamptz; v_end timestamptz;
  n bigint; v_changed boolean;
  c jsonb := '{}'::jsonb;
  has_conv boolean := 'conversations' = any(p_cats);
  has_res boolean := 'reservations' = any(p_cats);
  has_fin boolean := 'finance' = any(p_cats);
  has_guest boolean := 'guests' = any(p_cats);
  has_ops boolean := 'operations' = any(p_cats);
  has_logs boolean := 'logs' = any(p_cats);
  has_audit boolean := 'audit' = any(p_cats);
begin
  select array_agg(id) into v_branches from branches where organization_id = p_org and (v_all or id = p_branch);
  if v_branches is null then raise exception 'NOT_FOUND: branch'; end if;
  v_tz := coalesce((select timezone from branches where id = coalesce(p_branch, v_branches[1])), 'Asia/Riyadh');
  v_start := (p_from::timestamp) at time zone v_tz;
  v_end := ((p_to + 1)::timestamp) at time zone v_tz;

  create temp table if not exists _purge_res(id uuid primary key) on commit drop;
  create temp table if not exists _purge_vouchers(id uuid primary key) on commit drop;
  create temp table if not exists _purge_payments(id uuid primary key) on commit drop;
  create temp table if not exists _purge_invoices(id uuid primary key) on commit drop;
  create temp table if not exists _purge_profiles(id uuid primary key) on commit drop;
  truncate _purge_res, _purge_vouchers, _purge_payments, _purge_invoices, _purge_profiles;

  -- finished stays arriving in the period (never in-house, never upcoming)
  insert into _purge_res
  select r.id from reservations r
  where r.branch_id = any(v_branches) and r.check_in between p_from and p_to
    and (r.status in ('checked_out', 'closed', 'cancelled', 'rejected', 'no_show')
         or (r.status in ('draft', 'pending_verification', 'confirmed') and r.check_out < fn_branch_today(r.branch_id)));

  -- ---------------- finance ----------------
  if has_fin then
    insert into _purge_vouchers
    select v.id from financial_vouchers v
    where v.branch_id = any(v_branches)
      and ((v.occurred_at >= v_start and v.occurred_at < v_end) or (has_res and v.reservation_id in (select id from _purge_res)))
      and (v.reservation_id is null or v.reservation_id in (select id from _purge_res))
    on conflict do nothing;
    insert into _purge_invoices
    select i.id from invoices i
    where i.branch_id = any(v_branches)
      and ((i.issued_at >= v_start and i.issued_at < v_end) or (has_res and i.reservation_id in (select id from _purge_res)))
      and (i.reservation_id is null or i.reservation_id in (select id from _purge_res))
    on conflict do nothing;
    insert into _purge_payments
    select p.id from payment_transactions p join reservations r on r.id = p.reservation_id
    where r.branch_id = any(v_branches)
      and ((p.created_at >= v_start and p.created_at < v_end) or (has_res and p.reservation_id in (select id from _purge_res)))
      and p.reservation_id in (select id from _purge_res)
    on conflict do nothing;
    -- a voucher another kept voucher points to (a reversal of it) stays, and so does what it points to
    loop
      delete from _purge_vouchers pv where exists (select 1 from financial_vouchers x where x.original_voucher_id = pv.id and x.id not in (select id from _purge_vouchers));
      get diagnostics n = row_count; v_changed := n > 0;
      exit when not v_changed;
    end loop;
    delete from _purge_payments pp where exists (select 1 from financial_vouchers x where x.payment_transaction_id = pp.id and x.id not in (select id from _purge_vouchers));
  end if;

  -- a stay keeps its record while any of its money stays
  if has_res then
    select count(*) into n from _purge_res pr
    where exists (select 1 from financial_vouchers x where x.reservation_id = pr.id and x.id not in (select id from _purge_vouchers))
       or exists (select 1 from invoices x where x.reservation_id = pr.id and x.id not in (select id from _purge_invoices))
       or exists (select 1 from payment_transactions x where x.reservation_id = pr.id and x.id not in (select id from _purge_payments))
       or (not has_fin and exists (select 1 from reservation_charges x where x.reservation_id = pr.id));
    c := c || jsonb_build_object('reservations_skipped_with_money', n);
    delete from _purge_res pr
    where exists (select 1 from financial_vouchers x where x.reservation_id = pr.id and x.id not in (select id from _purge_vouchers))
       or exists (select 1 from invoices x where x.reservation_id = pr.id and x.id not in (select id from _purge_invoices))
       or exists (select 1 from payment_transactions x where x.reservation_id = pr.id and x.id not in (select id from _purge_payments))
       or (not has_fin and exists (select 1 from reservation_charges x where x.reservation_id = pr.id));
    select count(*) into n from reservations r
    where r.branch_id = any(v_branches) and r.check_in between p_from and p_to and r.id not in (select id from _purge_res);
    c := c || jsonb_build_object('reservations_kept_active_or_with_money', n);
  end if;

  -- ---------------- conversations & AI ----------------
  if has_conv then
    select count(*) into n from conversation_messages m join conversations cv on cv.id = m.conversation_id
    where (cv.branch_id = any(v_branches) or (v_all and cv.branch_id is null)) and cv.created_at >= v_start and cv.created_at < v_end;
    c := c || jsonb_build_object('conversation_messages', n);
    delete from human_handoff_tickets where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('handoff_tickets', n);
    delete from conversations where (branch_id = any(v_branches) or (v_all and branch_id is null)) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('conversations', n);
    delete from ai_action_proposals where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    delete from ai_ops_conversations where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('staff_assistant_chats', n);
    delete from unanswered_questions where branch_id = any(v_branches) and last_asked_at >= v_start and last_asked_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('unanswered_questions', n);
    if v_all then
      delete from ai_tool_executions where conversation_id is null and created_at >= v_start and created_at < v_end;
      delete from ai_guardrail_events where conversation_id is null and created_at >= v_start and created_at < v_end;
      delete from ai_usage_daily where organization_id = p_org and day between p_from and p_to;
    end if;
  end if;

  -- ---------------- operations ----------------
  if has_ops then
    delete from housekeeping_tasks where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end
      and status::text in ('completed', 'cancelled', 'verified', 'done', 'closed');
    get diagnostics n = row_count; c := c || jsonb_build_object('housekeeping_tasks', n);
    delete from maintenance_tickets where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end
      and status::text in ('resolved', 'closed', 'cancelled', 'done', 'completed');
    get diagnostics n = row_count; c := c || jsonb_build_object('maintenance_tickets', n);
    delete from released_slots where branch_id = any(v_branches) and date between p_from and p_to and date < fn_branch_today(branch_id);
    get diagnostics n = row_count; c := c || jsonb_build_object('released_slots', n);
  end if;

  -- ---------------- finance (delete) ----------------
  if has_fin then
    delete from financial_vouchers where id in (select id from _purge_vouchers);
    get diagnostics n = row_count; c := c || jsonb_build_object('vouchers', n);
    delete from payment_transactions where id in (select id from _purge_payments);
    get diagnostics n = row_count; c := c || jsonb_build_object('payments', n);
    delete from invoices where id in (select id from _purge_invoices);
    get diagnostics n = row_count; c := c || jsonb_build_object('invoices', n);
  end if;

  -- ---------------- reservations ----------------
  if has_res then
    insert into _purge_profiles select distinct g.guest_profile_id from reservation_guests g
      where g.reservation_id in (select id from _purge_res) and g.guest_profile_id is not null on conflict do nothing;
    delete from reservations where id in (select id from _purge_res);
    get diagnostics n = row_count; c := c || jsonb_build_object('reservations', n);
  end if;

  -- ---------------- guests ----------------
  if has_guest then
    delete from guest_profiles gp
    where gp.organization_id = p_org
      and not exists (select 1 from reservation_guests g where g.guest_profile_id = gp.id)
      and ((v_all and gp.created_at >= v_start and gp.created_at < v_end) or gp.id in (select id from _purge_profiles));
    get diagnostics n = row_count; c := c || jsonb_build_object('guest_profiles', n);
  end if;

  -- ---------------- logs ----------------
  if has_logs then
    delete from notifications where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('notifications', n);
    delete from whatsapp_inbound_messages where (branch_id = any(v_branches) or (v_all and branch_id is null)) and received_at >= v_start and received_at < v_end;
    if v_all then
      delete from integration_events where organization_id = p_org and created_at >= v_start and created_at < v_end;
      get diagnostics n = row_count; c := c || jsonb_build_object('integration_events', n);
      delete from guest_lookup_attempts where created_at >= v_start and created_at < v_end;
      delete from guest_phone_challenges where created_at >= v_start and created_at < v_end;
      delete from guest_phone_sessions where created_at >= v_start and created_at < v_end;
    end if;
  end if;

  -- ---------------- audit ----------------
  if has_audit then
    delete from audit_events where organization_id = p_org and (v_all or branch_id = p_branch) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('audit_events', n);
  end if;

  return c;
end $$;
revoke all on function fn_purge_run(uuid, uuid, date, date, text[]) from public, anon, authenticated;

create or replace function fn_purge_validate(p_branch uuid, p_from date, p_to date, p_cats text[]) returns text[]
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_cats text[];
begin
  perform fn_require_role('owner');
  if p_from is null or p_to is null or p_from > p_to then raise exception 'VALIDATION: period'; end if;
  if p_to > fn_branch_today(coalesce(p_branch, (select id from branches where organization_id = fn_user_org_id() order by created_at limit 1))) then
    raise exception 'VALIDATION: period_after_today';
  end if;
  if p_branch is not null and not exists (select 1 from branches where id = p_branch and organization_id = fn_user_org_id()) then
    raise exception 'NOT_FOUND: branch';
  end if;
  select array_agg(distinct x order by x) into v_cats from unnest(p_cats) x;
  if v_cats is null or cardinality(v_cats) = 0 then raise exception 'VALIDATION: choose_category'; end if;
  if not v_cats <@ fn_purge_categories() then raise exception 'VALIDATION: unknown_category'; end if;
  return v_cats;
end $$;
revoke all on function fn_purge_validate(uuid, date, date, text[]) from public, anon, authenticated;

-- 1st confirmation: exact counts (the real deletion, rolled back) + a one-time token
create or replace function fn_admin_purge_preview(p_branch uuid, p_from date, p_to date, p_categories text[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_cats text[] := fn_purge_validate(p_branch, p_from, p_to, p_categories); v_counts jsonb; v_token text; v_id uuid;
begin
  begin
    v_counts := fn_purge_run(fn_user_org_id(), p_branch, p_from, p_to, v_cats);
    raise exception 'PURGE_DRY_RUN' using errcode = 'P0D01';
  exception when sqlstate 'P0D01' then null;   -- everything deleted inside the block is rolled back; the counts stay
  end;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into data_purge_requests(organization_id, branch_id, date_from, date_to, categories, token_hash, requested_by, preview)
  values (fn_user_org_id(), p_branch, p_from, p_to, v_cats, encode(digest(v_token, 'sha256'), 'hex'), fn_staff_id(), v_counts)
  returning id into v_id;
  return jsonb_build_object('request_id', v_id, 'token', v_token, 'counts', v_counts, 'categories', to_jsonb(v_cats),
                            'phrase', 'احذف نهائيا', 'expires_in_minutes', 15);
end $$;
grant execute on function fn_admin_purge_preview(uuid, date, date, text[]) to authenticated;

-- 2nd and 3rd confirmations: the typed phrase and a fresh sign-in; then the deletion and its audit record
create or replace function fn_admin_purge_execute(p_token text, p_phrase text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare q data_purge_requests%rowtype; v_counts jsonb; v_iat bigint;
begin
  perform fn_require_role('owner');
  select * into q from data_purge_requests
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and organization_id = fn_user_org_id()
   for update;
  if not found or q.status <> 'pending' or q.expires_at < now() then raise exception 'VALIDATION: preview_expired'; end if;
  if q.requested_by <> fn_staff_id() then raise exception 'FORBIDDEN: only the owner who previewed can confirm' using errcode = '42501'; end if;
  if regexp_replace(btrim(coalesce(p_phrase, '')), '[ًٌٍَُِّْ]', '', 'g') <> 'احذف نهائيا' then
    raise exception 'VALIDATION: confirmation_phrase';
  end if;
  v_iat := nullif(auth.jwt()->>'iat', '')::bigint;
  if v_iat is null or v_iat < extract(epoch from now())::bigint - 600 then
    raise exception 'REAUTH_REQUIRED: sign in again to confirm' using errcode = '42501';
  end if;
  v_counts := fn_purge_run(q.organization_id, q.branch_id, q.date_from, q.date_to, q.categories);
  update data_purge_requests set status = 'done', result = v_counts, executed_at = now() where id = q.id;
  perform fn_audit(q.organization_id, q.branch_id, fn_staff_id(), 'data_purge_executed', 'organization', q.organization_id,
    jsonb_build_object('branch_id', q.branch_id, 'from', q.date_from, 'to', q.date_to, 'categories', to_jsonb(q.categories),
                       'counts', v_counts, 'request_id', q.id));
  return jsonb_build_object('ok', true, 'counts', v_counts);
end $$;
grant execute on function fn_admin_purge_execute(text, text) to authenticated;

create or replace function fn_admin_purge_history() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform fn_require_role('owner');
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'branch_name', b.name_ar, 'from', q.date_from, 'to', q.date_to,
      'categories', to_jsonb(q.categories), 'counts', q.result, 'executed_at', q.executed_at, 'by', s.full_name) order by q.executed_at desc)
    from data_purge_requests q left join branches b on b.id = q.branch_id left join staff_profiles s on s.id = q.requested_by
    where q.organization_id = fn_user_org_id() and q.status = 'done'), '[]'::jsonb);
end $$;
grant execute on function fn_admin_purge_history() to authenticated;
