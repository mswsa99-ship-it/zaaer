-- =====================================================================================================
-- للصق مرة واحدة في Supabase ← SQL Editor ← New query ← الصق هذا الملف كله ← Run
--
-- خمسة ترحيلات فيها أوامر حذف أو إسقاط أو كلمة الحذف نفسها، وأداة المساعد ممنوعة منها، فيشغّلها المالك بنفسه:
--   0022  صفحة «تفريغ البيانات» للمالك (حذف بثلاثة تأكيدات)
--   0031  التفريغ يشمل ليالي الحجز وتسويات الشبكة ومطابقات المنصات
--   0034  التفريغ يشمل فحوص المغادرة وأسباب الاستمرار وبنود المراجعة
--   0039  (المرحلة 5) إسقاط الفهرس القديم لرقم المنصة حتى تشترك وحدات المجموعة في رقم واحد (القرار 69)،
--         وربط إقرارات ملخص الإقامة وشعار الفرع بحجزها وفرعها عند التفريغ، وبقاء الحظر إن حُذف ملف صاحبه
--   0041  (المرحلة 6) إسقاط تواقيع التقارير القديمة بلا مرشحات (القرار 36)، وإكمال قاموس أسماء سجل الإجراءات
--         وقائمة القدرات بأكواد «حذف تعريف» التي لا يحملها 0040 (القراران 14 و55)
-- كل شيء في معاملة واحدة: إن فشل أي جزء لا يتغير شيء. لا يحذف هذا الملف أي بيانات عند تشغيله (0039 يحذف فقط
-- صفوفًا يتيمة إن وُجدت، ولا توجد)؛ حذف البيانات لا يقع إلا حين يستعمل المالك صفحة التفريغ نفسها لاحقًا ويؤكد ثلاث مرات.
-- يُشغَّل بعد تطبيق 0040 (الترحيلات العادية يطبقها المساعد). تشغيله مرة ثانية لا يغيّر شيئًا.
-- =====================================================================================================
begin;

-- ===================== 20261023091000_0022_data_purge =====================
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

insert into supabase_migrations.schema_migrations (version, name) values ('20261023091000', '0022_data_purge') on conflict (version) do nothing;

-- ===================== 20261025040000_0031_purge_cascades =====================
-- =====================================================================
-- 0031 — what a purge or a branch removal takes along with it, for the tables of 0028 and 0030.
-- This migration removes rows, so the owner pastes it in the Supabase SQL editor (as with 0022); it is never sent
-- through the assistant's database tool. Apply it together with 0022, after 0030.
--   1. A stay's nights go with the stay when a purge removes the stay (reservation_nights → reservations).
--   2. A branch removed while unused takes its automatic cash box and bank account with it (cash_accounts →
--      branches). A branch with any voucher, settlement or payout is never removable (fn_definition_dependencies).
--   3. Purging «المالية» also removes the period's card-terminal settlements, and the platform payouts left with no
--      payment; a payout that still has a payment stays.
-- =====================================================================
select set_config('app.source', 'migration', true);

delete from reservation_nights n where not exists (select 1 from reservations r where r.id = n.reservation_id);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservation_nights_reservation_fk') then
    alter table reservation_nights add constraint reservation_nights_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
end $$;

alter table cash_accounts drop constraint if exists cash_accounts_branch_id_fkey;
alter table cash_accounts add constraint cash_accounts_branch_id_fkey foreign key (branch_id) references branches(id) on delete cascade;

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
    -- the period's card-terminal settlements, and its platform payouts none of whose payments remain (0028)
    delete from pos_settlements where branch_id = any(v_branches) and business_date between p_from and p_to;
    get diagnostics n = row_count; c := c || jsonb_build_object('pos_settlements', n);
    delete from platform_payouts pp where pp.branch_id = any(v_branches) and pp.received_on between p_from and p_to
      and not exists (select 1 from financial_vouchers v where v.payout_id = pp.id);
    get diagnostics n = row_count; c := c || jsonb_build_object('platform_payouts', n);
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

insert into supabase_migrations.schema_migrations (version, name) values ('20261025040000', '0031_purge_cascades') on conflict (version) do nothing;

-- ===================== 20261025052000_0034_stay_cascades =====================
-- =====================================================================
-- 0034 — what a purge needs for the stay cycle's tables (Phase 3).
-- Pasted by the owner in the Supabase SQL editor, after 0033, together with 0022 and 0031 (STAGING.md §0-ب): the SQL
-- tools that apply the other migrations refuse any statement that removes rows, and this one has to.
--   * rows left without their stay by a purge run before this migration are removed;
--   * the inspections, the overdue reasons and the review items of a stay now go with it in a purge.
-- =====================================================================
delete from checkout_inspections i where not exists (select 1 from reservations r where r.id = i.reservation_id);
delete from stay_payment_exceptions e where not exists (select 1 from reservations r where r.id = e.reservation_id);
delete from review_items v where v.reservation_id is not null and not exists (select 1 from reservations r where r.id = v.reservation_id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'checkout_inspections_reservation_fk') then
    alter table checkout_inspections add constraint checkout_inspections_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stay_payment_exceptions_reservation_fk') then
    alter table stay_payment_exceptions add constraint stay_payment_exceptions_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'review_items_reservation_fk') then
    alter table review_items add constraint review_items_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
end $$;

insert into supabase_migrations.schema_migrations (version, name) values ('20261025052000', '0034_stay_cascades') on conflict (version) do nothing;

-- ===================== 20261027020000_0039_guest_cascades =====================
-- =====================================================================
-- 0039 — what phase 5 needs that the SQL tools refuse (they refuse any statement that removes rows or objects).
-- Pasted by the owner in the Supabase SQL editor, after 0038, together with 0022, 0031 and 0034 (STAGING.md §0-ب).
--   * decision 69: the older unique index on the platform number allowed it on one booking only, so a group whose
--     units share their platform number could not be created. 0038's constraint (one booking or one group per number)
--     replaces it.
--   * the stay summaries accepted by a guest go with their stay in a purge; a branch's logo and image go with an
--     unused branch that is removed; a ban stays when the profile it was made on is purged (its phones and documents
--     still match).
-- =====================================================================
drop index if exists uniq_reservation_source_ref;

delete from stay_acknowledgements a where not exists (select 1 from reservations r where r.id = a.reservation_id);
update stay_acknowledgements a set guest_id = null where guest_id is not null and not exists (select 1 from reservation_guests g where g.id = a.guest_id);
delete from branch_media m where not exists (select 1 from branches b where b.id = m.branch_id);
update guest_bans b set guest_profile_id = null where guest_profile_id is not null and not exists (select 1 from guest_profiles p where p.id = b.guest_profile_id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'stay_acknowledgements_reservation_fk') then
    alter table stay_acknowledgements add constraint stay_acknowledgements_reservation_fk
      foreign key (reservation_id) references reservations(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stay_acknowledgements_guest_fk') then
    alter table stay_acknowledgements add constraint stay_acknowledgements_guest_fk
      foreign key (guest_id) references reservation_guests(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'branch_media_branch_fk') then
    alter table branch_media add constraint branch_media_branch_fk
      foreign key (branch_id) references branches(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'guest_bans_profile_fk') then
    alter table guest_bans add constraint guest_bans_profile_fk
      foreign key (guest_profile_id) references guest_profiles(id) on delete set null;
  end if;
end $$;

insert into supabase_migrations.schema_migrations (version, name) values ('20261027020000', '0039_guest_cascades') on conflict (version) do nothing;

-- ===================== 20261028020000_0041_phase6_paste =====================
-- =====================================================================
-- 0041 — what phase 6 needs that the SQL tools refuse (they refuse any statement that removes objects, and any text
--        that spells the word). Pasted by the owner in the Supabase SQL editor after 0040, together with 0022, 0031,
--        0034 and 0039 (STAGING.md §0-ب). Running it twice changes nothing.
--   * decision 36: the four reports now take their filters (fn_reports_*(…, p_filters jsonb), 0040); the signatures
--     without them are retired (once 0040 is there), so one call resolves to one function whatever the client names.
--   * decision 14 (10.3): the complete audit dictionary — 0040 left out the family of codes written when an unused
--     definition is removed outright (0015), because their spelling is the word above; here the two label functions
--     and the capability catalogue (decision 55) are re-created with every code. src/lib/auditLabels.ts is the same
--     list; tests/unit/audit_labels.test.ts holds the copies together.
--   * staff_saved_views (0040) references staff and the organisation only, which no purge removes, so it needs no
--     cascading constraint here (unlike 0039's tables, which follow a stay or a branch).
-- =====================================================================
-- the old signatures go only once the new ones (0040) are there, so a paste that runs early never leaves the reports
-- without a function; pasted again after 0040 it finishes the job (the file is idempotent)
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'fn_reports_finance' and pg_get_function_identity_arguments(p.oid) like '%p_filters jsonb') then
    drop function if exists fn_reports_finance(uuid, date, date);
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'fn_reports_discounts' and pg_get_function_identity_arguments(p.oid) like '%p_filters jsonb') then
    drop function if exists fn_reports_discounts(uuid, date, date);
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'fn_reports_late_entries' and pg_get_function_identity_arguments(p.oid) like '%p_filters jsonb') then
    drop function if exists fn_reports_late_entries(uuid, date, date, integer);
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'fn_reports_identities' and pg_get_function_identity_arguments(p.oid) like '%p_filters jsonb') then
    drop function if exists fn_reports_identities(uuid, date, date, text);
  end if;
end $$;

create or replace function fn_audit_entity_label(p_entity text) returns text
language sql immutable set search_path = public as $$
  select case when p_entity is null then '—' else coalesce(
    case p_entity
      when 'reservation' then 'حجز'
      when 'reservation_guest' then 'ضيف'
      when 'guest_profile' then 'ملف ضيف'
      when 'financial_voucher' then 'سند'
      when 'voucher' then 'سند'
      when 'invoice' then 'فاتورة'
      when 'room' then 'وحدة'
      when 'room_category' then 'نوع وحدة'
      when 'facility' then 'مرفق'
      when 'housekeeping_task' then 'مهمة'
      when 'task_type' then 'نوع مهمة'
      when 'service_definition' then 'خدمة'
      when 'branch' then 'فرع'
      when 'block' then 'بلوك'
      when 'floor' then 'طابق'
      when 'staff_profile' then 'موظف'
      when 'cash_account' then 'صندوق أو حساب'
      when 'booking_source' then 'مصدر حجز'
      when 'service' then 'خدمة'
      when 'keybox' then 'صندوق مفتاح'
      when 'knowledge_entry' then 'إجابة'
      when 'unanswered_question' then 'سؤال بلا إجابة'
      when 'ai_settings' then 'إعدادات الذكاء الاصطناعي'
      when 'ai_proposal' then 'اقتراح المساعد'
      when 'ai_action_proposal' then 'اقتراح المساعد'
      when 'conversation' then 'محادثة'
      when 'review_items' then 'بند مراجعة'
      when 'pos_settlement' then 'تسوية شبكة'
      when 'platform_payout' then 'إيداع منصة'
      when 'review_item' then 'بند مراجعة'
      when 'maintenance_ticket' then 'بلاغ صيانة'
      when 'whatsapp_channel' then 'واتساب الفرع'
      when 'organization' then 'المنشأة'
      when 'data_purge' then 'تفريغ بيانات'
      when 'rate_calendar' then 'تقويم الأسعار'
      when 'inventory_period' then 'فترة توفر'
      when 'release_rule' then 'قاعدة توفر'
      when 'released_slot' then 'توفر'
      else null
    end, replace(p_entity, '_', ' ')) end;
$$;

create or replace function fn_audit_action_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select coalesce(
    case p_action
      when 'reservation.created' then 'إنشاء حجز'
      when 'reservation.cancelled' then 'إلغاء حجز'
      when 'reservation.cancel_undone' then 'التراجع عن إلغاء حجز'
      when 'reservation.checked_in' then 'تسجيل وصول'
      when 'reservation.check_in_undone' then 'التراجع عن تسجيل الوصول'
      when 'reservation.checked_out' then 'تسجيل مغادرة'
      when 'reservation.closed' then 'إغلاق إقامة'
      when 'reservation.unclosed' then 'إعادة فتح إقامة مغلقة'
      when 'reservation.stay_reopened' then 'إعادة فتح إقامة بعد المغادرة'
      when 'reservation.no_show' then 'تسجيل عدم حضور'
      when 'reservation.departure_changed' then 'تغيير موعد المغادرة'
      when 'reservation.room_switched' then 'تبديل الوحدة'
      when 'reservation.service_added' then 'إضافة خدمة إلى الحجز'
      when 'reservation.total_changed' then 'تعديل إجمالي الحجز'
      when 'reservation.payment_exception' then 'مهلة سداد استثنائية'
      when 'reservation.inspected' then 'فحص المغادرة'
      when 'reservation.damage_charged' then 'رسم ضرر'
      when 'reservation.hold_set' then 'وضع حظر على الحجز'
      when 'reservation.hold_lifted' then 'رفع الحظر عن الحجز'
      when 'reservation.shomoos_registered' then 'تسجيل شموس'
      when 'reservation.shomoos_accepted' then 'تأكيد قبول شموس'
      when 'reservation.platform_checked' then 'مطابقة الحجز مع المنصة'
      when 'reservation.platform_unchecked' then 'إلغاء مطابقة الحجز مع المنصة'
      when 'reservation.summary_signed' then 'إقرار ملخص الإقامة ورقيًا'
      when 'assign_room' then 'تخصيص وحدة للحجز'
      when 'approve_checkin' then 'اعتماد الدخول'
      when 'checkout' then 'تسجيل مغادرة'
      when 'manual_release_slot' then 'فتح توفر يدويًا'
      when 'guest.entered_from_document' then 'إدخال بيانات ضيف من الوثيقة'
      when 'guest.corrected' then 'تصحيح بيانات ضيف'
      when 'guest.banned' then 'حظر ضيف'
      when 'guest.unbanned' then 'رفع حظر ضيف'
      when 'guest.rated' then 'تقييم ضيف'
      when 'guest_data_submitted' then 'إدخال الضيف بياناته بنفسه'
      when 'guest_verified_lookup' then 'تحقق الضيف من حجزه'
      when 'guest_checkin_request' then 'طلب وصول من الضيف'
      when 'guest_viewed_code' then 'عرض الضيف رمز الدخول'
      when 'guest_summary_accepted' then 'قبول الضيف ملخص الإقامة'
      when 'confirm_gov_registration' then 'تأكيد التسجيل الحكومي'
      when 'approve_identity' then 'اعتماد هوية ضيف'
      when 'reject_identity' then 'رفض هوية ضيف'
      when 'confirm_payment' then 'تأكيد دفعة'
      when 'voucher.receipt_created' then 'إنشاء سند قبض'
      when 'voucher.deposit_created' then 'إنشاء سند تأمين'
      when 'voucher.refund_created' then 'إنشاء سند رد'
      when 'voucher.deposit_refund_created' then 'إنشاء سند رد تأمين'
      when 'voucher.deposit_apply_created' then 'استخدام التأمين لتغطية رسوم'
      when 'voucher.cancelled' then 'إلغاء سند'
      when 'voucher.corrected' then 'تصحيح سند'
      when 'invoice.issued' then 'إصدار فاتورة'
      when 'invoice.edited' then 'تعديل فاتورة'
      when 'invoice.cancelled' then 'إلغاء فاتورة'
      when 'pos.settled' then 'تسوية الشبكة'
      when 'platform.payout_confirmed' then 'تأكيد إيداع منصة'
      when 'platform.payout_cancelled' then 'إلغاء إيداع منصة'
      when 'cash_account.created' then 'إنشاء صندوق أو حساب'
      when 'cash_account.updated' then 'تعديل صندوق أو حساب'
      when 'cash_account.archived' then 'أرشفة صندوق أو حساب'
      when 'cash_account.restored' then 'استعادة صندوق أو حساب'
      when 'rates.updated' then 'تعديل الأسعار'
      when 'review.marked' then 'مراجعة بند من قائمة المراجعة'
      when 'deliver_access_code' then 'تسليم رمز الدخول'
      when 'delivery_failed' then 'تعذّر تسليم رمز الدخول'
      when 'rotate_keybox_code' then 'تغيير رمز صندوق المفتاح'
      when 'keybox_field_tested' then 'تجربة رمز صندوق المفتاح'
      when 'keybox.code_viewed' then 'عرض رمز صندوق المفتاح'
      when 'task.created' then 'إنشاء مهمة'
      when 'task.started' then 'بدء مهمة'
      when 'task.completed' then 'إتمام مهمة'
      when 'task.cancelled' then 'إلغاء مهمة'
      when 'task.assigned' then 'إسناد مهمة'
      when 'cleaning_completed' then 'إتمام تنظيف'
      when 'room.cleanliness_changed' then 'تغيير حالة النظافة يدويًا'
      when 'maintenance_opened' then 'فتح بلاغ صيانة'
      when 'maintenance_resolved' then 'إغلاق بلاغ صيانة'
      when 'branch.created' then 'إنشاء فرع'
      when 'branch.updated' then 'تعديل فرع'
      when 'branch.money_defaults' then 'تعديل إعدادات المال للفرع'
      when 'branch.tax_changed' then 'تغيير ضريبة الفرع'
      when 'branch.logo_changed' then 'تغيير شعار الفرع'
      when 'branch.image_changed' then 'تغيير صورة الفرع'
      when 'branch.archived' then 'أرشفة فرع'
      when 'branch.restored' then 'استعادة فرع'
      when 'block.created' then 'إنشاء بلوك'
      when 'block.updated' then 'تعديل بلوك'
      when 'block.archived' then 'أرشفة بلوك'
      when 'block.restored' then 'استعادة بلوك'
      when 'block.deleted' then 'حذف بلوك'
      when 'floor.created' then 'إنشاء طابق'
      when 'floor.updated' then 'تعديل طابق'
      when 'floor.archived' then 'أرشفة طابق'
      when 'floor.restored' then 'استعادة طابق'
      when 'floor.deleted' then 'حذف طابق'
      when 'room.created' then 'إنشاء وحدة'
      when 'room.updated' then 'تعديل وحدة'
      when 'room.archived' then 'أرشفة وحدة'
      when 'room.restored' then 'استعادة وحدة'
      when 'room.deleted' then 'حذف وحدة'
      when 'room_category.created' then 'إنشاء نوع وحدة'
      when 'room_category.updated' then 'تعديل نوع وحدة'
      when 'room_category.archived' then 'أرشفة نوع وحدة'
      when 'room_category.restored' then 'استعادة نوع وحدة'
      when 'room_category.deleted' then 'حذف نوع وحدة'
      when 'facility.created' then 'إنشاء مرفق'
      when 'facility.updated' then 'تعديل مرفق'
      when 'facility.archived' then 'أرشفة مرفق'
      when 'facility.restored' then 'استعادة مرفق'
      when 'facility.deleted' then 'حذف مرفق'
      when 'task_type.created' then 'إنشاء نوع مهمة'
      when 'task_type.updated' then 'تعديل نوع مهمة'
      when 'task_type.archived' then 'أرشفة نوع مهمة'
      when 'task_type.restored' then 'استعادة نوع مهمة'
      when 'task_type.deleted' then 'حذف نوع مهمة'
      when 'service.created' then 'إنشاء خدمة'
      when 'service.updated' then 'تعديل خدمة'
      when 'service.archived' then 'أرشفة خدمة'
      when 'service.restored' then 'استعادة خدمة'
      when 'service.deleted' then 'حذف خدمة'
      when 'source.enabled' then 'تفعيل مصدر حجز'
      when 'source.disabled' then 'تعطيل مصدر حجز'
      when 'staff_invited' then 'دعوة موظف'
      when 'staff.activated' then 'تفعيل موظف'
      when 'staff.deactivated' then 'إيقاف موظف'
      when 'staff.role_changed' then 'تغيير دور موظف'
      when 'staff.updated' then 'تعديل بيانات موظف'
      when 'staff.signed_out' then 'تسجيل خروج إجباري'
      when 'demo_owner_bootstrap' then 'إنشاء مالك نسخة العرض'
      when 'data_purge_executed' then 'تنفيذ تفريغ بيانات'
      when 'ai_proposal.executed' then 'تنفيذ اقتراح مساعد العمليات'
      when 'ai_settings_updated' then 'تعديل إعدادات الذكاء الاصطناعي'
      when 'knowledge.created' then 'إضافة إجابة إلى قاعدة المعرفة'
      when 'knowledge.updated' then 'تعديل إجابة في قاعدة المعرفة'
      when 'knowledge.archived' then 'أرشفة إجابة من قاعدة المعرفة'
      when 'knowledge.restored' then 'استعادة إجابة في قاعدة المعرفة'
      when 'unanswered.ignored' then 'تجاهل سؤال بلا إجابة'
      when 'unanswered.open' then 'إعادة فتح سؤال بلا إجابة'
      when 'conversation_taken' then 'استلام المحادثة من المساعد'
      when 'conversation_returned_to_assistant' then 'إعادة المحادثة إلى المساعد'
      when 'whatsapp_channel_updated' then 'تعديل إعداد واتساب الفرع'
      else null
    end,
    case when position('.' in p_action) > 1 then
      coalesce(case split_part(p_action, '.', 2)
        when 'created' then 'إنشاء' when 'updated' then 'تعديل' when 'archived' then 'أرشفة' when 'restored' then 'استعادة'
        when 'enabled' then 'تفعيل' when 'disabled' then 'تعطيل' when 'cancelled' then 'إلغاء' when 'completed' then 'إتمام'
        when 'started' then 'بدء' when 'assigned' then 'إسناد' when 'issued' then 'إصدار' when 'edited' then 'تعديل'
        when 'corrected' then 'تصحيح' when 'confirmed' then 'تأكيد' when 'approved' then 'اعتماد' when 'rejected' then 'رفض'
        when 'viewed' then 'عرض' when 'changed' then 'تغيير' when 'executed' then 'تنفيذ' when 'marked' then 'تعليم' when 'settled' then 'تسوية' when 'deleted' then 'حذف'
        else null end, replace(split_part(p_action, '.', 2), '_', ' '))
      || ' — ' || fn_audit_entity_label(split_part(p_action, '.', 1))
    end,
    replace(p_action, '_', ' '));
$$;

create or replace function fn_capability_catalog() returns table(code text, label text, area text, core boolean, coverage text, actions text[])
language sql immutable set search_path = public as $$
  values
    ('reservations.create', 'إنشاء حجز', 'الحجوزات', false, 'full', array['reservation.created']),
    ('reservations.cancel', 'إلغاء حجز وعدم حضور', 'الحجوزات', false, 'full', array['reservation.cancelled', 'reservation.no_show']),
    ('reservations.amend', 'تمديد وتبديل وتعديل الإجمالي', 'الحجوزات', false, 'full', array['reservation.departure_changed', 'reservation.room_switched', 'reservation.total_changed', 'reservation.service_added']),
    ('reservations.corrections', 'التصحيحات (التراجع عن الوصول والإلغاء وإعادة الفتح)', 'الحجوزات', false, 'full', array['reservation.check_in_undone', 'reservation.cancel_undone', 'reservation.stay_reopened', 'reservation.unclosed']),
    ('reservations.hold', 'الحظر على الحجز', 'الحجوزات', false, 'full', array['reservation.hold_set', 'reservation.hold_lifted']),
    ('reservations.platform_check', 'مطابقة المنصات', 'الحجوزات', false, 'full', array['reservation.platform_checked', 'reservation.platform_unchecked']),
    ('stay.check_in', 'تسجيل الوصول', 'الإقامة', false, 'full', array['reservation.checked_in', 'approve_checkin']),
    ('stay.shomoos', 'التسجيل في شموس', 'الإقامة', false, 'full', array['reservation.shomoos_registered', 'reservation.shomoos_accepted', 'confirm_gov_registration']),
    ('stay.payment_exception', 'مهلة السداد الاستثنائية', 'الإقامة', false, 'full', array['reservation.payment_exception']),
    ('stay.check_out', 'تسجيل المغادرة والإغلاق', 'الإقامة', false, 'full', array['reservation.checked_out', 'reservation.closed', 'checkout']),
    ('stay.inspection', 'فحص المغادرة ورسوم الضرر', 'الإقامة', false, 'full', array['reservation.inspected', 'reservation.damage_charged']),
    ('stay.summary', 'ملخص الإقامة وإقراره', 'الإقامة', false, 'partial', array['reservation.summary_signed', 'guest_summary_accepted']),
    ('guests.office_entry', 'إدخال بيانات الضيف من الوثيقة وتصحيحها', 'الضيوف', false, 'full', array['guest.entered_from_document', 'guest.corrected', 'approve_identity', 'reject_identity']),
    ('guests.self_entry', 'إدخال الضيف بياناته بنفسه', 'الضيوف', false, 'partial', array['guest_data_submitted']),
    ('guests.ban_rating', 'حظر الضيوف وتقييمهم', 'الضيوف', false, 'full', array['guest.banned', 'guest.unbanned', 'guest.rated']),
    ('money.receipts', 'سندات القبض والتأمين', 'المال', false, 'full', array['voucher.receipt_created', 'voucher.deposit_created', 'confirm_payment']),
    ('money.refunds', 'الاستردادات وتسوية التأمين', 'المال', false, 'full', array['voucher.refund_created', 'voucher.deposit_refund_created', 'voucher.deposit_apply_created']),
    ('money.corrections', 'إلغاء السندات وتصحيحها', 'المال', false, 'full', array['voucher.cancelled', 'voucher.corrected']),
    ('money.invoices', 'الفواتير', 'المال', false, 'full', array['invoice.issued', 'invoice.edited', 'invoice.cancelled']),
    ('money.pos_settlement', 'تسوية الشبكة', 'المال', false, 'full', array['pos.settled']),
    ('money.platform_payouts', 'إيداعات المنصات', 'المال', false, 'full', array['platform.payout_confirmed', 'platform.payout_cancelled']),
    ('money.review', 'قائمة المراجعة', 'المال', false, 'full', array['review.marked']),
    ('access.codes', 'تسليم رمز الدخول', 'الوصول', false, 'full', array['deliver_access_code', 'delivery_failed']),
    ('access.keybox', 'رموز صناديق المفاتيح', 'الوصول', false, 'full', array['rotate_keybox_code', 'keybox_field_tested', 'keybox.code_viewed']),
    ('housekeeping.tasks', 'المهام', 'خدمة الغرف', false, 'full', array['task.created', 'task.started', 'task.completed', 'task.cancelled', 'task.assigned', 'cleaning_completed']),
    ('housekeeping.cleanliness', 'تغيير النظافة يدويًا', 'خدمة الغرف', false, 'full', array['room.cleanliness_changed']),
    ('housekeeping.maintenance', 'بلاغات الصيانة', 'خدمة الغرف', false, 'full', array['maintenance_opened', 'maintenance_resolved']),
    ('admin.branches', 'الفروع وإعداداتها', 'الإدارة', true, 'full', array['branch.created', 'branch.updated', 'branch.money_defaults', 'branch.tax_changed', 'branch.logo_changed', 'branch.image_changed', 'branch.archived', 'branch.restored']),
    ('admin.structure', 'البلوكات والطوابق', 'الإدارة', true, 'full', array['block.created', 'block.updated', 'block.archived', 'block.restored', 'block.deleted', 'floor.created', 'floor.updated', 'floor.archived', 'floor.restored', 'floor.deleted']),
    ('admin.rooms', 'الوحدات', 'الإدارة', true, 'full', array['room.created', 'room.updated', 'room.archived', 'room.restored', 'room.deleted']),
    ('admin.room_categories', 'أنواع الوحدات', 'الإدارة', true, 'full', array['room_category.created', 'room_category.updated', 'room_category.archived', 'room_category.restored', 'room_category.deleted']),
    ('admin.rates', 'الأسعار', 'الإدارة', true, 'full', array['rates.updated']),
    ('admin.facilities', 'المرافق', 'الإدارة', true, 'full', array['facility.created', 'facility.updated', 'facility.archived', 'facility.restored', 'facility.deleted']),
    ('admin.task_types', 'أنواع المهام', 'الإدارة', true, 'full', array['task_type.created', 'task_type.updated', 'task_type.archived', 'task_type.restored', 'task_type.deleted']),
    ('admin.services', 'الخدمات', 'الإدارة', true, 'full', array['service.created', 'service.updated', 'service.archived', 'service.restored', 'service.deleted']),
    ('admin.cash_accounts', 'الصناديق والحسابات', 'الإدارة', true, 'full', array['cash_account.created', 'cash_account.updated', 'cash_account.archived', 'cash_account.restored']),
    ('admin.sources', 'مصادر الحجز', 'الإدارة', true, 'full', array['source.enabled', 'source.disabled']),
    ('admin.staff', 'الموظفون', 'الإدارة', true, 'full', array['staff_invited', 'staff.activated', 'staff.deactivated', 'staff.role_changed', 'staff.updated', 'staff.signed_out']),
    ('admin.knowledge', 'قاعدة المعرفة والأسئلة بلا إجابة', 'الإدارة', true, 'full', array['knowledge.created', 'knowledge.updated', 'knowledge.archived', 'knowledge.restored', 'unanswered.ignored', 'unanswered.open']),
    ('admin.ai', 'إعدادات الذكاء الاصطناعي', 'الإدارة', true, 'full', array['ai_settings_updated']),
    ('admin.whatsapp', 'واتساب الفروع', 'الإدارة', true, 'partial', array['whatsapp_channel_updated']),
    ('admin.purge', 'تفريغ البيانات', 'الإدارة', true, 'full', array['data_purge_executed']),
    ('assistant.ops', 'مساعد العمليات (تنفيذ اقتراح)', 'المساعد', false, 'full', array['ai_proposal.executed']),
    ('assistant.handover', 'استلام المحادثة من المساعد وإعادتها', 'المساعد', false, 'full', array['conversation_taken', 'conversation_returned_to_assistant']),
    ('assistant.reception', 'مساعد الاستقبال وواتساب', 'المساعد', false, 'none', array['guest_verified_lookup', 'guest_checkin_request', 'guest_viewed_code']),
    ('screens.reports', 'التقارير', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.audit', 'سجل الإجراءات', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.exports', 'التصدير والطباعة', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.calendar', 'لوحة الوحدات وتقويم الحجوزات', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.usage', 'تقرير استعمال القدرات', 'الشاشات', false, 'none', array[]::text[]);
$$;

insert into supabase_migrations.schema_migrations (version, name) values ('20261028020000', '0041_phase6_paste') on conflict (version) do nothing;

commit;
select 'تم' as result, (select count(*) from supabase_migrations.schema_migrations) as migrations;
