-- =====================================================================
-- 0082 — plan 5.3 (finding S4): the audit log hardens.
--   1. المصدر يُشتق في الخادم: a browser's x-client-source header is attribution the caller can forge, so it no
--      longer writes the log's source. The source derives in the database from the trusted in-database setting
--      app.source (migrations, the operations assistant), else from the verified request role and actor kind.
--   2. مشغّل يمنع تعديل السجل وحذفه من أي دور: a trigger refuses every UPDATE and DELETE of audit_events, from
--      any role, even the owner and the superuser — the one sanctioned exception is the data purge, which opens
--      the door inside fn_purge_run itself (app.audit_purge, transaction-local; no API role can set it).
--   3. سلسلة هاش تكشف أي حذف لاحقًا: every row joins its hotel's hash chain (prev_hash → row_hash, sha-256).
--      fn_audit_chain_verify() walks the caller's hotel chain and names the first broken link, so a row removed
--      through the purge — or any other path — shows up at the next verification.
-- This file redefines fn_purge_run with its DELETE words: it is an owner's paste, like 0073.
-- =====================================================================

alter table audit_events add column if not exists chain_seq bigint;
alter table audit_events add column if not exists prev_hash text;
alter table audit_events add column if not exists row_hash text;
create index if not exists idx_audit_chain on audit_events(organization_id, chain_seq);

-- The canonical content hash of one row. Epoch seconds, never the session's time zone spelling of created_at.
create or replace function fn_audit_hash(p_prev text, p_org uuid, p_branch uuid, p_actor uuid, p_action text,
  p_entity_type text, p_entity_id uuid, p_details jsonb, p_created_at timestamptz, p_correlation text,
  p_source text, p_actor_type text, p_result text, p_category text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(digest(concat_ws('|',
    coalesce(p_prev, ''), coalesce(p_org::text, ''), coalesce(p_branch::text, ''), coalesce(p_actor::text, ''),
    coalesce(p_action, ''), coalesce(p_entity_type, ''), coalesce(p_entity_id::text, ''), coalesce(p_details::text, ''),
    coalesce(extract(epoch from p_created_at)::text, ''), coalesce(p_correlation, ''), coalesce(p_source, ''),
    coalesce(p_actor_type, ''), coalesce(p_result, ''), coalesce(p_category, '')), 'sha256'), 'hex')
$$;
revoke all on function fn_audit_hash(text, uuid, uuid, uuid, text, text, uuid, jsonb, timestamptz, text, text, text, text, text) from public, anon, authenticated;

-- Existing rows join the chain in their recorded order (one chain per hotel; the rows 0076 left without a hotel
-- keep their own partition).
do $$
declare r record; v_part uuid; v_prev text; v_seq bigint; v_hash text;
begin
  for v_part in select distinct coalesce(organization_id, '00000000-0000-0000-0000-000000000000') from audit_events loop
    v_prev := null; v_seq := 0;
    for r in select * from audit_events
             where coalesce(organization_id, '00000000-0000-0000-0000-000000000000') = v_part
             order by created_at, id loop
      v_seq := v_seq + 1;
      v_hash := fn_audit_hash(v_prev, r.organization_id, r.branch_id, r.actor_id, r.action, r.entity_type, r.entity_id,
                              r.details, r.created_at, r.correlation_id, r.source, r.actor_type, r.result, r.category);
      update audit_events set chain_seq = v_seq, prev_hash = v_prev, row_hash = v_hash where id = r.id;
      v_prev := v_hash;
    end loop;
  end loop;
end $$;

-- fn_audit_enrich, redefined in full: the 0076 hotel fill kept, the source now derived in the server (plan 5.3),
-- and every new row chained.
create or replace function fn_audit_enrich() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_corr text; v_src text; v_role text; v_prev text; v_seq bigint;
begin
  v_corr := fn_request_header('x-correlation-id');
  if v_corr is not null and v_corr !~ '^[A-Za-z0-9_-]{6,64}$' then v_corr := null; end if;
  new.correlation_id := coalesce(new.correlation_id, v_corr, 'tx-' || txid_current()::text);

  -- plan 5.3: the source derives in the server. app.source is set only inside the database (a migration, the
  -- operations assistant); a request header is caller attribution and no longer writes the log's source.
  v_src := nullif(current_setting('app.source', true), '');
  if v_src is not null and v_src !~ '^[a-z][a-z_-]{1,31}$' then v_src := null; end if;

  v_role := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role';
  new.actor_id := coalesce(new.actor_id, fn_staff_id());
  -- the row's hotel (0076): from its branch, else from the staff member who acted
  if new.organization_id is null and new.branch_id is not null then
    select b.organization_id into new.organization_id from branches b where b.id = new.branch_id;
  end if;
  if new.organization_id is null and new.actor_id is not null then
    select sp.organization_id into new.organization_id from staff_profiles sp where sp.id = new.actor_id;
  end if;
  new.actor_type := coalesce(new.actor_type,
    case when new.actor_id is not null then 'staff'
         when v_role = 'anon' then 'guest'
         when auth.uid() is not null then 'user'
         else 'system' end);
  new.source := coalesce(v_src, case when v_role = 'service_role' or new.actor_type = 'system' then 'system' else 'screen' end);
  if new.action ~ '^(staff|membership|security|data_purge|permissions)' then new.category := 'security'; end if;
  new.result := coalesce(new.result, 'success');

  -- the hotel's hash chain (plan 5.3): serialized per hotel so two concurrent operations never read the same tail
  perform pg_advisory_xact_lock(hashtext('audit-chain:' || coalesce(new.organization_id, '00000000-0000-0000-0000-000000000000')::text));
  select a.row_hash, a.chain_seq into v_prev, v_seq from audit_events a
   where coalesce(a.organization_id, '00000000-0000-0000-0000-000000000000') = coalesce(new.organization_id, '00000000-0000-0000-0000-000000000000')
     and a.chain_seq is not null
   order by a.chain_seq desc limit 1;
  new.chain_seq := coalesce(v_seq, 0) + 1;
  new.prev_hash := v_prev;
  new.row_hash := fn_audit_hash(v_prev, new.organization_id, new.branch_id, new.actor_id, new.action, new.entity_type,
                                new.entity_id, new.details, new.created_at, new.correlation_id, new.source,
                                new.actor_type, new.result, new.category);
  return new;
end $$;
revoke all on function fn_audit_enrich() from public, anon, authenticated;

-- No role changes or deletes a logged row. The data purge is the single sanctioned exception, and it opens the
-- door from inside fn_purge_run only.
create or replace function fn_audit_immutable() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' and current_setting('app.audit_purge', true) = 'on' then return old; end if;
  raise exception 'AUDIT_IMMUTABLE: the audit log accepts no change and no deletion' using errcode = '42501';
end $$;
revoke all on function fn_audit_immutable() from public, anon, authenticated;
drop trigger if exists trg_audit_immutable on audit_events;
create trigger trg_audit_immutable before update or delete on audit_events for each row execute function fn_audit_immutable();

-- The owner walks their hotel's chain; a removed or altered row names itself.
create or replace function fn_audit_chain_verify() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_prev text; v_count int := 0;
begin
  perform fn_require_cap('security');
  for r in select * from audit_events where organization_id = fn_user_org_id() and chain_seq is not null order by chain_seq loop
    v_count := v_count + 1;
    if r.prev_hash is distinct from v_prev then
      return jsonb_build_object('ok', false, 'checked', v_count, 'broken_at', r.id, 'reason', 'link');
    end if;
    if r.row_hash is distinct from fn_audit_hash(r.prev_hash, r.organization_id, r.branch_id, r.actor_id, r.action,
        r.entity_type, r.entity_id, r.details, r.created_at, r.correlation_id, r.source, r.actor_type, r.result, r.category) then
      return jsonb_build_object('ok', false, 'checked', v_count, 'broken_at', r.id, 'reason', 'hash');
    end if;
    v_prev := r.row_hash;
  end loop;
  return jsonb_build_object('ok', true, 'checked', v_count);
end $$;
revoke all on function fn_audit_chain_verify() from public, anon;
grant execute on function fn_audit_chain_verify() to authenticated;

-- Preserve0083hotel-isolatedpurge; enable only audited scoped deletion.
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
  has_samples boolean := 'samples' = any(p_cats);
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
  create temp table if not exists _purge_expenses(id uuid primary key) on commit drop;
  create temp table if not exists _purge_closings(id uuid primary key) on commit drop;
  create temp table if not exists _purge_movements(id uuid primary key) on commit drop;
  create temp table if not exists _purge_payouts(id uuid primary key) on commit drop;
  create temp table if not exists _purge_messages(id uuid primary key) on commit drop;
  create temp table if not exists _purge_entries(id uuid primary key) on commit drop;
  truncate _purge_res, _purge_vouchers, _purge_payments, _purge_invoices, _purge_profiles, _purge_expenses, _purge_closings, _purge_movements, _purge_payouts,
           _purge_messages, _purge_entries;

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
    -- 0063–0067: the period's closings, expenses and bank movements
    insert into _purge_closings select d.id from day_closings d where d.branch_id = any(v_branches) and d.business_date between p_from and p_to;
    insert into _purge_expenses select e.id from expense_vouchers e where e.branch_id = any(v_branches) and e.occurred_at >= v_start and e.occurred_at < v_end;
    insert into _purge_movements select m.id from bank_movements m
      where (m.branch_id = any(v_branches) or (v_all and m.branch_id is null) or (v_all and m.organization_id = p_org and m.branch_id is null))
        and m.organization_id = p_org and m.occurred_at >= v_start and m.occurred_at < v_end
    on conflict do nothing;
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
    where cv.organization_id = p_org and (cv.branch_id = any(v_branches) or (v_all and cv.branch_id is null)) and cv.created_at >= v_start and cv.created_at < v_end;
    c := c || jsonb_build_object('conversation_messages', n);
    delete from human_handoff_tickets where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('handoff_tickets', n);
    -- the reception computer's queue of the period's conversations goes with them
    delete from whatsapp_outbox o where o.branch_id = any(v_branches)
      and o.message_id in (select m.id from conversation_messages m join conversations cv on cv.id = m.conversation_id
                            where cv.organization_id = p_org and (cv.branch_id = any(v_branches) or (v_all and cv.branch_id is null)) and cv.created_at >= v_start and cv.created_at < v_end);
    delete from conversations where organization_id = p_org and (branch_id = any(v_branches) or (v_all and branch_id is null)) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('conversations', n);
    delete from ai_action_proposals where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    delete from ai_ops_conversations where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('staff_assistant_chats', n);
    delete from unanswered_questions where branch_id = any(v_branches) and last_asked_at >= v_start and last_asked_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('unanswered_questions', n);
    if v_all then
      delete from ai_tool_executions where organization_id = p_org and conversation_id is null and created_at >= v_start and created_at < v_end;
      delete from ai_guardrail_events where organization_id = p_org and conversation_id is null and created_at >= v_start and created_at < v_end;
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
    -- the platform payouts of the period none of whose kept payments remain, and the journal's entries of all that goes
    -- (0065: a voucher, an expense, a closing, a bank movement, a payout); the opening balances stay
    insert into _purge_payouts select pp.id from platform_payouts pp where pp.branch_id = any(v_branches) and pp.received_on between p_from and p_to
      and not exists (select 1 from financial_vouchers v where v.payout_id = pp.id and v.id not in (select id from _purge_vouchers));
    insert into _purge_entries select e.id from journal_entries e
     where e.organization_id = p_org
       and ((e.source_type = 'voucher' and e.source_id in (select id from _purge_vouchers))
            or (e.source_type = 'expense' and e.source_id in (select id from _purge_expenses))
            or (e.source_type = 'day_closing' and e.source_id in (select id from _purge_closings))
            or (e.source_type = 'bank_movement' and e.source_id in (select id from _purge_movements))
            or (e.source_type = 'payout' and e.source_id in (select id from _purge_payouts)));
    -- the bank's matching that rests on what goes (0067): its items and matches; a kept movement waits again
    delete from bank_match_items i using bank_matches mt
     where i.match_id = mt.id and (mt.movement_id in (select id from _purge_movements)
           or exists (select 1 from bank_match_items x where x.match_id = mt.id
                       and ((x.target_type = 'voucher' and x.target_id in (select id from _purge_vouchers))
                            or (x.target_type = 'expense' and x.target_id in (select id from _purge_expenses))
                            or (x.target_type = 'platform_payout' and x.target_id in (select id from _purge_payouts))
                            or (x.target_type = 'journal' and x.target_id in (select id from _purge_entries)))));
    delete from bank_matches mt where mt.organization_id = p_org and not exists (select 1 from bank_match_items i where i.match_id = mt.id)
      and (mt.movement_id in (select id from _purge_movements) or mt.kind <> 'set_aside');
    get diagnostics n = row_count; c := c || jsonb_build_object('bank_matches', n);
    update bank_movements m set status = 'pending'
     where m.organization_id = p_org and m.status in ('matched', 'converted') and m.id not in (select id from _purge_movements)
       and not exists (select 1 from bank_matches mt where mt.movement_id = m.id and mt.active);
    delete from journal_lines where entry_id in (select id from _purge_entries);
    delete from journal_entries where id in (select id from _purge_entries);
    get diagnostics n = row_count; c := c || jsonb_build_object('journal_entries', n);
    delete from financial_vouchers where id in (select id from _purge_vouchers);
    get diagnostics n = row_count; c := c || jsonb_build_object('vouchers', n);
    delete from payment_transactions where id in (select id from _purge_payments);
    get diagnostics n = row_count; c := c || jsonb_build_object('payments', n);
    delete from invoices where id in (select id from _purge_invoices);
    get diagnostics n = row_count; c := c || jsonb_build_object('invoices', n);
    -- the period's card-terminal settlements, and its platform payouts none of whose payments remain (0028)
    delete from pos_settlements where branch_id = any(v_branches) and business_date between p_from and p_to;
    get diagnostics n = row_count; c := c || jsonb_build_object('pos_settlements', n);
    delete from platform_payouts pp where pp.id in (select id from _purge_payouts) and not exists (select 1 from financial_vouchers v where v.payout_id = pp.id);
    get diagnostics n = row_count; c := c || jsonb_build_object('platform_payouts', n);
    -- the closings (their lines and edit requests), the expenses (their receipts)
    delete from day_closing_lines where closing_id in (select id from _purge_closings);
    delete from day_closing_requests where closing_id in (select id from _purge_closings);
    delete from day_closings where id in (select id from _purge_closings);
    get diagnostics n = row_count; c := c || jsonb_build_object('day_closings', n);
    delete from expense_attachments where expense_id in (select id from _purge_expenses);
    delete from expense_vouchers where id in (select id from _purge_expenses);
    get diagnostics n = row_count; c := c || jsonb_build_object('expense_vouchers', n);
    -- the bank's movements, and their messages: a message goes with the movements it made or repeated — and, when all
    -- branches are chosen, a message of the period that made no movement — but never the message a kept movement was
    -- read from (a movement is dated by its text, so it may fall outside the period its message arrived in)
    insert into _purge_messages select bm.id from bank_messages bm
     where bm.organization_id = p_org
       and (bm.movement_id in (select id from _purge_movements)
            or bm.id in (select message_id from bank_movements where id in (select id from _purge_movements))
            or (v_all and bm.received_at >= v_start and bm.received_at < v_end and bm.movement_id is null))
       and not exists (select 1 from bank_movements k where k.message_id = bm.id and k.id not in (select id from _purge_movements))
    on conflict do nothing;
    update bank_messages set movement_id = null where id not in (select id from _purge_messages) and movement_id in (select id from _purge_movements);
    delete from bank_movements where id in (select id from _purge_movements);
    get diagnostics n = row_count; c := c || jsonb_build_object('bank_movements', n);
    delete from bank_messages where id in (select id from _purge_messages);
    get diagnostics n = row_count; c := c || jsonb_build_object('bank_messages', n);
  end if;

  -- ---------------- reservations ----------------
  if has_res then
    insert into _purge_profiles select distinct g.guest_profile_id from reservation_guests g
      where g.reservation_id in (select id from _purge_res) and g.guest_profile_id is not null on conflict do nothing;
    -- what the stay's journey and orders left (0068, 0070): kept by the functions, not by references of the database
    delete from product_order_lines where order_id in (select id from product_orders where reservation_id in (select id from _purge_res));
    delete from product_orders where reservation_id in (select id from _purge_res);
    get diagnostics n = row_count; c := c || jsonb_build_object('product_orders', n);
    delete from journey_messages where reservation_id in (select id from _purge_res);
    delete from stay_extension_requests where reservation_id in (select id from _purge_res);
    delete from guest_reviews where reservation_id in (select id from _purge_res);
    get diagnostics n = row_count; c := c || jsonb_build_object('guest_reviews', n);
    delete from alert_events where reservation_id in (select id from _purge_res);
    delete from reservations where id in (select id from _purge_res);
    get diagnostics n = row_count; c := c || jsonb_build_object('reservations', n);
    -- over all branches: what an earlier erasing (before 0073) left of stays that are gone
    if v_all then
      delete from product_order_lines where order_id in (select o.id from product_orders o where o.organization_id = p_org and not exists (select 1 from reservations r where r.id = o.reservation_id));
      delete from product_orders o where o.organization_id = p_org and not exists (select 1 from reservations r where r.id = o.reservation_id);
      delete from journey_messages o where o.organization_id = p_org and not exists (select 1 from reservations r where r.id = o.reservation_id);
      delete from stay_extension_requests o where o.organization_id = p_org and not exists (select 1 from reservations r where r.id = o.reservation_id);
      delete from guest_reviews o where o.organization_id = p_org and not exists (select 1 from reservations r where r.id = o.reservation_id);
      delete from alert_events o where o.organization_id = p_org and o.reservation_id is not null and not exists (select 1 from reservations r where r.id = o.reservation_id);
    end if;
  end if;

  -- ---------------- guests (never the guests imported from Zaaer) ----------------
  if has_guest then
    -- marked again first (0072: by their note or by the import's hour); and if none is marked while profiles from the
    -- import's days exist, nothing is taken: the marking failed, and the hotel's guests would go with the trial's
    perform fn_mark_imported_guests(p_org);
    if not exists (select 1 from guest_profiles where organization_id = p_org and imported_at is not null)
       and exists (select 1 from guest_profiles where organization_id = p_org and created_at < timestamptz '2026-11-01 00:00:00+03') then
      raise exception 'VALIDATION: import_unmarked';
    end if;
    delete from guest_profiles gp
    where gp.organization_id = p_org and gp.imported_at is null
      and not exists (select 1 from reservation_guests g where g.guest_profile_id = gp.id)
      and ((v_all and gp.created_at >= v_start and gp.created_at < v_end) or gp.id in (select id from _purge_profiles));
    get diagnostics n = row_count; c := c || jsonb_build_object('guest_profiles', n);
  end if;

  -- ---------------- logs ----------------
  if has_logs then
    delete from notifications where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('notifications', n);
    delete from alert_events where branch_id = any(v_branches) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('alerts', n);
    delete from whatsapp_inbound_messages where organization_id = p_org and (branch_id = any(v_branches) or (v_all and branch_id is null)) and received_at >= v_start and received_at < v_end;
    if v_all then
      delete from integration_events where organization_id = p_org and created_at >= v_start and created_at < v_end;
      get diagnostics n = row_count; c := c || jsonb_build_object('integration_events', n);
      delete from guest_lookup_attempts where organization_id = p_org and created_at >= v_start and created_at < v_end;
      delete from guest_phone_challenges where organization_id = p_org and created_at >= v_start and created_at < v_end;
      delete from guest_phone_sessions where organization_id = p_org and created_at >= v_start and created_at < v_end;
      delete from journey_ticks where branch_id = any(v_branches);
    end if;
  end if;

  -- ---------------- the example catalogue (0072) ----------------
  if has_samples then
    delete from product_branches pb using products x
     where pb.product_id = x.id and x.organization_id = p_org and x.is_sample
       and not exists (select 1 from product_order_lines l where l.product_id = x.id);
    delete from products x where x.organization_id = p_org and x.is_sample and not exists (select 1 from product_order_lines l where l.product_id = x.id);
    get diagnostics n = row_count; c := c || jsonb_build_object('sample_products', n);
    delete from product_categories pc where pc.organization_id = p_org and pc.is_sample and not exists (select 1 from products x where x.category_id = pc.id);
  end if;

  -- ---------------- audit ----------------
  if has_audit then
    perform set_config('app.audit_purge', 'on', true);
    delete from audit_events where organization_id = p_org and (v_all or branch_id = p_branch) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('audit_events', n);
    perform set_config('app.audit_purge', '', true);
  end if;

  return c;
end $$;
revoke all on function fn_purge_run(uuid, uuid, date, date, text[]) from public, anon, authenticated;
