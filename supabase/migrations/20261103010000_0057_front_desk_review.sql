-- 0057 — Phase 3a of the 31 October review: the front desk, as the owner decided it (1 November 2026).
--
-- FRONT-08 (recommended): a booking whose whole stay is already past is refused, unless the owner, a manager or a
--   supervisor enters it late with a reason (recorded in the audit trail).
-- FRONT-09 (recommended): a cancelled, rejected or no-show booking owes nothing on the lists; «مقيم في يوم» lists the
--   stays that were or are in a unit that day, including a guest past their departure who has not left.
-- FRONT-16 (recommended): a key-box code of one repeated digit or a straight run («1111», «1234», «9876») is refused.

-- ---------------------------------------------------------------------------------------------- FRONT-09 the list
CREATE OR REPLACE FUNCTION public.fn_reservation_list(p_branch uuid, p_filters jsonb DEFAULT '{}'::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  with f as (select coalesce(p_filters, '{}'::jsonb) j, coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh') tz),
  base as (
    select r.*, (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1) as guest_name,
           (select room_number from rooms where id = r.room_id) as room_number, (select name from booking_sources where id = r.source_id) as source_name,
           (select name_ar from room_categories where id = r.room_category_id) as category_name,
           (select full_name from staff_profiles where id = r.created_by) as created_by_name,
           fn_sees_money() as money
    from reservations r, f
    where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
      and (coalesce(f.j->>'status','') = '' or r.status::text = any(string_to_array(f.j->>'status', ',')))
      and (coalesce(f.j->>'open_only','false') <> 'true' or r.status in ('pending_verification','confirmed','checked_in'))
      and (f.j->>'check_in_from' is null or r.check_in >= (f.j->>'check_in_from')::date)
      and (f.j->>'check_in_to' is null or r.check_in <= (f.j->>'check_in_to')::date)
      and (f.j->>'check_out_from' is null or r.check_out >= (f.j->>'check_out_from')::date)
      and (f.j->>'check_out_to' is null or r.check_out <= (f.j->>'check_out_to')::date)
      and (f.j->>'created_from' is null or (r.created_at at time zone f.tz)::date >= (f.j->>'created_from')::date)
      and (f.j->>'created_to' is null or (r.created_at at time zone f.tz)::date <= (f.j->>'created_to')::date)
      -- FRONT-09: «مقيم في يوم» is a stay that was or is in the unit that day — never a cancelled, rejected or no-show
      -- booking; a guest past their departure who has not left is still in house today
      and (f.j->>'stay_on' is null or (r.status not in ('cancelled', 'rejected', 'no_show', 'draft') and r.check_in <= (f.j->>'stay_on')::date
           and (r.check_out > (f.j->>'stay_on')::date or (r.status = 'checked_in' and (f.j->>'stay_on')::date <= fn_branch_today(p_branch)))))
      and (f.j->>'source_id' is null or r.source_id = (f.j->>'source_id')::uuid)
      and (f.j->>'category_id' is null or r.room_category_id = (f.j->>'category_id')::uuid)
      and (f.j->>'room_id' is null or r.room_id = (f.j->>'room_id')::uuid)
      and (coalesce(f.j->>'room_number','') = '' or exists (select 1 from rooms rm where rm.id = r.room_id and rm.room_number = f.j->>'room_number'))
      and (coalesce(f.j->>'booking_type','') = '' or r.booking_type = f.j->>'booking_type')
      and (coalesce(f.j->>'company','') = '' or coalesce(r.company_name,'') ilike '%' || (f.j->>'company') || '%')
      and (coalesce(f.j->>'price_basis','') = '' or r.price_basis = f.j->>'price_basis')
      and (coalesce(f.j->>'payment_status','') = '' or r.payment_status::text = f.j->>'payment_status')
      and (coalesce(f.j->>'identity_status','') = '' or r.identity_status::text = f.j->>'identity_status')
      and (coalesce(f.j->>'access_status','') = '' or r.access_status::text = f.j->>'access_status')
      and (coalesce(f.j->>'group_ref','') = '' or r.group_ref = f.j->>'group_ref')
      and (coalesce(f.j->>'has_discount','false') <> 'true' or r.discount_halalas > 0)
      and (coalesce(f.j->>'platform_collects','') = '' or r.platform_collects = (f.j->>'platform_collects')::boolean)
      and (coalesce(f.j->>'has_balance','false') <> 'true' or (fn_sees_money() and r.balance_due_halalas > 0 and r.status not in ('cancelled', 'rejected', 'no_show')))
      and (coalesce(f.j->>'q','') = '' or r.internal_ref ilike '%' || (f.j->>'q') || '%' or coalesce(r.external_ref,'') ilike '%' || (f.j->>'q') || '%'
           or coalesce(r.cancel_reference,'') ilike '%' || (f.j->>'q') || '%' or coalesce(r.company_name,'') ilike '%' || (f.j->>'q') || '%'
           or exists (select 1 from reservation_guests g where g.reservation_id = r.id and (g.full_name ilike '%' || (f.j->>'q') || '%' or g.phone like '%' || (f.j->>'q') || '%')))
  ),
  ordered as (
    select b.*, row_number() over (order by
      case when (select j->>'sort' from f) = 'check_in_asc' then b.check_in end asc,
      case when (select j->>'sort' from f) = 'check_out' then b.check_out end desc,
      case when (select j->>'sort' from f) = 'created' then b.created_at end desc,
      case when (select j->>'sort' from f) = 'ref' then b.internal_ref end asc,
      b.check_in desc, b.created_at desc) as rn
    from base b)
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'status', status, 'check_in', check_in, 'check_out', check_out,
               'nights', check_out - check_in, 'guest_name', guest_name, 'room_number', room_number, 'source_name', source_name, 'category_name', category_name,
               'booking_type', booking_type, 'company_name', company_name, 'price_basis', price_basis, 'adults', adults, 'companions', companions,
               'platform_booked_on', platform_booked_on, 'platform_collects', platform_collects, 'created_by_name', created_by_name,
               'actual_check_in', actual_check_in, 'actual_check_out', actual_check_out, 'cancelled_at', cancelled_at, 'cancel_reference', cancel_reference,
               'total_halalas', case when money then total_halalas end, 'paid_halalas', case when money then paid_halalas end,
               'discount_halalas', case when money then discount_halalas end, 'nightly_rate_halalas', case when money then nightly_rate_halalas end,
               'balance_due_halalas', case when money then (case when status in ('cancelled', 'rejected', 'no_show') then 0 else balance_due_halalas end) end, 'deposit_balance_halalas', case when money then deposit_balance_halalas end,
               'payment_status', payment_status, 'identity_status', identity_status, 'access_status', access_status, 'created_at', created_at,
               'group_ref', group_ref, 'hold', coalesce(security_hold, false),
               'ban', case when fn_sees_money() then jsonb_array_length(fn_reservation_ban_matches(id)) > 0 end,
               'rating', case when fn_has_role('owner','manager','supervisor') then (select gp.rating from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id
                                                                                     where g.reservation_id = b.id and g.is_primary limit 1) end) order by rn), '[]'::jsonb)
             from (select * from ordered where rn > coalesce(p_offset, 0) and rn <= coalesce(p_offset, 0) + least(greatest(coalesce(p_limit, 50), 1), 1000)) b));
$function$;

-- ---------------------------------------------------------------------------------------------- FRONT-08 past stays
CREATE OR REPLACE FUNCTION public.fn_staff_create_reservation(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare units jsonb := p->'units'; u jsonb; res jsonb; first jsonb; ids jsonb := '[]'::jsonb; refs jsonb := '[]'::jsonb; g text; n int;
        v_today date; v_reason text := nullif(trim(coalesce(p->>'late_entry_reason', '')), ''); v_late boolean := false; x jsonb;
begin
  perform fn_require_cap('res.create');
  -- FRONT-08: a stay that has already ended is a late entry: allowed for the owner, a manager or a supervisor, with a reason
  v_today := fn_branch_today(nullif(p->>'branch_id', '')::uuid);
  for x in select value from jsonb_array_elements(case when jsonb_typeof(units) = 'array' and jsonb_array_length(units) > 0 then units else '[{}]'::jsonb end) loop
    if nullif(coalesce(x->>'check_out', p->>'check_out'), '')::date <= v_today then v_late := true; end if;
  end loop;
  if v_late then
    if v_reason is null then raise exception 'PAST_STAY'; end if;
    if not fn_has_role('owner', 'manager', 'supervisor') then raise exception 'FORBIDDEN: late entry' using errcode = '42501'; end if;
  end if;
  if units is null or jsonb_typeof(units) <> 'array' or jsonb_array_length(units) = 0 then
    res := fn_staff_create_reservation_unit(p, null);
    if v_late then
      perform fn_audit_change(nullif(p->>'branch_id', '')::uuid, 'reservation.late_entry', 'reservation', (res->>'id')::uuid, null,
        jsonb_build_object('check_in', p->>'check_in', 'check_out', p->>'check_out'), v_reason);
    end if;
    return res;
  end if;
  n := jsonb_array_length(units);
  if n > 20 then raise exception 'VALIDATION: too many units'; end if;
  if n > 1 then
    g := 'G-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));
    if nullif(trim(coalesce(p->>'external_ref', '')), '') is not null and to_regclass('public.uniq_reservation_source_ref') is not null then
      raise exception 'GROUP_NUMBER_PENDING_MIGRATION: migration 0039 lets a group share its platform number';
    end if;
  end if;
  for u in select * from jsonb_array_elements(units) loop
    -- unit keys override the booking-level keys (guest, dates, source, notes stay shared)
    res := fn_staff_create_reservation_unit((p - 'units') || u, g);
    if first is null then first := res; end if;
    ids := ids || to_jsonb(res->>'id'); refs := refs || to_jsonb(res->>'internal_ref');
    if v_late then
      perform fn_audit_change(nullif(p->>'branch_id', '')::uuid, 'reservation.late_entry', 'reservation', (res->>'id')::uuid, null,
        jsonb_build_object('check_in', coalesce(u->>'check_in', p->>'check_in'), 'check_out', coalesce(u->>'check_out', p->>'check_out')), v_reason);
    end if;
  end loop;
  return first || jsonb_build_object('ids', ids, 'internal_refs', refs, 'group_ref', g, 'units', n);
end $function$;

-- ---------------------------------------------------------------------------------------------- FRONT-16 weak codes
-- one repeated digit, or every digit one more (or one less) than the one before
create or replace function fn_weak_keybox_code(p text) returns boolean
language plpgsql immutable set search_path = public as $$
declare i int; up boolean := true; dn boolean := true;
begin
  if p is null or length(p) < 2 then return false; end if;
  if p ~ '^(\d)\1+$' then return true; end if;
  for i in 2..length(p) loop
    if substr(p, i, 1)::int <> (substr(p, i - 1, 1)::int + 1) % 10 then up := false; end if;
    if substr(p, i, 1)::int <> (substr(p, i - 1, 1)::int + 9) % 10 then dn := false; end if;
  end loop;
  return up or dn;
end $$;
revoke all on function fn_weak_keybox_code(text) from public, anon, authenticated;

-- every path that writes a new code goes through the key box row: the new code is checked there. Re-encrypting the same
-- code under another key (fn_bootstrap_encryption_keys) is not a new code and is left alone.
create or replace function fn_trg_keybox_code_strength() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_new text; v_old text;
begin
  if new.code_encrypted is null or (tg_op = 'UPDATE' and new.code_encrypted is not distinct from old.code_encrypted) then return new; end if;
  begin v_new := pgp_sym_decrypt(new.code_encrypted, fn_secret('keybox_key')); exception when others then return new; end;
  if tg_op = 'UPDATE' and old.code_encrypted is not null then
    begin v_old := pgp_sym_decrypt(old.code_encrypted, fn_secret('keybox_key')); exception when others then return new; end;
    if v_old = v_new then return new; end if;
  end if;
  if fn_weak_keybox_code(v_new) then raise exception 'VALIDATION: code_weak'; end if;
  return new;
end $$;
revoke all on function fn_trg_keybox_code_strength() from public, anon, authenticated;
create or replace trigger trg_keybox_code_strength before insert or update of code_encrypted on keyboxes
  for each row execute function fn_trg_keybox_code_strength();
