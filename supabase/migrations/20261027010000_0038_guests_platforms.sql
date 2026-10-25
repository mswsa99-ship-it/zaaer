-- =====================================================================
-- 0038 — guests, platforms and the website (phase 5).
--   decision 2   guest data on two paths: the guest's own form (as before), or the owner, a manager or a supervisor
--                from the original document («طابقتُ الوثيقة الأصلية»), which verifies it at once. A correction needs a
--                reason and is recorded with masked values before and after. Each verified document links its guest to
--                a guest profile (search, previous stays); two profiles that share a phone or a document are shown as a
--                possible duplicate and never merged. The owner's report lists the identities approved at the office.
--   decision 21  a guest ban (owner or manager, with a reason) matched by profile, phone or identity fingerprint: a red
--                alert on the guest's bookings and no arrival while it stands; lifting it needs a reason too. A hold on
--                one booking (owner, manager or supervisor; lifted by the owner or a manager). A rating 1–5 with an
--                internal note that staff see on the guest's next bookings.
--   decision 22  the twelve booking sources, each with a code, a kind and whether it needs the platform's number; the
--                screen only switches them on and off.
--   decision 4   platform fields at creation (the platform's number, who collects, the date booked there); a platform
--                that collects gets its receipt «آجل عبر المنصات» automatically; cancelling by the platform's
--                cancellation number refunds nothing; the arrivals of today and tomorrow are matched against the
--                platform; the owner's report of bookings entered late.
--   decision 69  one platform number for a group: its units share it, another group or booking may not use it.
--   decision 19  «ملخص الإقامة» (the stay, its money, the deposit and the branch's policies) that the guest accepts
--                when registering or signs on paper; the time and the exact text are kept.
--   decision 31  the branch's English name (required), country, default language, Google Maps link, booking platform
--                link, logo (PNG, JPG or WebP up to 200 KB) and image (up to 1 MB), kept with the branch's settings.
--   decision 23  no availability for guests: the public availability is no longer open to visitors.
-- Applied through the SQL tools, so it only adds and updates. 0039 (the owner's paste) retires the older one-booking
-- index on the platform number, after which a group can share its number.
-- =====================================================================
select set_config('app.source', 'migration', true);
-- pgcrypto lives in "extensions" on the hosted project
select set_config('search_path', 'public, extensions', true);

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The identity fingerprint: a keyed hash of the document number, so a document can be matched (the same guest
--    again, a ban, a duplicate) without decrypting anything. A Saudi national ID and an iqama share one number space.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_identity_fingerprint(p_type identity_type, p_number text)
returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare n text := upper(regexp_replace(coalesce(p_number, ''), '\s', '', 'g'));
begin
  if n = '' or p_type is null then return null; end if;
  return encode(hmac('fp|' || case p_type when 'national_id' then 'sa' when 'iqama' then 'sa' when 'gcc_id' then 'gcc' else 'pp' end || '|' || n,
                     fn_secret('identity_key'), 'sha256'), 'hex');
end $$;
revoke all on function fn_identity_fingerprint(identity_type, text) from public, anon, authenticated;

alter table reservation_guests add column if not exists identity_fingerprint text;
alter table reservation_guests add column if not exists entry_path text;          -- guest | office
alter table reservation_guests add column if not exists entered_by uuid;
alter table reservation_guests add column if not exists entered_at timestamptz;
alter table reservation_guests add column if not exists verified_by uuid;
alter table reservation_guests add column if not exists verified_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservation_guests_entry_path_chk') then
    alter table reservation_guests add constraint reservation_guests_entry_path_chk check (entry_path is null or entry_path in ('guest', 'office'));
  end if;
end $$;
create index if not exists idx_resguests_fingerprint on reservation_guests(identity_fingerprint) where identity_fingerprint is not null;
create index if not exists idx_resguests_profile on reservation_guests(guest_profile_id) where guest_profile_id is not null;
-- the guest columns are readable column by column (0009): the new ones except the fingerprint
do $$ begin
  if has_column_privilege('authenticated', 'public.reservation_guests', 'full_name', 'SELECT')
     and not has_table_privilege('authenticated', 'public.reservation_guests', 'SELECT') then
    grant select (entry_path, entered_by, entered_at, verified_by, verified_at) on public.reservation_guests to authenticated;
  end if;
end $$;

-- the documents already on file get their fingerprint (decrypted inside the database only)
update reservation_guests g
   set identity_fingerprint = fn_identity_fingerprint(g.identity_type, pgp_sym_decrypt(g.identity_number_encrypted, fn_secret('identity_key')))
 where g.identity_number_encrypted is not null and g.identity_fingerprint is null and g.identity_type is not null;
-- who entered and who approved what is already on file (the audit trail), so the owner's report starts complete
update reservation_guests g set entry_path = 'guest',
       entered_at = coalesce((select max(e.created_at) from audit_events e where e.entity_id = g.id and e.action = 'guest_data_submitted'), g.created_at)
 where g.data_submitted and g.entry_path is null;
update reservation_guests g set verified_by = e.actor_id, verified_at = e.created_at
  from (select distinct on (entity_id) entity_id, actor_id, created_at from audit_events
         where action = 'approve_identity' and entity_type = 'reservation_guest' order by entity_id, created_at desc) e
 where e.entity_id = g.id and g.verification_status = 'verified' and g.verified_at is null;

-- what an audit entry may say about a guest: the document's last four digits, the birth year, the phone's last four
create or replace function fn_guest_masked(p_guest uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'guest_id', g.id, 'full_name', g.full_name, 'identity_type', g.identity_type,
    'identity_number', case when g.identity_number_last4 is not null then '••••' || g.identity_number_last4 end,
    'identity_issue_number', case when g.identity_issue_number is not null then '••' || right(g.identity_issue_number, 2) end,
    'nationality', g.nationality, 'birth_year', extract(year from g.birth_date)::int,
    'phone', case when g.phone is not null then '••••' || right(regexp_replace(g.phone, '\D', '', 'g'), 4) end,
    'relationship', g.relationship, 'verification_status', g.verification_status, 'entry_path', g.entry_path))
  from reservation_guests g where g.id = p_guest;
$$;
revoke all on function fn_guest_masked(uuid) from public, anon, authenticated;

-- one stay's identity status from its guests: all verified (and as many as booked) → verified; one refused → rejected
create or replace function fn_rollup_identity(p_reservation uuid)
returns guest_verification_status language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; n int; s int; v int; rj int; req int; st guest_verification_status;
begin
  select * into r from reservations where id = p_reservation;
  select count(*), count(*) filter (where data_submitted), count(*) filter (where verification_status = 'verified'),
         count(*) filter (where verification_status = 'rejected')
    into n, s, v, rj from reservation_guests where reservation_id = p_reservation;
  req := r.adults + r.companions;
  st := case when v >= req and v = n and n > 0 then 'verified'
             when rj > 0 then 'rejected'
             when s >= req and s = n and n > 0 then 'pending_supervisor'
             when s > 0 then 'data_submitted'
             else 'not_started' end;
  if st is distinct from r.identity_status then
    update reservations set identity_status = st, updated_at = now() where id = p_reservation;
  end if;
  return st;
end $$;
revoke all on function fn_rollup_identity(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Guest profiles: the document that identifies them, a rating with an internal note; read only through functions
-- ---------------------------------------------------------------------------------------------------------------
alter table guest_profiles add column if not exists identity_fingerprint text;
alter table guest_profiles add column if not exists identity_type identity_type;
alter table guest_profiles add column if not exists identity_last4 text;
alter table guest_profiles add column if not exists rating smallint;
alter table guest_profiles add column if not exists rating_note text;
alter table guest_profiles add column if not exists rated_by uuid;
alter table guest_profiles add column if not exists rated_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'guest_profiles_rating_chk') then
    alter table guest_profiles add constraint guest_profiles_rating_chk check (rating is null or rating between 1 and 5);
  end if;
end $$;
create index if not exists idx_guest_profiles_fingerprint on guest_profiles(organization_id, identity_fingerprint) where identity_fingerprint is not null;
create index if not exists idx_guest_profiles_phone_norm on guest_profiles(organization_id, fn_normalize_phone(phone)) where phone is not null;
-- staff read profiles through fn_guest_profiles / fn_guest_profile; the table itself shows no fingerprint to anyone
revoke all on guest_profiles from anon, authenticated;
grant select (id, organization_id, full_name, phone, nationality, email, notes, created_at, updated_at, identity_type, identity_last4,
              rating, rating_note, rated_by, rated_at) on guest_profiles to authenticated;

-- a profile takes the document of its first verified stay
update guest_profiles p set identity_fingerprint = x.identity_fingerprint, identity_type = x.identity_type, identity_last4 = x.identity_number_last4
  from (select distinct on (guest_profile_id) guest_profile_id, identity_fingerprint, identity_type, identity_number_last4
          from reservation_guests where guest_profile_id is not null and identity_fingerprint is not null and verification_status = 'verified'
         order by guest_profile_id, created_at) x
 where x.guest_profile_id = p.id and p.identity_fingerprint is null;

-- a verified guest joins a profile: the one it already has, else the one profile with the same document, else a new one.
-- Two or more profiles with that document: the guest stays unlinked and the profiles show as a possible duplicate.
create or replace function fn_link_guest_profile(p_guest uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare g reservation_guests%rowtype; v_org uuid; n int; v uuid;
begin
  select * into g from reservation_guests where id = p_guest;
  if not found or g.identity_fingerprint is null or g.verification_status <> 'verified' then return g.guest_profile_id; end if;
  select organization_id into v_org from reservations where id = g.reservation_id;
  if g.guest_profile_id is not null then
    update guest_profiles set identity_fingerprint = g.identity_fingerprint, identity_type = g.identity_type, identity_last4 = g.identity_number_last4,
           nationality = coalesce(nationality, g.nationality), updated_at = now()
     where id = g.guest_profile_id and identity_fingerprint is null;
    return g.guest_profile_id;
  end if;
  select count(*), (array_agg(id))[1] into n, v from guest_profiles where organization_id = v_org and identity_fingerprint = g.identity_fingerprint;
  if n = 0 then
    insert into guest_profiles(organization_id, full_name, phone, nationality, identity_fingerprint, identity_type, identity_last4)
    values (v_org, g.full_name, g.phone, g.nationality, g.identity_fingerprint, g.identity_type, g.identity_number_last4) returning id into v;
  elsif n > 1 then
    return null;
  end if;
  update reservation_guests set guest_profile_id = v where id = g.id;
  return v;
end $$;
revoke all on function fn_link_guest_profile(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Guest bans (decision 21): matched by the profile, a phone or a document seen on it when it was banned
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists guest_bans (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  guest_profile_id uuid,              -- the banned profile; 0039 links it (a purged profile leaves its ban standing)
  name_snapshot text not null,
  phones text[] not null default '{}',
  fingerprints text[] not null default '{}',
  reason text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  lifted_at timestamptz,
  lifted_by uuid,
  lift_reason text
);
create unique index if not exists uniq_guest_ban_active on guest_bans(guest_profile_id) where lifted_at is null and guest_profile_id is not null;
create index if not exists idx_guest_bans_active on guest_bans(organization_id) where lifted_at is null;
alter table guest_bans enable row level security;
revoke all on guest_bans from anon, authenticated;

-- the active bans that match a stay's guests, one entry per ban, with every way it matched (profile, document, phone)
create or replace function fn_reservation_ban_matches(p_reservation uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('ban_id', m.id, 'name', m.name_snapshot, 'reason', m.reason, 'since', m.created_at, 'matched_by', to_jsonb(m.matched_by))
                            order by m.created_at), '[]'::jsonb)
  from (
    select b.id, b.name_snapshot, b.reason, b.created_at, array_agg(distinct k.kind order by k.kind) as matched_by
    from reservation_guests g
    join reservations r on r.id = g.reservation_id
    join guest_bans b on b.organization_id = r.organization_id and b.lifted_at is null
    cross join lateral unnest(array[
      case when g.guest_profile_id is not null and g.guest_profile_id = b.guest_profile_id then 'profile' end,
      case when g.identity_fingerprint is not null and g.identity_fingerprint = any(b.fingerprints) then 'identity' end,
      case when fn_normalize_phone(g.phone) is not null and fn_normalize_phone(g.phone) = any(b.phones) then 'phone' end]) as k(kind)
    where g.reservation_id = p_reservation and k.kind is not null
    group by b.id, b.name_snapshot, b.reason, b.created_at) m;
$$;
revoke all on function fn_reservation_ban_matches(uuid) from public, anon, authenticated;

create or replace function fn_profile_banned(p_profile uuid)
returns guest_bans language sql stable security definer set search_path = public as $$
  select b.* from guest_profiles p join guest_bans b on b.organization_id = p.organization_id and b.lifted_at is null
   and (b.guest_profile_id = p.id
        or (p.identity_fingerprint is not null and p.identity_fingerprint = any(b.fingerprints))
        or (fn_normalize_phone(p.phone) is not null and fn_normalize_phone(p.phone) = any(b.phones)))
  where p.id = p_profile order by b.created_at limit 1;
$$;
revoke all on function fn_profile_banned(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Reservation columns: platform fields (decision 4), the platform's cancellation number, who held the booking
-- ---------------------------------------------------------------------------------------------------------------
alter table reservations add column if not exists platform_booked_on date;
alter table reservations add column if not exists platform_collects boolean;
alter table reservations add column if not exists platform_verified_at timestamptz;
alter table reservations add column if not exists platform_verified_by uuid;
alter table reservations add column if not exists cancel_reference text;
alter table reservations add column if not exists security_hold_by uuid;
alter table reservations add column if not exists security_hold_at timestamptz;
do $$ begin
  -- reservations are readable column by column (0009, 0035): none of these carries money
  if has_column_privilege('authenticated', 'public.reservations', 'status', 'SELECT')
     and not has_table_privilege('authenticated', 'public.reservations', 'SELECT') then
    grant select (platform_booked_on, platform_collects, platform_verified_at, platform_verified_by, cancel_reference, security_hold_by, security_hold_at)
      on public.reservations to authenticated;
  end if;
end $$;

-- decision 69: a platform number belongs to one booking or one group. Its units share it; another group or booking may
-- not use it. (The older unique index allowed one booking only; 0039 retires it.)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'excl_reservation_source_ref') then
    alter table reservations add constraint excl_reservation_source_ref exclude using gist
      (organization_id with =, source_id with =, external_ref with =, (coalesce(group_ref, id::text)) with <>) where (external_ref is not null);
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. The twelve booking sources (decision 22). A platform is "external" (its own prices, who collects is asked);
--    the reception is "direct". Booking Engine is a direct online booking, which the property does not take (decision
--    23): it is added switched off. Names and kinds follow this list; whether a source is on stays the owner's choice.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_seed_booking_sources(p_org uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into booking_sources(organization_id, code, name, kind, external_reference_required, is_active)
  select p_org, s.code, s.name, s.kind, s.ref, s.active
  from (values ('reception', 'الاستقبال', 'direct', false, true),
               ('booking_com', 'Booking.com', 'external', true, true),
               ('airbnb', 'Airbnb', 'external', true, true),
               ('almosafer', 'Almosafer Web', 'external', true, true),
               ('airport', 'المطار', 'external', false, true),
               ('agoda', 'Agoda.com', 'external', true, true),
               ('hotels_com', 'Hotels.com', 'external', true, true),
               ('expedia', 'Expedia', 'external', true, true),
               ('jathr_inn', 'جذر إن', 'external', true, true),
               ('booking_engine', 'Booking Engine', 'direct', true, false),
               ('trip_com', 'Trip.Com', 'external', true, true),
               ('gathern', 'Gathern', 'external', true, true)) as s(code, name, kind, ref, active)
  on conflict (organization_id, code) do update
     set name = excluded.name, kind = excluded.kind, external_reference_required = excluded.external_reference_required;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function fn_seed_booking_sources(uuid) from public, anon, authenticated;
select fn_seed_booking_sources(id) from organizations;

-- the list is fixed: staff read it; switching a source on or off goes through fn_admin_set_source_active (audited)
revoke all on booking_sources from anon, authenticated;
grant select on booking_sources to authenticated;

create or replace function fn_admin_set_source_active(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s booking_sources%rowtype; v_active boolean := (p->>'is_active')::boolean;
begin
  perform fn_require_role('owner', 'manager');
  if v_active is null then raise exception 'VALIDATION: is_active'; end if;
  select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.is_active = v_active then return jsonb_build_object('ok', true, 'changed', false); end if;
  update booking_sources set is_active = v_active where id = s.id;
  perform fn_audit_change(null, case when v_active then 'source.enabled' else 'source.disabled' end, 'booking_source', s.id,
    jsonb_build_object('code', s.code, 'is_active', s.is_active), jsonb_build_object('code', s.code, 'is_active', v_active), nullif(trim(coalesce(p->>'reason', '')), ''));
  return jsonb_build_object('ok', true, 'changed', true);
end $$;
revoke all on function fn_admin_set_source_active(jsonb) from public, anon;
grant execute on function fn_admin_set_source_active(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Branch fields (decision 31)
-- ---------------------------------------------------------------------------------------------------------------
alter table branches add column if not exists country_code text not null default 'SA';
alter table branches add column if not exists default_language text not null default 'ar';
alter table branches add column if not exists booking_platform_url text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'branches_default_language_chk') then
    alter table branches add constraint branches_default_language_chk check (default_language in ('ar', 'en'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'branches_country_code_chk') then
    alter table branches add constraint branches_country_code_chk check (country_code ~ '^[A-Z]{2}$');
  end if;
end $$;

-- the logo and the branch image live with the branch's settings (no file store)
create table if not exists branch_media (
  branch_id uuid not null,            -- 0039 ties it to its branch (the media go with an unused branch removed)
  kind text not null check (kind in ('logo', 'image')),
  mime text,
  bytes bytea,
  size_bytes int not null default 0,
  sha256 text,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (branch_id, kind)
);
alter table branch_media enable row level security;
revoke all on branch_media from anon, authenticated;

create or replace function fn_valid_map_url(p text) returns boolean language sql immutable set search_path = public as $$
  select p ~* '^https://((www\.)?google\.[a-z.]{2,10}/maps|maps\.google\.[a-z.]{2,10}/|maps\.app\.goo\.gl/|goo\.gl/maps/)[^\s<>"]*$' and length(p) <= 500;
$$;
create or replace function fn_valid_https_url(p text) returns boolean language sql immutable set search_path = public as $$
  select p ~* '^https://[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]{2,5})?(/[^\s<>"]*)?$' and length(p) <= 500;
$$;

create or replace function fn_admin_upsert_branch(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb; tax_changed boolean;
        v_map text := nullif(trim(coalesce(p->>'map_url', '')), ''); v_link text := nullif(trim(coalesce(p->>'booking_platform_url', '')), '');
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p->>'name_ar'), '') = '' then raise exception 'VALIDATION: name_ar'; end if;
  -- decision 31: the English name is required (a change that leaves it out keeps the one on file)
  if (v_id is null or p ? 'name_en') and coalesce(trim(p->>'name_en'), '') = '' then raise exception 'VALIDATION: name_en'; end if;
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
    values (fn_user_org_id(), trim(p->>'name_ar'), trim(p->>'name_en'), p->>'city', p->>'address', v_map, p->>'phone', p->>'email',
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
    if tax_changed and not fn_has_role('owner') then raise exception 'FORBIDDEN: tax settings are the owner''s'; end if;
    if not (p ? 'name_en') and coalesce(trim(b.name_en), '') = '' then raise exception 'VALIDATION: name_en'; end if;
    before := to_jsonb(b);
    update branches set
      name_ar = trim(p->>'name_ar'), name_en = case when p ? 'name_en' then trim(p->>'name_en') else name_en end, city = coalesce(p->>'city', city), address = coalesce(p->>'address', address),
      map_url = case when p ? 'map_url' then v_map else map_url end, phone = coalesce(p->>'phone', phone), email = coalesce(p->>'email', email),
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
end $$;
revoke all on function fn_admin_upsert_branch(jsonb) from public, anon;
grant execute on function fn_admin_upsert_branch(jsonb) to authenticated;

-- the logo (PNG, JPG or WebP up to 200 KB) or the branch image (up to 1 MB). The type is read from the file's own first
-- bytes, never from its name, so an SVG or a page renamed .png is refused. An empty payload clears it.
create or replace function fn_admin_set_branch_media(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_kind text := p->>'kind'; raw text := regexp_replace(coalesce(p->>'data_base64', ''), '^data:[^,]*,', '');
        bin bytea; v_mime text; v_limit int; cur branch_media%rowtype; before jsonb; after jsonb;
begin
  perform fn_require_role('owner', 'manager');
  perform fn_require_branch(v_branch);
  if v_kind not in ('logo', 'image') then raise exception 'VALIDATION: kind'; end if;
  select * into cur from branch_media where branch_id = v_branch and kind = v_kind for update;
  before := case when found and cur.bytes is not null then jsonb_build_object('mime', cur.mime, 'size_bytes', cur.size_bytes, 'sha256', cur.sha256) end;
  if raw = '' then
    if cur.branch_id is null then return jsonb_build_object('ok', true, 'changed', false); end if;
    update branch_media set mime = null, bytes = null, size_bytes = 0, sha256 = null, updated_at = now(), updated_by = fn_staff_id() where branch_id = v_branch and kind = v_kind;
  else
    begin bin := decode(regexp_replace(raw, '\s', '', 'g'), 'base64'); exception when others then raise exception 'VALIDATION: image'; end;
    v_limit := case v_kind when 'logo' then 204800 else 1048576 end;
    if length(bin) > v_limit then raise exception 'VALIDATION: image_too_large'; end if;
    v_mime := case when substring(bin from 1 for 8) = '\x89504e470d0a1a0a'::bytea then 'image/png'
                   when substring(bin from 1 for 3) = '\xffd8ff'::bytea then 'image/jpeg'
                   when substring(bin from 1 for 4) = '\x52494646'::bytea and substring(bin from 9 for 4) = '\x57454250'::bytea then 'image/webp' end;
    if v_mime is null then raise exception 'VALIDATION: image_type'; end if;
    insert into branch_media(branch_id, kind, mime, bytes, size_bytes, sha256, updated_at, updated_by)
    values (v_branch, v_kind, v_mime, bin, length(bin), encode(digest(bin, 'sha256'), 'hex'), now(), fn_staff_id())
    on conflict (branch_id, kind) do update set mime = excluded.mime, bytes = excluded.bytes, size_bytes = excluded.size_bytes, sha256 = excluded.sha256,
                                                updated_at = excluded.updated_at, updated_by = excluded.updated_by;
    after := jsonb_build_object('mime', v_mime, 'size_bytes', length(bin), 'sha256', encode(digest(bin, 'sha256'), 'hex'));
  end if;
  perform fn_audit_change(v_branch, 'branch.' || v_kind || '_changed', 'branch', v_branch, before, after);
  return jsonb_build_object('ok', true, 'changed', true, 'media', after);
end $$;
revoke all on function fn_admin_set_branch_media(jsonb) from public, anon;
grant execute on function fn_admin_set_branch_media(jsonb) to authenticated;

-- the logo or image as a data URL: public for an active branch (guest pages, printouts), staff of the branch otherwise
create or replace function fn_branch_media(p_branch uuid, p_kind text)
returns text language sql stable security definer set search_path = public as $$
  select 'data:' || m.mime || ';base64,' || replace(encode(m.bytes, 'base64'), E'\n', '')
  from branch_media m join branches b on b.id = m.branch_id
  where m.branch_id = p_branch and m.kind = p_kind and m.bytes is not null
    and (b.is_active or b.id in (select fn_user_branch_ids()));
$$;
revoke all on function fn_branch_media(uuid, text) from public;
grant execute on function fn_branch_media(uuid, text) to anon, authenticated, service_role;

-- what a guest page and the assistant may show of a branch
create or replace function fn_public_branch(p_branch uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', b.id, 'name_ar', b.name_ar, 'name_en', b.name_en, 'city', b.city, 'address', b.address, 'phone', b.phone,
           'map_url', b.map_url, 'booking_platform_url', b.booking_platform_url, 'default_language', b.default_language, 'country_code', b.country_code,
           'check_in_time', to_char(b.check_in_time, 'HH24:MI'), 'check_out_time', to_char(b.check_out_time, 'HH24:MI'),
           'logo_version', (select left(sha256, 12) from branch_media where branch_id = b.id and kind = 'logo' and bytes is not null),
           'image_version', (select left(sha256, 12) from branch_media where branch_id = b.id and kind = 'image' and bytes is not null))
  from branches b where b.id = p_branch and (b.is_active or b.id in (select fn_user_branch_ids()));
$$;
revoke all on function fn_public_branch(uuid) from public;
grant execute on function fn_public_branch(uuid) to anon, authenticated, service_role;

-- staff: media of the branches they manage (the branch screen shows what is set without downloading it)
create or replace function fn_admin_branch_media_info(p_branch uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_role('owner', 'manager');
  perform fn_require_branch(p_branch);
  return coalesce((select jsonb_object_agg(kind, jsonb_build_object('mime', mime, 'size_bytes', size_bytes, 'updated_at', updated_at,
                                                                     'updated_by', (select full_name from staff_profiles where id = m.updated_by)))
                   from branch_media m where m.branch_id = p_branch and m.bytes is not null), '{}'::jsonb);
end $$;
revoke all on function fn_admin_branch_media_info(uuid) from public, anon;
grant execute on function fn_admin_branch_media_info(uuid) to authenticated;

-- decision 23: guests see no availability (the function stays for the staff's own tools)
revoke all on function fn_get_public_availability(uuid, date) from public, anon;
grant execute on function fn_get_public_availability(uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 7. «ملخص الإقامة» (decision 19): the stay, its money, the deposit and the branch's public policies, in the branch's
--    default language. Its exact text is what the guest accepts (electronically or on paper) and what is kept.
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists stay_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  reservation_id uuid not null,       -- 0039 ties it to its stay, so a purge takes it along
  guest_id uuid,
  method text not null check (method in ('electronic', 'paper')),
  language text not null default 'ar',
  text_snapshot text not null,
  text_hash text not null,
  accepted_at timestamptz not null default now(),
  recorded_by uuid
);
create index if not exists idx_stay_ack_reservation on stay_acknowledgements(reservation_id, accepted_at desc);
alter table stay_acknowledgements enable row level security;
revoke all on stay_acknowledgements from anon, authenticated;

create or replace function fn_money_text(p bigint, p_lang text)
returns text language sql immutable set search_path = public as $$
  select case when p_lang = 'en' then 'SAR ' || to_char(coalesce(p, 0) / 100.0, 'FM999,999,990.00')
              else to_char(coalesce(p, 0) / 100.0, 'FM999,999,990.00') || ' ر.س' end;
$$;
revoke all on function fn_money_text(bigint, text) from public, anon, authenticated;

create or replace function fn_stay_summary_internal(p_reservation uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare r reservations%rowtype; b branches%rowtype; lang text; en boolean; src booking_sources%rowtype; cat room_categories%rowtype; v_room text;
        f jsonb; g_name text; pols jsonb; t text[] := '{}'; pol record; nights int; ci text; co text; v_text text; dep bigint;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return null; end if;
  select * into b from branches where id = r.branch_id;
  lang := coalesce(b.default_language, 'ar'); en := lang = 'en';
  select * into src from booking_sources where id = r.source_id;
  select * into cat from room_categories where id = r.room_category_id;
  select room_number into v_room from rooms where id = r.room_id;
  select full_name into g_name from reservation_guests where reservation_id = r.id and is_primary order by created_at limit 1;
  f := fn_reservation_finance_internal(r.id);
  nights := r.check_out - r.check_in;
  ci := to_char(coalesce(b.check_in_time, time '16:00'), 'HH24:MI');
  co := to_char(coalesce(r.late_checkout_until, b.check_out_time, time '12:00'), 'HH24:MI');
  dep := coalesce(b.default_deposit_halalas, 0);
  select coalesce(jsonb_agg(jsonb_build_object('title', x.title, 'content', x.content) order by x.sort_order, x.created_at), '[]'::jsonb) into pols
  from (select p.title, case when en and coalesce(trim(p.content_en), '') <> '' then p.content_en else p.content_ar end as content, p.sort_order, p.created_at
          from property_policies p where p.branch_id = r.branch_id and p.is_public) x;

  if en then
    t := t || ('Stay summary — ' || coalesce(nullif(b.name_en, ''), b.name_ar));
    t := t || ('Booking: ' || r.internal_ref);
    if r.external_ref is not null then t := t || ('Platform booking number: ' || r.external_ref || coalesce(' (' || src.name || ')', '')); end if;
    if g_name is not null then t := t || ('Guest: ' || g_name); end if;
    t := t || ('Unit: ' || coalesce(nullif(cat.name_en, ''), cat.name_ar, '—') || coalesce(' — no. ' || v_room, ''));
    t := t || ('Arrival: ' || r.check_in || ' from ' || ci);
    t := t || ('Departure: ' || r.check_out || ' by ' || co);
    t := t || ('Nights: ' || nights);
    t := t || ('Rent: ' || fn_money_text((f->>'rent')::bigint, lang));
    if (f->>'discounts')::bigint <> 0 then t := t || ('Discount: ' || fn_money_text(abs((f->>'discounts')::bigint), lang)); end if;
    if (f->>'addons')::bigint + (f->>'penalties')::bigint + (f->>'adjustments')::bigint <> 0 then
      t := t || ('Extras: ' || fn_money_text((f->>'addons')::bigint + (f->>'penalties')::bigint + (f->>'adjustments')::bigint, lang)); end if;
    if (f->>'tax')::bigint <> 0 then t := t || ('Tax: ' || fn_money_text((f->>'tax')::bigint, lang)); end if;
    t := t || ('Total: ' || fn_money_text((f->>'total')::bigint, lang));
    t := t || ('Paid: ' || fn_money_text((f->>'net_collected')::bigint, lang));
    t := t || ('Balance: ' || fn_money_text((f->>'balance_due')::bigint, lang));
    t := t || ('Deposit: ' || fn_money_text(dep, lang) || ' per unit, returned after the unit is inspected at departure'
               || case when (f->>'deposit_balance')::bigint > 0 then ' (held: ' || fn_money_text((f->>'deposit_balance')::bigint, lang) || ')' else '' end);
    if jsonb_array_length(pols) > 0 then t := t || ''::text || 'Branch policies:'::text; end if;
  else
    t := t || ('ملخص الإقامة — ' || b.name_ar);
    t := t || ('الحجز: ' || r.internal_ref);
    if r.external_ref is not null then t := t || ('رقم الحجز في المنصة: ' || r.external_ref || coalesce(' (' || src.name || ')', '')); end if;
    if g_name is not null then t := t || ('الضيف: ' || g_name); end if;
    t := t || ('الوحدة: ' || coalesce(cat.name_ar, '—') || coalesce(' — رقم ' || v_room, ''));
    t := t || ('الوصول: ' || r.check_in || ' من الساعة ' || ci);
    t := t || ('المغادرة: ' || r.check_out || ' حتى الساعة ' || co);
    t := t || ('عدد الليالي: ' || nights);
    t := t || ('الإيجار: ' || fn_money_text((f->>'rent')::bigint, lang));
    if (f->>'discounts')::bigint <> 0 then t := t || ('الخصم: ' || fn_money_text(abs((f->>'discounts')::bigint), lang)); end if;
    if (f->>'addons')::bigint + (f->>'penalties')::bigint + (f->>'adjustments')::bigint <> 0 then
      t := t || ('الإضافات: ' || fn_money_text((f->>'addons')::bigint + (f->>'penalties')::bigint + (f->>'adjustments')::bigint, lang)); end if;
    if (f->>'tax')::bigint <> 0 then t := t || ('الضريبة: ' || fn_money_text((f->>'tax')::bigint, lang)); end if;
    t := t || ('الإجمالي: ' || fn_money_text((f->>'total')::bigint, lang));
    t := t || ('المدفوع: ' || fn_money_text((f->>'net_collected')::bigint, lang));
    t := t || ('المتبقي: ' || fn_money_text((f->>'balance_due')::bigint, lang));
    t := t || ('التأمين: ' || fn_money_text(dep, lang) || ' للوحدة، يُرد بعد فحص الوحدة عند المغادرة'
               || case when (f->>'deposit_balance')::bigint > 0 then ' (المقبوض: ' || fn_money_text((f->>'deposit_balance')::bigint, lang) || ')' else '' end);
    if jsonb_array_length(pols) > 0 then t := t || ''::text || 'سياسات الفرع:'::text; end if;
  end if;
  for pol in select x->>'title' as title, x->>'content' as content from jsonb_array_elements(pols) x loop
    t := t || ('• ' || pol.title || ': ' || regexp_replace(pol.content, '\s+', ' ', 'g'));
  end loop;
  v_text := array_to_string(t, E'\n');
  return jsonb_build_object(
    'language', lang, 'text', v_text, 'hash', encode(digest(v_text, 'sha256'), 'hex'),
    'branch', jsonb_build_object('id', b.id, 'name', case when en then coalesce(nullif(b.name_en, ''), b.name_ar) else b.name_ar end, 'name_ar', b.name_ar, 'name_en', b.name_en,
                                 'city', b.city, 'address', b.address, 'phone', b.phone, 'country_code', b.country_code, 'commercial_register', b.commercial_register,
                                 'logo_version', (select left(sha256, 12) from branch_media where branch_id = b.id and kind = 'logo' and bytes is not null)),
    'reservation', jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'source', src.name, 'guest_name', g_name,
                                      'category', case when en then coalesce(nullif(cat.name_en, ''), cat.name_ar) else cat.name_ar end, 'room_number', v_room,
                                      'check_in', r.check_in, 'check_out', r.check_out, 'check_in_time', ci, 'check_out_time', co, 'nights', nights),
    'money', jsonb_build_object('rent', (f->>'rent')::bigint, 'discounts', (f->>'discounts')::bigint,
                                'extras', (f->>'addons')::bigint + (f->>'penalties')::bigint + (f->>'adjustments')::bigint, 'tax', (f->>'tax')::bigint,
                                'total', (f->>'total')::bigint, 'paid', (f->>'net_collected')::bigint, 'balance', (f->>'balance_due')::bigint,
                                'deposit_required', dep, 'deposit_held', (f->>'deposit_balance')::bigint),
    'policies', pols);
end $$;
revoke all on function fn_stay_summary_internal(uuid) from public, anon, authenticated;

create or replace function fn_record_ack(p_reservation uuid, p_guest uuid, p_method text, p_hash text, p_staff uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s jsonb := fn_stay_summary_internal(p_reservation); r reservations%rowtype; a stay_acknowledgements%rowtype;
begin
  if coalesce(p_hash, '') <> s->>'hash' then raise exception 'SUMMARY_CHANGED: the stay summary changed; read it again'; end if;
  select * into r from reservations where id = p_reservation;
  select * into a from stay_acknowledgements where reservation_id = p_reservation and text_hash = p_hash and method = p_method order by accepted_at desc limit 1;
  if found then return jsonb_build_object('ok', true, 'duplicate', true, 'accepted_at', a.accepted_at); end if;
  insert into stay_acknowledgements(organization_id, branch_id, reservation_id, guest_id, method, language, text_snapshot, text_hash, recorded_by)
  values (r.organization_id, r.branch_id, r.id, p_guest, p_method, s->>'language', s->>'text', p_hash, p_staff) returning * into a;
  return jsonb_build_object('ok', true, 'duplicate', false, 'accepted_at', a.accepted_at);
end $$;
revoke all on function fn_record_ack(uuid, uuid, text, text, uuid) from public, anon, authenticated;

create or replace function fn_ack_list(p_reservation uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'method', a.method, 'language', a.language, 'accepted_at', a.accepted_at, 'text_hash', a.text_hash,
                                               'recorded_by', (select full_name from staff_profiles where id = a.recorded_by)) order by a.accepted_at desc), '[]'::jsonb)
  from stay_acknowledgements a where a.reservation_id = p_reservation;
$$;
revoke all on function fn_ack_list(uuid) from public, anon, authenticated;

-- staff: the summary to print, and the acknowledgements on file
create or replace function fn_stay_summary(p_reservation uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_branch uuid;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  select branch_id into v_branch from reservations where id = p_reservation;
  if v_branch is null then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  return fn_stay_summary_internal(p_reservation) || jsonb_build_object('acknowledgements', fn_ack_list(p_reservation));
end $$;
revoke all on function fn_stay_summary(uuid) from public, anon;
grant execute on function fn_stay_summary(uuid) to authenticated;

-- the guest signed the printed summary (the hash printed on it must still be the current one)
create or replace function fn_staff_record_paper_ack(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; res jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled', 'rejected', 'no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  res := fn_record_ack(r.id, (select id from reservation_guests where reservation_id = r.id and is_primary order by created_at limit 1), 'paper', p->>'text_hash', fn_staff_id());
  if not (res->>'duplicate')::boolean then
    perform fn_audit_change(r.branch_id, 'reservation.summary_signed', 'reservation', r.id, null, jsonb_build_object('method', 'paper', 'text_hash', p->>'text_hash'));
  end if;
  return res;
end $$;
revoke all on function fn_staff_record_paper_ack(jsonb) from public, anon;
grant execute on function fn_staff_record_paper_ack(jsonb) to authenticated;

-- the guest's own page: the summary and whether it was accepted
create or replace function fn_guest_stay_summary(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rid uuid := fn_token_reservation(p_token); a stay_acknowledgements%rowtype; s jsonb;
begin
  s := fn_stay_summary_internal(rid);
  select * into a from stay_acknowledgements where reservation_id = rid order by accepted_at desc limit 1;
  return jsonb_build_object('language', s->>'language', 'text', s->>'text', 'hash', s->>'hash', 'policies', s->'policies', 'money', s->'money',
                            'reservation', s->'reservation', 'branch', s->'branch',
                            'accepted_at', a.accepted_at, 'method', a.method, 'current', a.text_hash is not distinct from s->>'hash');
end $$;
revoke all on function fn_guest_stay_summary(text) from public;
grant execute on function fn_guest_stay_summary(text) to anon, authenticated, service_role;

create or replace function fn_guest_acknowledge(p_token text, p_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare rid uuid := fn_token_reservation(p_token); r reservations%rowtype; res jsonb;
begin
  select * into r from reservations where id = rid for update;
  if r.status in ('cancelled', 'rejected', 'no_show', 'closed') then raise exception 'RESERVATION_NOT_EDITABLE'; end if;
  res := fn_record_ack(rid, (select id from reservation_guests where reservation_id = rid and is_primary order by created_at limit 1), 'electronic', p_hash, null);
  if not (res->>'duplicate')::boolean then
    perform fn_audit(r.organization_id, r.branch_id, null, 'guest_summary_accepted', 'reservation', r.id, jsonb_build_object('text_hash', p_hash));
  end if;
  return res;
end $$;
revoke all on function fn_guest_acknowledge(text, text) from public;
grant execute on function fn_guest_acknowledge(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 8. Guest data on two paths (decision 2)
-- ---------------------------------------------------------------------------------------------------------------
-- the format rules of a document number (one place for the guest's form and the office's)
create or replace function fn_check_identity(p_type identity_type, p_number text)
returns void language plpgsql immutable set search_path = public as $$
begin
  if p_type in ('national_id', 'iqama') and p_number !~ '^[12]\d{9}$' then raise exception 'VALIDATION: identity_number_format'; end if;
  if p_type = 'gcc_id' and p_number !~ '^[A-Za-z0-9]{6,15}$' then raise exception 'VALIDATION: identity_number_format'; end if;
  if p_type = 'passport' and p_number !~ '^[A-Za-z0-9]{5,12}$' then raise exception 'VALIDATION: identity_number_format'; end if;
end $$;
revoke all on function fn_check_identity(identity_type, text) from public, anon, authenticated;

-- the guest's own form (as before), with the document's fingerprint, and the stay summary accepted by the main guest
create or replace function fn_guest_submit(p_token text, p_guest_id uuid, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype;
  g reservation_guests%rowtype;
  v_name text := trim(coalesce(p_payload->>'full_name',''));
  v_type identity_type;
  v_number text := regexp_replace(coalesce(p_payload->>'identity_number',''), '\s', '', 'g');
  v_nat text := trim(coalesce(p_payload->>'nationality',''));
  v_birth date;
  v_phone text := nullif(regexp_replace(coalesce(p_payload->>'phone',''), '[^0-9+]', '', 'g'), '');
  v_rel text := coalesce(p_payload->>'relationship','other');
  v_issue text := nullif(trim(coalesce(p_payload->>'identity_issue_number','')), '');
  v_ack text := nullif(trim(coalesce(p_payload->>'ack_hash', '')), '');
  fp text; total_required int; current_count int; new_id uuid; st guest_verification_status; before_st guest_verification_status;
begin
  select * into r from reservations where id = rid for update;
  if r.status in ('cancelled','rejected','closed','checked_out','no_show') then raise exception 'RESERVATION_NOT_EDITABLE'; end if;
  before_st := r.identity_status;

  -- validation (server-side, authoritative)
  if array_length(regexp_split_to_array(v_name, '\s+'), 1) < 3 then raise exception 'VALIDATION: full_name_three_parts'; end if;
  begin v_type := (p_payload->>'identity_type')::identity_type; exception when others then raise exception 'VALIDATION: identity_type'; end;
  perform fn_check_identity(v_type, v_number);
  if v_nat = '' then raise exception 'VALIDATION: nationality'; end if;
  begin v_birth := (p_payload->>'birth_date')::date; exception when others then raise exception 'VALIDATION: birth_date'; end;
  if v_birth is null or v_birth > fn_branch_today(r.branch_id) or v_birth < fn_branch_today(r.branch_id) - interval '120 years' then raise exception 'VALIDATION: birth_date_range'; end if;
  if coalesce(p_payload->>'consent','false') <> 'true' then raise exception 'VALIDATION: consent_required'; end if;
  fp := fn_identity_fingerprint(v_type, v_number);

  if p_guest_id is not null then
    select * into g from reservation_guests where id = p_guest_id and reservation_id = rid for update;
    if not found then raise exception 'GUEST_NOT_FOUND'; end if;
    if g.verification_status = 'verified' then raise exception 'GUEST_ALREADY_VERIFIED'; end if;
    if g.is_primary and v_phone is null then v_phone := g.phone; end if;
    if g.is_primary and v_phone is null then raise exception 'VALIDATION: phone_required_primary'; end if;
    -- decision 19: the main guest accepts the stay summary when registering (once is enough)
    if g.is_primary and v_ack is null and not exists (select 1 from stay_acknowledgements where reservation_id = rid) then
      raise exception 'VALIDATION: acknowledgement_required';
    end if;
    if exists (select 1 from reservation_guests x where x.reservation_id = rid and x.id <> g.id and x.identity_fingerprint = fp) then raise exception 'DUPLICATE_GUEST'; end if;
    -- the summary the guest read carries their name as it was: it is recorded before their data changes it
    if g.is_primary and v_ack is not null then perform fn_record_ack(rid, g.id, 'electronic', v_ack, null); end if;
    update reservation_guests set
      full_name = v_name, identity_type = v_type,
      identity_number_encrypted = pgp_sym_encrypt(v_number, fn_secret('identity_key')),
      identity_number_last4 = right(v_number, 4), identity_issue_number = v_issue, identity_fingerprint = fp,
      nationality = v_nat, birth_date = v_birth, phone = coalesce(v_phone, phone),
      relationship = case when g.is_primary then 'self' else v_rel end,
      data_submitted = true, verification_status = 'data_submitted',
      entry_path = 'guest', entered_by = null, entered_at = now(), verified_by = null, verified_at = null
    where id = g.id;
    new_id := g.id;
  else
    total_required := r.adults + r.companions;
    select count(*) into current_count from reservation_guests where reservation_id = rid;
    if current_count >= total_required then raise exception 'GUEST_LIMIT_REACHED'; end if;
    -- duplicate companion guard (the same document in the same stay)
    if exists (select 1 from reservation_guests x where x.reservation_id = rid and x.identity_fingerprint = fp) then raise exception 'DUPLICATE_GUEST'; end if;
    insert into reservation_guests (reservation_id, is_primary, full_name, identity_type, identity_number_encrypted, identity_number_last4,
      identity_issue_number, nationality, birth_date, phone, relationship, data_submitted, verification_status, identity_fingerprint, entry_path, entered_at)
    values (rid, false, v_name, v_type, pgp_sym_encrypt(v_number, fn_secret('identity_key')), right(v_number,4),
      v_issue, v_nat, v_birth, v_phone, v_rel, true, 'data_submitted', fp, 'guest', now())
    returning id into new_id;
  end if;

  st := fn_rollup_identity(rid);
  if st = 'pending_supervisor' and before_st is distinct from 'pending_supervisor' then
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'بيانات نزلاء مكتملة بانتظار المطابقة', 'الحجز ' || r.internal_ref, '/staff/reservations/' || r.id);
  end if;

  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_data_submitted', 'reservation_guest', new_id, jsonb_build_object('reservation_id', rid));
  return jsonb_build_object('ok', true, 'guest_id', new_id);
end $$;
revoke all on function fn_guest_submit(text, uuid, jsonb) from public;
grant execute on function fn_guest_submit(text, uuid, jsonb) to anon, authenticated, service_role;

-- the office path: the owner, a manager or a supervisor enters (or corrects) a guest from the original document.
-- Matching the document is the verification, so the guest is verified at once; a correction needs a reason and the
-- trail keeps masked values before and after. Leaving the number empty in a correction keeps the one on file.
create or replace function fn_staff_enter_guest(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r reservations%rowtype; g reservation_guests%rowtype; v_guest uuid := nullif(p->>'guest_id', '')::uuid;
        v_name text := trim(coalesce(p->>'full_name', '')); v_type identity_type; v_number text := regexp_replace(coalesce(p->>'identity_number', ''), '\s', '', 'g');
        v_nat text := trim(coalesce(p->>'nationality', '')); v_birth date; v_phone text := nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9+]', '', 'g'), '');
        v_rel text := nullif(trim(coalesce(p->>'relationship', '')), ''); v_issue text := nullif(trim(coalesce(p->>'identity_issue_number', '')), '');
        v_reason text := nullif(trim(coalesce(p->>'reason', '')), ''); fp text; before jsonb; correcting boolean := false; cnt int; new_id uuid; st guest_verification_status;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled', 'rejected', 'closed', 'checked_out', 'no_show') then raise exception 'RESERVATION_NOT_EDITABLE'; end if;
  if coalesce((p->>'document_matched')::boolean, false) is not true then raise exception 'VALIDATION: document_matched'; end if;
  if array_length(regexp_split_to_array(v_name, '\s+'), 1) < 3 then raise exception 'VALIDATION: full_name_three_parts'; end if;
  begin v_type := (p->>'identity_type')::identity_type; exception when others then raise exception 'VALIDATION: identity_type'; end;
  if v_type is null then raise exception 'VALIDATION: identity_type'; end if;
  if v_guest is not null then
    select * into g from reservation_guests where id = v_guest and reservation_id = r.id for update;
    if not found then raise exception 'GUEST_NOT_FOUND'; end if;
    correcting := g.data_submitted;
  end if;
  if v_number = '' then
    -- keep the number on file: only for a correction of the same kind of document
    if not correcting or g.identity_number_encrypted is null or v_type is distinct from g.identity_type then raise exception 'VALIDATION: identity_number_format'; end if;
    fp := g.identity_fingerprint;
  else
    perform fn_check_identity(v_type, v_number);
    fp := fn_identity_fingerprint(v_type, v_number);
  end if;
  if v_nat = '' then raise exception 'VALIDATION: nationality'; end if;
  begin v_birth := (p->>'birth_date')::date; exception when others then raise exception 'VALIDATION: birth_date'; end;
  if v_birth is null or v_birth > fn_branch_today(r.branch_id) or v_birth < fn_branch_today(r.branch_id) - interval '120 years' then raise exception 'VALIDATION: birth_date_range'; end if;
  if correcting and v_reason is null then raise exception 'VALIDATION: reason'; end if;
  if exists (select 1 from reservation_guests x where x.reservation_id = r.id and x.identity_fingerprint = fp and x.id is distinct from v_guest) then
    raise exception 'DUPLICATE_GUEST';
  end if;

  if v_guest is not null then
    before := fn_guest_masked(g.id);
    if g.is_primary and v_phone is null then v_phone := g.phone; end if;
    update reservation_guests set full_name = v_name, identity_type = v_type,
      identity_number_encrypted = case when v_number = '' then identity_number_encrypted else pgp_sym_encrypt(v_number, fn_secret('identity_key')) end,
      identity_number_last4 = case when v_number = '' then identity_number_last4 else right(v_number, 4) end,
      identity_issue_number = v_issue, identity_fingerprint = fp, nationality = v_nat, birth_date = v_birth, phone = coalesce(v_phone, phone),
      relationship = case when is_primary then 'self' else coalesce(v_rel, relationship, 'other') end,
      data_submitted = true, verification_status = 'verified', entry_path = 'office', entered_by = fn_staff_id(), entered_at = now(),
      verified_by = fn_staff_id(), verified_at = now()
    where id = g.id;
    new_id := g.id;
  else
    select count(*) into cnt from reservation_guests where reservation_id = r.id;
    if cnt >= r.adults + r.companions then raise exception 'GUEST_LIMIT_REACHED'; end if;
    insert into reservation_guests(reservation_id, is_primary, full_name, identity_type, identity_number_encrypted, identity_number_last4, identity_issue_number,
      nationality, birth_date, phone, relationship, data_submitted, verification_status, identity_fingerprint, entry_path, entered_by, entered_at, verified_by, verified_at)
    values (r.id, false, v_name, v_type, pgp_sym_encrypt(v_number, fn_secret('identity_key')), right(v_number, 4), v_issue, v_nat, v_birth, v_phone,
            coalesce(v_rel, 'other'), true, 'verified', fp, 'office', fn_staff_id(), now(), fn_staff_id(), now())
    returning id into new_id;
  end if;
  perform fn_link_guest_profile(new_id);
  st := fn_rollup_identity(r.id);
  perform fn_audit_change(r.branch_id, case when correcting then 'guest.corrected' else 'guest.entered_from_document' end, 'reservation', r.id,
                          before, fn_guest_masked(new_id), v_reason);
  if correcting then
    perform fn_add_review_item(r.branch_id, 'guest_corrected', 'reservation_guest', new_id, r.id, 'تصحيح بيانات نزيل في ' || r.internal_ref, v_reason,
      jsonb_build_object('before', before, 'after', fn_guest_masked(new_id)));
  end if;
  return jsonb_build_object('ok', true, 'guest_id', new_id, 'identity_status', st);
end $$;
revoke all on function fn_staff_enter_guest(jsonb) from public, anon;
grant execute on function fn_staff_enter_guest(jsonb) to authenticated;

-- approving or refusing a guest's own entry: who and when are kept, an approved document joins its guest profile
create or replace function fn_staff_approve_identity(p_guest_id uuid, p_approve boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare g reservation_guests%rowtype; r reservations%rowtype; st guest_verification_status;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into g from reservation_guests where id = p_guest_id for update;
  if not found then raise exception 'GUEST_NOT_FOUND'; end if;
  select * into r from reservations where id = g.reservation_id for update;
  perform fn_require_branch(r.branch_id);
  if not g.data_submitted then raise exception 'GUEST_DATA_NOT_SUBMITTED'; end if;
  if not p_approve and coalesce(trim(p_reason),'') = '' then raise exception 'REASON_REQUIRED'; end if;

  update reservation_guests set verification_status = case when p_approve then 'verified' else 'rejected' end::guest_verification_status,
         verified_by = case when p_approve then fn_staff_id() end, verified_at = case when p_approve then now() end
   where id = g.id;
  if p_approve then perform fn_link_guest_profile(g.id); end if;
  st := fn_rollup_identity(r.id);
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), case when p_approve then 'approve_identity' else 'reject_identity' end,
                   'reservation_guest', g.id, jsonb_build_object('reservation_id', r.id, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'identity_status', st);
end $$;
revoke all on function fn_staff_approve_identity(uuid, boolean, text) from public, anon;
grant execute on function fn_staff_approve_identity(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 9. Guest profiles: search, one profile, the rating, the ban (decisions 2 and 21)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_mask_phone(p text) returns text language sql immutable set search_path = public as $$
  select case when coalesce(regexp_replace(p, '\D', '', 'g'), '') = '' then null else '••••' || right(regexp_replace(p, '\D', '', 'g'), 4) end;
$$;

-- may this staff member see this profile? the owner always; others when it has a stay in one of their branches
create or replace function fn_profile_visible(p_profile uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select fn_has_role('owner') or exists (select 1 from reservation_guests g join reservations r on r.id = g.reservation_id
                                          where g.guest_profile_id = p_profile and r.branch_id in (select fn_user_branch_ids()));
$$;
revoke all on function fn_profile_visible(uuid) from public, anon, authenticated;

create or replace function fn_guest_profiles(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare q text := nullif(trim(coalesce(p->>'q', '')), ''); v_filter text := coalesce(nullif(p->>'filter', ''), 'all');
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        digits text; fps text[] := '{}'; v_org uuid := fn_user_org_id(); res jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  if q is not null then
    digits := regexp_replace(translate(q, '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g');
    if q ~ '^[A-Za-z0-9]{5,15}$' then
      fps := array[fn_identity_fingerprint('national_id', q), fn_identity_fingerprint('passport', q), fn_identity_fingerprint('gcc_id', q)];
    end if;
  end if;
  with prof as (
    select gp.*,
           (select count(distinct g.reservation_id) from reservation_guests g where g.guest_profile_id = gp.id) as stays,
           (select max(r.check_in) from reservation_guests g join reservations r on r.id = g.reservation_id where g.guest_profile_id = gp.id) as last_check_in,
           (select b.reason from fn_profile_banned(gp.id) b where b.id is not null) as ban_reason,
           (select count(*) from guest_profiles o where o.organization_id = gp.organization_id and o.id <> gp.id
              and ((fn_normalize_phone(o.phone) is not null and fn_normalize_phone(o.phone) = fn_normalize_phone(gp.phone))
                   or (o.identity_fingerprint is not null and o.identity_fingerprint = gp.identity_fingerprint))) as duplicates
    from guest_profiles gp
    where gp.organization_id = v_org and fn_profile_visible(gp.id)
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
    where v_filter = 'all' or (v_filter = 'banned' and ban_reason is not null) or (v_filter = 'duplicates' and duplicates > 0)
       or (v_filter = 'rated' and rating is not null) or (v_filter = 'low' and rating <= 2)
  )
  select jsonb_build_object('total', (select count(*) from f),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'phone_masked', fn_mask_phone(phone), 'nationality', nationality,
                                                         'identity_type', identity_type, 'identity_last4', identity_last4, 'rating', rating, 'rating_note', rating_note,
                                                         'stays', stays, 'last_check_in', last_check_in, 'banned', ban_reason is not null, 'ban_reason', ban_reason,
                                                         'duplicates', duplicates, 'created_at', created_at)
                                      order by last_check_in desc nulls last, created_at desc)
                      from (select * from f order by last_check_in desc nulls last, created_at desc limit v_limit offset v_offset) x), '[]'::jsonb))
  into res;
  return res;
end $$;
revoke all on function fn_guest_profiles(jsonb) from public, anon;
grant execute on function fn_guest_profiles(jsonb) to authenticated;

create or replace function fn_guest_profile(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare gp guest_profiles%rowtype; ban guest_bans%rowtype; v_owner boolean := fn_has_role('owner');
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
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
end $$;
revoke all on function fn_guest_profile(uuid) from public, anon;
grant execute on function fn_guest_profile(uuid) to authenticated;

-- the rating 1–5 and the internal note that staff see on the guest's next bookings (owner, manager, supervisor)
create or replace function fn_guest_rate(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gp guest_profiles%rowtype; v_rating smallint; v_note text := nullif(trim(coalesce(p->>'note', '')), '');
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  begin v_rating := nullif(p->>'rating', '')::smallint; exception when others then raise exception 'VALIDATION: rating'; end;
  if v_rating is not null and (v_rating < 1 or v_rating > 5) then raise exception 'VALIDATION: rating'; end if;
  if length(coalesce(v_note, '')) > 500 then raise exception 'VALIDATION: note'; end if;
  select * into gp from guest_profiles where id = (p->>'profile_id')::uuid and organization_id = fn_user_org_id() for update;
  if not found or not fn_profile_visible(gp.id) then raise exception 'NOT_FOUND'; end if;
  update guest_profiles set rating = v_rating, rating_note = v_note, rated_by = fn_staff_id(), rated_at = now(), updated_at = now() where id = gp.id;
  perform fn_audit_change(null, 'guest.rated', 'guest_profile', gp.id, jsonb_build_object('rating', gp.rating, 'note', gp.rating_note),
                          jsonb_build_object('rating', v_rating, 'note', v_note));
  return jsonb_build_object('ok', true, 'rating', v_rating);
end $$;
revoke all on function fn_guest_rate(jsonb) from public, anon;
grant execute on function fn_guest_rate(jsonb) to authenticated;

-- a guest ban (owner or manager, with a reason), or lifting it (with a reason)
create or replace function fn_guest_ban(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gp guest_profiles%rowtype; b guest_bans%rowtype; v_ban boolean := (p->>'ban')::boolean; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        v_branch uuid; v_phones text[]; v_fps text[];
begin
  perform fn_require_role('owner', 'manager');
  if v_ban is null then raise exception 'VALIDATION: ban'; end if;
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  if not v_ban and (p->>'ban_id') is not null then
    select * into b from guest_bans where id = (p->>'ban_id')::uuid and organization_id = fn_user_org_id() and lifted_at is null for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    select * into gp from guest_profiles where id = b.guest_profile_id;
  else
    select * into gp from guest_profiles where id = (p->>'profile_id')::uuid and organization_id = fn_user_org_id() for update;
    if not found or not fn_profile_visible(gp.id) then raise exception 'NOT_FOUND'; end if;
  end if;
  -- the review list belongs to a branch: the one of the guest's latest stay
  select r.branch_id into v_branch from reservation_guests g join reservations r on r.id = g.reservation_id
   where g.guest_profile_id = coalesce(gp.id, b.guest_profile_id) order by r.check_in desc limit 1;
  if v_ban then
    if exists (select 1 from guest_bans where guest_profile_id = gp.id and lifted_at is null) then
      return jsonb_build_object('ok', true, 'duplicate', true);
    end if;
    v_phones := array(select distinct x from (select fn_normalize_phone(gp.phone) as x
                                              union select fn_normalize_phone(g.phone) from reservation_guests g where g.guest_profile_id = gp.id) s where x is not null);
    v_fps := array(select distinct x from (select gp.identity_fingerprint as x
                                           union select g.identity_fingerprint from reservation_guests g where g.guest_profile_id = gp.id) s where x is not null);
    insert into guest_bans(organization_id, guest_profile_id, name_snapshot, phones, fingerprints, reason, created_by)
    values (gp.organization_id, gp.id, gp.full_name, v_phones, v_fps, v_reason, fn_staff_id()) returning * into b;
    perform fn_audit_change(v_branch, 'guest.banned', 'guest_profile', gp.id, null,
      jsonb_build_object('ban_id', b.id, 'phones', cardinality(v_phones), 'documents', cardinality(v_fps)), v_reason);
    insert into review_items(organization_id, branch_id, kind, entity_type, entity_id, summary, reason, details, created_by)
    values (gp.organization_id, v_branch, 'guest_banned', 'guest_profile', gp.id, 'حظر الضيف ' || gp.full_name, v_reason,
            jsonb_build_object('ban_id', b.id), fn_staff_id());
  else
    if b.id is null then
      select * into b from guest_bans where guest_profile_id = gp.id and lifted_at is null for update;
      if not found then raise exception 'NOT_FOUND'; end if;
    end if;
    update guest_bans set lifted_at = now(), lifted_by = fn_staff_id(), lift_reason = v_reason where id = b.id;
    perform fn_audit_change(v_branch, 'guest.unbanned', 'guest_profile', coalesce(gp.id, b.id), jsonb_build_object('ban_id', b.id, 'reason', b.reason), null, v_reason);
    insert into review_items(organization_id, branch_id, kind, entity_type, entity_id, summary, reason, details, created_by)
    values (b.organization_id, v_branch, 'guest_unbanned', 'guest_profile', coalesce(gp.id, b.id), 'رفع الحظر عن الضيف ' || b.name_snapshot, v_reason,
            jsonb_build_object('ban_id', b.id, 'banned_since', b.created_at), fn_staff_id());
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'ban_id', b.id);
end $$;
revoke all on function fn_guest_ban(jsonb) from public, anon;
grant execute on function fn_guest_ban(jsonb) to authenticated;

-- a hold on one booking (decision 21): placed by the owner, a manager or a supervisor, lifted by the owner or a manager
create or replace function fn_staff_set_hold(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v_hold boolean := (p->>'hold')::boolean; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
begin
  if v_hold is null then raise exception 'VALIDATION: hold'; end if;
  if v_hold then perform fn_require_role('owner', 'manager', 'supervisor'); else perform fn_require_role('owner', 'manager'); end if;
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if coalesce(r.security_hold, false) = v_hold then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  update reservations set security_hold = v_hold, security_hold_reason = case when v_hold then v_reason end,
         security_hold_by = case when v_hold then fn_staff_id() end, security_hold_at = case when v_hold then now() end,
         version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, case when v_hold then 'reservation.hold_set' else 'reservation.hold_lifted' end, 'reservation', r.id,
    jsonb_build_object('security_hold', coalesce(r.security_hold, false), 'reason', r.security_hold_reason), jsonb_build_object('security_hold', v_hold), v_reason);
  if v_hold then
    perform fn_add_review_item(r.branch_id, 'security_hold', 'reservation', r.id, r.id, 'حظر على الحجز ' || r.internal_ref, v_reason, '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'security_hold', v_hold);
end $$;
revoke all on function fn_staff_set_hold(jsonb) from public, anon;
grant execute on function fn_staff_set_hold(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 10. Creating a booking (one unit of it): the guest profile chosen or matched by phone, the platform fields, the
--     receipt «آجل عبر المنصات» when the platform collects, and one platform number per booking or group
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_staff_create_reservation_unit(p jsonb, p_group_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; v_room uuid := (p->>'room_id')::uuid;
        ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date; src booking_sources%rowtype; q jsonb; r reservations%rowtype; b branches%rowtype;
        gp guest_profiles%rowtype; v_phone text := nullif(trim(p->>'guest_phone'),''); v_name text := trim(p->>'guest_name'); v_status reservation_status; ext text := nullif(trim(p->>'external_ref'),'');
        v_adults int := coalesce((p->>'adults')::int, 1); v_comp int := coalesce((p->>'companions')::int, 0); cap int;
        v_details jsonb := coalesce(p->'companions_details', '[]'::jsonb); d jsonb; v_arr time; v_dep time;
        v_disc bigint := coalesce(nullif(p->>'discount_halalas', '')::bigint, 0); v_ovr bigint := nullif(p->>'nightly_rate_halalas', '')::bigint;
        v_profile uuid := nullif(p->>'guest_profile_id', '')::uuid; v_new_profile boolean := coalesce((p->>'new_profile')::boolean, false);
        v_collects boolean; v_booked date; platform boolean; f jsonb; vch jsonb; v_con text;
begin
  perform fn_require_role('owner','manager','supervisor');
  perform fn_require_branch(v_branch);
  select * into b from branches where id = v_branch;
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if coalesce(v_name,'') = '' then raise exception 'VALIDATION: guest_name'; end if;
  if jsonb_typeof(v_details) <> 'array' then raise exception 'VALIDATION: companions_details'; end if;
  -- companions: the detailed list wins over a bare count (never fewer rows than people declared)
  if jsonb_array_length(v_details) > v_comp then v_comp := jsonb_array_length(v_details); end if;
  if v_adults < 1 or v_comp < 0 then raise exception 'VALIDATION: guests'; end if;
  for d in select * from jsonb_array_elements(v_details) loop
    if coalesce(trim(d->>'full_name'),'') = '' then raise exception 'VALIDATION: companion_name'; end if;
  end loop;
  begin
    v_arr := coalesce(nullif(p->>'arrival_time','')::time, b.check_in_time);
    v_dep := coalesce(nullif(p->>'departure_time','')::time, b.check_out_time);
  exception when others then raise exception 'VALIDATION: times'; end;
  select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id() and is_active;
  if not found then raise exception 'VALIDATION: source'; end if;
  if src.external_reference_required and ext is null then raise exception 'VALIDATION: external_ref_required'; end if;
  -- decision 4: a platform's booking says who collects and when it was booked there
  platform := src.kind = 'external';
  if platform then
    if (p->>'platform_collects') is null then raise exception 'VALIDATION: platform_collects'; end if;
    v_collects := (p->>'platform_collects')::boolean;
    begin v_booked := nullif(p->>'platform_booked_on', '')::date; exception when others then raise exception 'VALIDATION: platform_booked_on'; end;
    if v_booked is null or v_booked > fn_branch_today(v_branch) or v_booked < ci - 730 then raise exception 'VALIDATION: platform_booked_on'; end if;
  end if;
  -- decision 69: one platform number per booking or group (the units of a group share it)
  if ext is not null and exists (select 1 from reservations x where x.organization_id = fn_user_org_id() and x.source_id = src.id and x.external_ref = ext
                                   and coalesce(x.group_ref, x.id::text) <> coalesce(p_group_ref, '-')) then
    raise exception 'DUPLICATE_EXTERNAL_REF';
  end if;
  select max_capacity into cap from room_categories where id = v_cat and branch_id = v_branch and archived_at is null;
  if cap is null then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_adults + v_comp > cap then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- the stay's nights from the calendar (or the weekly / monthly price), the platform row for a platform booking
  q := fn_quote_stay(jsonb_build_object('branch_id', v_branch, 'category_id', v_cat, 'check_in', ci, 'check_out', co, 'source_id', src.id,
                                        'nightly_rate_halalas', v_ovr, 'discount_halalas', v_disc));
  -- a manual nightly price under what the stay would cost is a discount by another name: the owner's or a manager's
  if v_ovr is not null and (q->>'rent_gross')::bigint < (q->>'computed_rent')::bigint and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: rate below the quoted price requires manager';
  end if;
  if v_disc > 0 and coalesce(trim(p->>'discount_reason'), '') = '' then raise exception 'VALIDATION: discount_reason'; end if;
  perform fn_check_discount(v_cat, v_branch, (q->>'nights')::int, (q->>'rent_gross')::bigint, 0, v_disc, false);
  v_status := case when coalesce((p->>'confirm')::boolean, true) then 'confirmed' else 'pending_verification' end;

  -- the guest profile: the one chosen, else the one with this phone, else a new one (never matched by name alone, never merged)
  if v_profile is not null then
    select * into gp from guest_profiles where id = v_profile and organization_id = fn_user_org_id();
    if not found then raise exception 'VALIDATION: guest_profile'; end if;
  elsif not v_new_profile and v_phone is not null then
    select * into gp from guest_profiles where organization_id = fn_user_org_id()
       and (phone = v_phone or (fn_normalize_phone(v_phone) is not null and fn_normalize_phone(phone) = fn_normalize_phone(v_phone)))
     order by created_at limit 1;
  end if;
  if gp.id is null then
    insert into guest_profiles(organization_id, full_name, phone, nationality) values (fn_user_org_id(), v_name, v_phone, p->>'nationality') returning * into gp;
  end if;

  insert into reservations(organization_id, branch_id, external_ref, source_id, status, booking_type, company_name, visit_purpose, check_in, check_out, adults, companions,
                           room_category_id, nightly_rate_halalas, price_basis, notes, created_by, identity_status, payment_status, expected_arrival_time, expected_departure_time, group_ref,
                           platform_booked_on, platform_collects)
  values (fn_user_org_id(), v_branch, ext, src.id, v_status, coalesce(p->>'booking_type','individual'), p->>'company_name', p->>'visit_purpose', ci, co, v_adults, v_comp,
          v_cat, (q->>'nightly_rate')::bigint, q->>'basis', p->>'notes', fn_staff_id(), 'not_started', 'pending', v_arr, v_dep, p_group_ref,
          case when platform then v_booked end, case when platform then v_collects end) returning * into r;

  insert into reservation_guests(reservation_id, guest_profile_id, is_primary, full_name, phone, nationality) values (r.id, gp.id, true, v_name, v_phone, p->>'nationality');
  -- companions: identity stays 'not_started' until the document is matched at arrival (G-identity)
  for d in select * from jsonb_array_elements(v_details) loop
    insert into reservation_guests(reservation_id, is_primary, full_name, relationship, nationality, phone)
    values (r.id, false, trim(d->>'full_name'), nullif(trim(d->>'relationship'),''), nullif(trim(d->>'nationality'),''), nullif(trim(d->>'phone'),''));
  end loop;

  perform fn_book_nights(r.id, q->'runs', 'إيجار');
  if v_disc > 0 then
    perform fn_add_charge(r.id, 'discount', trim(p->>'discount_reason'), 1, v_disc, true, trim(p->>'discount_reason'));
  end if;
  if v_room is not null then
    if not fn_room_available(v_room, ci, co) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    perform fn_allocate(r.id, v_room, ci, co, 'create');
  end if;
  f := fn_recompute_reservation_finance(r.id);
  -- decision 4: the platform collected the stay → its receipt «آجل عبر المنصات», matched later against the platform's deposit
  if platform and v_collects and (f->>'total')::bigint > 0 then
    vch := fn_create_voucher(jsonb_build_object('kind', 'receipt', 'reservation_id', r.id, 'amount_halalas', (f->>'total')::bigint, 'method', 'ota_deferred',
                                                'reference', ext, 'note', 'قبضته المنصة عند الحجز', 'idempotency_key', 'platform-collect:' || r.id));
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.created', 'reservation', r.id, null,
    jsonb_build_object('internal_ref', r.internal_ref, 'source', src.code, 'external_ref', ext, 'check_in', ci, 'check_out', co, 'room_id', v_room, 'quote', q,
                       'arrival_time', v_arr, 'departure_time', v_dep, 'companions', v_comp, 'group_ref', p_group_ref, 'guest_profile_id', gp.id,
                       'platform_booked_on', r.platform_booked_on, 'platform_collects', r.platform_collects, 'platform_voucher', vch->>'number'));
  return jsonb_build_object('ok', true, 'id', r.id, 'internal_ref', r.internal_ref, 'quote', q, 'group_ref', p_group_ref, 'guest_profile_id', gp.id,
                            'platform_voucher', vch->>'number');
exception when unique_violation or exclusion_violation then
  get stacked diagnostics v_con = constraint_name;
  if v_con in ('uniq_reservation_source_ref', 'excl_reservation_source_ref') then raise exception 'DUPLICATE_EXTERNAL_REF'; end if;
  raise;
end $$;
revoke all on function fn_staff_create_reservation_unit(jsonb, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 11. Cancelling (decision 4): a platform's booking is cancelled with the platform's cancellation number, once per
--     number, optionally with every unit of its group; nothing is refunded by the cancellation itself
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_staff_cancel(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; src booking_sources%rowtype; t reservations%rowtype; ev integration_events%rowtype;
        v_reason text := nullif(trim(coalesce(p->>'reason', '')), ''); v_number text := nullif(trim(coalesce(p->>'cancel_number', '')), '');
        v_group boolean := coalesce((p->>'whole_group')::boolean, false); by_platform boolean; v_source text; ids uuid[]; n int := 0;
        v_money boolean := false; v_collected boolean := false; fin jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select * into src from booking_sources where id = r.source_id;
  -- a platform's booking is cancelled on the platform first (its number), unless it was entered here by mistake
  by_platform := coalesce(src.kind, 'direct') = 'external' and coalesce((p->>'by_platform')::boolean, true);
  if by_platform and v_number is null then raise exception 'VALIDATION: cancel_number'; end if;
  if v_number is not null and length(v_number) > 60 then raise exception 'VALIDATION: cancel_number'; end if;
  v_source := case when by_platform then 'platform' else 'staff' end;
  ids := case when v_group and r.group_ref is not null
              then array(select x.id from reservations x where x.organization_id = r.organization_id and x.group_ref = r.group_ref order by x.id)
              else array[r.id] end;
  perform 1 from (select x.id from reservations x where x.id = any(ids) order by x.id for update) l;
  if by_platform then
    insert into integration_events(organization_id, source, external_event_id, kind, reference, state)
    values (r.organization_id, 'platform:' || src.code, v_number, 'reservation.cancelled', r.external_ref, 'received')
    on conflict (organization_id, source, external_event_id) do nothing;
    select * into ev from integration_events where organization_id = r.organization_id and source = 'platform:' || src.code and external_event_id = v_number for update;
    if ev.state = 'processed' then
      update integration_events set attempts = attempts + 1 where id = ev.id;
      return jsonb_build_object('ok', true, 'duplicate', true, 'cancelled', 0, 'status', (select status from reservations where id = r.id));
    end if;
  end if;
  for t in select * from reservations where id = any(ids) order by id loop
    if t.status in ('cancelled', 'rejected', 'no_show') then continue; end if;
    if t.status in ('checked_in', 'checked_out', 'closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
    perform fn_release_allocations(t.id, 'cancel');
    update reservations set status = 'cancelled', status_before_cancel = t.status::text, cancelled_at = now(), cancel_reason = v_reason, cancel_source = v_source,
           cancel_reference = v_number, access_status = 'locked', version = version + 1, updated_at = now() where id = t.id;
    perform fn_audit_change(t.branch_id, 'reservation.cancelled', 'reservation', t.id, jsonb_build_object('status', t.status),
      jsonb_build_object('status', 'cancelled', 'source', v_source, 'cancel_reference', v_number, 'whole_group', v_group and t.group_ref is not null), v_reason);
    fin := fn_reservation_finance_internal(t.id);
    v_money := v_money or (fin->>'net_collected')::bigint > 0 or (fin->>'deposit_balance')::bigint > 0;
    v_collected := v_collected or exists (select 1 from financial_vouchers v where v.reservation_id = t.id and v.method = 'ota_deferred' and v.kind = 'receipt' and v.status = 'approved');
    n := n + 1;
  end loop;
  if ev.id is not null then
    update integration_events set state = 'processed', processed_at = now(), result = jsonb_build_object('reservations', n, 'reservation_id', r.id) where id = ev.id;
  end if;
  return jsonb_build_object('ok', true, 'duplicate', n = 0, 'cancelled', n, 'status', 'cancelled',
                            'refund_required_separately', v_money, 'platform_collected', v_collected);
end $$;
revoke all on function fn_staff_cancel(jsonb) from public, anon;
grant execute on function fn_staff_cancel(jsonb) to authenticated;

-- undoing a cancellation within the hour (decision 10) also frees the platform's cancellation number it used
create or replace function fn_staff_undo_cancel(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); a record; back reservation_status; today date; n int := 0;
begin
  perform fn_require_role('owner', 'manager');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status <> 'cancelled' then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.cancelled_at is null or now() - r.cancelled_at > interval '1 hour' then
    raise exception 'CORRECTION_WINDOW_PASSED: a cancellation is undone within 1 hour';
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  today := fn_branch_today(r.branch_id);
  if r.check_out <= today then raise exception 'VALIDATION: stay_ended'; end if;
  if exists (select 1 from room_categories c where c.id = r.room_category_id and c.archived_at is not null) then raise exception 'CATEGORY_ARCHIVED: this unit type is archived'; end if;
  back := case when r.status_before_cancel in ('pending_verification', 'confirmed') then r.status_before_cancel::reservation_status else 'confirmed'::reservation_status end;
  -- the allocations this cancellation released come back; a unit booked for someone else meanwhile is a conflict
  for a in select * from reservation_allocations where reservation_id = r.id and status = 'cancelled' and closed_at = r.cancelled_at order by from_date loop
    perform 1 from rooms where id = a.room_id and is_active and archived_at is null and status not in ('blocked', 'out_of_service', 'maintenance') for update;
    if not found then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    begin
      update reservation_allocations set status = 'active', closed_at = null where id = a.id;
    exception when exclusion_violation then
      raise exception 'ALLOCATION_CONFLICT: the unit was booked for someone else after the cancellation' using errcode = '23P01';
    end;
    if a.from_date <= today and today < a.to_date then
      update rooms set status = 'reserved' where id = a.room_id and status in ('available', 'ready', 'cleaning');
    end if;
    n := n + 1;
  end loop;
  -- a platform's cancellation number undone here can be entered again (on the right booking)
  if r.cancel_reference is not null and r.cancel_source = 'platform' then
    update integration_events set state = 'reverted', result = coalesce(result, '{}'::jsonb) || jsonb_build_object('reverted_at', now(), 'reverted_reservation', r.id)
     where organization_id = r.organization_id and source like 'platform:%' and external_event_id = r.cancel_reference and state = 'processed';
  end if;
  update reservations set status = back, cancelled_at = null, cancel_reason = null, cancel_source = null, status_before_cancel = null, cancel_reference = null,
         version = version + 1, updated_at = now()
   where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(r.branch_id, 'cancel_undone', 'reservation', r.id, r.id, 'تراجع عن إلغاء ' || r.internal_ref, reason,
    jsonb_build_object('cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason, 'allocations_restored', n, 'cancel_reference', r.cancel_reference));
  perform fn_audit_change(r.branch_id, 'reservation.cancel_undone', 'reservation', r.id,
    jsonb_build_object('status', 'cancelled', 'cancel_reason', r.cancel_reason, 'cancel_reference', r.cancel_reference), jsonb_build_object('status', back, 'allocations_restored', n), reason);
  return jsonb_build_object('ok', true, 'status', back);
end $$;
revoke all on function fn_staff_undo_cancel(jsonb) from public, anon;
grant execute on function fn_staff_undo_cancel(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 12. The platforms' daily list (today's and tomorrow's arrivals, matched against the platform) and the owner's
--     reports: bookings entered late (decision 4) and identities approved at the office (decision 2)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_platform_check_list(p_branch uuid, p_date date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
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
end $$;
revoke all on function fn_platform_check_list(uuid, date) from public, anon;
grant execute on function fn_platform_check_list(uuid, date) to authenticated;

-- «طابقتُ مع المنصة» (or taking it back): for the booking, or all units of its group, which share the platform number
create or replace function fn_platform_mark_checked(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; v_checked boolean := coalesce((p->>'checked')::boolean, true); n int;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into r from reservations where id = (p->>'reservation_id')::uuid;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if not exists (select 1 from booking_sources s where s.id = r.source_id and s.kind = 'external') then raise exception 'VALIDATION: not_platform'; end if;
  update reservations set platform_verified_at = case when v_checked then now() end, platform_verified_by = case when v_checked then fn_staff_id() end, updated_at = now()
   where organization_id = r.organization_id and (id = r.id or (r.group_ref is not null and group_ref = r.group_ref));
  get diagnostics n = row_count;
  perform fn_audit_change(r.branch_id, case when v_checked then 'reservation.platform_checked' else 'reservation.platform_unchecked' end, 'reservation', r.id, null,
                          jsonb_build_object('units', n, 'external_ref', r.external_ref));
  return jsonb_build_object('ok', true, 'units', n);
end $$;
revoke all on function fn_platform_mark_checked(jsonb) from public, anon;
grant execute on function fn_platform_mark_checked(jsonb) to authenticated;

-- platform bookings entered at least p_min_days after the day they were booked on the platform (the owner and managers)
create or replace function fn_reports_late_entries(p_branch uuid, p_from date, p_to date, p_min_days int default 1)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  perform fn_require_role('owner', 'manager');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  return (with x as (
    select r.id, r.internal_ref, r.external_ref, s.name as source_name, r.platform_booked_on, (r.created_at at time zone tz)::date as entered_on,
           r.created_at, r.check_in, r.status, (select full_name from staff_profiles where id = r.created_by) as created_by
    from reservations r join booking_sources s on s.id = r.source_id and s.kind = 'external'
    where r.branch_id = p_branch and r.platform_booked_on is not null and (r.created_at at time zone tz)::date between p_from and p_to
  ), late as (select *, entered_on - platform_booked_on as lag_days from x where entered_on - platform_booked_on >= greatest(p_min_days, 0))
  select jsonb_build_object(
    'platform_bookings', (select count(*) from x), 'late', (select count(*) from late),
    'after_arrival', (select count(*) from late where entered_on > check_in),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', coalesce(created_by, '—'), 'count', c, 'max_lag', m) order by c desc)
                          from (select created_by, count(*) c, max(lag_days) m from late group by created_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'source_name', source_name,
                                                         'booked_on', platform_booked_on, 'entered_on', entered_on, 'entered_at', created_at, 'lag_days', lag_days,
                                                         'check_in', check_in, 'after_arrival', entered_on > check_in, 'status', status, 'created_by', created_by)
                                      order by lag_days desc, created_at) from late), '[]'::jsonb)));
end $$;
revoke all on function fn_reports_late_entries(uuid, date, date, int) from public, anon;
grant execute on function fn_reports_late_entries(uuid, date, date, int) to authenticated;

-- identities approved in a period: at the office from the document (default), by matching the guest's own entry, or both
create or replace function fn_reports_identities(p_branch uuid, p_from date, p_to date, p_path text default 'office')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  perform fn_require_role('owner');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  if coalesce(p_path, 'office') not in ('office', 'guest', 'all') then raise exception 'VALIDATION: path'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  return (with x as (
    select g.id, r.id as reservation_id, r.internal_ref, g.full_name, g.is_primary, g.identity_type, g.identity_number_last4, g.entry_path,
           g.entered_at, g.verified_at, (select full_name from staff_profiles where id = g.entered_by) as entered_by,
           (select full_name from staff_profiles where id = g.verified_by) as verified_by
    from reservation_guests g join reservations r on r.id = g.reservation_id
    where r.branch_id = p_branch and g.verification_status = 'verified' and g.verified_at is not null
      and (g.verified_at at time zone tz)::date between p_from and p_to
      and (coalesce(p_path, 'office') = 'all' or g.entry_path = coalesce(p_path, 'office'))
  )
  select jsonb_build_object(
    'count', (select count(*) from x),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', coalesce(verified_by, '—'), 'office', o, 'guest', gu) order by o + gu desc)
                          from (select verified_by, count(*) filter (where entry_path = 'office') o, count(*) filter (where entry_path is distinct from 'office') gu
                                  from x group by verified_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('guest_id', id, 'reservation_id', reservation_id, 'internal_ref', internal_ref, 'full_name', full_name,
                                                         'is_primary', is_primary, 'identity_type', identity_type, 'identity_last4', identity_number_last4,
                                                         'entry_path', entry_path, 'entered_by', entered_by, 'entered_at', entered_at,
                                                         'verified_by', verified_by, 'verified_at', verified_at) order by verified_at desc) from x), '[]'::jsonb)));
end $$;
revoke all on function fn_reports_identities(uuid, date, date, text) from public, anon;
grant execute on function fn_reports_identities(uuid, date, date, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 13. The group's page (decision 69): every unit with its own money and arrival, and the group's totals
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_reservation_group_summary(p_reservation uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; m boolean := fn_has_role('owner', 'manager', 'supervisor', 'finance'); units jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance', 'housekeeping');
  select * into r from reservations where id = p_reservation;
  if not found or r.branch_id not in (select fn_user_branch_ids()) then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if r.group_ref is null then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'internal_ref', s.internal_ref, 'status', s.status, 'check_in', s.check_in, 'check_out', s.check_out,
                                               'adults', s.adults, 'companions', s.companions, 'room_number', (select room_number from rooms where id = s.room_id),
                                               'category_name', (select name_ar from room_categories where id = s.room_category_id),
                                               'total_halalas', case when m then s.total_halalas end, 'paid_halalas', case when m then s.paid_halalas end,
                                               'balance_due_halalas', case when m then s.balance_due_halalas end, 'deposit_balance_halalas', case when m then s.deposit_balance_halalas end)
                            order by s.internal_ref), '[]'::jsonb)
    into units from reservations s where s.organization_id = r.organization_id and s.group_ref = r.group_ref;
  return jsonb_build_object('group_ref', r.group_ref, 'external_ref', r.external_ref, 'source_name', (select name from booking_sources where id = r.source_id),
    'units', units,
    'totals', case when m then (select jsonb_build_object('units', count(*), 'active_units', count(*) filter (where s.status not in ('cancelled', 'rejected', 'no_show')),
                                                         'total_halalas', sum(s.total_halalas), 'paid_halalas', sum(s.paid_halalas),
                                                         'balance_due_halalas', sum(s.balance_due_halalas), 'deposit_balance_halalas', sum(s.deposit_balance_halalas))
                                 from reservations s where s.organization_id = r.organization_id and s.group_ref = r.group_ref)
                   else (select jsonb_build_object('units', count(*)) from reservations s where s.organization_id = r.organization_id and s.group_ref = r.group_ref) end);
end $$;
revoke all on function fn_reservation_group_summary(uuid) from public, anon;
grant execute on function fn_reservation_group_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 14. Arrival and the code are refused while a ban matches (decision 21); the guest's own page says only to see
--     the reception. The staff's booking screens show the red alert, the hold, the rating and the platform's fields.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_checkin_core_blockers(p_reservation uuid)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; rm rooms%rowtype; v text[] := '{}'; today date; gc int; sc int; vc int;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return array['الحجز غير موجود']; end if;
  if r.status = 'checked_in' then return array['سُجِّل وصول هذا الحجز مسبقًا']; end if;
  today := fn_branch_today(r.branch_id);
  if r.status <> 'confirmed' then v := array_append(v, 'الحجز غير مؤكد'); end if;
  if coalesce(r.security_hold, false) then v := array_append(v, 'يوجد حظر أمني على الحجز'); end if;
  if jsonb_array_length(fn_reservation_ban_matches(r.id)) > 0 then v := array_append(v, 'الضيف محظور من الإدارة'); end if;
  if today < r.check_in then v := array_append(v, 'لم يحن تاريخ الوصول (' || r.check_in || ')');
  elsif today >= r.check_out then v := array_append(v, 'انتهت فترة الإقامة'); end if;
  select count(*), count(*) filter (where data_submitted), count(*) filter (where verification_status = 'verified')
    into gc, sc, vc from reservation_guests where reservation_id = r.id;
  if gc = 0 then v := array_append(v, 'لم تُسجَّل بيانات النزلاء');
  elsif sc < gc then v := array_append(v, 'بيانات أحد النزلاء ناقصة');
  elsif gc < r.adults + r.companions then v := array_append(v, 'عدد النزلاء المسجلين أقل من عدد الحجز'); end if;
  if r.identity_status <> 'verified' or vc < gc then v := array_append(v, 'لم تُعتمد مطابقة الهوية لجميع النزلاء'); end if;
  -- Shomoos: the reference with every guest registered, then Shomoos's acceptance (decision 6, no exception)
  if not coalesce(r.government_registration, false) or coalesce(trim(r.gov_registration_ref), '') = '' then
    v := array_append(v, 'لم يُسجَّل النزلاء في شموس');
  elsif r.shomoos_guest_count is distinct from (r.adults + r.companions) then
    v := array_append(v, 'تغيّر عدد النزلاء بعد تسجيل شموس؛ حدِّث التسجيل');
  elsif r.shomoos_accepted_at is null then
    v := array_append(v, 'لم يُؤكَّد قبول شموس للتسجيل');
  end if;
  if r.room_id is null then
    v := array_append(v, 'لم تُخصَّص وحدة');
  else
    select * into rm from rooms where id = r.room_id;
    if not rm.is_active or rm.archived_at is not null then v := array_append(v, 'الوحدة موقوفة عن العمل');
    elsif rm.status in ('maintenance', 'blocked', 'out_of_service')
       or exists (select 1 from maintenance_tickets m where m.room_id = rm.id and m.status <> 'resolved') then v := array_append(v, 'الوحدة تحت الصيانة');
    elsif rm.cleanliness <> 'clean' then v := array_append(v, 'الوحدة غير نظيفة');
    end if;
    if exists (select 1 from reservations o where o.room_id = rm.id and o.status = 'checked_in' and o.id <> r.id) then
      v := array_append(v, 'في الوحدة نزيل لم تُسجَّل مغادرته');
    end if;
    if not exists (select 1 from reservation_allocations a where a.reservation_id = r.id and a.room_id = rm.id and a.status = 'active'
                   and a.from_date <= today and today < a.to_date)
       and exists (select 1 from reservation_allocations a where a.room_id = rm.id and a.status = 'active' and a.reservation_id <> r.id
                   and daterange(a.from_date, a.to_date, '[)') && daterange(today, greatest(r.check_out, today + 1), '[)')) then
      v := array_append(v, 'الوحدة محجوزة لحجز آخر في هذه الفترة');
    end if;
  end if;
  return v;
end $$;
revoke all on function fn_checkin_core_blockers(uuid) from public, anon, authenticated;

create or replace function fn_code_blockers(p_reservation uuid)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; kb keyboxes%rowtype; v text[] := '{}'; loc timestamp; dep time;
begin
  select * into r from reservations where id = p_reservation;
  if not found then return array['الحجز غير موجود']; end if;
  if r.status <> 'checked_in' then return array['لم يُسجَّل الوصول بعد']; end if;
  if coalesce(r.security_hold, false) then v := array_append(v, 'يوجد حظر أمني على الحجز'); end if;
  if jsonb_array_length(fn_reservation_ban_matches(r.id)) > 0 then v := array_append(v, 'الضيف محظور من الإدارة'); end if;
  loc := fn_branch_local_now(r.branch_id);
  dep := coalesce(r.late_checkout_until, (select check_out_time from branches where id = r.branch_id), time '12:00');
  if loc > (r.check_out + dep) then v := array_append(v, 'انتهى موعد المغادرة'); end if;
  if r.room_id is null then return array_append(v, 'لم تُخصَّص وحدة'); end if;
  select * into kb from keyboxes where room_id = r.room_id limit 1;
  if not found then v := array_append(v, 'الوحدة بلا صندوق مفتاح؛ يُسلَّم مفتاحها يدويًا');
  elsif kb.code_encrypted is null then v := array_append(v, 'لم يُعيَّن رمز الصندوق');
  elsif kb.code_status <> 'active' then v := array_append(v, 'رمز الصندوق يحتاج إلى تغيير');
  elsif not kb.field_tested then v := array_append(v, 'لم يُجرَّب رمز الصندوق على الصندوق');
  elsif kb.last_reservation_id is not null and kb.last_reservation_id <> r.id then v := array_append(v, 'الرمز الحالي سُلِّم لحجز آخر ويجب تغييره');
  end if;
  return v;
end $$;
revoke all on function fn_code_blockers(uuid) from public, anon, authenticated;

-- the guest's page: a ban or a hold reads «يرجى مراجعة الاستقبال», nothing more
create or replace function fn_guest_session(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  rid uuid := fn_token_reservation(p_token);
  r reservations%rowtype;
  ev record;
  d jsonb;
begin
  select * into r from reservations where id = rid;
  select * into ev from fn_evaluate_access(rid, false);
  d := fn_stay_due_internal(rid);
  return jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out, 'adults', r.adults, 'companions', r.companions,
      'payment_status', r.payment_status, 'identity_status', r.identity_status,
      'government_registration', r.government_registration, 'access_status', r.access_status,
      'total_halalas', r.total_halalas, 'paid_halalas', r.paid_halalas,
      'has_keybox', exists (select 1 from keyboxes k where k.room_id = r.room_id),
      'first_night_paid', coalesce((d->>'collected')::bigint >= (d->>'first_night')::bigint, false),
      'branch_id', r.branch_id,
      'branch_name', (select name_ar from branches where id = r.branch_id),
      'room_number', (select room_number from rooms where id = r.room_id),
      'category_name', (select name_ar from room_categories where id = r.room_category_id),
      'summary_accepted', exists (select 1 from stay_acknowledgements a where a.reservation_id = r.id)),
    'guests', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'is_primary', g.is_primary, 'full_name', g.full_name, 'identity_type', g.identity_type,
        'identity_number_last4', g.identity_number_last4, 'nationality', g.nationality, 'birth_date', g.birth_date,
        'relationship', g.relationship, 'verification_status', g.verification_status, 'data_submitted', g.data_submitted)
        order by g.is_primary desc, g.created_at)
      from reservation_guests g where g.reservation_id = rid), '[]'::jsonb),
    'access', jsonb_build_object('allowed', ev.allowed,
      'reasons', to_jsonb(array(select y from (select case when x in ('الضيف محظور من الإدارة', 'يوجد حظر أمني على الحجز') then 'يرجى مراجعة الاستقبال' else x end as y,
                                                      min(i) as i from unnest(ev.reasons) with ordinality u(x, i) group by 1) z order by i))),
    'expires_at', (select expires_at from registration_sessions where token = p_token));
end $$;
revoke all on function fn_guest_session(text) from public;
grant execute on function fn_guest_session(text) to anon, authenticated, service_role;

-- the red alerts, holds and ratings of a branch's current bookings (for the lists and the arrivals)
create or replace function fn_reservation_flags(p_branch uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  perform fn_require_branch(p_branch);
  return coalesce((
    select jsonb_object_agg(x.id, jsonb_build_object('ban', x.ban, 'hold', x.hold, 'rating', x.rating))
    from (select r.id, jsonb_array_length(fn_reservation_ban_matches(r.id)) > 0 as ban, coalesce(r.security_hold, false) as hold,
                 (select gp.rating from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id where g.reservation_id = r.id and g.is_primary limit 1) as rating
            from reservations r
           where r.branch_id = p_branch and r.status in ('draft', 'pending_verification', 'confirmed', 'checked_in')) x
    where x.ban or x.hold or x.rating is not null), '{}'::jsonb);
end $$;
revoke all on function fn_reservation_flags(uuid) from public, anon;
grant execute on function fn_reservation_flags(uuid) to authenticated;

create or replace function fn_reservation_detail(p_reservation uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when r.branch_id in (select fn_user_branch_ids()) then jsonb_build_object(
    'reservation', case when fn_has_role('owner','manager','supervisor','finance') then to_jsonb(r) - 'notes'
                        else to_jsonb(r) - 'notes' - 'total_halalas' - 'paid_halalas' - 'rent_amount_halalas' - 'discount_halalas' - 'addons_halalas' - 'taxes_halalas'
                             - 'balance_due_halalas' - 'deposit_balance_halalas' - 'refunded_halalas' - 'nightly_rate_halalas' - 'payment_status' - 'company_name' - 'gov_registration_ref'
                             - 'platform_collects' end,
    'notes', r.notes,
    'source', (select jsonb_build_object('name', name, 'code', code, 'kind', kind) from booking_sources where id = r.source_id),
    'category', (select name_ar from room_categories where id = r.room_category_id),
    'room', (select jsonb_build_object('id', id, 'room_number', room_number, 'status', status, 'cleanliness', cleanliness) from rooms where id = r.room_id),
    'guests', case when fn_has_role('owner','manager','supervisor','finance') then (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'is_primary', g.is_primary, 'full_name', g.full_name,
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
                  'booked_on', r.platform_booked_on, 'collects', case when fn_has_role('owner','manager','supervisor','finance') then r.platform_collects end,
                  'verified_at', r.platform_verified_at, 'verified_by', (select full_name from staff_profiles where id = r.platform_verified_by),
                  'cancel_reference', r.cancel_reference) end,
    'acknowledgements', case when fn_has_role('owner','manager','supervisor','finance') then fn_ack_list(r.id) end,
    'allocations', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'room_number', rm.room_number, 'from_date', a.from_date, 'to_date', a.to_date, 'status', a.status, 'reason', a.reason, 'created_at', a.created_at) order by a.from_date, a.created_at), '[]'::jsonb)
                    from reservation_allocations a join rooms rm on rm.id = a.room_id where a.reservation_id = r.id),
    'charges', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('invoiced_halalas', coalesce((
                      select sum((l->>'amount_halalas')::bigint) from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
                       where i.reservation_id = r.id and i.status = 'issued' and (l->>'charge_id')::uuid = c.id), 0)) order by c.created_at), '[]'::jsonb)
                    from reservation_charges c where c.reservation_id = r.id) end,
    'vouchers', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg((to_jsonb(v) - 'content_hash') || jsonb_build_object(
                      'created_by_name', (select full_name from staff_profiles where id = v.created_by),
                      'original_number', (select number from financial_vouchers o where o.id = v.original_voucher_id),
                      'replaced_by_number', (select x.number from financial_vouchers x where x.original_voucher_id = v.id order by x.created_at desc limit 1))
                    order by v.occurred_at), '[]'::jsonb) from financial_vouchers v where v.reservation_id = r.id) end,
    'invoices', case when fn_has_role('owner','manager','supervisor','finance') then
                 (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number, 'status', i.status, 'scope', i.scope, 'origin', i.origin, 'version', i.version,
                      'subtotal_halalas', i.subtotal_halalas, 'tax_halalas', i.tax_halalas, 'total_halalas', i.total_halalas,
                      'issued_at', i.issued_at, 'issued_by', (select full_name from staff_profiles where id = i.issued_by),
                      'updated_at', i.updated_at, 'updated_by', (select full_name from staff_profiles where id = i.updated_by),
                      'cancelled_at', i.cancelled_at, 'cancel_reason', i.cancel_reason,
                      'period_from', i.period_from, 'period_to', i.period_to, 'bill_to', i.bill_to, 'lines', i.snapshot->'lines', 'versions', i.versions)
                    order by i.issued_at), '[]'::jsonb) from invoices i where i.reservation_id = r.id) end,
    'invoicing', case when fn_has_role('owner','manager','supervisor','finance') then jsonb_build_object('uninvoiced_halalas', fn_uninvoiced_value(r.id)) end,
    'finance', case when fn_has_role('owner','manager','supervisor','finance') then fn_reservation_finance_internal(r.id) end,
    'history', case when fn_has_role('owner','manager','supervisor') then (select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'at', e.created_at, 'actor', (select full_name from staff_profiles where id = e.actor_id), 'details', e.details) order by e.created_at desc), '[]'::jsonb)
                from (select * from audit_events where entity_id = r.id order by created_at desc limit 50) e) end
  ) end
  from reservations r where r.id = p_reservation;
$$;
revoke all on function fn_reservation_detail(uuid) from public, anon;
grant execute on function fn_reservation_detail(uuid) to authenticated;

create or replace function fn_reservation_list(p_branch uuid, p_filters jsonb default '{}'::jsonb, p_limit int default 50, p_offset int default 0)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with base as (
    select r.*, (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1) as guest_name,
           (select room_number from rooms where id = r.room_id) as room_number, (select name from booking_sources where id = r.source_id) as source_name,
           (select name_ar from room_categories where id = r.room_category_id) as category_name,
           fn_has_role('owner','manager','supervisor','finance') as money
    from reservations r
    where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
      and (coalesce(p_filters->>'status','') = '' or r.status::text = any(string_to_array(p_filters->>'status', ',')))
      and (coalesce(p_filters->>'open_only','false') <> 'true' or r.status in ('pending_verification','confirmed','checked_in'))
      and (p_filters->>'check_in_from' is null or r.check_in >= (p_filters->>'check_in_from')::date)
      and (p_filters->>'check_in_to' is null or r.check_in <= (p_filters->>'check_in_to')::date)
      and (p_filters->>'check_out_from' is null or r.check_out >= (p_filters->>'check_out_from')::date)
      and (p_filters->>'check_out_to' is null or r.check_out <= (p_filters->>'check_out_to')::date)
      and (p_filters->>'source_id' is null or r.source_id = (p_filters->>'source_id')::uuid)
      and (coalesce(p_filters->>'has_balance','false') <> 'true' or (fn_has_role('owner','manager','supervisor','finance') and r.balance_due_halalas > 0))
      and (coalesce(p_filters->>'q','') = '' or r.internal_ref ilike '%' || (p_filters->>'q') || '%' or coalesce(r.external_ref,'') ilike '%' || (p_filters->>'q') || '%'
           or coalesce(r.cancel_reference,'') ilike '%' || (p_filters->>'q') || '%'
           or exists (select 1 from reservation_guests g where g.reservation_id = r.id and (g.full_name ilike '%' || (p_filters->>'q') || '%' or g.phone like '%' || (p_filters->>'q') || '%')))
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'status', status, 'check_in', check_in, 'check_out', check_out,
               'nights', check_out - check_in, 'guest_name', guest_name, 'room_number', room_number, 'source_name', source_name, 'category_name', category_name,
               'total_halalas', case when money then total_halalas end, 'paid_halalas', case when money then paid_halalas end,
               'balance_due_halalas', case when money then balance_due_halalas end, 'deposit_balance_halalas', case when money then deposit_balance_halalas end,
               'payment_status', payment_status, 'identity_status', identity_status, 'access_status', access_status, 'created_at', created_at,
               'group_ref', group_ref, 'hold', coalesce(security_hold, false),
               'ban', case when fn_has_role('owner','manager','supervisor','finance') then jsonb_array_length(fn_reservation_ban_matches(id)) > 0 end,
               'rating', case when fn_has_role('owner','manager','supervisor') then (select gp.rating from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id
                                                                                     where g.reservation_id = b.id and g.is_primary limit 1) end) order by check_in desc, created_at desc), '[]'::jsonb)
             from (select * from base order by check_in desc, created_at desc limit p_limit offset p_offset) b));
$$;
revoke all on function fn_reservation_list(uuid, jsonb, int, int) from public, anon;
grant execute on function fn_reservation_list(uuid, jsonb, int, int) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 15. A group booking (decision 69). Until 0039 (the owner's paste) retires the one-booking index, a group that shares
--     its platform number cannot be created: it is refused whole, with a message that says so, never half-made.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_staff_create_reservation(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare units jsonb := p->'units'; u jsonb; res jsonb; first jsonb; ids jsonb := '[]'::jsonb; refs jsonb := '[]'::jsonb; g text; n int;
begin
  perform fn_require_role('owner','manager','supervisor');
  if units is null or jsonb_typeof(units) <> 'array' or jsonb_array_length(units) = 0 then
    return fn_staff_create_reservation_unit(p, null);
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
  end loop;
  return first || jsonb_build_object('ids', ids, 'internal_refs', refs, 'group_ref', g, 'units', n);
end $$;
revoke all on function fn_staff_create_reservation(jsonb) from public, anon;
grant execute on function fn_staff_create_reservation(jsonb) to authenticated;
