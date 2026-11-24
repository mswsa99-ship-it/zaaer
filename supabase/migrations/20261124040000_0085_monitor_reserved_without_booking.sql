-- 0085: add reserved-without-booking finding while preserving0082suspended-hotel guards.
CREATE OR REPLACE FUNCTION public.fn_run_monitors(p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; x record; f jsonb; res jsonb := '{}'::jsonb; orgs uuid[] := '{}'; o uuid; k text; cnt int; fails int; codes int;
  here jsonb;
begin
  for b in select id, organization_id from branches where exists(select 1 from organizations o where o.id=branches.organization_id and o.platform_status='active') and archived_at is null and is_active and (p_branch is null or id = p_branch) order by id loop
    perform pg_advisory_xact_lock(hashtext('monitors:' || b.id::text));
    if not (b.organization_id = any(orgs)) then orgs := orgs || b.organization_id; end if;
    here := '{}'::jsonb;

    -- 1 allocation conflicts (the exclusion constraint forbids them; this says so if one ever gets through)
    for x in
      select a1.room_id, rm.room_number, array_agg(distinct r1.internal_ref) || array_agg(distinct r2.internal_ref) as refs
        from reservation_allocations a1
        join reservation_allocations a2 on a2.room_id = a1.room_id and a2.id > a1.id and a2.status = 'active'
                                       and daterange(a1.from_date, a1.to_date, '[)') && daterange(a2.from_date, a2.to_date, '[)')
        join rooms rm on rm.id = a1.room_id
        join reservations r1 on r1.id = a1.reservation_id
        join reservations r2 on r2.id = a2.reservation_id
       where a1.status = 'active' and rm.branch_id = b.id
       group by a1.room_id, rm.room_number
      union all
      select rm.id, rm.room_number, array_agg(r.internal_ref)
        from reservations r join rooms rm on rm.id = r.room_id
       where r.branch_id = b.id and r.status = 'checked_in'
       group by rm.id, rm.room_number having count(*) > 1
    loop
      if fn_monitor_finding(b.organization_id, b.id, 'allocation_conflict', 'room', x.room_id, null, 'تعارض تخصيص في الوحدة ' || x.room_number,
                            jsonb_build_object('room', x.room_number, 'reservations', to_jsonb(x.refs))) then
        here := here || jsonb_build_object('allocation_conflict', coalesce((here->>'allocation_conflict')::int, 0) + 1);
      end if;
    end loop;

    -- 2 and 3: the stays of the last 90 days and every open one, against their ledger
    for x in
      select r.id, r.internal_ref, r.status, r.total_halalas, r.paid_halalas, r.balance_due_halalas, r.deposit_balance_halalas
        from reservations r
       where r.branch_id = b.id
         and (r.status in ('pending_verification', 'confirmed', 'checked_in', 'checked_out') or r.updated_at > now() - interval '90 days')
    loop
      f := fn_reservation_finance_internal(x.id);
      if x.total_halalas is distinct from (f->>'total')::bigint or x.paid_halalas is distinct from (f->>'net_collected')::bigint
         or x.balance_due_halalas is distinct from (f->>'balance_due')::bigint or x.deposit_balance_halalas is distinct from (f->>'deposit_balance')::bigint then
        if fn_monitor_finding(b.organization_id, b.id, 'ledger_mismatch', 'reservation', x.id, x.id,
             'الملخص المالي للحجز ' || x.internal_ref || ' يختلف عن الدفتر',
             jsonb_build_object('stored', jsonb_build_object('total', x.total_halalas, 'paid', x.paid_halalas, 'balance_due', x.balance_due_halalas, 'deposit', x.deposit_balance_halalas),
                                'ledger', jsonb_build_object('total', (f->>'total')::bigint, 'paid', (f->>'net_collected')::bigint,
                                                             'balance_due', (f->>'balance_due')::bigint, 'deposit', (f->>'deposit_balance')::bigint))) then
          here := here || jsonb_build_object('ledger_mismatch', coalesce((here->>'ledger_mismatch')::int, 0) + 1);
        end if;
      end if;
      if (f->>'deposit_balance')::bigint < 0 or (x.status = 'closed' and (f->>'deposit_balance')::bigint <> 0) then
        if fn_monitor_finding(b.organization_id, b.id, 'deposit_invalid', 'reservation', x.id, x.id,
             'رصيد التأمين في الحجز ' || x.internal_ref || ' غير صالح (' || fn_sar_text((f->>'deposit_balance')::bigint) || ')',
             jsonb_build_object('deposit_balance', (f->>'deposit_balance')::bigint, 'status', x.status)) then
          here := here || jsonb_build_object('deposit_invalid', coalesce((here->>'deposit_invalid')::int, 0) + 1);
        end if;
      end if;
    end loop;

    -- 4 (the branch's part): WhatsApp replies waiting for more than an hour while the channel is on
    select count(*) into cnt from whatsapp_outbox w
     where w.branch_id = b.id and w.status in ('pending', 'sending') and w.created_at < now() - interval '1 hour'
       and exists (select 1 from branch_whatsapp_channels c where c.branch_id = b.id and c.enabled);
    if cnt > 0 and fn_monitor_finding(b.organization_id, b.id, 'provider_stuck', 'branch', b.id, null,
                                      cnt || ' رد واتساب لم يُرسل منذ أكثر من ساعة', jsonb_build_object('whatsapp_waiting', cnt)) then
      here := here || jsonb_build_object('provider_stuck', coalesce((here->>'provider_stuck')::int, 0) + 1);
    end if;

    -- 6 two open departure cleanings for one stay
    for x in
      select h.reservation_id, r.internal_ref, rm.room_number, count(*) as n
        from housekeeping_tasks h join reservations r on r.id = h.reservation_id left join rooms rm on rm.id = h.room_id
       where h.branch_id = b.id and h.status in ('pending', 'in_progress') and h.description = 'تنظيف بعد المغادرة'
       group by h.reservation_id, r.internal_ref, rm.room_number having count(*) > 1
    loop
      if fn_monitor_finding(b.organization_id, b.id, 'duplicate_departure', 'reservation', x.reservation_id, x.reservation_id,
                            x.n || ' مهام تنظيف مغادرة مفتوحة للحجز ' || x.internal_ref, jsonb_build_object('room', x.room_number, 'open_tasks', x.n)) then
        here := here || jsonb_build_object('duplicate_departure', coalesce((here->>'duplicate_departure')::int, 0) + 1);
      end if;
    end loop;

    -- 8 (plan 7.4, observation O7): a unit flagged «محجوزة» that no active booking covers today
    for x in
      select rm.id, rm.room_number
        from rooms rm
       where rm.branch_id = b.id and rm.status = 'reserved' and rm.is_active and rm.archived_at is null
         and not exists (select 1 from reservation_allocations a
                          join reservations r on r.id = a.reservation_id
                         where a.room_id = rm.id and a.status = 'active'
                           and a.from_date <= fn_branch_today(b.id) and fn_branch_today(b.id) < a.to_date
                           and r.status in ('pending_verification', 'confirmed', 'checked_in'))
    loop
      if fn_monitor_finding(b.organization_id, b.id, 'reserved_without_booking', 'room', x.id, null,
                            'الوحدة ' || x.room_number || ' محجوزة ولا يغطي اليومَ أيُّ حجز نشط',
                            jsonb_build_object('room', x.room_number, 'status', 'reserved')) then
        here := here || jsonb_build_object('reserved_without_booking', coalesce((here->>'reserved_without_booking')::int, 0) + 1);
      end if;
    end loop;
    insert into monitor_runs(branch_id, last_run_at, result) values (b.id, now(), here)
    on conflict (branch_id) do update set last_run_at = excluded.last_run_at, result = excluded.result;
    for k in select jsonb_object_keys(here) loop
      res := res || jsonb_build_object(k, coalesce((res->>k)::int, 0) + (here->>k)::int);
    end loop;
  end loop;

  -- the organisation-wide checks
  foreach o in array orgs loop
    perform pg_advisory_xact_lock(hashtext('monitors-org:' || o::text));
    -- 4 provider events received and not processed for an hour
    select count(*) into cnt from integration_events e where e.organization_id = o and e.state = 'received' and e.created_at < now() - interval '1 hour';
    if cnt > 0 and fn_monitor_finding(o, null, 'provider_stuck', 'organization', o, null, cnt || ' حدث من مزود خارجي لم يُعالَج منذ أكثر من ساعة',
                                      jsonb_build_object('events_waiting', cnt)) then
      res := res || jsonb_build_object('provider_stuck', coalesce((res->>'provider_stuck')::int, 0) + 1);
    end if;
    -- 5 failed guest look-ups and exhausted phone codes in the last hour (the guest pages are the property's own)
    select count(*) into fails from guest_lookup_attempts where organization_id=o and not ok and created_at > now() - interval '1 hour';
    select count(*) into codes from guest_phone_challenges where organization_id=o and attempts >= 5 and verified_at is null and created_at > now() - interval '1 hour';
    if (fails >= 10 or codes >= 3) and fn_monitor_finding(o, null, 'verification_failures', 'organization', o, null,
         'محاولات تحقق فاشلة متكررة في صفحات النزلاء خلال الساعة الأخيرة', jsonb_build_object('failed_lookups', fails, 'exhausted_codes', codes)) then
      res := res || jsonb_build_object('verification_failures', coalesce((res->>'verification_failures')::int, 0) + 1);
    end if;
    -- 7 a staff member refused three times or more in a day
    for x in
      select e.staff_id, sp.full_name, count(*) as n, array_agg(distinct e.context) filter (where e.context is not null) as contexts
        from client_errors e left join staff_profiles sp on sp.id = e.staff_id
       where e.organization_id = o and e.error_code like 'FORBIDDEN%' and e.created_at > now() - interval '1 day' and e.staff_id is not null
       group by e.staff_id, sp.full_name having count(*) >= 3
    loop
      if fn_monitor_finding(o, null, 'out_of_scope', 'staff', x.staff_id, null,
                            coalesce(x.full_name, 'موظف') || ': ' || x.n || ' محاولات مرفوضة خارج صلاحياته خلال يوم',
                            jsonb_build_object('attempts', x.n, 'operations', to_jsonb(coalesce(x.contexts, '{}'::text[])))) then
        res := res || jsonb_build_object('out_of_scope', coalesce((res->>'out_of_scope')::int, 0) + 1);
      end if;
    end loop;
  end loop;
  return jsonb_build_object('ran_at', now(), 'found', res);
end $function$
;
