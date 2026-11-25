-- 0143: mask company VAT number and national address from roles that do not see money,
-- the same way company_name is already masked in fn_reservation_detail__impl.
-- Only the exclusion list changes. Body, signature, grants and branch scoping are kept as live.
CREATE OR REPLACE FUNCTION public.fn_reservation_detail__impl(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when r.branch_id in (select fn_user_branch_ids()) then jsonb_build_object(
    'reservation', case when fn_sees_money() then to_jsonb(r) - 'notes'
                        else to_jsonb(r) - 'notes' - 'total_halalas' - 'paid_halalas' - 'rent_amount_halalas' - 'discount_halalas' - 'addons_halalas' - 'taxes_halalas'
                             - 'balance_due_halalas' - 'deposit_balance_halalas' - 'refunded_halalas' - 'nightly_rate_halalas' - 'payment_status' - 'company_name' - 'company_vat_number' - 'company_address' - 'gov_registration_ref'
                             - 'platform_collects' end,
    'notes', r.notes,
    'source', (select jsonb_build_object('name', name, 'code', code, 'kind', kind) from booking_sources where id = r.source_id),
    'category', (select name_ar from room_categories where id = r.room_category_id),
    'room', (select jsonb_build_object('id', id, 'room_number', room_number, 'status', status, 'cleanliness', cleanliness) from rooms where id = r.room_id),
    'guests', case when fn_sees_money() then (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'is_primary', g.is_primary, 'full_name', g.full_name,
                 'identity_type', g.identity_type, 'identity_number_last4', g.identity_number_last4, 'nationality', g.nationality,
                 'phone', case when fn_has_role('owner','manager','supervisor') then g.phone end, 'relationship', g.relationship, 'birth_date', case when fn_has_role('owner','manager','supervisor') then g.birth_date end,
                 'verification_status', g.verification_status, 'data_submitted', g.data_submitted, 'entry_path', g.entry_path,
                 'verified_at', g.verified_at, 'verified_by', (select full_name from staff_profiles where id = g.verified_by),
                 'profile_id', g.guest_profile_id,
                 'profile_mismatch', exists (select 1 from guest_profiles gp where gp.id = g.guest_profile_id and gp.identity_fingerprint is not null
                                              and g.identity_fingerprint is not null and gp.identity_fingerprint <> g.identity_fingerprint)) order by g.is_primary desc, g.created_at), '[]'::jsonb)
               from reservation_guests g where g.reservation_id = r.id) end,
    'bans', case when fn_has_role('owner','manager','supervisor') then fn_reservation_ban_matches(r.id) end,
    'guest_profile', case when fn_has_role('owner','manager','supervisor') then (select jsonb_build_object('id', gp.id, 'rating', gp.rating, 'rating_note', gp.rating_note,
                        'rated_at', gp.rated_at, 'rated_by', (select full_name from staff_profiles where id = gp.rated_by),
                        'stays', (select count(distinct g2.reservation_id) from reservation_guests g2 where g2.guest_profile_id = gp.id))
                      from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id where g.reservation_id = r.id and g.is_primary order by g.created_at limit 1) end,
    'hold', case when coalesce(r.security_hold, false) then jsonb_build_object('reason', r.security_hold_reason, 'at', r.security_hold_at,
                                                                              'by', (select full_name from staff_profiles where id = r.security_hold_by)) end,
    'platform', case when exists (select 1 from booking_sources s where s.id = r.source_id and s.kind = 'external') then jsonb_build_object(
                  'booked_on', r.platform_booked_on, 'collects', case when fn_sees_money() then r.platform_collects end,
                  'verified_at', r.platform_verified_at, 'verified_by', (select full_name from staff_profiles where id = r.platform_verified_by),
                  'cancel_reference', r.cancel_reference) end,
    'acknowledgements', case when fn_sees_money() then fn_ack_list(r.id) end,
    'allocations', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'room_number', rm.room_number, 'from_date', a.from_date, 'to_date', a.to_date, 'status', a.status, 'reason', a.reason, 'created_at', a.created_at) order by a.from_date, a.created_at), '[]'::jsonb)
                    from reservation_allocations a join rooms rm on rm.id = a.room_id where a.reservation_id = r.id),
    'charges', case when fn_sees_money() then
                 (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('invoiced_halalas', coalesce((
                      select sum((l->>'amount_halalas')::bigint) from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
                       where i.reservation_id = r.id and i.status = 'issued' and (l->>'charge_id')::uuid = c.id), 0)) order by c.created_at), '[]'::jsonb)
                    from reservation_charges c where c.reservation_id = r.id) end,
    'vouchers', case when fn_sees_money() then
                 (select coalesce(jsonb_agg((to_jsonb(v) - 'content_hash') || jsonb_build_object(
                      'created_by_name', (select full_name from staff_profiles where id = v.created_by),
                      'original_number', (select number from financial_vouchers o where o.id = v.original_voucher_id),
                      'replaced_by_number', (select x.number from financial_vouchers x where x.original_voucher_id = v.id order by x.created_at desc limit 1))
                    order by v.occurred_at), '[]'::jsonb) from financial_vouchers v where v.reservation_id = r.id) end,
    'invoices', case when fn_sees_money() then
                 (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number, 'status', i.status, 'scope', i.scope, 'origin', i.origin, 'version', i.version,
                      'subtotal_halalas', i.subtotal_halalas, 'tax_halalas', i.tax_halalas, 'total_halalas', i.total_halalas,
                      'issued_at', i.issued_at, 'issued_by', (select full_name from staff_profiles where id = i.issued_by),
                      'updated_at', i.updated_at, 'updated_by', (select full_name from staff_profiles where id = i.updated_by),
                      'cancelled_at', i.cancelled_at, 'cancel_reason', i.cancel_reason,
                      'period_from', i.period_from, 'period_to', i.period_to, 'bill_to', i.bill_to, 'lines', i.snapshot->'lines', 'versions', i.versions)
                    order by i.issued_at), '[]'::jsonb) from invoices i where i.reservation_id = r.id) end,
    'invoicing', case when fn_sees_money() then jsonb_build_object('uninvoiced_halalas', fn_uninvoiced_value(r.id)) end,
    'finance', case when fn_sees_money() then fn_reservation_finance_internal(r.id) end,
    'history', case when fn_has_role('owner','manager','supervisor') then (select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'at', e.created_at, 'actor', (select full_name from staff_profiles where id = e.actor_id), 'details', case when fn_history_details_allowed(true) then e.details else jsonb_build_object('reason', e.details->'reason') end) order by e.created_at desc), '[]'::jsonb)
                from (select * from audit_events where entity_id = r.id order by created_at desc limit 50) e) end
  ) end
  from reservations r where r.id = p_reservation;
$function$;
