-- 0049 — the guest list at the size of the Zaaer import (I5, plan «خطة تصحيح ملاحظات التجربة»).
--
-- 1. fn_guest_profiles computed «possible duplicate» with a correlated scan of every other profile per profile, calling
--    fn_normalize_phone on both sides: quadratic. With 2,452 imported profiles one call took 113 s in production. The
--    rewrite normalises each phone once, finds duplicates with two equality joins (phone, document fingerprint), counts the
--    stays with one grouped pass, and looks up a ban only for the profiles it returns (or all of them for the «banned»
--    filter). Same result shape, same permissions, same ordering.
-- 2. I5 asked that an imported guest without a valid phone or without a document carries «يحتاج استكمال». It is derived,
--    not stored: a profile with no phone or no document fingerprint is incomplete, and stops being so the moment staff
--    record the missing item. The list returns it per row and offers it as a filter.

create or replace function fn_guest_profiles(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare q text := nullif(trim(coalesce(p->>'q', '')), ''); v_filter text := coalesce(nullif(p->>'filter', ''), 'all');
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        digits text; fps text[] := '{}'; v_org uuid := fn_user_org_id(); v_owner boolean := fn_has_role('owner'); res jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  if v_filter not in ('all', 'banned', 'duplicates', 'rated', 'low', 'incomplete') then raise exception 'VALIDATION: filter'; end if;
  if q is not null then
    digits := regexp_replace(translate(q, '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g');
    if q ~ '^[A-Za-z0-9]{5,15}$' then
      fps := array[fn_identity_fingerprint('national_id', q), fn_identity_fingerprint('passport', q), fn_identity_fingerprint('gcc_id', q)];
    end if;
  end if;
  with org as (                                   -- every profile of the organisation, its phone normalised once
    select gp.id, fn_normalize_phone(gp.phone) as np, gp.identity_fingerprint as fp from guest_profiles gp where gp.organization_id = v_org
  ), pairs as (                                   -- possible duplicates: the same phone or the same document, never merged
    select a.id, b.id as other from org a join org b on b.np = a.np and b.id <> a.id where a.np is not null
    union
    select a.id, b.id from org a join org b on b.fp = a.fp and b.id <> a.id where a.fp is not null
  ), dup as (select id, count(*) as n from pairs group by id),
  st as (                                         -- stays and last arrival, one grouped pass
    select g.guest_profile_id as id, count(distinct g.reservation_id) as stays, max(r.check_in) as last_check_in,
           bool_or(v_owner or r.branch_id in (select fn_user_branch_ids())) as visible
    from reservation_guests g join reservations r on r.id = g.reservation_id
    where g.guest_profile_id is not null and r.organization_id = v_org
    group by g.guest_profile_id
  ), prof as (
    select gp.*, coalesce(st.stays, 0) as stays, st.last_check_in, coalesce(dup.n, 0) as duplicates,
           (gp.phone is null or gp.identity_fingerprint is null) as incomplete
    from guest_profiles gp left join st on st.id = gp.id left join dup on dup.id = gp.id
    where gp.organization_id = v_org and (v_owner or coalesce(st.visible, false))
      and (q is null
           or gp.full_name ilike '%' || q || '%'
           or (length(digits) >= 4 and regexp_replace(coalesce(gp.phone, ''), '\D', '', 'g') like '%' || digits || '%')
           or (length(digits) = 4 and gp.identity_last4 = digits)
           or gp.identity_fingerprint = any(fps)
           or exists (select 1 from reservation_guests g where g.guest_profile_id = gp.id and (g.identity_fingerprint = any(fps) or (length(digits) = 4 and g.identity_number_last4 = digits)))
           or exists (select 1 from reservation_guests g join reservations r on r.id = g.reservation_id
                       where g.guest_profile_id = gp.id and (r.internal_ref ilike q or r.external_ref ilike q)))
  ), f as (
    select * from prof
    where v_filter = 'all' or (v_filter = 'duplicates' and duplicates > 0) or (v_filter = 'incomplete' and incomplete)
       or (v_filter = 'rated' and rating is not null) or (v_filter = 'low' and rating <= 2)
       or (v_filter = 'banned' and exists (select 1 from fn_profile_banned(prof.id) b where b.id is not null))
  ), pg as (
    select f.*, (select b.reason from fn_profile_banned(f.id) b where b.id is not null) as ban_reason
    from f order by last_check_in desc nulls last, created_at desc, id limit v_limit offset v_offset
  )
  select jsonb_build_object('total', (select count(*) from f),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'phone_masked', fn_mask_phone(phone), 'nationality', nationality,
                                                         'identity_type', identity_type, 'identity_last4', identity_last4, 'rating', rating, 'rating_note', rating_note,
                                                         'stays', stays, 'last_check_in', last_check_in, 'banned', ban_reason is not null, 'ban_reason', ban_reason,
                                                         'duplicates', duplicates, 'incomplete', incomplete, 'created_at', created_at)
                                      order by last_check_in desc nulls last, created_at desc, id)
                      from pg), '[]'::jsonb))
  into res;
  return res;
end $$;
revoke all on function fn_guest_profiles(jsonb) from public, anon;
grant execute on function fn_guest_profiles(jsonb) to authenticated;
