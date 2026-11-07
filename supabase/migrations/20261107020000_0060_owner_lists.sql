-- 0060 — owner review Phase 4b (31 Oct review, owner's decisions):
--   OWNER-12  the guests list: the page shows a few and the rest is reached by search. From three letters of a name the
--             search returns the exact matches first, then the near names (a letter or two apart: «محمود» for «محمد»,
--             «عبدالله» for «عبد الله», with or without hamza, taa marbuta or diacritics), marked as near.
--   OWNER-13  the review list: the owner can object to an item (a note is required) — the item stays open as «اعتراض»,
--             and the branch's supervisors are told; a «تمت المراجعة» can be undone for 10 minutes by whoever marked it.

-- ---------------------------------------------------------------------------------------------------- near names
create or replace function fn_name_norm(s text) returns text language sql immutable set search_path = public as $$
  select lower(regexp_replace(regexp_replace(translate(coalesce(s, ''), 'أإآٱىئؤة', 'ااااييوه'), '[ًٌٍَُِّْـ]', '', 'g'), '\s+', ' ', 'g'))
$$;
create or replace function fn_trigram_set(s text) returns text[] language sql immutable set search_path = public as $$
  select coalesce(array_agg(distinct substr(x.t, i, 3)), '{}') from (select '  ' || s || ' ' as t) x, generate_series(1, greatest(length(x.t) - 2, 1)) i
$$;
-- the best trigram overlap (0–1) between the query and the whole name, any word of it, or any two words joined
-- («عبد الله» against «عبدالله»)
create or replace function fn_name_closeness(p_name text, p_q text) returns numeric language sql immutable set search_path = public as $$
  with q as (select fn_trigram_set(replace(fn_name_norm(p_q), ' ', '')) as b),
       w as (select string_to_array(fn_name_norm(p_name), ' ') as ws),
       parts as (select replace(fn_name_norm(p_name), ' ', '') as p
                 union all select unnest(ws) from w
                 union all select ws[i] || ws[i + 1] from w, generate_series(1, greatest(cardinality(ws) - 1, 0)) i)
  select coalesce(max(round(cardinality(array(select unnest(a.a) intersect select unnest(q.b)))::numeric
                        / nullif(cardinality(array(select unnest(a.a) union select unnest(q.b))), 0), 3)), 0)
  from q, (select fn_trigram_set(p) as a from parts where p <> '') a
$$;
revoke all on function fn_name_norm(text) from public, anon;
revoke all on function fn_trigram_set(text) from public, anon;
revoke all on function fn_name_closeness(text, text) from public, anon;
grant execute on function fn_name_norm(text) to authenticated;
grant execute on function fn_trigram_set(text) to authenticated;
grant execute on function fn_name_closeness(text, text) to authenticated;

create or replace function fn_guest_profiles(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare q text := nullif(trim(coalesce(p->>'q', '')), ''); v_filter text := coalesce(nullif(p->>'filter', ''), 'all');
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        digits text; fps text[] := '{}'; v_org uuid := fn_user_org_id(); v_owner boolean := fn_has_role('owner'); res jsonb;
        v_name boolean;   -- OWNER-12: three letters or more of a name also find the near names
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
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
end $$;

revoke all on function fn_guest_profiles(jsonb) from public, anon;
grant execute on function fn_guest_profiles(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------- the review list
alter table review_items add column if not exists objection_note text;
alter table review_items add column if not exists objection_at timestamptz;
alter table review_items add column if not exists objection_by uuid references staff_profiles(id);

-- p: { ids: [...], note, outcome: 'ok' | 'objection' }. «ok» closes the items; «objection» needs a note, keeps them open
-- as an objection and tells the branch's supervisors what the owner asks.
create or replace function fn_review_mark(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ids uuid[]; note text := nullif(trim(coalesce(p->>'note', '')), ''); n int; v_outcome text := coalesce(nullif(p->>'outcome', ''), 'ok'); r record;
begin
  perform fn_require_role('owner');
  if v_outcome not in ('ok', 'objection') then raise exception 'VALIDATION: outcome'; end if;
  select coalesce(array_agg(x::uuid), '{}') into ids
    from jsonb_array_elements_text(case when jsonb_typeof(p->'ids') = 'array' then p->'ids' else '[]'::jsonb end) x;
  if coalesce(array_length(ids, 1), 0) = 0 then raise exception 'VALIDATION: ids'; end if;
  if v_outcome = 'objection' then
    if note is null or length(note) < 3 then raise exception 'VALIDATION: objection_note'; end if;
    update review_items set objection_note = note, objection_at = now(), objection_by = fn_staff_id()
     where id = any(ids) and reviewed_at is null and organization_id = fn_user_org_id()
       and (branch_id is null or branch_id in (select fn_user_branch_ids()));
    get diagnostics n = row_count;
    for r in select ri.* from review_items ri where ri.id = any(ids) and ri.objection_at is not null and ri.reviewed_at is null loop
      insert into notifications(branch_id, audience, title, body, link)
      values (r.branch_id, 'supervisor', 'اعتراض المالك: ' || left(r.summary, 120),
              coalesce((select full_name from staff_profiles where id = r.created_by) || ' — ', '') || note,
              case when r.reservation_id is not null then '/staff/reservations/' || r.reservation_id end);
    end loop;
    perform fn_audit_change(null, 'review.objection', 'review_items', null, null, jsonb_build_object('count', n, 'ids', to_jsonb(ids)), note);
    return jsonb_build_object('ok', true, 'objected', n);
  end if;
  update review_items set reviewed_at = now(), reviewed_by = fn_staff_id(), review_note = note
   where id = any(ids) and reviewed_at is null and organization_id = fn_user_org_id()
     and (branch_id is null or branch_id in (select fn_user_branch_ids()));
  get diagnostics n = row_count;
  perform fn_audit_change(null, 'review.marked', 'review_items', null, null, jsonb_build_object('count', n, 'ids', to_jsonb(ids)), note);
  return jsonb_build_object('ok', true, 'marked', n);
end $$;
revoke all on function fn_review_mark(jsonb) from public, anon;
grant execute on function fn_review_mark(jsonb) to authenticated;

-- a «تمت المراجعة» taken back within 10 minutes, by whoever marked it
create or replace function fn_review_undo(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ids uuid[]; n int;
begin
  perform fn_require_role('owner');
  select coalesce(array_agg(x::uuid), '{}') into ids
    from jsonb_array_elements_text(case when jsonb_typeof(p->'ids') = 'array' then p->'ids' else '[]'::jsonb end) x;
  if coalesce(array_length(ids, 1), 0) = 0 then raise exception 'VALIDATION: ids'; end if;
  if exists (select 1 from review_items where id = any(ids) and reviewed_at is not null and (reviewed_by is distinct from fn_staff_id() or reviewed_at < now() - interval '10 minutes')) then
    raise exception 'CORRECTION_WINDOW_PASSED';
  end if;
  update review_items set reviewed_at = null, reviewed_by = null, review_note = null
   where id = any(ids) and reviewed_at is not null and organization_id = fn_user_org_id();
  get diagnostics n = row_count;
  perform fn_audit_change(null, 'review.undone', 'review_items', null, null, jsonb_build_object('count', n, 'ids', to_jsonb(ids)), null);
  return jsonb_build_object('ok', true, 'undone', n);
end $$;
revoke all on function fn_review_undo(jsonb) from public, anon;
grant execute on function fn_review_undo(jsonb) to authenticated;

-- the list says which items carry an objection, and which «تمت المراجعة» the caller can still take back
create or replace function fn_review_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare st text := coalesce(nullif(p->>'status', ''), 'open'); lim int := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500); items jsonb;
begin
  perform fn_require_role('owner');
  if st not in ('open', 'reviewed', 'all') then raise exception 'VALIDATION: status'; end if;
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) into items from (
    select jsonb_build_object('id', ri.id, 'kind', ri.kind, 'entity_type', ri.entity_type, 'entity_id', ri.entity_id, 'reservation_id', ri.reservation_id,
             'internal_ref', (select internal_ref from reservations where id = ri.reservation_id),
             'branch_id', ri.branch_id, 'branch_name', (select name_ar from branches where id = ri.branch_id),
             'summary', ri.summary, 'reason', ri.reason, 'details', ri.details,
             'created_at', ri.created_at, 'created_by', (select full_name from staff_profiles where id = ri.created_by),
             'reviewed_at', ri.reviewed_at, 'reviewed_by', (select full_name from staff_profiles where id = ri.reviewed_by), 'review_note', ri.review_note,
             'reviewed_by_me', ri.reviewed_by = fn_staff_id(),
             'objection_note', ri.objection_note, 'objection_at', ri.objection_at, 'objection_by', (select full_name from staff_profiles where id = ri.objection_by)) as x
      from review_items ri
     where ri.organization_id = fn_user_org_id()
       and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))
       and (st = 'all' or (st = 'open') = (ri.reviewed_at is null))
       and (nullif(p->>'kind', '') is null or ri.kind = p->>'kind' or (p->>'kind' = 'monitor' and ri.kind like 'monitor:%'))
       and (nullif(p->>'branch_id', '') is null or ri.branch_id = (p->>'branch_id')::uuid)
       and (nullif(p->>'before', '') is null or ri.created_at < (p->>'before')::timestamptz)
     order by ri.created_at desc
     limit lim) s;
  return jsonb_build_object('items', items, 'open_count',
    (select count(*) from review_items ri where ri.organization_id = fn_user_org_id() and ri.reviewed_at is null
        and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))));
end $$;

revoke all on function fn_review_list(jsonb) from public, anon;
grant execute on function fn_review_list(jsonb) to authenticated;
