-- 0083: retain historical 0073 text; bind its branchless deletions to the requested hotel.
-- Installing this function does not execute a purge. Paired with 0073 before API exposure.
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
    delete from audit_events where organization_id = p_org and (v_all or branch_id = p_branch) and created_at >= v_start and created_at < v_end;
    get diagnostics n = row_count; c := c || jsonb_build_object('audit_events', n);
  end if;

  return c;
end $$;
revoke all on function fn_purge_run(uuid, uuid, date, date, text[]) from public, anon, authenticated;
