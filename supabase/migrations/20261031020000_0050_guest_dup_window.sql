-- 0050 — the guest list stays fast when the table's statistics are older than its rows.
--
-- After a bulk load (the Zaaer import, a test database) and before the table is analysed, the planner misjudged 0049's
-- list: a search over 3,000 profiles took about 5 s locally (worse on CI), because each profile ran its own
-- «matches the search?» subqueries, and the duplicate self-join could become a nested loop. Now:
--   * a search finds its profiles once, as one set (names, phone digits, document, booking numbers), and the list keeps
--     the profiles in that set;
--   * possible duplicates are three window counts — same phone, plus same document, minus both (each other profile
--     counted once) — sorted, never squared.
-- Same rows, same permissions, same ordering; 0049 stays as it was applied.

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
  with qm as (                                    -- the profiles a search matches, found once as a set (not per profile)
    select gp.id from guest_profiles gp
    where q is not null and gp.organization_id = v_org
      and (gp.full_name ilike '%' || q || '%'
           or (length(digits) >= 4 and regexp_replace(coalesce(gp.phone, ''), '\D', '', 'g') like '%' || digits || '%')
           or (length(digits) = 4 and gp.identity_last4 = digits)
           or gp.identity_fingerprint = any(fps))
    union
    select g.guest_profile_id from reservation_guests g join reservations r on r.id = g.reservation_id
    where q is not null and r.organization_id = v_org and g.guest_profile_id is not null
      and (g.identity_fingerprint = any(fps) or (length(digits) = 4 and g.identity_number_last4 = digits)
           or r.internal_ref ilike q or r.external_ref ilike q)
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
      and (q is null or c.id in (select id from qm))
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
