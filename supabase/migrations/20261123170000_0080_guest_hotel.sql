-- 0080, plan2.6: an explicit hotel address scopes guest data and proof of phone ownership.
-- Historical unscoped phone sessions are not guessed into a hotel. Per-booking links remain valid.
-- No remote application until the backup/restore and independent gates pass.
alter table organizations add column if not exists guest_slug text;
update organizations set guest_slug=id::text where guest_slug is null;
alter table organizations alter column guest_slug set default gen_random_uuid()::text;
alter table organizations alter column guest_slug set not null;
create unique index if not exists organizations_guest_slug_key on organizations(lower(guest_slug));
alter table organizations drop constraint if exists organizations_guest_slug_format;
alter table organizations add constraint organizations_guest_slug_format check(guest_slug ~ '^[a-z0-9][a-z0-9-]{0,79}$') not valid;
alter table organizations validate constraint organizations_guest_slug_format;

-- This is a public-site selector, never proof of access to private hotel data.
create or replace function fn_guest_org_id() returns uuid
language plpgsql stable security definer set search_path=public,extensions as $$
declare h jsonb; v uuid; t text;
begin
 begin h:=coalesce(nullif(current_setting('request.headers',true),'')::jsonb,'{}'::jsonb); exception when others then return null; end;
 if coalesce(h->>'x-hotel-slug','')<>'' then
  select id into v from organizations where guest_slug=h->>'x-hotel-slug' and exists(select 1 from branches b where b.organization_id=organizations.id and b.is_active and b.archived_at is null);
  return v;
 end if;
 t:=h->>'x-guest-token';
 if t is not null then
  select r.organization_id into v from registration_sessions s join reservations r on r.id=s.reservation_id where s.token=t and s.expires_at>now();
  if v is null then select organization_id into v from guest_reviews where token_hash=encode(extensions.digest(t,'sha256'),'hex') and invited_at>now()-interval '14 days'; end if;
  return v;
 end if;
 -- Compatibility for the original single-hotel installation only. Never choose the first of several.
 select min(id::text)::uuid into v from organizations where exists(select 1 from branches b where b.organization_id=organizations.id and b.is_active and b.archived_at is null) having count(*)=1;
 return v;
end $$;
revoke all on function fn_guest_org_id() from public;
grant execute on function fn_guest_org_id() to anon,authenticated,service_role;

create or replace function fn_guest_site(p_slug text) returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('id',o.id,'slug',o.guest_slug,'name_ar',o.name_ar,'name_en',o.name_en)
 from organizations o where o.guest_slug=p_slug and exists(select 1 from branches b where b.organization_id=o.id and b.is_active and b.archived_at is null)
$$;
revoke all on function fn_guest_site(text) from public;
grant execute on function fn_guest_site(text) to anon,authenticated,service_role;

-- Existing column grants remain narrow, but raw public rows now belong to one site's hotel.
alter policy anon_read_branches_public on branches using(is_active and archived_at is null and organization_id=fn_guest_org_id());
alter policy anon_read_sources on booking_sources using(is_active and organization_id=fn_guest_org_id());
alter policy anon_read_public_policies on property_policies using(is_public and organization_id=fn_guest_org_id());
alter policy anon_read_public_cats on room_categories using(is_public and is_active and organization_id=fn_guest_org_id());

-- Private reservation selector; no cross-hotel phone matching.
create or replace function fn_phone_reservation_ids(p_phone text,p_org uuid,p_branch uuid default null) returns setof uuid
language sql stable security definer set search_path=public,extensions as $$
 select distinct r.id from reservations r join reservation_guests g on g.reservation_id=r.id and g.is_primary
 left join guest_profiles gp on gp.id=g.guest_profile_id
 where r.organization_id=p_org and (p_branch is null or r.branch_id=p_branch) and p_phone is not null
 and (fn_normalize_phone(g.phone)=p_phone or fn_normalize_phone(gp.phone)=p_phone)
 and r.status<>'rejected' and r.check_out>=fn_branch_today(r.branch_id)-60
$$;
revoke all on function fn_phone_reservation_ids(text,uuid,uuid) from public,anon,authenticated;

create or replace function fn_phone_session(p_phone text,p_method text,p_org uuid,p_branch uuid default null) returns text
language plpgsql security definer set search_path=public,extensions as $$
declare v text;
begin
 if p_org is null or (p_branch is not null and not exists(select 1 from branches where id=p_branch and organization_id=p_org)) then raise exception 'HOTEL_REQUIRED'; end if;
 insert into guest_phone_sessions(phone,method,organization_id,branch_id) values(p_phone,p_method,p_org,p_branch) returning token into v;
 return v;
end $$;
revoke all on function fn_phone_session(text,text,uuid,uuid) from public,anon,authenticated;

create or replace function fn_whatsapp_phone_session(p_phone text,p_branch uuid) returns text
language plpgsql security definer set search_path=public,extensions as $$
declare v_phone text:=fn_normalize_phone(p_phone); v_org uuid;
begin
 select organization_id into v_org from branches where id=p_branch and is_active and archived_at is null;
 if v_phone is null or v_org is null then raise exception 'VALIDATION: phone_or_branch'; end if;
 return fn_phone_session(v_phone,'whatsapp_sender',v_org,p_branch);
end $$;
revoke all on function fn_whatsapp_phone_session(text,uuid) from public,anon,authenticated;
grant execute on function fn_whatsapp_phone_session(text,uuid) to service_role;
-- Prevent legacy service callers from creating hotel-less capabilities.
create or replace function fn_whatsapp_phone_session(p_phone text) returns text
language plpgsql security definer set search_path=public as $$ begin raise exception 'BRANCH_REQUIRED'; end $$;
create or replace function fn_phone_session(p_phone text,p_method text) returns text
language plpgsql security definer set search_path=public as $$ begin raise exception 'HOTEL_REQUIRED'; end $$;

CREATE OR REPLACE FUNCTION public.fn_guest_phone_start(p_phone text, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_org uuid:=fn_guest_org_id(); v_phone text := fn_normalize_phone(p_phone); v_code text; v_id uuid; v_branch uuid;
begin
  if v_org is null or v_phone is null then return jsonb_build_object('status', 'invalid'); end if;
  if (select count(*) from guest_phone_challenges where organization_id=v_org and phone = v_phone and created_at > now() - interval '1 hour') >= 5
     or (p_fingerprint is not null and (select count(*) from guest_phone_challenges where organization_id=v_org and client_fingerprint = p_fingerprint and created_at > now() - interval '1 hour') >= 20) then
    return jsonb_build_object('status', 'throttled');
  end if;
  select r.branch_id into v_branch from reservations r where r.id in (select fn_phone_reservation_ids(v_phone,v_org)) order by r.check_in desc limit 1;
  if v_branch is null then
    return jsonb_build_object('status', 'no_reservations', 'phone', v_phone);
  end if;
  v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  insert into guest_phone_challenges(phone, code_hash, client_fingerprint,organization_id,branch_id)
  values (v_phone, 'pending', p_fingerprint,v_org,v_branch) returning id into v_id;
  update guest_phone_challenges set code_hash = encode(digest(v_id::text || ':' || v_code, 'sha256'), 'hex') where id = v_id;
  return jsonb_build_object('status', 'ok', 'phone', v_phone, 'code', v_code, 'challenge_id', v_id, 'branch_id', v_branch);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_guest_phone_verify(p_phone text, p_code text, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_org uuid:=fn_guest_org_id(); v_phone text := fn_normalize_phone(p_phone); c guest_phone_challenges%rowtype;
        v_code text := regexp_replace(translate(coalesce(p_code, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g');
begin
  if v_org is null or v_phone is null or v_code !~ '^\d{6}$' then return jsonb_build_object('status', 'invalid'); end if;
  select * into c from guest_phone_challenges
   where organization_id=v_org and phone = v_phone and verified_at is null and expires_at > now()
   order by created_at desc limit 1 for update;
  if not found then return jsonb_build_object('status', 'expired'); end if;
  if c.attempts >= 5 then return jsonb_build_object('status', 'throttled'); end if;
  if c.code_hash <> encode(digest(c.id::text || ':' || v_code, 'sha256'), 'hex') then
    update guest_phone_challenges set attempts = attempts + 1 where id = c.id;
    return jsonb_build_object('status', 'mismatch', 'attempts_left', 4 - c.attempts);
  end if;
  update guest_phone_challenges set verified_at = now() where id = c.id;
  update reservation_guests g set phone_verified = true
   where g.is_primary and g.reservation_id in (select fn_phone_reservation_ids(v_phone,v_org)) and fn_normalize_phone(g.phone) = v_phone;
  return jsonb_build_object('status', 'ok', 'token', fn_phone_session(v_phone, 'whatsapp_code',v_org));
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_guest_phone_verify_ref(p_phone text, p_ref text, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_org uuid:=fn_guest_org_id(); v_phone text := fn_normalize_phone(p_phone); v_ref text := upper(trim(coalesce(p_ref, ''))); v_ok boolean;
begin
  if v_org is null or v_phone is null or v_ref = '' then return jsonb_build_object('status', 'invalid'); end if;
  perform pg_advisory_xact_lock(hashtext('lookup:' || v_phone));
  if (select count(*) from guest_lookup_attempts where organization_id=v_org and external_ref = 'PHONE:' || v_phone and not ok and created_at > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('status', 'throttled');
  end if;
  select exists (select 1 from reservations r where r.id in (select fn_phone_reservation_ids(v_phone,v_org))
                  and (upper(r.external_ref) = v_ref or upper(r.internal_ref) = v_ref)) into v_ok;
  insert into guest_lookup_attempts(external_ref, client_fingerprint, ok,organization_id) values ('PHONE:' || v_phone, p_fingerprint, v_ok,v_org);
  if not v_ok then return jsonb_build_object('status', 'mismatch'); end if;
  return jsonb_build_object('status', 'ok', 'token', fn_phone_session(v_phone, 'booking_number',v_org));
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_guest_phone_reservations(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s guest_phone_sessions%rowtype;
begin
  select * into s from guest_phone_sessions where token = p_token and expires_at > now() and organization_id is not null and (organization_id=fn_guest_org_id() or (method='whatsapp_sender' and coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null));
  if not found then raise exception 'TOKEN_INVALID'; end if;
  return jsonb_build_object('phone_last4', right(s.phone, 4), 'reservations', coalesce((
    select jsonb_agg(jsonb_build_object(
      'ref', coalesce(r.external_ref, r.internal_ref), 'internal_ref', r.internal_ref, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out, 'nights', r.check_out - r.check_in,
      'branch_name', b.name_ar, 'category_name', c.name_ar, 'payment_status', r.payment_status,
      'access_status', r.access_status, 'identity_status', r.identity_status)
      order by (r.check_out < fn_branch_today(r.branch_id)), r.check_in)
    from reservations r
    join branches b on b.id = r.branch_id
    left join room_categories c on c.id = r.room_category_id
    where r.id in (select fn_phone_reservation_ids(s.phone,s.organization_id,s.branch_id))), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_guest_phone_open(p_token text, p_internal_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s guest_phone_sessions%rowtype; r reservations%rowtype; v_token text;
begin
  select * into s from guest_phone_sessions where token = p_token and expires_at > now() and organization_id is not null and (organization_id=fn_guest_org_id() or (method='whatsapp_sender' and coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null));
  if not found then raise exception 'TOKEN_INVALID'; end if;
  select * into r from reservations where internal_ref = p_internal_ref and id in (select fn_phone_reservation_ids(s.phone,s.organization_id,s.branch_id));
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into registration_sessions(reservation_id, expires_at) values (r.id, now() + interval '24 hours') returning token into v_token;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_verified_lookup', 'reservation', r.id,
    jsonb_build_object('channel', case when s.method = 'whatsapp_sender' then 'whatsapp' else 'web' end, 'method', s.method));
  return jsonb_build_object('status', 'ok', 'token', v_token);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_public_organization()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('name_ar', o.name_ar, 'name_en', o.name_en, 'logo', fn_organization_logo(o.id))
  from organizations o
  where o.id=case when coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is not null then fn_guest_org_id() else coalesce(fn_user_org_id(),fn_guest_org_id()) end and exists (select 1 from branches b where b.organization_id = o.id and b.is_active and b.archived_at is null)
  order by o.created_at limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_public_branch(p_branch uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('id', b.id, 'name_ar', b.name_ar, 'name_en', b.name_en, 'city', b.city, 'address', b.address, 'phone', b.phone,
           'map_url', b.map_url, 'booking_platform_url', b.booking_platform_url, 'default_language', b.default_language, 'country_code', b.country_code,
           'check_in_time', to_char(b.check_in_time, 'HH24:MI'), 'check_out_time', to_char(b.check_out_time, 'HH24:MI'),
           'logo_version', (select left(sha256, 12) from branch_media where branch_id = b.id and kind = 'logo' and bytes is not null),
           'image_version', (select left(sha256, 12) from branch_media where branch_id = b.id and kind = 'image' and bytes is not null))
  from branches b where b.id = p_branch and (b.organization_id=fn_guest_org_id() or (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null and b.id in(select fn_user_branch_ids())) or current_setting('role',true)='service_role') and (b.is_active or b.id in (select fn_user_branch_ids()));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_public_whatsapp(p_branch uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select jsonb_build_object(
    'active', coalesce(c.enabled and (c.status in ('configured', 'active') or (c.mode = 'web_bridge' and c.status = 'error')), false),
    'wa_phone', case when c.enabled and (c.status in ('configured', 'active') or (c.mode = 'web_bridge' and c.status = 'error')) then c.display_phone end,
    'branch_name', b.name_ar, 'branch_phone', b.phone)
  from branches b left join branch_whatsapp_channels c on c.branch_id = b.id
  where b.id = p_branch and (b.organization_id=fn_guest_org_id() or (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null and b.id in(select fn_user_branch_ids())) or current_setting('role',true)='service_role') and b.is_active and b.archived_at is null
$function$
;

CREATE OR REPLACE FUNCTION public.fn_public_branch_guide(p_branch uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'arrival_instructions', b.arrival_instructions,
    'bank', case when b.bank_iban is not null then jsonb_build_object('bank_name', b.bank_name, 'beneficiary', b.bank_beneficiary, 'iban', b.bank_iban) end,
    'photos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'caption', m.caption, 'version', left(m.sha256, 12)) order by m.sort_order, m.created_at)
                        from branch_media_items m where m.branch_id = b.id and m.kind = 'photo' and m.archived_at is null and m.room_id is null), '[]'::jsonb),
    'videos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'caption', m.caption, 'url', m.url, 'block_id', m.block_id, 'room_id', m.room_id) order by m.sort_order, m.created_at)
                        from branch_media_items m where m.branch_id = b.id and m.kind = 'video' and m.archived_at is null), '[]'::jsonb))
  from branches b where b.id = p_branch and (b.organization_id=fn_guest_org_id() or (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null and b.id in(select fn_user_branch_ids())) or current_setting('role',true)='service_role') and (b.is_active or b.id in (select fn_user_branch_ids()));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_branch_media(p_branch uuid, p_kind text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select 'data:' || m.mime || ';base64,' || replace(encode(m.bytes, 'base64'), E'\n', '')
  from branch_media m join branches b on b.id = m.branch_id
  where (b.organization_id=fn_guest_org_id() or (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null and b.id in(select fn_user_branch_ids())) or current_setting('role',true)='service_role') and m.branch_id = p_branch and m.kind = p_kind and m.bytes is not null
    and (b.is_active or b.id in (select fn_user_branch_ids()));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_branch_photo(p_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select 'data:' || m.mime || ';base64,' || replace(encode(m.bytes, 'base64'), E'\n', '')
  from branch_media_items m join branches b on b.id = m.branch_id
  where (b.organization_id=fn_guest_org_id() or (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null and b.id in(select fn_user_branch_ids())) or current_setting('role',true)='service_role') and m.id = p_id and m.kind = 'photo' and m.bytes is not null
    and ((m.archived_at is null and b.is_active and (m.purpose = 'gallery' or m.approved_at is not null)) or m.branch_id in (select fn_user_branch_ids()));
$function$
;

CREATE OR REPLACE FUNCTION public.fn_guest_lookup(p_external_ref text, p_phone_last4 text, p_source_id uuid DEFAULT NULL::uuid, p_fingerprint text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_org uuid:=fn_guest_org_id();
  r reservations%rowtype;
  pg reservation_guests%rowtype;
  v_ref text := upper(trim(p_external_ref));
  v_token text;
  attempts int;
  v_match boolean := false;
begin
  if v_org is null or v_ref = '' or p_phone_last4 !~ '^\d{4}$' then
    return jsonb_build_object('status','invalid');
  end if;

  -- brute-force throttle: 5 failed attempts / 15 min per reference
  select count(*) into attempts from guest_lookup_attempts
   where organization_id=v_org and external_ref = v_ref and not ok and created_at > now() - interval '15 minutes';
  if attempts >= 5 then
    return jsonb_build_object('status','throttled');
  end if;

  select * into r from reservations
   where organization_id=v_org and upper(external_ref) = v_ref and (p_source_id is null or source_id = p_source_id)
     and status not in ('cancelled','rejected','closed')
   limit 1;

  if not found then
    insert into guest_lookup_attempts(external_ref, client_fingerprint, ok,organization_id) values (v_ref, p_fingerprint, false,v_org);
    insert into human_handoff_tickets(organization_id, branch_id, kind, external_ref, source_name, details)
    select o.id, null, 'unmatched_reservation', v_ref, (select name from booking_sources where id = p_source_id),
           jsonb_build_object('phone_last4_given', true)
    from organizations o where o.id=v_org;
    return jsonb_build_object('status','unmatched');
  end if;

  select * into pg from reservation_guests where reservation_id = r.id and is_primary limit 1;
  if found and pg.phone is not null and right(regexp_replace(pg.phone,'\D','','g'),4) = p_phone_last4 then
    v_match := true;
  elsif found and pg.guest_profile_id is not null then
    select right(regexp_replace(phone,'\D','','g'),4) = p_phone_last4 into v_match from guest_profiles where id = pg.guest_profile_id;
  end if;

  insert into guest_lookup_attempts(external_ref, client_fingerprint, ok,organization_id) values (v_ref, p_fingerprint, coalesce(v_match,false),v_org);
  if not coalesce(v_match,false) then
    return jsonb_build_object('status','mismatch');
  end if;

  insert into registration_sessions(reservation_id, expires_at) values (r.id, now() + interval '24 hours')
  returning token into v_token;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_verified_lookup', 'reservation', r.id, jsonb_build_object('channel','web'));
  return jsonb_build_object('status','ok','token', v_token);
end $function$
;
CREATE OR REPLACE FUNCTION public.fn_token_reservation(p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v uuid;
begin
  select reservation_id into v from registration_sessions
   where token = p_token and expires_at > now() and (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null or organization_id=fn_guest_org_id()) limit 1;
  if v is null then raise exception 'TOKEN_INVALID' using errcode = 'P0002'; end if;
  return v;
end $function$
;

-- The guest-facing list is the same even if this browser also has a staff session.
create or replace function fn_guest_branches() returns jsonb
language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name_ar',b.name_ar,'name_en',b.name_en,'check_in_time',b.check_in_time,'check_out_time',b.check_out_time,'tax_rate_bp',b.tax_rate_bp,'prices_include_tax',b.prices_include_tax,'map_url',b.map_url,'booking_platform_url',b.booking_platform_url,'default_language',b.default_language) order by b.created_at),'[]'::jsonb)
 from branches b where b.organization_id=fn_guest_org_id() and b.is_active and b.archived_at is null
$$;
revoke all on function fn_guest_branches() from public;
grant execute on function fn_guest_branches() to anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.fn_public_review(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare g guest_reviews%rowtype; r reservations%rowtype;
begin
  select * into g from guest_reviews where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and invited_at > now() - interval '14 days' and (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null or organization_id=fn_guest_org_id());
  if not found then raise exception 'TOKEN_INVALID' using errcode = 'P0002'; end if;
  select * into r from reservations where id = g.reservation_id;
  return jsonb_build_object('branch_name', (select name_ar from branches where id = g.branch_id), 'check_in', r.check_in, 'check_out', r.check_out,
                            'submitted', g.submitted_at is not null, 'aspects', fn_review_aspects(), 'reply', g.reply);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_public_submit_review(p_token text, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare g guest_reviews%rowtype; k text; s branch_journey_settings%rowtype; v_comment text := nullif(btrim(coalesce(p->>'comment', '')), ''); v_room text;
begin
  select * into g from guest_reviews where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and invited_at > now() - interval '14 days' and (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null or organization_id=fn_guest_org_id()) for update;
  if not found then raise exception 'TOKEN_INVALID' using errcode = 'P0002'; end if;
  if g.submitted_at is not null then raise exception 'VALIDATION: review_submitted'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'VALIDATION: review_marks'; end if;
  foreach k in array array['overall', 'staff', 'cleanliness', 'comfort', 'facilities', 'value', 'location'] loop
    if coalesce(p->>k, '') !~ '^[0-9]{1,2}$' or (p->>k)::int not between 1 and 10 then raise exception 'VALIDATION: review_marks'; end if;
  end loop;
  if v_comment is not null and char_length(v_comment) > 1000 then raise exception 'VALIDATION: review_comment'; end if;
  update guest_reviews set submitted_at = now(), overall = (p->>'overall')::int, staff = (p->>'staff')::int, cleanliness = (p->>'cleanliness')::int,
         comfort = (p->>'comfort')::int, facilities = (p->>'facilities')::int, value = (p->>'value')::int, location = (p->>'location')::int,
         comment = v_comment, version = version + 1
   where id = g.id;
  select * into s from branch_journey_settings where branch_id = g.branch_id;
  if (p->>'overall')::int < s.review_alert_below then
    v_room := coalesce((select rm.room_number from reservations rs join rooms rm on rm.id = rs.room_id where rs.id = g.reservation_id), '');
    perform fn_alert_raise(g.branch_id, 'review_low', 'review:' || g.id, 'تقييم ' || (p->>'overall') || ' من 10 — غرفة ' || v_room,
      coalesce(left(v_comment, 300), 'بلا تعليق'), '/staff/journey', g.reservation_id);
  end if;
  return jsonb_build_object('ok', true);
end $function$
;
