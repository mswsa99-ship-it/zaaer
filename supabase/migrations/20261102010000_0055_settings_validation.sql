-- 0055 — Phase 2a of the 31 October review: settings and validation, as the owner decided them (1 November 2026).
--
-- SETUP-04: the organisation has its own record in the settings («المنشأة»): Arabic and English name, licence number and
--   logo, edited by the owner and read by every screen (fn_organization_info for staff, fn_public_organization for guests).
-- SETUP-12 (owner's decision): one base price per unit type, required and above zero. For the supervisor and for the
--   manager separately, the owner sets a lowest and a highest nightly price as a percentage of the type's base price.
--   A price outside the caller's range is refused (calendar prices, a manual nightly price, a discount that brings a
--   night under the lowest, a price adjustment). The owner is not limited. A service is priced above zero unless free.
--   A nightly amount over 1,000,000 SAR is refused for everyone (a typing error, not a price).
-- SETUP-01: the daily inventory and the release rules are changed only through checked functions: 0 ≤ blocked ≤ total
--   ≤ the type's units, public ≤ total − blocked, initial ≥ 0, increment ≥ 1; a rule can be created and its trigger set.
-- SETUP-06: a unit number is stored and compared with Latin digits («١٠١» is «101»); existing numbers are converted.
-- SETUP-08: an invite needs a valid email, and a branch for every role but the owner; a phone can be given; the email
--   can be corrected while the person has not signed in yet; a phone is checked (and kept as typed, digits and +).
-- SETUP-09: two branches cannot share a name; a branch's phone and email are checked.
-- SETUP-13 (owner's decision): an answer that contradicts an active one for the same question is refused; the owner
--   edits the existing answer instead.

-- ---------------------------------------------------------------------------------------------- the organisation
alter table organizations add column if not exists logo_mime text;
alter table organizations add column if not exists logo_bytes bytea;
alter table organizations add column if not exists logo_sha256 text;
alter table organizations add column if not exists price_min_bp_supervisor int;
alter table organizations add column if not exists price_max_bp_supervisor int;
alter table organizations add column if not exists price_min_bp_manager int;
alter table organizations add column if not exists price_max_bp_manager int;
alter table organizations add column if not exists version int not null default 1;
alter table organizations add column if not exists updated_at timestamptz;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'organizations_price_limits_valid') then
    alter table organizations add constraint organizations_price_limits_valid check (
      (price_min_bp_supervisor is null or price_min_bp_supervisor between 1 and 10000)
      and (price_max_bp_supervisor is null or price_max_bp_supervisor between 10000 and 100000)
      and (price_min_bp_manager is null or price_min_bp_manager between 1 and 10000)
      and (price_max_bp_manager is null or price_max_bp_manager between 10000 and 100000));
  end if;
end $c$;

-- the logo as a data URL (null when none)
create or replace function fn_organization_logo(p_org uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when o.logo_bytes is null then null else 'data:' || o.logo_mime || ';base64,' || replace(encode(o.logo_bytes, 'base64'), E'\n', '') end
  from organizations o where o.id = p_org;
$$;
revoke all on function fn_organization_logo(uuid) from public, anon, authenticated;

create or replace function fn_organization_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'name_ar', o.name_ar, 'name_en', o.name_en, 'license_number', o.license_number,
           'logo', fn_organization_logo(o.id), 'version', o.version,
           'price_min_bp_supervisor', o.price_min_bp_supervisor, 'price_max_bp_supervisor', o.price_max_bp_supervisor,
           'price_min_bp_manager', o.price_min_bp_manager, 'price_max_bp_manager', o.price_max_bp_manager)
  from organizations o where o.id = fn_user_org_id();
$$;
revoke all on function fn_organization_info() from public, anon;
grant execute on function fn_organization_info() to authenticated;

-- what a guest page shows of the organisation: its names and logo (the organisation of the active branches)
create or replace function fn_public_organization() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('name_ar', o.name_ar, 'name_en', o.name_en, 'logo', fn_organization_logo(o.id))
  from organizations o
  where exists (select 1 from branches b where b.organization_id = o.id and b.is_active and b.archived_at is null)
  order by o.created_at limit 1;
$$;
revoke all on function fn_public_organization() from public;
grant execute on function fn_public_organization() to anon, authenticated;

create or replace function fn_admin_update_organization(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare o organizations%rowtype; before jsonb; after jsonb; v text; raw text; bin bytea; v_mime text; k text; n int;
begin
  perform fn_require_role('owner');
  select * into o from organizations where id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if (p->>'version') is not null then perform fn_check_version(o.version, (p->>'version')::int); end if;
  before := jsonb_build_object('name_ar', o.name_ar, 'name_en', o.name_en, 'license_number', o.license_number, 'logo_sha256', o.logo_sha256,
    'price_min_bp_supervisor', o.price_min_bp_supervisor, 'price_max_bp_supervisor', o.price_max_bp_supervisor,
    'price_min_bp_manager', o.price_min_bp_manager, 'price_max_bp_manager', o.price_max_bp_manager);
  if p ? 'name_ar' then
    v := trim(coalesce(p->>'name_ar', ''));
    if v = '' or char_length(v) > 120 then raise exception 'VALIDATION: name_ar'; end if;
    o.name_ar := v;
  end if;
  if p ? 'name_en' then
    v := nullif(trim(coalesce(p->>'name_en', '')), '');
    if v is not null and char_length(v) > 120 then raise exception 'VALIDATION: name_en'; end if;
    o.name_en := v;
  end if;
  if p ? 'license_number' then
    v := nullif(translate(trim(coalesce(p->>'license_number', '')), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'), '');
    if v is not null and (char_length(v) > 40 or v !~ '^[0-9A-Za-z/-]+$') then raise exception 'VALIDATION: license_number'; end if;
    o.license_number := v;
  end if;
  -- the price range of each role, in basis points of the base price (null: no range for that bound)
  foreach k in array array['price_min_bp_supervisor', 'price_max_bp_supervisor', 'price_min_bp_manager', 'price_max_bp_manager'] loop
    if p ? k then
      v := nullif(trim(coalesce(p->>k, '')), '');
      if v is not null and v !~ '^[0-9]{1,6}$' then raise exception 'VALIDATION: price_limits'; end if;
      n := v::int;
      case k
        when 'price_min_bp_supervisor' then o.price_min_bp_supervisor := n;
        when 'price_max_bp_supervisor' then o.price_max_bp_supervisor := n;
        when 'price_min_bp_manager' then o.price_min_bp_manager := n;
        else o.price_max_bp_manager := n;
      end case;
    end if;
  end loop;
  if (o.price_min_bp_supervisor is not null and o.price_min_bp_supervisor not between 1 and 10000)
     or (o.price_max_bp_supervisor is not null and o.price_max_bp_supervisor not between 10000 and 100000)
     or (o.price_min_bp_manager is not null and o.price_min_bp_manager not between 1 and 10000)
     or (o.price_max_bp_manager is not null and o.price_max_bp_manager not between 10000 and 100000) then
    raise exception 'VALIDATION: price_limits';
  end if;
  -- the logo: PNG, JPG or WebP up to 200 KB, read from the file's own first bytes; an empty value clears it
  if p ? 'logo_base64' then
    raw := regexp_replace(coalesce(p->>'logo_base64', ''), '^data:[^,]*,', '');
    if raw = '' then
      o.logo_bytes := null; o.logo_mime := null; o.logo_sha256 := null;
    else
      begin bin := decode(regexp_replace(raw, '\s', '', 'g'), 'base64'); exception when others then raise exception 'VALIDATION: image'; end;
      if length(bin) > 204800 then raise exception 'VALIDATION: image_too_large'; end if;
      v_mime := case when substring(bin from 1 for 8) = '\x89504e470d0a1a0a'::bytea then 'image/png'
                     when substring(bin from 1 for 3) = '\xffd8ff'::bytea then 'image/jpeg'
                     when substring(bin from 1 for 4) = '\x52494646'::bytea and substring(bin from 9 for 4) = '\x57454250'::bytea then 'image/webp' end;
      if v_mime is null then raise exception 'VALIDATION: image_type'; end if;
      o.logo_bytes := bin; o.logo_mime := v_mime; o.logo_sha256 := encode(digest(bin, 'sha256'), 'hex');
    end if;
  end if;
  update organizations set name_ar = o.name_ar, name_en = o.name_en, license_number = o.license_number,
    logo_bytes = o.logo_bytes, logo_mime = o.logo_mime, logo_sha256 = o.logo_sha256,
    price_min_bp_supervisor = o.price_min_bp_supervisor, price_max_bp_supervisor = o.price_max_bp_supervisor,
    price_min_bp_manager = o.price_min_bp_manager, price_max_bp_manager = o.price_max_bp_manager,
    version = version + 1, updated_at = now()
  where id = o.id returning * into o;
  after := jsonb_build_object('name_ar', o.name_ar, 'name_en', o.name_en, 'license_number', o.license_number, 'logo_sha256', o.logo_sha256,
    'price_min_bp_supervisor', o.price_min_bp_supervisor, 'price_max_bp_supervisor', o.price_max_bp_supervisor,
    'price_min_bp_manager', o.price_min_bp_manager, 'price_max_bp_manager', o.price_max_bp_manager);
  if after is distinct from before then
    perform fn_audit(o.id, null, fn_staff_id(), 'organization.updated', 'organization', o.id,
                     jsonb_build_object('before', before, 'after', after));
  end if;
  return jsonb_build_object('ok', true, 'version', o.version);
end $$;
revoke all on function fn_admin_update_organization(jsonb) from public, anon;
grant execute on function fn_admin_update_organization(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------- SETUP-12 the price range
-- the caller's nightly range for a unit type: {base, min, max} in halalas (min or max null when the owner set none;
-- both null for the owner). Null when the type is not in the caller's branches.
create or replace function fn_price_limits(p_category uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c room_categories%rowtype; o organizations%rowtype; mn int; mx int; v_role text;
begin
  select * into c from room_categories where id = p_category;
  if not found or not (c.branch_id in (select fn_user_branch_ids())) then return null; end if;
  select * into o from organizations where id = c.organization_id;
  v_role := case when fn_has_role('owner') then 'owner' when fn_has_role('manager') then 'manager' else 'supervisor' end;
  if v_role = 'manager' then mn := o.price_min_bp_manager; mx := o.price_max_bp_manager;
  elsif v_role = 'supervisor' then mn := o.price_min_bp_supervisor; mx := o.price_max_bp_supervisor; end if;
  return jsonb_build_object('role', v_role, 'base', c.base_price_halalas, 'min_bp', mn, 'max_bp', mx,
    'min', case when mn is not null and c.base_price_halalas > 0 then ceil(c.base_price_halalas::numeric * mn / 10000)::bigint end,
    'max', case when mx is not null and c.base_price_halalas > 0 then floor(c.base_price_halalas::numeric * mx / 10000)::bigint end);
end $$;
revoke all on function fn_price_limits(uuid) from public, anon;
grant execute on function fn_price_limits(uuid) to authenticated;

-- refuses a nightly price outside the caller's range ('min': only the lowest is checked, 'max': only the highest)
create or replace function fn_check_price_band(p_category uuid, p_nightly numeric, p_dir text default 'both') returns void
language plpgsql stable security definer set search_path = public as $$
declare lim jsonb;
begin
  if p_nightly is null then return; end if;
  if p_nightly > 100000000 then raise exception 'VALIDATION: amount_too_large'; end if;
  lim := fn_price_limits(p_category);
  if lim is null then return; end if;
  if p_dir in ('both', 'min') and (lim->>'min') is not null and p_nightly < (lim->>'min')::bigint then
    raise exception 'PRICE_BELOW_LIMIT: %', lim->>'min';
  end if;
  if p_dir in ('both', 'max') and (lim->>'max') is not null and p_nightly > (lim->>'max')::bigint then
    raise exception 'PRICE_ABOVE_LIMIT: %', lim->>'max';
  end if;
end $$;
revoke all on function fn_check_price_band(uuid, numeric, text) from public, anon, authenticated;

-- a manual nightly price (a price typed for the stay) is within the range of whoever books it
create or replace function fn_trg_manual_night_band() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.basis = 'manual' and fn_staff_id() is not null then
    perform fn_check_price_band((select room_category_id from reservations where id = new.reservation_id), new.price_halalas, 'both');
  end if;
  return new;
end $$;
revoke all on function fn_trg_manual_night_band() from public, anon, authenticated;
create or replace trigger trg_manual_night_band before insert on reservation_nights
  for each row execute function fn_trg_manual_night_band();

-- a discount that brings the nights under the caller's lowest price is refused (with the existing rules)
create or replace function fn_check_discount(p_category uuid, p_branch uuid, p_nights integer, p_rent bigint, p_existing bigint, p_new bigint, p_after_arrival boolean)
returns void language plpgsql stable security definer set search_path = public as $$
declare bp int; mn bigint;
begin
  if coalesce(p_new, 0) <= 0 then return; end if;
  if coalesce(p_existing, 0) + p_new > p_rent then raise exception 'VALIDATION: discount_exceeds_rent'; end if;
  if coalesce(p_nights, 0) > 0 then
    perform fn_check_price_band(p_category, (p_rent - coalesce(p_existing, 0) - p_new)::numeric / p_nights, 'min');
  end if;
  if fn_can('disc.after') then return; end if;
  if not fn_can('disc.before') then raise exception 'FORBIDDEN: discount'; end if;
  if p_after_arrival then raise exception 'FORBIDDEN: post-arrival discount'; end if;
  select supervisor_max_discount_bp into bp from branches where id = p_branch;
  if coalesce(p_existing, 0) + p_new > floor(p_rent::numeric * coalesce(bp, 0) / 10000) then raise exception 'VALIDATION: discount_percent'; end if;
  select min_nightly_halalas into mn from room_categories where id = p_category;
  if mn is not null and p_rent - coalesce(p_existing, 0) - p_new < mn * p_nights then raise exception 'VALIDATION: discount_minimum'; end if;
end $$;

-- a price adjustment moves the nights' average: up to the caller's highest, down to their lowest
create or replace function public.fn_staff_adjust_price(p_reservation uuid, p_kind text, p_amount_halalas bigint, p_description text, p_reason text, p_expected_version integer default null::integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r reservations%rowtype; before jsonb; rent bigint; n int; disc bigint; adj bigint;
begin
  if p_kind not in ('discount','adjustment','penalty','addon') then raise exception 'VALIDATION: kind'; end if;
  if p_kind = 'adjustment' then perform fn_require_cap('price.adjust'); elsif p_kind = 'discount' then perform fn_require_any_cap(array['disc.before', 'disc.after']); else perform fn_require_cap('charges.add'); end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_amount_halalas = 0 or (p_kind in ('discount','penalty','addon') and p_amount_halalas < 0) then raise exception 'VALIDATION: amount'; end if;
  if abs(p_amount_halalas) > 10000000000 then raise exception 'VALIDATION: amount_too_large'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_kind in ('discount', 'adjustment') then
    perform fn_ensure_nights(r.id);
    select coalesce(sum(price_halalas), 0), count(*) into rent, n from reservation_nights where reservation_id = r.id and status = 'active';
    disc := coalesce((select sum(round(abs(quantity * unit_price_halalas)))::bigint from reservation_charges where reservation_id = r.id and kind = 'discount'), 0);
    if p_kind = 'discount' then
      perform fn_check_discount(r.room_category_id, r.branch_id, n, rent, disc, p_amount_halalas, r.status in ('checked_in','checked_out'));
    elsif n > 0 then
      adj := coalesce((select sum(round(quantity * unit_price_halalas))::bigint from reservation_charges where reservation_id = r.id and kind = 'adjustment'), 0);
      perform fn_check_price_band(r.room_category_id, (rent - disc + adj + p_amount_halalas)::numeric / n, case when p_amount_halalas > 0 then 'max' else 'min' end);
    end if;
  end if;
  before := jsonb_build_object('total_halalas', r.total_halalas);
  perform fn_add_charge(r.id, p_kind, coalesce(nullif(trim(p_description),''), p_kind), 1, p_amount_halalas, true, p_reason);
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.total_changed', 'reservation', r.id, before, jsonb_build_object('total_halalas', (select total_halalas from reservations where id = r.id), 'kind', p_kind, 'amount_halalas', p_amount_halalas), p_reason);
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id));
end $function$;

-- the calendar: each price within the range of whoever sets it (with the existing rules)
create or replace function public.fn_rate_calendar_set(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_branch uuid := (p->>'branch_id')::uuid; today date; cats uuid[]; wd int[]; d0 date := nullif(p->>'from', '')::date; d1 date := nullif(p->>'to', '')::date;
        v_cells jsonb := p->'cells'; v_clear text := case when p->>'clear' = 'true' then 'both' when p->>'clear' in ('price', 'platform') then p->>'clear' end;
        set_p boolean := nullif(p->>'price_halalas', '') is not null; set_pp boolean := nullif(p->>'platform_price_halalas', '') is not null;
        v_p bigint := nullif(p->>'price_halalas', '')::bigint; v_pp bigint := nullif(p->>'platform_price_halalas', '')::bigint;
        x record; old_p bigint; old_pp bigint; new_p bigint; new_pp bigint; n int := 0; seen int := 0; before jsonb := '[]'::jsonb; checked uuid[] := '{}';
begin
  perform fn_require_cap('rates');
  perform fn_require_branch(v_branch);
  today := fn_branch_today(v_branch);
  if v_clear is null and not set_p and not set_pp then raise exception 'VALIDATION: price'; end if;
  if (set_p and v_p <= 0) or (set_pp and v_pp <= 0) then raise exception 'VALIDATION: amount'; end if;
  if v_cells is not null and jsonb_typeof(v_cells) <> 'array' then raise exception 'VALIDATION: cells'; end if;
  if v_cells is null then
    if d0 is null or d1 is null or d1 < d0 or d1 - d0 > 731 then raise exception 'VALIDATION: range'; end if;
    select array_agg(value::uuid) into cats from jsonb_array_elements_text(coalesce(p->'category_ids', '[]'::jsonb));
    if cats is null then raise exception 'VALIDATION: categories'; end if;
    if p ? 'weekdays' and jsonb_typeof(p->'weekdays') = 'array' and jsonb_array_length(p->'weekdays') > 0 then
      select array_agg(value::int) into wd from jsonb_array_elements_text(p->'weekdays');
    end if;
  end if;
  for x in
    select c.id as category_id, c.min_nightly_halalas as min_p, c.price_mode, t.night
    from room_categories c
    join lateral (
      select (e->>'night')::date as night from jsonb_array_elements(coalesce(v_cells, '[]'::jsonb)) e
      where v_cells is not null and (e->>'category_id')::uuid = c.id
      union
      select g::date from generate_series(d0, d1, interval '1 day') g
      where v_cells is null and c.id = any(cats) and (wd is null or extract(dow from g)::int = any(wd))
    ) t on true
    where c.branch_id = v_branch and c.archived_at is null
    order by t.night, c.id
  loop
    seen := seen + 1;
    if seen > 5000 then raise exception 'VALIDATION: too_many_cells'; end if;
    if x.night < today then raise exception 'VALIDATION: past_night'; end if;
    if set_p and x.min_p is not null and v_p < x.min_p then raise exception 'VALIDATION: below_minimum'; end if;
    if set_pp and x.price_mode = 'by_channel' and x.min_p is not null and v_pp < x.min_p then raise exception 'VALIDATION: below_minimum'; end if;
    if not (x.category_id = any(checked)) then
      if set_p then perform fn_check_price_band(x.category_id, v_p, 'both'); end if;
      if set_pp and x.price_mode = 'by_channel' then perform fn_check_price_band(x.category_id, v_pp, 'both'); end if;
      checked := array_append(checked, x.category_id);
    end if;
    select price_halalas, platform_price_halalas into old_p, old_pp from rate_calendar where category_id = x.category_id and night = x.night;
    if not found then old_p := null; old_pp := null; end if;
    new_p := case when v_clear in ('both', 'price') then null when set_p then v_p else old_p end;
    new_pp := case when v_clear in ('both', 'platform') then null when set_pp and x.price_mode = 'by_channel' then v_pp else old_pp end;
    if new_p is distinct from old_p or new_pp is distinct from old_pp then
      insert into rate_calendar(organization_id, branch_id, category_id, night, price_halalas, platform_price_halalas, updated_by)
      values (fn_user_org_id(), v_branch, x.category_id, x.night, new_p, new_pp, fn_staff_id())
      on conflict (category_id, night) do update set price_halalas = excluded.price_halalas, platform_price_halalas = excluded.platform_price_halalas,
                                                      updated_by = excluded.updated_by, updated_at = now();
      n := n + 1;
      if n <= 400 then
        before := before || jsonb_build_array(jsonb_build_object('category_id', x.category_id, 'night', x.night, 'price', old_p, 'platform_price', old_pp));
      end if;
    end if;
  end loop;
  if seen = 0 then raise exception 'VALIDATION: cells'; end if;
  if n > 0 then
    perform fn_audit_change(v_branch, 'rates.updated', 'rate_calendar', v_branch,
      jsonb_build_object('cells', before, 'more', greatest(n - 400, 0)),
      jsonb_build_object('changed', n, 'price_halalas', case when v_clear in ('both', 'price') then null else v_p end,
                         'platform_price_halalas', case when v_clear in ('both', 'platform') then null else v_pp end, 'clear', v_clear, 'from', d0, 'to', d1, 'category_ids', to_jsonb(cats), 'weekdays', to_jsonb(wd), 'cells', v_cells is not null),
      nullif(trim(coalesce(p->>'reason', '')), ''));
  end if;
  return jsonb_build_object('ok', true, 'changed', n, 'matched', seen);
end $function$;

-- the unit type: a base price above zero (required for a new type); no price beyond the technical bound
create or replace function public.fn_admin_upsert_room_category(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare c room_categories%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb; affected int := 0; low int;
begin
  perform fn_require_cap('definitions');
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
end $function$;

-- a service is priced above zero unless it is free
create or replace function public.fn_admin_upsert_service(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare s service_definitions%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_tt uuid := (p->>'task_type_id')::uuid; before jsonb;
        v_late time; v_unit text; v_free boolean; v_price bigint;
begin
  perform fn_require_cap('definitions');
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
end $function$;

-- ---------------------------------------------------------------------------------------------- SETUP-01 inventory
-- the units of a type: its active, not archived rooms
create or replace function fn_category_units(p_category uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from rooms where category_id = p_category and archived_at is null and is_active;
$$;
revoke all on function fn_category_units(uuid) from public, anon, authenticated;

create or replace function fn_admin_set_inventory(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare iv inventory_periods%rowtype; before jsonb; v_total int; v_pub int; v_blk int; v_units int; k text;
begin
  perform fn_require_role('owner', 'manager');
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
end $$;
revoke all on function fn_admin_set_inventory(jsonb) from public, anon;
grant execute on function fn_admin_set_inventory(jsonb) to authenticated;

create or replace function fn_admin_upsert_release_rule(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rr release_rules%rowtype; before jsonb; v_cat uuid; v_branch uuid; v_units int; v_init int; v_inc int; v_trig text; v_en boolean;
begin
  perform fn_require_role('owner', 'manager');
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
end $$;
revoke all on function fn_admin_upsert_release_rule(jsonb) from public, anon;
grant execute on function fn_admin_upsert_release_rule(jsonb) to authenticated;

-- the screens read these tables; only the functions above write them
revoke all on inventory_periods from anon, authenticated;
grant select on inventory_periods to authenticated;
revoke all on release_rules from anon, authenticated;
grant select on release_rules to authenticated;

-- ---------------------------------------------------------------------------------------------- SETUP-06 unit numbers
create or replace function fn_latin_digits(p text) returns text
language sql immutable set search_path = public as $$
  select translate(p, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
$$;

create or replace function public.fn_admin_upsert_room(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r rooms%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid;
        v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; before jsonb; future_count int;
        v_number text := nullif(trim(fn_latin_digits(coalesce(p->>'room_number', ''))), '');
begin
  perform fn_require_cap('definitions');
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
end $function$;

-- the numbers already stored with Arabic digits become Latin (only where no other unit of the branch has that number)
do $d$ declare x record; begin
  for x in select r.id, r.branch_id, r.room_number from rooms r
           where r.room_number <> fn_latin_digits(r.room_number)
             and not exists (select 1 from rooms o where o.branch_id = r.branch_id and o.id <> r.id and fn_latin_digits(o.room_number) = fn_latin_digits(r.room_number)) loop
    update rooms set room_number = fn_latin_digits(x.room_number), updated_at = now() where id = x.id;
    perform fn_audit_change(x.branch_id, 'room.updated', 'room', x.id, jsonb_build_object('room_number', x.room_number),
      jsonb_build_object('room_number', fn_latin_digits(x.room_number)), 'أرقام لاتينية لرقم الوحدة (0055)');
  end loop;
end $d$;

-- ---------------------------------------------------------------------------------------------- SETUP-08 staff
create or replace function fn_valid_email(p text) returns boolean
language sql immutable set search_path = public as $$
  select p is not null and char_length(p) <= 254 and p ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$';
$$;

-- the invite with every check (the screen's call); fn_staff_invite keeps its signature and goes through it
create or replace function fn_admin_invite_staff(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp staff_profiles%rowtype; b uuid; v_email text := lower(trim(coalesce(p->>'email', ''))); v_name text := trim(coalesce(p->>'full_name', ''));
        v_role role_code; v_branches uuid[]; v_phone_in text := nullif(trim(coalesce(p->>'phone', '')), ''); v_phone text;
begin
  perform fn_require_cap('staff.manage');
  begin v_role := (p->>'role')::role_code; exception when others then raise exception 'INVALID_ROLE'; end;
  if v_role is null or v_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  if v_role = 'owner' and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if not fn_role_within_mine(v_role) then raise exception 'FORBIDDEN: a role beyond your own' using errcode = '42501'; end if;
  if v_email = '' or v_name = '' then raise exception 'VALIDATION: email_and_name'; end if;
  if not fn_valid_email(v_email) then raise exception 'VALIDATION: email'; end if;
  if char_length(v_name) > 120 then raise exception 'VALIDATION: full_name'; end if;
  if v_phone_in is not null then
    v_phone := nullif(regexp_replace(fn_latin_digits(v_phone_in), '[^0-9+]', '', 'g'), '');
    if fn_normalize_phone(v_phone) is null then raise exception 'VALIDATION: phone'; end if;
  end if;
  select coalesce(array_agg(distinct x::uuid), '{}') into v_branches from jsonb_array_elements_text(coalesce(p->'branch_ids', '[]'::jsonb)) x;
  if v_role <> 'owner' and cardinality(v_branches) = 0 then raise exception 'VALIDATION: branch_required'; end if;
  if exists (select 1 from staff_profiles where organization_id = fn_user_org_id() and lower(email) = v_email) then
    raise exception 'DUPLICATE_EMAIL';
  end if;
  insert into staff_profiles(organization_id, full_name, email, phone, role, is_active) values (fn_user_org_id(), v_name, v_email, v_phone, v_role, true) returning * into sp;
  foreach b in array v_branches loop
    perform fn_require_branch(b);
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  perform fn_audit(sp.organization_id, null, fn_staff_id(), 'staff_invited', 'staff_profile', sp.id,
                   jsonb_build_object('role', v_role, 'branch_ids', to_jsonb(v_branches), 'phone', v_phone is not null));
  return jsonb_build_object('ok', true, 'staff_id', sp.id);
end $$;
revoke all on function fn_admin_invite_staff(jsonb) from public, anon;
grant execute on function fn_admin_invite_staff(jsonb) to authenticated;

create or replace function public.fn_staff_invite(p_email text, p_full_name text, p_role role_code, p_branch_ids uuid[])
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
begin
  return fn_admin_invite_staff(jsonb_build_object('email', p_email, 'full_name', p_full_name, 'role', p_role, 'branch_ids', to_jsonb(coalesce(p_branch_ids, '{}'))));
end $function$;

-- the edit: a phone is checked; the email can be corrected until the person has signed in for the first time
create or replace function public.fn_admin_update_staff(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare sp staff_profiles%rowtype; me uuid := fn_staff_id(); v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        v_name text; v_phone text; v_role role_code; v_branches uuid[]; before_b uuid[]; after_b uuid[]; b uuid; changed text[] := '{}';
        before_j jsonb; after_j jsonb; owners int; v_email text;
begin
  perform fn_require_cap('staff.manage');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = (p->>'staff_id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if (sp.role = 'owner' or coalesce(p->>'role', '') = 'owner') and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  v_email := sp.email;
  if p ? 'email' and lower(trim(coalesce(p->>'email', ''))) is distinct from sp.email then
    if sp.auth_user_id is not null then raise exception 'EMAIL_NOT_EDITABLE'; end if;
    v_email := lower(trim(coalesce(p->>'email', '')));
    if not fn_valid_email(v_email) then raise exception 'VALIDATION: email'; end if;
    if exists (select 1 from staff_profiles where organization_id = sp.organization_id and lower(email) = v_email and id <> sp.id) then raise exception 'DUPLICATE_EMAIL'; end if;
  end if;

  v_name := case when p ? 'full_name' then nullif(trim(p->>'full_name'), '') else sp.full_name end;
  if v_name is null or char_length(v_name) > 120 then raise exception 'VALIDATION: full_name'; end if;
  if p ? 'phone' then
    if nullif(trim(coalesce(p->>'phone', '')), '') is null then v_phone := null;
    else
      v_phone := nullif(regexp_replace(fn_latin_digits(p->>'phone'), '[^0-9+]', '', 'g'), '');
      if fn_normalize_phone(v_phone) is null then raise exception 'VALIDATION: phone'; end if;
    end if;
  else v_phone := sp.phone; end if;
  v_role := case when p ? 'role' then (p->>'role')::role_code else sp.role end;
  if v_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into before_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  v_branches := case when p ? 'branch_ids' then coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(p->'branch_ids') x), '{}') else before_b end;

  if sp.id = me and (v_role is distinct from sp.role or not (v_branches <@ before_b and before_b <@ v_branches)) then
    raise exception 'SELF_ROLE_OR_BRANCHES';                                            -- no one changes their own role or branches
  end if;
  -- no one acts on a role beyond their own, or gives one (0046)
  if sp.id <> me and (not fn_role_within_mine(sp.role) or not fn_role_within_mine(v_role)) then
    raise exception 'FORBIDDEN: a role beyond your own' using errcode = '42501';
  end if;
  if sp.role = 'owner' and v_role <> 'owner' then
    select count(*) into owners from staff_profiles where organization_id = sp.organization_id and role = 'owner' and is_active and id <> sp.id;
    if owners = 0 then raise exception 'LAST_OWNER: cannot remove or demote the last active owner'; end if;
  end if;
  foreach b in array v_branches loop perform fn_require_branch(b); end loop;
  -- a branch is taken away, as it is given, only by someone in it (0046)
  foreach b in array before_b loop
    if not (b = any(v_branches)) then perform fn_require_branch(b); end if;
  end loop;

  if v_email is distinct from sp.email then changed := array_append(changed, 'email'); end if;
  if v_name is distinct from sp.full_name then changed := array_append(changed, 'full_name'); end if;
  if v_phone is distinct from sp.phone then changed := array_append(changed, 'phone'); end if;
  if v_role is distinct from sp.role then changed := array_append(changed, 'role'); end if;
  if not (v_branches <@ before_b and before_b <@ v_branches) then changed := array_append(changed, 'branches'); end if;
  if coalesce(array_length(changed, 1), 0) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;

  perform set_config('app.staff_edit', '1', true);
  update staff_profiles set email = v_email, full_name = v_name, phone = v_phone, role = v_role, updated_at = now() where id = sp.id;
  -- memberships: retire what is gone, re-open or add what is new (effective from the person's next operation)
  update branch_memberships set removed_at = now(), removed_by = me where staff_id = sp.id and removed_at is null and not (branch_id = any(v_branches));
  foreach b in array v_branches loop
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into after_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  perform set_config('app.staff_edit', '', true);

  before_j := jsonb_build_object('email', sp.email, 'full_name', sp.full_name, 'phone', case when sp.phone is null then null else '••••' || right(sp.phone, 4) end, 'role', sp.role, 'branch_ids', to_jsonb(before_b));
  after_j  := jsonb_build_object('email', v_email, 'full_name', v_name, 'phone', case when v_phone is null then null else '••••' || right(v_phone, 4) end, 'role', v_role, 'branch_ids', to_jsonb(after_b));
  perform fn_audit(sp.organization_id, null, me, case when 'role' = any(changed) then 'staff.role_changed' else 'staff.updated' end, 'staff_profile', sp.id,
                   jsonb_build_object('changed', to_jsonb(changed), 'before', before_j, 'after', after_j, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'changed', to_jsonb(changed));
end $function$;

-- ---------------------------------------------------------------------------------------------- SETUP-09 branches
create or replace function public.fn_admin_upsert_branch(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare b branches%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb; tax_changed boolean;
        v_map text := nullif(trim(coalesce(p->>'map_url', '')), ''); v_link text := nullif(trim(coalesce(p->>'booking_platform_url', '')), '');
        v_phone text := nullif(trim(fn_latin_digits(coalesce(p->>'phone', ''))), ''); v_email text := nullif(lower(trim(coalesce(p->>'email', ''))), '');
begin
  perform fn_require_cap('branch.settings');
  if coalesce(trim(p->>'name_ar'), '') = '' then raise exception 'VALIDATION: name_ar'; end if;
  -- decision 31: the English name is required (a change that leaves it out keeps the one on file)
  if (v_id is null or p ? 'name_en') and coalesce(trim(p->>'name_en'), '') = '' then raise exception 'VALIDATION: name_en'; end if;
  -- SETUP-09: one branch per name in the organisation (archived branches aside); a phone and an email that work
  if exists (select 1 from branches x where x.organization_id = fn_user_org_id() and x.archived_at is null and x.id is distinct from v_id
               and fn_normalize_ar(trim(x.name_ar)) = fn_normalize_ar(trim(p->>'name_ar'))) then
    raise exception 'DUPLICATE_BRANCH_NAME';
  end if;
  if p ? 'phone' and v_phone is not null and fn_normalize_phone(v_phone) is null then raise exception 'VALIDATION: phone'; end if;
  if p ? 'email' and v_email is not null and not fn_valid_email(v_email) then raise exception 'VALIDATION: email'; end if;
  if p ? 'timezone' then
    begin perform now() at time zone (p->>'timezone'); exception when others then raise exception 'VALIDATION: timezone'; end;
  end if;
  if (p->>'tax_rate_bp') is not null and ((p->>'tax_rate_bp') !~ '^[0-9]{1,4}$' or (p->>'tax_rate_bp')::int > 10000) then raise exception 'VALIDATION: tax_rate'; end if;
  if (p->>'default_deposit_halalas') is not null and (p->>'default_deposit_halalas') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: amount'; end if;
  if (p->>'supervisor_max_discount_bp') is not null and ((p->>'supervisor_max_discount_bp') !~ '^[0-9]{1,5}$' or (p->>'supervisor_max_discount_bp')::int > 10000) then
    raise exception 'VALIDATION: discount_limit';
  end if;
  if (p->>'country_code') is not null and (p->>'country_code') !~ '^[A-Z]{2}$' then raise exception 'VALIDATION: country'; end if;
  if (p->>'default_language') is not null and (p->>'default_language') not in ('ar', 'en') then raise exception 'VALIDATION: language'; end if;
  if v_map is not null and not fn_valid_map_url(v_map) then raise exception 'VALIDATION: map_url'; end if;
  if v_link is not null and not fn_valid_https_url(v_link) then raise exception 'VALIDATION: booking_url'; end if;
  if v_id is null then
    perform fn_require_role('owner');
    insert into branches(organization_id, name_ar, name_en, city, address, map_url, phone, email, check_in_time, check_out_time, timezone, tax_rate_bp, prices_include_tax,
                         default_deposit_halalas, tax_number, commercial_register, is_active, supervisor_max_discount_bp, country_code, default_language, booking_platform_url)
    values (fn_user_org_id(), trim(p->>'name_ar'), trim(p->>'name_en'), p->>'city', p->>'address', v_map, v_phone, v_email,
            coalesce((p->>'check_in_time')::time, '16:00'), coalesce((p->>'check_out_time')::time, '12:00'),
            coalesce(p->>'timezone', 'Asia/Riyadh'), coalesce((p->>'tax_rate_bp')::int, 0), coalesce((p->>'prices_include_tax')::boolean, false),
            coalesce((p->>'default_deposit_halalas')::bigint, 5000), nullif(trim(coalesce(p->>'tax_number', '')), ''), p->>'commercial_register', coalesce((p->>'is_active')::boolean, true),
            coalesce((p->>'supervisor_max_discount_bp')::int, 0), coalesce(p->>'country_code', 'SA'), coalesce(p->>'default_language', 'ar'), v_link)
    returning * into b;
    perform fn_room_cleaning_type(b.id);   -- (its cash box and bank account come from trg_branch_bootstrap_accounts)
    perform fn_audit_change(b.id, 'branch.created', 'branch', b.id, null, to_jsonb(b));
  else
    select * into b from branches where id = v_id and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.id);
    perform fn_check_version(b.version, (p->>'version')::int);
    tax_changed := ((p->>'tax_rate_bp') is not null and (p->>'tax_rate_bp')::int is distinct from b.tax_rate_bp)
                or ((p->>'prices_include_tax') is not null and (p->>'prices_include_tax')::boolean is distinct from b.prices_include_tax)
                or ((p ? 'tax_number') and nullif(trim(coalesce(p->>'tax_number', '')), '') is distinct from b.tax_number);
    if tax_changed and not fn_can('branch.tax') then raise exception 'FORBIDDEN: tax settings are the owner''s'; end if;
    if not (p ? 'name_en') and coalesce(trim(b.name_en), '') = '' then raise exception 'VALIDATION: name_en'; end if;
    before := to_jsonb(b);
    update branches set
      name_ar = trim(p->>'name_ar'), name_en = case when p ? 'name_en' then trim(p->>'name_en') else name_en end, city = coalesce(p->>'city', city), address = coalesce(p->>'address', address),
      map_url = case when p ? 'map_url' then v_map else map_url end,
      phone = case when p ? 'phone' then v_phone else phone end, email = case when p ? 'email' then v_email else email end,
      check_in_time = coalesce((p->>'check_in_time')::time, check_in_time), check_out_time = coalesce((p->>'check_out_time')::time, check_out_time),
      timezone = coalesce(p->>'timezone', timezone), tax_rate_bp = coalesce((p->>'tax_rate_bp')::int, tax_rate_bp),
      prices_include_tax = coalesce((p->>'prices_include_tax')::boolean, prices_include_tax),
      default_deposit_halalas = coalesce((p->>'default_deposit_halalas')::bigint, default_deposit_halalas),
      supervisor_max_discount_bp = coalesce((p->>'supervisor_max_discount_bp')::int, supervisor_max_discount_bp),
      tax_number = case when p ? 'tax_number' then nullif(trim(coalesce(p->>'tax_number', '')), '') else tax_number end,
      commercial_register = coalesce(p->>'commercial_register', commercial_register),
      country_code = coalesce(p->>'country_code', country_code), default_language = coalesce(p->>'default_language', default_language),
      booking_platform_url = case when p ? 'booking_platform_url' then v_link else booking_platform_url end,
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = b.id returning * into b;
    perform fn_audit_change(b.id, 'branch.updated', 'branch', b.id, before, to_jsonb(b));
    if tax_changed then
      perform fn_audit_change(b.id, 'branch.tax_changed', 'branch', b.id,
        jsonb_build_object('tax_rate_bp', before->'tax_rate_bp', 'prices_include_tax', before->'prices_include_tax', 'tax_number', before->'tax_number'),
        jsonb_build_object('tax_rate_bp', b.tax_rate_bp, 'prices_include_tax', b.prices_include_tax, 'tax_number', b.tax_number),
        'يسري على الحجوزات الجديدة فقط');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
end $function$;

-- ---------------------------------------------------------------------------------------------- SETUP-13 knowledge
-- the question as compared: normalised Arabic without punctuation
create or replace function fn_knowledge_question_key(p text) returns text
language sql immutable set search_path = public as $$
  select trim(regexp_replace(regexp_replace(fn_normalize_ar(p), '[؟?!.,،؛;:"''«»()\-]', ' ', 'g'), '\s+', ' ', 'g'));
$$;

create or replace function public.fn_admin_upsert_knowledge(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare k knowledge_entries%rowtype; v_org uuid; v_branch uuid; v_kw text[]; v_before jsonb; v_q text; v_a text; v_other uuid; v_active boolean;
begin
  perform fn_require_cap('knowledge');
  v_org := fn_user_org_id();
  v_branch := nullif(p->>'branch_id','')::uuid;
  if v_branch is not null then perform fn_require_branch(v_branch);
  elsif not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: org-wide entries require manager' using errcode = '42501'; end if;
  v_q := trim(coalesce(p->>'question',''));  v_a := trim(coalesce(p->>'answer',''));
  if char_length(v_q) < 3 then raise exception 'VALIDATION: question'; end if;
  if char_length(v_a) < 2 then raise exception 'VALIDATION: answer'; end if;
  if (p->>'id') is not null then
    select * into k from knowledge_entries where id = (p->>'id')::uuid and organization_id = v_org for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if not (p ? 'branch_id') then v_branch := k.branch_id; end if;
  end if;
  v_active := coalesce((p->>'is_active')::boolean, k.is_active, true);
  -- SETUP-13 (owner's decision): another active answer to the same question, for the same guests, is not added beside it;
  -- the existing one is edited instead
  if v_active then
    select x.id into v_other from knowledge_entries x
    where x.organization_id = v_org and x.archived_at is null and x.is_active and x.id is distinct from k.id
      and (x.branch_id is null or v_branch is null or x.branch_id = v_branch)
      and fn_knowledge_question_key(x.question) = fn_knowledge_question_key(v_q)
    limit 1;
    if v_other is not null then raise exception 'KNOWLEDGE_CONFLICT: %', v_other; end if;
  end if;
  -- normalized, de-duplicated, non-empty keywords; the question's own words are matched separately
  select coalesce(array_agg(distinct w order by w), '{}') into v_kw
  from (select fn_normalize_ar(x) w from jsonb_array_elements_text(coalesce(p->'keywords','[]'::jsonb)) x) s
  where char_length(w) >= 2;
  if (p->>'id') is null then
    insert into knowledge_entries(organization_id, branch_id, category, question, keywords, answer, answer_en, is_public, is_active, priority, created_by, updated_by)
    values (v_org, v_branch, coalesce(p->>'category','general'), v_q, v_kw, v_a, nullif(trim(coalesce(p->>'answer_en','')),''),
            coalesce((p->>'is_public')::boolean, true), coalesce((p->>'is_active')::boolean, true), coalesce((p->>'priority')::int, 0), fn_staff_id(), fn_staff_id())
    returning * into k;
    perform fn_audit(v_org, v_branch, fn_staff_id(), 'knowledge.created', 'knowledge_entry', k.id, jsonb_build_object('after', jsonb_build_object('question', k.question, 'keywords', k.keywords, 'is_public', k.is_public)));
  else
    if k.branch_id is not null then perform fn_require_branch(k.branch_id); end if;
    if (p->>'version') is null then raise exception 'VERSION_REQUIRED'; end if;
    perform fn_check_version(k.version, (p->>'version')::int);
    v_before := jsonb_build_object('question', k.question, 'answer', k.answer, 'keywords', k.keywords, 'is_public', k.is_public, 'is_active', k.is_active, 'category', k.category, 'branch_id', k.branch_id);
    update knowledge_entries set
      branch_id = case when p ? 'branch_id' then v_branch else branch_id end,
      category = coalesce(p->>'category', category), question = v_q, keywords = v_kw, answer = v_a,
      answer_en = case when p ? 'answer_en' then nullif(trim(coalesce(p->>'answer_en','')),'') else answer_en end,
      is_public = coalesce((p->>'is_public')::boolean, is_public), is_active = coalesce((p->>'is_active')::boolean, is_active),
      priority = coalesce((p->>'priority')::int, priority), version = version + 1, updated_by = fn_staff_id(), updated_at = now()
    where id = k.id returning * into k;
    perform fn_audit(v_org, k.branch_id, fn_staff_id(), 'knowledge.updated', 'knowledge_entry', k.id,
      jsonb_build_object('before', v_before, 'after', jsonb_build_object('question', k.question, 'answer', k.answer, 'keywords', k.keywords, 'is_public', k.is_public, 'is_active', k.is_active, 'category', k.category, 'branch_id', k.branch_id), 'reason', p->>'reason'));
  end if;
  -- an unanswered question linked to this entry is now answered
  if (p->>'unanswered_id') is not null then
    update unanswered_questions set status = 'answered', knowledge_entry_id = k.id, resolved_by = fn_staff_id(), resolved_at = now()
    where id = (p->>'unanswered_id')::uuid and organization_id = v_org;
  end if;
  return jsonb_build_object('ok', true, 'id', k.id, 'version', k.version);
end $function$;

-- the helpers are used inside the functions above only
revoke all on function fn_latin_digits(text) from public, anon, authenticated;
revoke all on function fn_valid_email(text) from public, anon, authenticated;
revoke all on function fn_knowledge_question_key(text) from public, anon, authenticated;
