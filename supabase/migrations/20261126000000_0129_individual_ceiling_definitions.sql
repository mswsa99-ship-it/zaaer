-- CANDIDATE (local, unapproved, not applied): individual-account role-ceiling lift for 9 functions (+lookup_trace/set_inventory/release rule etc. per ceiling_candidate_v2) and definitions add/edit/delete page gates.
-- Order: part 1 (ceiling_candidate_v2) then part 2 (definitions_candidate_v3c). Excludes archive_definition, set_room_license, payments, product/expense_category.
-- ===== PART 1: ceiling_candidate_v2 =====
-- LOCAL CANDIDATE ONLY (not wired, not approved). Individual-mode accounts: the page gate in the wrapper is authoritative; legacy accounts keep the exact role list.
create or replace function public.fn_require_role_ind(variadic p_roles role_code[]) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if fn_staff_id() is not null and fn_user_access_mode() = 'individual' then return; end if;
  perform fn_require_role(variadic p_roles);
end $$;
revoke all on function public.fn_require_role_ind(variadic role_code[]) from public, anon;
grant execute on function public.fn_require_role_ind(variadic role_code[]) to authenticated;
CREATE OR REPLACE FUNCTION public.fn_admin_delete_definition__impl(p_entity text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare deps jsonb; v_branch uuid; v_table text; before jsonb;
begin
  perform fn_require_role_ind('owner','manager');
  v_table := case p_entity when 'branch' then 'branches' when 'block' then 'blocks' when 'floor' then 'floors' when 'room_category' then 'room_categories'
                           when 'room' then 'rooms' when 'facility' then 'facilities' when 'task_type' then 'task_types' when 'service' then 'service_definitions' end;
  if v_table is null then raise exception 'VALIDATION: entity'; end if;
  execute format('select %s, to_jsonb(t) from %I t where id = $1 for update', case when p_entity = 'branch' then 'id' else 'branch_id' end, v_table) into v_branch, before using p_id;
  if before is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  if p_entity = 'branch' then perform fn_require_role('owner'); end if;
  deps := fn_definition_dependencies(p_entity, p_id);
  if fn_dependency_total(deps) > 0 then
    return jsonb_build_object('ok', false, 'error', 'HAS_DEPENDENCIES', 'dependencies', deps);
  end if;
  if p_entity = 'task_type' and (before->>'code') is not null then return jsonb_build_object('ok', false, 'error', 'SYSTEM_DEFINITION'); end if;
  -- audit first: the audit row must survive the entity
  perform fn_audit_change(v_branch, p_entity || '.deleted', p_entity, p_id, before, null);
  if p_entity = 'branch' then delete from task_types where branch_id = p_id and code is not null; end if;   -- the auto-seeded system type is not user data
  execute format('delete from %I where id = $1', v_table) using p_id;
  return jsonb_build_object('ok', true);
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_admin_set_inventory__impl(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare iv inventory_periods%rowtype; before jsonb; v_total int; v_pub int; v_blk int; v_units int; k text;
begin
  perform fn_require_role_ind('owner', 'manager');
  select * into iv from inventory_periods where id = (p->>'id')::uuid for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(iv.branch_id);
  foreach k in array array['total_units', 'publicly_visible_units', 'blocked_units'] loop
    if p ? k and coalesce(p->>k, '') !~ '^[0-9]{1,5}$' then raise exception 'VALIDATION: inventory'; end if;
  end loop;
  v_total := coalesce((p->>'total_units')::int, iv.total_units);
  v_pub := coalesce((p->>'publicly_visible_units')::int, iv.publicly_visible_units);
  v_blk := coalesce((p->>'blocked_units')::int, iv.blocked_units);
  v_units := fn_category_units(iv.category_id);
  if v_total > v_units then raise exception 'INVENTORY_OVER_UNITS: %', v_units; end if;
  if v_blk > v_total then raise exception 'VALIDATION: inventory_blocked'; end if;
  if v_pub > v_total - v_blk then raise exception 'VALIDATION: inventory_public'; end if;
  before := jsonb_build_object('total_units', iv.total_units, 'publicly_visible_units', iv.publicly_visible_units, 'blocked_units', iv.blocked_units);
  if v_total = iv.total_units and v_pub = iv.publicly_visible_units and v_blk = iv.blocked_units then
    return jsonb_build_object('ok', true, 'unchanged', true);
  end if;
  update inventory_periods set total_units = v_total, publicly_visible_units = v_pub, blocked_units = v_blk where id = iv.id;
  perform fn_audit_change(iv.branch_id, 'inventory.updated', 'inventory_period', iv.id, before || jsonb_build_object('date', iv.date, 'category_id', iv.category_id),
    jsonb_build_object('total_units', v_total, 'publicly_visible_units', v_pub, 'blocked_units', v_blk), nullif(trim(coalesce(p->>'reason', '')), ''));
  return jsonb_build_object('ok', true, 'unchanged', false);
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_admin_upsert_release_rule__impl(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rr release_rules%rowtype; before jsonb; v_cat uuid; v_branch uuid; v_units int; v_init int; v_inc int; v_trig text; v_en boolean;
begin
  perform fn_require_role_ind('owner', 'manager');
  if (p->>'id') is not null then
    select * into rr from release_rules where id = (p->>'id')::uuid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_cat := rr.category_id; v_branch := rr.branch_id;
  else
    v_cat := (p->>'category_id')::uuid;
    select branch_id into v_branch from room_categories where id = v_cat and archived_at is null;
    if v_branch is null then raise exception 'NOT_FOUND: category'; end if;
    if exists (select 1 from release_rules where category_id = v_cat) then raise exception 'DUPLICATE_RULE'; end if;
  end if;
  perform fn_require_branch(v_branch);
  if (p ? 'initial_public_release' and coalesce(p->>'initial_public_release', '') !~ '^[0-9]{1,5}$')
     or (p ? 'release_increment' and coalesce(p->>'release_increment', '') !~ '^[0-9]{1,5}$') then raise exception 'VALIDATION: release_rule'; end if;
  v_init := coalesce((p->>'initial_public_release')::int, rr.initial_public_release, 1);
  v_inc := coalesce((p->>'release_increment')::int, rr.release_increment, 1);
  v_trig := coalesce(nullif(p->>'release_trigger', ''), rr.release_trigger, 'access_delivered');
  v_en := coalesce((p->>'enabled')::boolean, rr.enabled, false);
  v_units := fn_category_units(v_cat);
  if v_trig not in ('access_delivered', 'confirmed', 'manual') then raise exception 'VALIDATION: release_trigger'; end if;
  if v_init > v_units then raise exception 'INVENTORY_OVER_UNITS: %', v_units; end if;
  if v_inc < 1 or v_inc > greatest(v_units, 1) then raise exception 'VALIDATION: release_increment'; end if;
  if rr.id is null then
    insert into release_rules(branch_id, category_id, enabled, initial_public_release, release_increment, release_trigger)
    values (v_branch, v_cat, v_en, v_init, v_inc, v_trig) returning * into rr;
    perform fn_audit_change(v_branch, 'release_rule.created', 'release_rule', rr.id, null, to_jsonb(rr), null);
  else
    before := to_jsonb(rr);
    update release_rules set enabled = v_en, initial_public_release = v_init, release_increment = v_inc, release_trigger = v_trig
    where id = rr.id returning * into rr;
    if to_jsonb(rr) is distinct from before then
      perform fn_audit_change(v_branch, 'release_rule.updated', 'release_rule', rr.id, before, to_jsonb(rr), nullif(trim(coalesce(p->>'reason', '')), ''));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', rr.id);
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_lookup_trace__impl(p_trace text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := fn_user_org_id();
begin
  perform fn_require_role_ind('owner','manager');
  if p_trace is null or p_trace !~ '^[A-Za-z0-9_-]{6,64}$' then raise exception 'VALIDATION: trace'; end if;
  return jsonb_build_object(
    'failure', (select (to_jsonb(e) - 'organization_id') || jsonb_build_object('staff_name', sp.full_name)
                  from client_errors e left join staff_profiles sp on sp.id = e.staff_id
                 where e.organization_id = v_org and e.trace_id = p_trace),
    'events', coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'entity_type', a.entity_type, 'entity_id', a.entity_id,
                                                            'actor_id', a.actor_id, 'actor_name', sp.full_name, 'source', a.source,
                                                            'result', a.result, 'created_at', a.created_at) order by a.created_at)
                         from audit_events a left join staff_profiles sp on sp.id = a.actor_id
                        where a.organization_id = v_org and a.correlation_id = p_trace
                          and (a.category <> 'security' or fn_has_role('owner'))), '[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_reports_late_entries__impl(p_branch uuid, p_from date, p_to date, p_min_days integer, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_source uuid;
begin
  perform fn_require_role_ind('owner', 'manager');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_staff := (f->>'staff_id')::uuid; v_source := (f->>'source_id')::uuid;
  return (with x as (
    select r.id, r.internal_ref, r.external_ref, s.name as source_name, r.platform_booked_on, (r.created_at at time zone tz)::date as entered_on,
           r.created_at, r.check_in, r.status, (select full_name from staff_profiles where id = r.created_by) as created_by
    from reservations r join booking_sources s on s.id = r.source_id and s.kind = 'external'
    where r.branch_id = p_branch and r.platform_booked_on is not null and (r.created_at at time zone tz)::date between p_from and p_to
      and (v_staff is null or r.created_by = v_staff) and (v_source is null or r.source_id = v_source)
  ), late as (select *, entered_on - platform_booked_on as lag_days from x where entered_on - platform_booked_on >= greatest(coalesce(p_min_days, 1), 0))
  select jsonb_build_object(
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'source_id', v_source)),
    'platform_bookings', (select count(*) from x), 'late', (select count(*) from late),
    'after_arrival', (select count(*) from late where entered_on > check_in),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', coalesce(created_by, '—'), 'count', c, 'max_lag', m) order by c desc)
                          from (select created_by, count(*) c, max(lag_days) m from late group by created_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'source_name', source_name,
                                                         'booked_on', platform_booked_on, 'entered_on', entered_on, 'entered_at', created_at, 'lag_days', lag_days,
                                                         'check_in', check_in, 'after_arrival', entered_on > check_in, 'status', status, 'created_by', created_by)
                                      order by lag_days desc, created_at) from late), '[]'::jsonb)));
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_guest_profile__impl(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare gp guest_profiles%rowtype; ban guest_bans%rowtype; v_owner boolean := fn_has_role('owner');
begin
  perform fn_require_role_ind('owner', 'manager', 'supervisor');
  select * into gp from guest_profiles where id = p_id and organization_id = fn_user_org_id();
  if not found or not fn_profile_visible(gp.id) then raise exception 'NOT_FOUND'; end if;
  select * into ban from fn_profile_banned(gp.id);
  return jsonb_build_object(
    'profile', jsonb_build_object('id', gp.id, 'full_name', gp.full_name, 'phone', gp.phone, 'nationality', gp.nationality, 'email', gp.email,
                                  'identity_type', gp.identity_type, 'identity_last4', gp.identity_last4, 'rating', gp.rating, 'rating_note', gp.rating_note,
                                  'rated_at', gp.rated_at, 'rated_by', (select full_name from staff_profiles where id = gp.rated_by), 'created_at', gp.created_at),
    'ban', case when ban.id is not null then jsonb_build_object('id', ban.id, 'reason', ban.reason, 'since', ban.created_at, 'own', ban.guest_profile_id = gp.id,
                                                              'by', (select full_name from staff_profiles where id = ban.created_by)) end,
    'ban_history', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'reason', b.reason, 'since', b.created_at, 'by', (select full_name from staff_profiles where id = b.created_by),
                                                                'lifted_at', b.lifted_at, 'lifted_by', (select full_name from staff_profiles where id = b.lifted_by), 'lift_reason', b.lift_reason)
                                            order by b.created_at desc) from guest_bans b where b.guest_profile_id = gp.id), '[]'::jsonb),
    'stays', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'status', r.status,
                                                          'check_in', r.check_in, 'check_out', r.check_out, 'branch_name', b.name_ar, 'is_primary', g.is_primary,
                                                          'room_number', (select room_number from rooms where id = r.room_id),
                                                          'category_name', (select name_ar from room_categories where id = r.room_category_id),
                                                          'source_name', (select name from booking_sources where id = r.source_id)) order by r.check_in desc)
                       from reservation_guests g join reservations r on r.id = g.reservation_id join branches b on b.id = r.branch_id
                       where g.guest_profile_id = gp.id and (v_owner or r.branch_id in (select fn_user_branch_ids()))), '[]'::jsonb),
    'duplicates', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'full_name', o.full_name,
                                                               'match', case when o.identity_fingerprint is not null and o.identity_fingerprint = gp.identity_fingerprint then 'identity' else 'phone' end,
                                                               'stays', (select count(distinct g.reservation_id) from reservation_guests g where g.guest_profile_id = o.id)))
                            from guest_profiles o where o.organization_id = gp.organization_id and o.id <> gp.id
                              and ((fn_normalize_phone(o.phone) is not null and fn_normalize_phone(o.phone) = fn_normalize_phone(gp.phone))
                                   or (o.identity_fingerprint is not null and o.identity_fingerprint = gp.identity_fingerprint))), '[]'::jsonb),
    'can_ban', fn_has_role('owner', 'manager'));
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_guest_profiles__impl(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare q text := nullif(trim(coalesce(p->>'q', '')), ''); v_filter text := coalesce(nullif(p->>'filter', ''), 'all');
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        digits text; fps text[] := '{}'; v_org uuid := fn_user_org_id(); v_owner boolean := fn_has_role('owner'); res jsonb;
        v_name boolean;   -- OWNER-12: three letters or more of a name also find the near names
begin
  perform fn_require_role_ind('owner', 'manager', 'supervisor');
  if v_filter not in ('all', 'banned', 'duplicates', 'rated', 'low', 'incomplete') then raise exception 'VALIDATION: filter'; end if;
  if q is not null then
    digits := regexp_replace(translate(q, '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g');
    v_name := length(regexp_replace(q, '[\d\s\W]', '', 'g')) >= 3;
    if q ~ '^[A-Za-z0-9]{5,15}$' then
      fps := array[fn_identity_fingerprint('national_id', q), fn_identity_fingerprint('passport', q), fn_identity_fingerprint('gcc_id', q)];
    end if;
  end if;
  with qm as (                                    -- the profiles a search matches, found once as a set (not per profile)
    select gp.id from guest_profiles gp
    where q is not null and gp.organization_id = v_org
      and (gp.full_name ilike '%' || q || '%'
           or (length(digits) >= 4 and regexp_replace(coalesce(gp.phone, ''), '\D', '', 'g') like '%' || digits || '%')
           or (length(digits) = 4 and gp.identity_last4 = digits)
           or gp.identity_fingerprint = any(fps)
           or (v_name and replace(fn_name_norm(gp.full_name), ' ', '') like '%' || replace(fn_name_norm(q), ' ', '') || '%'))   -- «عبد الله» = «عبدالله»
    union
    select g.guest_profile_id from reservation_guests g join reservations r on r.id = g.reservation_id
    where q is not null and r.organization_id = v_org and g.guest_profile_id is not null
      and (g.identity_fingerprint = any(fps) or (length(digits) = 4 and g.identity_number_last4 = digits)
           or r.internal_ref ilike q or r.external_ref ilike q)
  ), qn as (                                      -- OWNER-12: the near names (a letter or two apart), when a name is typed
                                                  -- (the «all» list only: a filter is a work list, exact matches only)
    select gp.id, fn_name_closeness(gp.full_name, q) as closeness from guest_profiles gp
    where v_name and v_filter = 'all' and gp.organization_id = v_org and gp.id not in (select id from qm) and fn_name_closeness(gp.full_name, q) >= 0.3
  ), org as (                                     -- every profile of the organisation, its phone normalised once, and its
    select gp.*, fn_normalize_phone(gp.phone) as np  -- possible duplicates as window counts over all of them (same phone +
    from guest_profiles gp where gp.organization_id = v_org   -- same document − both; never merged, never a self-join)
  ), counted as (
    select o.*,
           case when np is null then 0 else count(*) over (partition by np) - 1 end
         + case when identity_fingerprint is null then 0 else count(*) over (partition by identity_fingerprint) - 1 end
         - case when np is null or identity_fingerprint is null then 0 else count(*) over (partition by np, identity_fingerprint) - 1 end as duplicates
    from org o
  ), prof as (                                    -- stays and last arrival by index, profile by profile
    select c.*,
           (select count(distinct g.reservation_id) from reservation_guests g where g.guest_profile_id = c.id) as stays,
           (select max(r.check_in) from reservation_guests g join reservations r on r.id = g.reservation_id where g.guest_profile_id = c.id) as last_check_in,
           (c.phone is null or c.identity_fingerprint is null) as incomplete
    from counted c
    where (v_owner or exists (select 1 from reservation_guests g join reservations r on r.id = g.reservation_id
                               where g.guest_profile_id = c.id and r.branch_id in (select fn_user_branch_ids())))
      and (q is null or c.id in (select id from qm) or c.id in (select id from qn))
  ), f as (
    select * from prof
    where v_filter = 'all' or (v_filter = 'duplicates' and duplicates > 0) or (v_filter = 'incomplete' and incomplete)
       or (v_filter = 'rated' and rating is not null) or (v_filter = 'low' and rating <= 2)
       or (v_filter = 'banned' and exists (select 1 from fn_profile_banned(prof.id) b where b.id is not null))
  ), pg as (
    select f.*, (select b.reason from fn_profile_banned(f.id) b where b.id is not null) as ban_reason,
           (select closeness from qn where qn.id = f.id) as near
    from f order by (select closeness from qn where qn.id = f.id) nulls first, (select closeness from qn where qn.id = f.id) desc,
                    last_check_in desc nulls last, created_at desc, id limit v_limit offset v_offset
  )
  select jsonb_build_object('total', (select count(*) from f), 'near', (select count(*) from f where f.id in (select id from qn)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'phone_masked', fn_mask_phone(phone), 'nationality', nationality,
                                                         'identity_type', identity_type, 'identity_last4', identity_last4, 'rating', rating, 'rating_note', rating_note,
                                                         'stays', stays, 'last_check_in', last_check_in, 'banned', ban_reason is not null, 'ban_reason', ban_reason,
                                                         'duplicates', duplicates, 'incomplete', incomplete, 'created_at', created_at, 'near', near is not null)
                                      order by near nulls first, near desc, last_check_in desc nulls last, created_at desc, id)
                      from pg), '[]'::jsonb))
  into res;
  return res;
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_platform_check_list__impl(p_branch uuid, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d date;
begin
  perform fn_require_role_ind('owner', 'manager', 'supervisor');
  perform fn_require_branch(p_branch);
  d := coalesce(p_date, fn_branch_today(p_branch));
  return jsonb_build_object('date', d, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'source_name', s.name, 'source_code', s.code, 'status', r.status,
             'check_in', r.check_in, 'check_out', r.check_out, 'nights', r.check_out - r.check_in, 'guests', r.adults + r.companions,
             'guest_name', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary order by g.created_at limit 1),
             'group_ref', r.group_ref, 'platform_collects', r.platform_collects, 'platform_booked_on', r.platform_booked_on,
             'total_halalas', r.total_halalas, 'paid_halalas', r.paid_halalas, 'cancel_reference', r.cancel_reference,
             'verified_at', r.platform_verified_at, 'verified_by', (select full_name from staff_profiles where id = r.platform_verified_by))
           order by r.check_in, s.name, r.external_ref, r.internal_ref)
    from reservations r join booking_sources s on s.id = r.source_id and s.kind = 'external'
    where r.branch_id = p_branch and r.check_in between d and d + 1 and r.status not in ('draft', 'rejected')), '[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_platform_mark_checked__impl(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; v_checked boolean := coalesce((p->>'checked')::boolean, true); n int;
begin
  perform fn_require_role_ind('owner', 'manager', 'supervisor');
  select * into r from reservations where id = (p->>'reservation_id')::uuid;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if not exists (select 1 from booking_sources s where s.id = r.source_id and s.kind = 'external') then raise exception 'VALIDATION: not_platform'; end if;
  update reservations set platform_verified_at = case when v_checked then now() end, platform_verified_by = case when v_checked then fn_staff_id() end, updated_at = now()
   where organization_id = r.organization_id and branch_id in (select fn_user_branch_ids()) and (id = r.id or (r.group_ref is not null and group_ref = r.group_ref));
  get diagnostics n = row_count;
  perform fn_audit_change(r.branch_id, case when v_checked then 'reservation.platform_checked' else 'reservation.platform_unchecked' end, 'reservation', r.id, null,
                          jsonb_build_object('units', n, 'external_ref', r.external_ref));
  return jsonb_build_object('ok', true, 'units', n);
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_staff_release_next_slot__impl(p_branch uuid, p_category uuid, p_date date, p_reason text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare n int;
begin
  perform fn_require_role_ind('owner','manager');
  perform fn_require_branch(p_branch);
  if coalesce(trim(p_reason),'') = '' then raise exception 'REASON_REQUIRED'; end if;
  n := fn_release_next_slot(p_branch, p_category, p_date);
  perform fn_audit(fn_user_org_id(), p_branch, fn_staff_id(), 'manual_release_slot', 'release_rule', p_category,
                   jsonb_build_object('date', p_date, 'reason', p_reason, 'released', n));
  return n;
end $function$
;

-- ===== PART 2: definitions_candidate_v3c =====
-- LOCAL CANDIDATE v3 ONLY (unapproved, not wired). Operation-aware: create (no id in payload) needs page 'add', update needs page 'edit'.
-- Legacy/owner keep fn_require_cap('definitions'). Delete needs the ENTITY's own page 'delete'; archive/restore needs entity page 'edit'.
create or replace function public.fn_definition_entity_page(p_entity text) returns text language sql immutable set search_path = public as $$
  select case p_entity when 'block' then '/admin/structure' when 'floor' then '/admin/structure' when 'room' then '/admin/rooms'
    when 'room_category' then '/admin/room-categories' when 'facility' then '/admin/facilities' when 'service' then '/admin/services'
    when 'task_type' then '/admin/task-types' when 'branch' then '/admin/branches' else null end $$;
create or replace function public.fn_require_definition_page(p_page text, p_action text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_action not in ('add','edit','delete','view') then raise exception 'FORBIDDEN: definitions' using errcode='42501'; end if;
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual' then
    if p_page is null then raise exception 'FORBIDDEN: definitions' using errcode='42501'; end if;
    perform fn_require_user_page(p_page, p_action);
  else
    perform fn_require_cap('definitions');
  end if;
end $$;
revoke all on function public.fn_require_definition_page(text,text) from public, anon;
grant execute on function public.fn_require_definition_page(text,text) to authenticated;
revoke all on function public.fn_definition_entity_page(text) from public, anon; grant execute on function public.fn_definition_entity_page(text) to authenticated;
create or replace function public.fn_require_definition_entity_view(p_entity text) returns void
language plpgsql stable security definer set search_path = public as $$
begin perform fn_require_definition_page(fn_definition_entity_page(p_entity),'view'); end $$;
revoke all on function public.fn_require_definition_entity_view(text) from public, anon;
grant execute on function public.fn_require_definition_entity_view(text) to authenticated;
-- delete wrapper: entity page delete (legacy accounts: fn_require_user_page returns true for them, unchanged)
create or replace function public.fn_admin_delete_definition(p_entity text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if fn_user_access_mode() = 'individual' and fn_staff_id() is not null and fn_current_role() <> 'owner' then
    perform fn_require_definition_page(fn_definition_entity_page(p_entity),'delete');
  else
    perform fn_require_user_page('/admin/structure','delete');
  end if;
  return public.fn_admin_delete_definition__impl(p_entity,p_id);
end $$;
CREATE OR REPLACE FUNCTION public.fn_admin_upsert_block(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare b blocks%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_definition_page('/admin/structure', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into blocks(organization_id, branch_id, name, description, sort_order, created_by)
    values (fn_user_org_id(), v_branch, trim(p->>'name'), p->>'description', coalesce((p->>'sort_order')::int,0), fn_staff_id()) returning * into b;
    perform fn_audit_change(b.branch_id, 'block.created', 'block', b.id, null, to_jsonb(b));
  else
    select * into b from blocks where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.branch_id);
    perform fn_check_version_strict(b.version, (p->>'version')::int);
    before := to_jsonb(b);
    update blocks set name = trim(p->>'name'), description = p->>'description', sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = b.id returning * into b;
    perform fn_audit_change(b.branch_id, 'block.updated', 'block', b.id, before, to_jsonb(b));
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_floor(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare f floors%rowtype; blk blocks%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb;
begin
  perform fn_require_definition_page('/admin/structure', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    select * into blk from blocks where id = (p->>'block_id')::uuid;
    if not found then raise exception 'NOT_FOUND: block'; end if;
    perform fn_require_branch(blk.branch_id);
    insert into floors(organization_id, branch_id, block_id, name, sort_order)
    values (blk.organization_id, blk.branch_id, blk.id, trim(p->>'name'), coalesce((p->>'sort_order')::int,0)) returning * into f;
    perform fn_audit_change(f.branch_id, 'floor.created', 'floor', f.id, null, to_jsonb(f));
  else
    select * into f from floors where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(f.branch_id);
    perform fn_check_version_strict(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update floors set name = trim(p->>'name'), sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'floor.updated', 'floor', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_room(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r rooms%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid;
        v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; before jsonb; future_count int;
        v_number text := nullif(trim(fn_latin_digits(coalesce(p->>'room_number', ''))), '');
begin
  perform fn_require_definition_page('/admin/rooms', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if v_id is not null then
    select * into r from rooms where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := r.branch_id;
    v_block := coalesce(v_block, r.block_id); v_floor := coalesce(v_floor, r.floor_id); v_cat := coalesce(v_cat, r.category_id);
  end if;
  perform fn_require_branch(v_branch);
  if v_number is null and v_id is null then raise exception 'VALIDATION: room_number'; end if;
  if v_number is not null and char_length(v_number) > 20 then raise exception 'VALIDATION: room_number'; end if;
  -- one number per door: «١٠١» is «101» (SETUP-06)
  if v_number is not null and exists (select 1 from rooms where branch_id = v_branch and fn_latin_digits(room_number) = v_number and id is distinct from v_id) then
    raise exception 'DUPLICATE_ROOM_NUMBER';
  end if;
  -- cross-relation consistency: every parent must belong to the same branch (A02)
  if v_cat is null or not exists (select 1 from room_categories where id = v_cat and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_block is not null and not exists (select 1 from blocks where id = v_block and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if v_floor is not null and not exists (select 1 from floors where id = v_floor and branch_id = v_branch and (v_block is null or block_id = v_block)) then raise exception 'BRANCH_MISMATCH: floor'; end if;

  if v_id is null then
    insert into rooms(organization_id, branch_id, category_id, block_id, floor_id, room_number, floor, status, notes, is_active)
    values (fn_user_org_id(), v_branch, v_cat, v_block, v_floor, v_number, coalesce((p->>'floor')::int,1), 'available', p->>'notes', coalesce((p->>'is_active')::boolean, true))
    returning * into r;
    perform fn_audit_change(r.branch_id, 'room.created', 'room', r.id, null, to_jsonb(r));
  else
    perform fn_check_version_strict(r.version, (p->>'version')::int);
    before := to_jsonb(r);
    -- deactivating a room with a guest in house, or future/active commitments, is blocked until they are resolved (A09 / G17)
    if (p->>'is_active')::boolean is false and r.is_active then
      if fn_room_guest_in_house(r.id) then raise exception 'ROOM_HAS_GUEST: a guest is in house'; end if;
      select count(*) into future_count from reservation_allocations a join reservations rs on rs.id = a.reservation_id
        where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(r.branch_id);
      if future_count > 0 then
        raise exception 'HAS_FUTURE_COMMITMENTS: % allocation(s)', future_count;
      end if;
    end if;
    update rooms set room_number = coalesce(v_number, room_number), category_id = v_cat, block_id = v_block, floor_id = v_floor,
      floor = coalesce((p->>'floor')::int, floor), notes = coalesce(p->>'notes', notes), is_active = coalesce((p->>'is_active')::boolean, is_active),
      status = case when coalesce((p->>'is_active')::boolean, is_active) = false then 'out_of_service'
                    when coalesce((p->>'is_active')::boolean, is_active) and status = 'out_of_service' then 'available' else status end,
      version = version + 1, updated_at = now()
    where id = r.id returning * into r;
    perform fn_audit_change(r.branch_id, 'room.updated', 'room', r.id, before, to_jsonb(r));
  end if;
  return jsonb_build_object('ok', true, 'id', r.id, 'version', r.version);
exception when unique_violation then raise exception 'DUPLICATE_ROOM_NUMBER';
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_room_category(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c room_categories%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb; affected int := 0; low int;
begin
  perform fn_require_definition_page('/admin/room-categories', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (v_id is null and nullif(p->>'base_price_halalas', '') is null)
     or (nullif(p->>'base_price_halalas', '') is not null and (p->>'base_price_halalas')::bigint <= 0) then raise exception 'VALIDATION: base_price'; end if;
  if (nullif(p->>'weekly_price_halalas', '')::bigint <= 0) or (nullif(p->>'monthly_price_halalas', '')::bigint <= 0)
     or (nullif(p->>'min_nightly_halalas', '')::bigint <= 0) then raise exception 'VALIDATION: amount'; end if;
  if nullif(p->>'base_price_halalas', '')::bigint > 100000000 or nullif(p->>'min_nightly_halalas', '')::bigint > 100000000
     or nullif(p->>'weekly_price_halalas', '')::bigint > 700000000 or nullif(p->>'monthly_price_halalas', '')::bigint > 3000000000 then
    raise exception 'VALIDATION: amount_too_large';
  end if;
  if (p ? 'price_mode') and p->>'price_mode' not in ('unified', 'by_channel') then raise exception 'VALIDATION: price_mode'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into room_categories(organization_id, branch_id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, amenities, is_public, sort_order,
                                weekly_price_halalas, monthly_price_halalas, min_nightly_halalas, price_mode)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', coalesce((p->>'base_capacity')::int,2), coalesce((p->>'max_capacity')::int,4),
            (p->>'base_price_halalas')::bigint, coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'amenities','[]'::jsonb)) x), '{}'),
            coalesce((p->>'is_public')::boolean, true), coalesce((p->>'sort_order')::int, 0),
            nullif(p->>'weekly_price_halalas', '')::bigint, nullif(p->>'monthly_price_halalas', '')::bigint, nullif(p->>'min_nightly_halalas', '')::bigint,
            coalesce(p->>'price_mode', 'unified')) returning * into c;
    perform fn_audit_change(c.branch_id, 'room_category.created', 'room_category', c.id, null, to_jsonb(c));
  else
    select * into c from room_categories where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(c.branch_id);
    perform fn_check_version_strict(c.version, (p->>'version')::int);
    before := to_jsonb(c);
    -- changing a price never reprices existing reservations (their nights and charges are snapshots)
    update room_categories set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      base_capacity = coalesce((p->>'base_capacity')::int, base_capacity), max_capacity = coalesce((p->>'max_capacity')::int, max_capacity),
      base_price_halalas = coalesce(nullif(p->>'base_price_halalas', '')::bigint, base_price_halalas),
      weekly_price_halalas = case when p ? 'weekly_price_halalas' then nullif(p->>'weekly_price_halalas', '')::bigint else weekly_price_halalas end,
      monthly_price_halalas = case when p ? 'monthly_price_halalas' then nullif(p->>'monthly_price_halalas', '')::bigint else monthly_price_halalas end,
      min_nightly_halalas = case when p ? 'min_nightly_halalas' then nullif(p->>'min_nightly_halalas', '')::bigint else min_nightly_halalas end,
      price_mode = coalesce(p->>'price_mode', price_mode),
      amenities = case when p ? 'amenities' then (select array_agg(x) from jsonb_array_elements_text(p->'amenities') x) else amenities end,
      is_public = coalesce((p->>'is_public')::boolean, is_public), is_active = coalesce((p->>'is_active')::boolean, is_active),
      sort_order = coalesce((p->>'sort_order')::int, sort_order), version = version + 1, updated_at = now()
    where id = c.id returning * into c;
    if c.max_capacity < c.base_capacity then raise exception 'VALIDATION: capacity'; end if;
    if c.max_capacity < (before->>'max_capacity')::int then
      affected := jsonb_array_length(fn_category_capacity_impact(c.id, c.max_capacity));
    end if;
  end if;
  -- no nightly price of the type under its minimum: the base price, the weekly and monthly prices per night, and the
  -- calendar's coming nights (decision 33: «ولا سعر تحت الأدنى»)
  if c.min_nightly_halalas is not null then
    if c.base_price_halalas < c.min_nightly_halalas
       or (c.weekly_price_halalas is not null and c.weekly_price_halalas::numeric / 7 < c.min_nightly_halalas)
       or (c.monthly_price_halalas is not null and c.monthly_price_halalas::numeric / 30 < c.min_nightly_halalas) then
      raise exception 'VALIDATION: below_minimum';
    end if;
    select count(*) into low from rate_calendar rc
    where rc.category_id = c.id and rc.night >= fn_branch_today(c.branch_id)
      and (rc.price_halalas < c.min_nightly_halalas or (c.price_mode = 'by_channel' and rc.platform_price_halalas < c.min_nightly_halalas));
    if low > 0 then raise exception 'VALIDATION: calendar_below_minimum'; end if;
  end if;
  if v_id is not null then
    perform fn_audit_change(c.branch_id, 'room_category.updated', 'room_category', c.id, before, to_jsonb(c) || jsonb_build_object('stays_over_capacity', affected));
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version, 'stays_over_capacity', affected);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_category_capacity_impact(p_category uuid, p_max_capacity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c room_categories%rowtype;
begin
  perform fn_require_definition_page('/admin/room-categories','edit');
  select * into c from room_categories where id = p_category;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(c.branch_id);
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'check_in', r.check_in, 'check_out', r.check_out,
                                                       'guests', r.adults + r.companions, 'status', r.status) order by r.check_in)
                   from reservations r
                   where r.room_category_id = c.id and r.status in ('pending_verification', 'confirmed', 'checked_in')
                     and r.check_out > fn_branch_today(c.branch_id) and r.adults + r.companions > p_max_capacity), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_facility(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare f facilities%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; before jsonb;
begin
  perform fn_require_definition_page('/admin/facilities', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is not null then
    select * into f from facilities where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := f.branch_id;
    if p ? 'block_id' then v_block := (p->>'block_id')::uuid; else v_block := f.block_id; end if;
    if p ? 'floor_id' then v_floor := (p->>'floor_id')::uuid; else v_floor := f.floor_id; end if;
  end if;
  perform fn_require_branch(v_branch);
  if v_block is not null and not exists (select 1 from blocks where id = v_block and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if v_floor is not null and not exists (select 1 from floors where id = v_floor and branch_id = v_branch and (v_block is null or block_id = v_block)) then raise exception 'BRANCH_MISMATCH: floor'; end if;
  if v_id is null then
    insert into facilities(organization_id, branch_id, block_id, floor_id, name, description, images, created_by)
    values (fn_user_org_id(), v_branch, v_block, v_floor, trim(p->>'name'), p->>'description', coalesce(p->'images','[]'::jsonb), fn_staff_id()) returning * into f;
    perform fn_audit_change(f.branch_id, 'facility.created', 'facility', f.id, null, to_jsonb(f));
  else
    perform fn_check_version_strict(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update facilities set name = trim(p->>'name'), description = p->>'description', block_id = v_block, floor_id = v_floor,
      images = coalesce(p->'images', images), is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'facility.updated', 'facility', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_service(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s service_definitions%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_tt uuid := (p->>'task_type_id')::uuid; before jsonb;
        v_late time; v_unit text; v_free boolean; v_price bigint;
begin
  perform fn_require_definition_page('/admin/services', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if nullif(p->>'price_halalas', '') is not null and (p->>'price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  if nullif(p->>'price_halalas', '')::bigint > 100000000 then raise exception 'VALIDATION: amount_too_large'; end if;
  begin v_late := nullif(trim(coalesce(p->>'late_checkout_until', '')), '')::time; exception when others then raise exception 'VALIDATION: late_checkout_until'; end;
  if v_id is not null then
    select * into s from service_definitions where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := s.branch_id;
    if not (p ? 'task_type_id') then v_tt := s.task_type_id; end if;
    if not (p ? 'late_checkout_until') then v_late := s.late_checkout_until; end if;
  end if;
  perform fn_require_branch(v_branch);
  if v_tt is not null and not exists (select 1 from task_types where id = v_tt and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: task_type'; end if;
  v_unit := coalesce(p->>'billing_unit', s.billing_unit, 'once');
  v_free := coalesce((p->>'is_free')::boolean, s.is_free, false);
  v_price := coalesce(nullif(p->>'price_halalas', '')::bigint, s.price_halalas, 0);
  if not v_free and v_price <= 0 then raise exception 'VALIDATION: service_price'; end if;
  if v_free then v_price := 0; end if;
  if v_late is not null then
    if v_late <= coalesce((select check_out_time from branches where id = v_branch), time '12:00') then raise exception 'VALIDATION: late_checkout_until'; end if;
    if v_unit <> 'once' then raise exception 'VALIDATION: late_checkout_unit'; end if;
  end if;
  if v_id is null then
    insert into service_definitions(organization_id, branch_id, name_ar, name_en, description, billing_unit, price_halalas, is_free, taxable, task_type_id, late_checkout_until)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', v_unit,
            v_price, v_free, coalesce((p->>'taxable')::boolean,true), v_tt, v_late) returning * into s;
    perform fn_audit_change(s.branch_id, 'service.created', 'service', s.id, null, to_jsonb(s));
  else
    perform fn_check_version_strict(s.version, (p->>'version')::int);
    before := to_jsonb(s);
    -- catalogue edits never touch historical reservation_charges (snapshots) — G27
    update service_definitions set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      billing_unit = v_unit, price_halalas = v_price, is_free = v_free, taxable = coalesce((p->>'taxable')::boolean, taxable), task_type_id = v_tt,
      is_active = coalesce((p->>'is_active')::boolean, is_active), late_checkout_until = v_late, version = version + 1, updated_at = now()
    where id = s.id returning * into s;
    perform fn_audit_change(s.branch_id, 'service.updated', 'service', s.id, before, to_jsonb(s));
  end if;
  return jsonb_build_object('ok', true, 'id', s.id, 'version', s.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_task_type(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t task_types%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_definition_page('/admin/task-types', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into task_types(organization_id, branch_id, name, description) values (fn_user_org_id(), v_branch, trim(p->>'name'), p->>'description') returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.created', 'task_type', t.id, null, to_jsonb(t));
  else
    select * into t from task_types where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(t.branch_id);
    perform fn_check_version_strict(t.version, (p->>'version')::int);
    before := to_jsonb(t);
    -- renaming never rewrites task_type_name_snapshot on historical tasks
    update task_types set name = trim(p->>'name'), description = p->>'description', is_active = coalesce((p->>'is_active')::boolean, is_active),
      version = version + 1, updated_at = now() where id = t.id returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.updated', 'task_type', t.id, before, to_jsonb(t));
  end if;
  return jsonb_build_object('ok', true, 'id', t.id, 'version', t.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_source(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s booking_sources%rowtype; v_name text := trim(coalesce(p->>'name', '')); v_kind text; v_ref boolean; v_bp int; before jsonb; used boolean;
begin
  perform fn_require_definition_page('/admin/booking-sources', case when nullif(p->>'id','') is null then 'add' else 'edit' end);
  if (p->>'id') is not null then
    select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if not (p ? 'name') then v_name := s.name; end if;
  end if;
  if v_name = '' or char_length(v_name) > 80 then raise exception 'VALIDATION: name'; end if;
  if exists (select 1 from booking_sources x where x.organization_id = fn_user_org_id() and x.archived_at is null and x.id is distinct from s.id
               and fn_normalize_ar(trim(x.name)) = fn_normalize_ar(v_name)) then
    raise exception 'DUPLICATE_SOURCE_NAME';
  end if;
  v_kind := coalesce(nullif(p->>'kind', ''), s.kind, 'external');
  if v_kind not in ('direct', 'external') then raise exception 'VALIDATION: source_kind'; end if;
  v_ref := coalesce((p->>'external_reference_required')::boolean, s.external_reference_required, v_kind = 'external');
  if (p ? 'commission_bp') and coalesce(p->>'commission_bp', '') !~ '^[0-9]{1,5}$' then raise exception 'VALIDATION: commission'; end if;
  v_bp := coalesce((p->>'commission_bp')::int, s.commission_bp, 0);
  if v_bp > 10000 then raise exception 'VALIDATION: commission'; end if;
  if v_kind = 'direct' then v_bp := 0; end if;
  if s.id is null then
    insert into booking_sources(organization_id, name, code, kind, external_reference_required, commission_bp, is_active)
    values (fn_user_org_id(), v_name, 'custom_' || substr(md5(gen_random_uuid()::text), 1, 10), v_kind, v_ref, v_bp, true)
    returning * into s;
    perform fn_audit_change(null, 'source.created', 'booking_source', s.id, null,
      jsonb_build_object('name', s.name, 'code', s.code, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp), null);
  else
    -- a source already used by a booking keeps its kind (a platform's bookings stay platform bookings)
    select exists (select 1 from reservations where source_id = s.id) into used;
    if used and v_kind <> s.kind then raise exception 'SOURCE_IN_USE: kind'; end if;
    before := jsonb_build_object('name', s.name, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp);
    update booking_sources set name = v_name, kind = v_kind, external_reference_required = v_ref, commission_bp = v_bp where id = s.id returning * into s;
    if jsonb_build_object('name', s.name, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp) is distinct from before then
      perform fn_audit_change(null, 'source.updated', 'booking_source', s.id, before,
        jsonb_build_object('name', s.name, 'kind', s.kind, 'external_reference_required', s.external_reference_required, 'commission_bp', s.commission_bp),
        nullif(trim(coalesce(p->>'reason', '')), ''));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', s.id, 'code', s.code);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_set_source_active(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s booking_sources%rowtype; v_active boolean := (p->>'is_active')::boolean; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
begin
  perform fn_require_definition_page('/admin/booking-sources','edit');
  if v_active is null then raise exception 'VALIDATION: is_active'; end if;
  select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.is_active = v_active then return jsonb_build_object('ok', true, 'changed', false); end if;
  if not v_active and v_reason is null then raise exception 'VALIDATION: reason'; end if;
  update booking_sources set is_active = v_active where id = s.id;
  perform fn_audit_change(null, case when v_active then 'source.enabled' else 'source.disabled' end, 'booking_source', s.id,
    jsonb_build_object('code', s.code, 'is_active', s.is_active), jsonb_build_object('code', s.code, 'is_active', v_active), v_reason);
  return jsonb_build_object('ok', true, 'changed', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_admin_set_source_commission(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s booking_sources%rowtype; v_bp int;
begin
  perform fn_require_definition_page('/admin/booking-sources','edit');
  if coalesce(p->>'commission_bp', '') !~ '^[0-9]{1,5}$' then raise exception 'VALIDATION: commission'; end if;
  v_bp := (p->>'commission_bp')::int;
  if v_bp > 10000 then raise exception 'VALIDATION: commission'; end if;
  select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.commission_bp = v_bp then return jsonb_build_object('ok', true, 'changed', false); end if;
  update booking_sources set commission_bp = v_bp where id = s.id;
  perform fn_audit_change(null, 'source.commission_updated', 'booking_source', s.id,
    jsonb_build_object('code', s.code, 'commission_bp', s.commission_bp), jsonb_build_object('code', s.code, 'commission_bp', v_bp),
    nullif(trim(coalesce(p->>'reason', '')), ''));
  return jsonb_build_object('ok', true, 'changed', true);
end $function$
;

-- Dependency read used by delete/archive flows: individual accounts need view on the page that owns the entity; legacy/owner keep fn_require_cap('definitions').
-- Entities with no grounded page (e.g. branch, service categories) stay denied for individual accounts (fail closed).
CREATE OR REPLACE FUNCTION public.fn_definition_dependencies(p_entity text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d jsonb := '{}'::jsonb; v_branch uuid;
begin
  perform fn_require_definition_entity_view(p_entity);
  v_branch := case p_entity
    when 'branch' then p_id
    when 'block' then (select branch_id from blocks where id = p_id)
    when 'floor' then (select branch_id from floors where id = p_id)
    when 'room_category' then (select branch_id from room_categories where id = p_id)
    when 'room' then (select branch_id from rooms where id = p_id)
    when 'facility' then (select branch_id from facilities where id = p_id)
    when 'task_type' then (select branch_id from task_types where id = p_id)
    when 'service' then (select branch_id from service_definitions where id = p_id) end;
  if v_branch is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  case p_entity
    when 'branch' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where branch_id = p_id),
        'room_categories', (select count(*) from room_categories where branch_id = p_id),
        'reservations', (select count(*) from reservations where branch_id = p_id),
        'staff', (select count(*) from branch_memberships where branch_id = p_id),
        'blocks', (select count(*) from blocks where branch_id = p_id),
        'floors', (select count(*) from floors where branch_id = p_id),
        'facilities', (select count(*) from facilities where branch_id = p_id),
        'task_types', (select count(*) from task_types where branch_id = p_id and code is null),
        'services', (select count(*) from service_definitions where branch_id = p_id),
        'vouchers', (select count(*) from financial_vouchers where branch_id = p_id),
        'invoices', (select count(*) from invoices where branch_id = p_id),
        'keyboxes', (select count(*) from keyboxes where branch_id = p_id),
        'policies', (select count(*) from property_policies where branch_id = p_id),
        'conversations', (select count(*) from conversations where branch_id = p_id),
        'tasks', (select count(*) from housekeeping_tasks where branch_id = p_id),
        'pos_settlements', (select count(*) from pos_settlements where branch_id = p_id),
        'platform_payouts', (select count(*) from platform_payouts where branch_id = p_id),
        'rate_calendar', (select count(*) from rate_calendar where branch_id = p_id and (price_halalas is not null or platform_price_halalas is not null)));
    when 'block' then
      d := jsonb_build_object(
        'floors', (select count(*) from floors where block_id = p_id),
        'rooms', (select count(*) from rooms where block_id = p_id),
        'facilities', (select count(*) from facilities where block_id = p_id));
    when 'floor' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where floor_id = p_id),
        'facilities', (select count(*) from facilities where floor_id = p_id));
    when 'room_category' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where category_id = p_id),
        'reservations', (select count(*) from reservations where room_category_id = p_id),
        'inventory_periods', (select count(*) from inventory_periods where category_id = p_id),
        'release_rules', (select count(*) from release_rules where category_id = p_id),
        'released_slots', (select count(*) from released_slots where category_id = p_id),
        'rate_calendar', (select count(*) from rate_calendar where category_id = p_id and (price_halalas is not null or platform_price_halalas is not null)));
    when 'room' then
      d := jsonb_build_object(
        'reservations', (select count(*) from reservations where room_id = p_id),
        'allocations', (select count(*) from reservation_allocations where room_id = p_id),
        'tasks', (select count(*) from housekeeping_tasks where room_id = p_id),
        'keyboxes', (select count(*) from keyboxes where room_id = p_id),
        'maintenance_tickets', (select count(*) from maintenance_tickets where room_id = p_id),
        'code_rotation_events', (select count(*) from code_rotation_events where room_id = p_id));
    when 'facility' then
      d := jsonb_build_object('tasks', (select count(*) from housekeeping_tasks where facility_id = p_id));
    when 'task_type' then
      d := jsonb_build_object(
        'tasks', (select count(*) from housekeeping_tasks where task_type_id = p_id),
        'services', (select count(*) from service_definitions where task_type_id = p_id));
    when 'service' then
      d := jsonb_build_object('charges', (select count(*) from reservation_charges where service_definition_id = p_id));
    else raise exception 'VALIDATION: entity';
  end case;
  return d;
end $function$
;
-- archive_definition intentionally NOT changed (archive/restore action mapping not grounded in user approval)
-- set_room_license intentionally NOT changed (inline role gate unresolved); archive_definition NOT changed
