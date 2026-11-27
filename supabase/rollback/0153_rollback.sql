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
end $function$;

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
end $function$;
