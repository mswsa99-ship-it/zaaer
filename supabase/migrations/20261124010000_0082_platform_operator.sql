-- 0082 / plan2.8. Platform operators are not hotel staff and cannot enroll themselves.
-- A project administrator provisions the allowlist; this migration creates no operator account.
create table if not exists platform_operators(
 auth_user_id uuid primary key, full_name text not null, is_active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists platform_events(
 id uuid primary key default gen_random_uuid(), actor_user_id uuid not null, organization_id uuid references organizations(id),
 action text not null, reason text, details jsonb not null default '{}', created_at timestamptz not null default now()
);
create table if not exists platform_support_grants(
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references organizations(id),operator_user_id uuid not null references platform_operators(auth_user_id),
 approved_by uuid not null references staff_profiles(id),reason text not null check(length(btrim(reason)) between 5 and 500),
 expires_at timestamptz not null,revoked_at timestamptz,created_at timestamptz not null default now(),
 check(expires_at>created_at and expires_at<=created_at+interval '24 hours')
);
alter table platform_operators enable row level security;
alter table platform_events enable row level security;
alter table platform_support_grants enable row level security;
revoke all on platform_operators,platform_events,platform_support_grants from anon,authenticated;
grant select,insert,update,delete on platform_operators,platform_events,platform_support_grants to service_role;
alter table organizations add column if not exists platform_status text not null default 'active' check(platform_status in('active','suspended'));
alter table organizations add column if not exists platform_status_reason text;
alter table organizations add column if not exists platform_status_changed_at timestamptz;

create or replace function fn_platform_operator_id() returns uuid language sql stable security definer set search_path=public as $$
 select auth_user_id from platform_operators where auth_user_id=auth.uid() and is_active and fn_session_ok()
$$;
revoke all on function fn_platform_operator_id() from public,anon;
grant execute on function fn_platform_operator_id() to authenticated;
create or replace function fn_require_platform_operator() returns uuid language plpgsql stable security definer set search_path=public as $$
declare v uuid:=fn_platform_operator_id();begin if v is null then raise exception 'FORBIDDEN: platform operator required' using errcode='42501';end if;return v;end $$;
revoke all on function fn_require_platform_operator() from public,anon,authenticated;

-- Platform events are append-only even for the service role. No user-supplied actor or timestamp.
create or replace function fn_platform_event_immutable() returns trigger language plpgsql set search_path=public as $$
begin raise exception 'IMMUTABLE: platform event';end $$;
revoke all on function fn_platform_event_immutable() from public,anon,authenticated;
create or replace trigger platform_event_immutable before update or delete on platform_events for each row execute function fn_platform_event_immutable();
create or replace function fn_platform_audit(p_org uuid,p_action text,p_reason text default null,p_details jsonb default '{}') returns void language plpgsql security definer set search_path=public as $$
begin if auth.uid() is null then raise exception 'NOT_AUTHENTICATED';end if;
insert into platform_events(actor_user_id,organization_id,action,reason,details) values(auth.uid(),p_org,p_action,left(p_reason,500),p_details);end $$;
revoke all on function fn_platform_audit(uuid,text,text,jsonb) from public,anon,authenticated;

create or replace function fn_platform_hotels() returns jsonb language plpgsql security definer set search_path=public as $$
begin perform fn_require_platform_operator();
return coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name_ar',o.name_ar,'slug',o.guest_slug,'status',o.platform_status,'branches',(select count(*) from branches b where b.organization_id=o.id),'pending_owner_id',(select s.id from staff_profiles s where s.organization_id=o.id and s.role='owner' and s.is_active and s.auth_user_id is null order by s.created_at limit 1),'owner_invited',(select bool_or(s.auth_user_id is not null) from staff_profiles s where s.organization_id=o.id and s.role='owner')) order by o.created_at) from organizations o),'[]'::jsonb);end $$;
revoke all on function fn_platform_hotels() from public,anon;
grant execute on function fn_platform_hotels() to authenticated;

create or replace function fn_platform_create_hotel(p jsonb) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v uuid; b uuid; s uuid; n text:=btrim(p->>'name_ar');bn text:=btrim(p->>'branch_name');em text:=lower(btrim(p->>'owner_email'));oname text:=btrim(p->>'owner_name');slug text:=lower(btrim(p->>'slug'));
begin perform fn_require_platform_operator();
if n is null or length(n) not between 2 and 120 or bn is null or length(bn) not between 2 and 120 or oname is null or length(oname) not between 2 and 120 or em is null or length(em)>254 or em !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or slug is null or slug !~ '^[a-z0-9][a-z0-9-]{2,62}$' then raise exception 'VALIDATION: hotel_fields';end if;
perform pg_advisory_xact_lock(hashtext('platform-email:'||em));
if exists(select 1 from staff_profiles where lower(email)=em) or exists(select 1 from auth.users where lower(email)=em) then raise exception 'VALIDATION: email_unavailable';end if;
if exists(select 1 from organizations where guest_slug=slug) then raise exception 'VALIDATION: slug_unavailable';end if;
insert into organizations(name_ar,guest_slug) values(n,slug) returning id into v;
insert into branches(organization_id,name_ar) values(v,bn) returning id into b;
insert into staff_profiles(organization_id,full_name,email,role) values(v,oname,em,'owner') returning id into s;
insert into branch_memberships(staff_id,branch_id) values(s,b);
perform fn_platform_audit(v,'hotel.created',null,jsonb_build_object('branch_id',b,'owner_profile_id',s));
return jsonb_build_object('id',v,'branch_id',b,'owner_profile_id',s,'invitation_status','pending');
exception when unique_violation then raise exception 'VALIDATION: hotel_unavailable';end $$;
revoke all on function fn_platform_create_hotel(jsonb) from public,anon;
grant execute on function fn_platform_create_hotel(jsonb) to authenticated;

create or replace function fn_platform_set_hotel_status(p_org uuid,p_status text,p_reason text) returns jsonb language plpgsql security definer set search_path=public as $$
begin perform fn_require_platform_operator();
if p_status is null or p_status not in('active','suspended') or p_reason is null or length(btrim(p_reason)) not between 5 and 500 then raise exception 'VALIDATION: hotel_status';end if;
update organizations set platform_status=p_status,platform_status_reason=btrim(p_reason),platform_status_changed_at=now() where id=p_org;
if not found then raise exception 'NOT_FOUND';end if;
if p_status='suspended' then perform fn_end_sessions(auth_user_id) from staff_profiles where organization_id=p_org and auth_user_id is not null;end if;
perform fn_platform_audit(p_org,'hotel.'||p_status,p_reason);return jsonb_build_object('ok',true);end $$;
revoke all on function fn_platform_set_hotel_status(uuid,text,text) from public,anon;
grant execute on function fn_platform_set_hotel_status(uuid,text,text) to authenticated;

create or replace function fn_platform_owner_invite_target(p_staff uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare s staff_profiles%rowtype;begin perform fn_require_platform_operator();
select * into s from staff_profiles where id=p_staff and role='owner' and is_active and auth_user_id is null;
if s.id is null or not exists(select 1 from organizations where id=s.organization_id and platform_status='active') then raise exception 'NOT_FOUND';end if;
if exists(select 1 from auth.users where lower(email)=lower(s.email)) then raise exception 'VALIDATION: email_unavailable';end if;
perform fn_platform_audit(s.organization_id,'hotel.owner_invite_requested',null,jsonb_build_object('staff_id',s.id));
return jsonb_build_object('email',s.email,'full_name',s.full_name,'organization_id',s.organization_id);end $$;
revoke all on function fn_platform_owner_invite_target(uuid) from public,anon;
grant execute on function fn_platform_owner_invite_target(uuid) to authenticated;

-- A still-unexpired JWT is not permission to use a suspended hotel.
create or replace function fn_session_ok() returns boolean language sql stable security definer set search_path=public as $$
 select (case when auth.uid() is null then true
 when coalesce(auth.jwt()->>'session_id','') !~ '^[0-9a-fA-F-]{36}$' then true
 else exists(select 1 from auth.sessions s where s.id=(auth.jwt()->>'session_id')::uuid and(s.not_after is null or s.not_after>now())) end)
 and not exists(select 1 from staff_profiles sp join organizations o on o.id=sp.organization_id where sp.auth_user_id=auth.uid() and o.platform_status='suspended')
$$;
revoke all on function fn_session_ok() from public,anon,authenticated;

create or replace function fn_platform_grant_support(p_operator uuid,p_reason text,p_hours int default 1) returns jsonb language plpgsql security definer set search_path=public as $$
declare v uuid;o uuid:=fn_user_org_id();s uuid:=fn_staff_id();begin
if fn_current_role() is distinct from 'owner'::role_code or o is null or s is null then raise exception 'FORBIDDEN: hotel owner required';end if;
if p_operator=auth.uid() or not exists(select 1 from platform_operators where auth_user_id=p_operator and is_active) then raise exception 'VALIDATION: operator';end if;
if p_hours is null or p_hours not between 1 and 24 or p_reason is null or length(btrim(p_reason)) not between 5 and 500 then raise exception 'VALIDATION: support_scope';end if;
insert into platform_support_grants(organization_id,operator_user_id,approved_by,reason,expires_at) values(o,p_operator,s,btrim(p_reason),now()+make_interval(hours=>p_hours)) returning id into v;
perform fn_platform_audit(o,'support.granted',p_reason,jsonb_build_object('grant_id',v,'operator_id',p_operator,'hours',p_hours));
return jsonb_build_object('id',v);end $$;
revoke all on function fn_platform_grant_support(uuid,text,int) from public,anon;
grant execute on function fn_platform_grant_support(uuid,text,int) to authenticated;
create or replace function fn_platform_revoke_support(p_grant uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare o uuid:=fn_user_org_id();begin
if fn_current_role() is distinct from 'owner'::role_code or o is null then raise exception 'FORBIDDEN: hotel owner required';end if;
update platform_support_grants set revoked_at=now() where id=p_grant and organization_id=o and revoked_at is null;
if not found then raise exception 'NOT_FOUND';end if;
perform fn_platform_audit(o,'support.revoked',null,jsonb_build_object('grant_id',p_grant));return jsonb_build_object('ok',true);end $$;
revoke all on function fn_platform_revoke_support(uuid) from public,anon;
grant execute on function fn_platform_revoke_support(uuid) to authenticated;

-- Suspended hotels cannot resolve a public site, phone session or token context.
create or replace function fn_guest_org_id() returns uuid
language plpgsql stable security definer set search_path=public,extensions as $$
declare h jsonb; v uuid; t text;
begin
 begin h:=coalesce(nullif(current_setting('request.headers',true),'')::jsonb,'{}'::jsonb); exception when others then return null; end;
 if coalesce(h->>'x-hotel-slug','')<>'' then
  select id into v from organizations where platform_status='active' and guest_slug=h->>'x-hotel-slug' and exists(select 1 from branches b where b.organization_id=organizations.id and b.is_active and b.archived_at is null);
  return v;
 end if;
 t:=h->>'x-guest-token';
 if t is not null then
  select r.organization_id into v from registration_sessions s join reservations r on r.id=s.reservation_id join organizations o on o.id=r.organization_id where o.platform_status='active' and s.token=t and s.expires_at>now();
  if v is null then select gr.organization_id into v from guest_reviews gr join organizations o on o.id=gr.organization_id where o.platform_status='active' and token_hash=encode(extensions.digest(t,'sha256'),'hex') and invited_at>now()-interval '14 days'; end if;
  return v;
 end if;
 -- Compatibility for the original single-hotel installation only. Never choose the first of several.
 select min(id::text)::uuid into v from organizations where platform_status='active' and exists(select 1 from branches b where b.organization_id=organizations.id and b.is_active and b.archived_at is null) having count(*)=1;
 return v;
end $$;
revoke all on function fn_guest_org_id() from public;
grant execute on function fn_guest_org_id() to anon,authenticated,service_role;

create or replace function fn_guest_site(p_slug text) returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('id',o.id,'slug',o.guest_slug,'name_ar',o.name_ar,'name_en',o.name_en)
 from organizations o where o.platform_status='active' and o.guest_slug=p_slug and exists(select 1 from branches b where b.organization_id=o.id and b.is_active and b.archived_at is null)
$$;
revoke all on function fn_guest_site(text) from public;
grant execute on function fn_guest_site(text) to anon,authenticated,service_role;


-- A booking capability is also invalid while its hotel is suspended, even without a site header.
CREATE OR REPLACE FUNCTION public.fn_token_reservation(p_token text) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions' AS $$
declare v uuid;begin
select s.reservation_id into v from registration_sessions s join organizations o on o.id=s.organization_id
where s.token=p_token and s.expires_at>now() and o.platform_status='active'
and(coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null or s.organization_id=fn_guest_org_id()) limit 1;
if v is null then raise exception 'TOKEN_INVALID' using errcode='P0002';end if;return v;end $$;

-- Explicit support access never grants a hotel role or broad table access.
create or replace function fn_platform_support_guests(p_grant uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare g platform_support_grants%rowtype; a uuid:=fn_require_platform_operator(); result jsonb;begin
select * into g from platform_support_grants where id=p_grant and operator_user_id=a and revoked_at is null and expires_at>now()
and exists(select 1 from organizations o where o.id=platform_support_grants.organization_id and o.platform_status='active') for share;
if not found then raise exception 'FORBIDDEN: support grant required' using errcode='42501';end if;
select coalesce(jsonb_agg(x),'[]') into result from (select id,full_name from guest_profiles where organization_id=g.organization_id order by id limit 100) x;
perform fn_platform_audit(g.organization_id,'support.guests_read',g.reason,jsonb_build_object('grant_id',g.id,'fields',jsonb_build_array('id','full_name'),'limit',100));
return result;end $$;
revoke all on function fn_platform_support_guests(uuid) from public,anon;
grant execute on function fn_platform_support_guests(uuid) to authenticated;
drop trigger if exists zz_hotel_pointers on platform_support_grants;
create trigger zz_hotel_pointers after insert or update on platform_support_grants for each row execute function fn_hotel_pointers('approved_by','staff_profiles');

-- Platform accounts never claim a pending hotel invitation or bootstrap an owner.
create or replace function fn_claim_staff_profile(p_full_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(coalesce(auth.jwt()->>'email','')); sp staff_profiles%rowtype; demo boolean;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if exists(select 1 from platform_operators where auth_user_id=auth.uid()) then return jsonb_build_object('ok',false,'error','PLATFORM_ACCOUNT');end if;
  select * into sp from staff_profiles where auth_user_id = auth.uid() limit 1;
  if found then return jsonb_build_object('ok', true, 'role', sp.role, 'claimed', false); end if;

  select * into sp from staff_profiles where lower(email) = v_email and auth_user_id is null and is_active and exists(select 1 from organizations o where o.id=staff_profiles.organization_id and o.platform_status='active') limit 1;
  if found then
    update staff_profiles set auth_user_id = auth.uid(), full_name = coalesce(nullif(trim(p_full_name),''), full_name) where id = sp.id;
    return jsonb_build_object('ok', true, 'role', sp.role, 'claimed', true);
  end if;

  select demo_mode into demo from system_settings where organization_id = '00000000-0000-0000-0000-000000000001';
  if coalesce(demo,false) and not exists (select 1 from staff_profiles where organization_id = '00000000-0000-0000-0000-000000000001' and auth_user_id is not null and is_active) then
    insert into staff_profiles(auth_user_id, organization_id, full_name, email, role, is_active)
    values (auth.uid(), '00000000-0000-0000-0000-000000000001', coalesce(nullif(trim(p_full_name),''), v_email), v_email, 'owner', true) returning * into sp;
    insert into branch_memberships(staff_id, branch_id) select sp.id, id from branches where organization_id = sp.organization_id;
    perform fn_audit(sp.organization_id, null, sp.id, 'demo_owner_bootstrap', 'staff_profile', sp.id, '{}'::jsonb);
    return jsonb_build_object('ok', true, 'role', 'owner', 'claimed', true, 'bootstrap', true);
  end if;
  return jsonb_build_object('ok', false, 'error', 'NO_INVITATION');
end $$;

CREATE OR REPLACE FUNCTION public.fn_guest_phone_reservations(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s guest_phone_sessions%rowtype;
begin
  select * into s from guest_phone_sessions where token = p_token and expires_at > now() and organization_id is not null and exists(select 1 from organizations o where o.id=guest_phone_sessions.organization_id and o.platform_status='active') and (organization_id=fn_guest_org_id() or (method='whatsapp_sender' and coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null));
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
  select * into s from guest_phone_sessions where token = p_token and expires_at > now() and organization_id is not null and exists(select 1 from organizations o where o.id=guest_phone_sessions.organization_id and o.platform_status='active') and (organization_id=fn_guest_org_id() or (method='whatsapp_sender' and coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null));
  if not found then raise exception 'TOKEN_INVALID'; end if;
  select * into r from reservations where internal_ref = p_internal_ref and id in (select fn_phone_reservation_ids(s.phone,s.organization_id,s.branch_id));
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into registration_sessions(reservation_id, expires_at) values (r.id, now() + interval '24 hours') returning token into v_token;
  perform fn_audit(r.organization_id, r.branch_id, null, 'guest_verified_lookup', 'reservation', r.id,
    jsonb_build_object('channel', case when s.method = 'whatsapp_sender' then 'whatsapp' else 'web' end, 'method', s.method));
  return jsonb_build_object('status', 'ok', 'token', v_token);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_public_review(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare g guest_reviews%rowtype; r reservations%rowtype;
begin
  select * into g from guest_reviews where exists(select 1 from organizations o where o.id=guest_reviews.organization_id and o.platform_status='active') and token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and invited_at > now() - interval '14 days' and (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null or organization_id=fn_guest_org_id());
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
  select * into g from guest_reviews where exists(select 1 from organizations o where o.id=guest_reviews.organization_id and o.platform_status='active') and token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and invited_at > now() - interval '14 days' and (coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-hotel-slug' is null or organization_id=fn_guest_org_id()) for update;
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

CREATE OR REPLACE FUNCTION public.fn_run_monitors(p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; x record; f jsonb; res jsonb := '{}'::jsonb; orgs uuid[] := '{}'; o uuid; k text; cnt int; fails int; codes int;
  here jsonb;
begin
  for b in select id, organization_id from branches where exists(select 1 from organizations o where o.id=branches.organization_id and o.platform_status='active') and archived_at is null and is_active and (p_branch is null or id = p_branch) order by id loop
    perform pg_advisory_xact_lock(hashtext('monitors:' || b.id::text));
    if not (b.organization_id = any(orgs)) then orgs := orgs || b.organization_id; end if;
    here := '{}'::jsonb;

    -- 1 allocation conflicts (the exclusion constraint forbids them; this says so if one ever gets through)
    for x in
      select a1.room_id, rm.room_number, array_agg(distinct r1.internal_ref) || array_agg(distinct r2.internal_ref) as refs
        from reservation_allocations a1
        join reservation_allocations a2 on a2.room_id = a1.room_id and a2.id > a1.id and a2.status = 'active'
                                       and daterange(a1.from_date, a1.to_date, '[)') && daterange(a2.from_date, a2.to_date, '[)')
        join rooms rm on rm.id = a1.room_id
        join reservations r1 on r1.id = a1.reservation_id
        join reservations r2 on r2.id = a2.reservation_id
       where a1.status = 'active' and rm.branch_id = b.id
       group by a1.room_id, rm.room_number
      union all
      select rm.id, rm.room_number, array_agg(r.internal_ref)
        from reservations r join rooms rm on rm.id = r.room_id
       where r.branch_id = b.id and r.status = 'checked_in'
       group by rm.id, rm.room_number having count(*) > 1
    loop
      if fn_monitor_finding(b.organization_id, b.id, 'allocation_conflict', 'room', x.room_id, null, 'تعارض تخصيص في الوحدة ' || x.room_number,
                            jsonb_build_object('room', x.room_number, 'reservations', to_jsonb(x.refs))) then
        here := here || jsonb_build_object('allocation_conflict', coalesce((here->>'allocation_conflict')::int, 0) + 1);
      end if;
    end loop;

    -- 2 and 3: the stays of the last 90 days and every open one, against their ledger
    for x in
      select r.id, r.internal_ref, r.status, r.total_halalas, r.paid_halalas, r.balance_due_halalas, r.deposit_balance_halalas
        from reservations r
       where r.branch_id = b.id
         and (r.status in ('pending_verification', 'confirmed', 'checked_in', 'checked_out') or r.updated_at > now() - interval '90 days')
    loop
      f := fn_reservation_finance_internal(x.id);
      if x.total_halalas is distinct from (f->>'total')::bigint or x.paid_halalas is distinct from (f->>'net_collected')::bigint
         or x.balance_due_halalas is distinct from (f->>'balance_due')::bigint or x.deposit_balance_halalas is distinct from (f->>'deposit_balance')::bigint then
        if fn_monitor_finding(b.organization_id, b.id, 'ledger_mismatch', 'reservation', x.id, x.id,
             'الملخص المالي للحجز ' || x.internal_ref || ' يختلف عن الدفتر',
             jsonb_build_object('stored', jsonb_build_object('total', x.total_halalas, 'paid', x.paid_halalas, 'balance_due', x.balance_due_halalas, 'deposit', x.deposit_balance_halalas),
                                'ledger', jsonb_build_object('total', (f->>'total')::bigint, 'paid', (f->>'net_collected')::bigint,
                                                             'balance_due', (f->>'balance_due')::bigint, 'deposit', (f->>'deposit_balance')::bigint))) then
          here := here || jsonb_build_object('ledger_mismatch', coalesce((here->>'ledger_mismatch')::int, 0) + 1);
        end if;
      end if;
      if (f->>'deposit_balance')::bigint < 0 or (x.status = 'closed' and (f->>'deposit_balance')::bigint <> 0) then
        if fn_monitor_finding(b.organization_id, b.id, 'deposit_invalid', 'reservation', x.id, x.id,
             'رصيد التأمين في الحجز ' || x.internal_ref || ' غير صالح (' || fn_sar_text((f->>'deposit_balance')::bigint) || ')',
             jsonb_build_object('deposit_balance', (f->>'deposit_balance')::bigint, 'status', x.status)) then
          here := here || jsonb_build_object('deposit_invalid', coalesce((here->>'deposit_invalid')::int, 0) + 1);
        end if;
      end if;
    end loop;

    -- 4 (the branch's part): WhatsApp replies waiting for more than an hour while the channel is on
    select count(*) into cnt from whatsapp_outbox w
     where w.branch_id = b.id and w.status in ('pending', 'sending') and w.created_at < now() - interval '1 hour'
       and exists (select 1 from branch_whatsapp_channels c where c.branch_id = b.id and c.enabled);
    if cnt > 0 and fn_monitor_finding(b.organization_id, b.id, 'provider_stuck', 'branch', b.id, null,
                                      cnt || ' رد واتساب لم يُرسل منذ أكثر من ساعة', jsonb_build_object('whatsapp_waiting', cnt)) then
      here := here || jsonb_build_object('provider_stuck', coalesce((here->>'provider_stuck')::int, 0) + 1);
    end if;

    -- 6 two open departure cleanings for one stay
    for x in
      select h.reservation_id, r.internal_ref, rm.room_number, count(*) as n
        from housekeeping_tasks h join reservations r on r.id = h.reservation_id left join rooms rm on rm.id = h.room_id
       where h.branch_id = b.id and h.status in ('pending', 'in_progress') and h.description = 'تنظيف بعد المغادرة'
       group by h.reservation_id, r.internal_ref, rm.room_number having count(*) > 1
    loop
      if fn_monitor_finding(b.organization_id, b.id, 'duplicate_departure', 'reservation', x.reservation_id, x.reservation_id,
                            x.n || ' مهام تنظيف مغادرة مفتوحة للحجز ' || x.internal_ref, jsonb_build_object('room', x.room_number, 'open_tasks', x.n)) then
        here := here || jsonb_build_object('duplicate_departure', coalesce((here->>'duplicate_departure')::int, 0) + 1);
      end if;
    end loop;

    insert into monitor_runs(branch_id, last_run_at, result) values (b.id, now(), here)
    on conflict (branch_id) do update set last_run_at = excluded.last_run_at, result = excluded.result;
    for k in select jsonb_object_keys(here) loop
      res := res || jsonb_build_object(k, coalesce((res->>k)::int, 0) + (here->>k)::int);
    end loop;
  end loop;

  -- the organisation-wide checks
  foreach o in array orgs loop
    perform pg_advisory_xact_lock(hashtext('monitors-org:' || o::text));
    -- 4 provider events received and not processed for an hour
    select count(*) into cnt from integration_events e where e.organization_id = o and e.state = 'received' and e.created_at < now() - interval '1 hour';
    if cnt > 0 and fn_monitor_finding(o, null, 'provider_stuck', 'organization', o, null, cnt || ' حدث من مزود خارجي لم يُعالَج منذ أكثر من ساعة',
                                      jsonb_build_object('events_waiting', cnt)) then
      res := res || jsonb_build_object('provider_stuck', coalesce((res->>'provider_stuck')::int, 0) + 1);
    end if;
    -- 5 failed guest look-ups and exhausted phone codes in the last hour (the guest pages are the property's own)
    select count(*) into fails from guest_lookup_attempts where organization_id=o and not ok and created_at > now() - interval '1 hour';
    select count(*) into codes from guest_phone_challenges where organization_id=o and attempts >= 5 and verified_at is null and created_at > now() - interval '1 hour';
    if (fails >= 10 or codes >= 3) and fn_monitor_finding(o, null, 'verification_failures', 'organization', o, null,
         'محاولات تحقق فاشلة متكررة في صفحات النزلاء خلال الساعة الأخيرة', jsonb_build_object('failed_lookups', fails, 'exhausted_codes', codes)) then
      res := res || jsonb_build_object('verification_failures', coalesce((res->>'verification_failures')::int, 0) + 1);
    end if;
    -- 7 a staff member refused three times or more in a day
    for x in
      select e.staff_id, sp.full_name, count(*) as n, array_agg(distinct e.context) filter (where e.context is not null) as contexts
        from client_errors e left join staff_profiles sp on sp.id = e.staff_id
       where e.organization_id = o and e.error_code like 'FORBIDDEN%' and e.created_at > now() - interval '1 day' and e.staff_id is not null
       group by e.staff_id, sp.full_name having count(*) >= 3
    loop
      if fn_monitor_finding(o, null, 'out_of_scope', 'staff', x.staff_id, null,
                            coalesce(x.full_name, 'موظف') || ': ' || x.n || ' محاولات مرفوضة خارج صلاحياته خلال يوم',
                            jsonb_build_object('attempts', x.n, 'operations', to_jsonb(coalesce(x.contexts, '{}'::text[])))) then
        res := res || jsonb_build_object('out_of_scope', coalesce((res->>'out_of_scope')::int, 0) + 1);
      end if;
    end loop;
  end loop;
  return jsonb_build_object('ran_at', now(), 'found', res);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_bank_mail_poll_config(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s bank_mail_settings%rowtype;
begin
  if not exists(select 1 from organizations where id=p_org and platform_status='active') then raise exception 'HOTEL_UNAVAILABLE';end if;
  select * into s from bank_mail_settings where organization_id=p_org;
  if s.organization_id is null or not s.enabled or s.mailbox_address is null or s.imap_user is null or s.password_encrypted is null or s.relay_key_encrypted is null then
    return jsonb_build_object('configured', false);
  end if;
  return jsonb_build_object('configured', true, 'host', s.imap_host, 'port', s.imap_port, 'user', s.imap_user,
                            'password', pgp_sym_decrypt(s.password_encrypted, fn_secret('keybox_key')), 'last_uid', s.last_uid, 'uid_validity', s.uid_validity);
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_bank_ingest(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s bank_mail_settings%rowtype; v_org uuid; body text := left(coalesce(p->>'body', ''), 20000); rel jsonb; hash text; msg uuid;
        from_addr text; at timestamptz; r jsonb;
begin
  if not exists(select 1 from organizations where id=p_org and platform_status='active') then raise exception 'HOTEL_UNAVAILABLE';end if;
  select * into s from bank_mail_settings where organization_id=p_org;
  if not exists(select 1 from organizations where id=p_org) then raise exception 'HOTEL_REQUIRED'; end if;
  v_org := p_org;
  rel := fn_bank_relay_parse(body);
  hash := md5(coalesce(rel->>'sender', '') || E'\n' || coalesce(rel->>'received', '') || E'\n' || coalesce(rel->>'text', body));
  begin at := nullif(p->>'date', '')::timestamptz; exception when others then at := null; end;
  from_addr := lower(btrim(coalesce(substring(coalesce(p->>'from', '') from '<([^>]+)>'), p->>'from', '')));
  insert into bank_messages(organization_id, mail_message_id, mail_from, mail_date, subject, raw_body, content_hash, sms_sender, channel, sms_text)
  values (v_org, left(p->>'message_id', 300), left(from_addr, 300), at, left(p->>'subject', 300), body, hash,
          left(rel->>'sender', 100), left(rel->>'channel', 20), rel->>'text')
  on conflict (organization_id, content_hash) do nothing
  returning id into msg;
  if msg is null then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  begin
    r := fn_bank_process(msg);
  exception when others then
    -- the raw text stays; the message waits for the owner as not understood
    update bank_messages set status = 'unparsed', reject_reason = 'تعذّرت القراءة: ' || left(sqlerrm, 120), processed_at = now() where id = msg;
    r := jsonb_build_object('status', 'unparsed', 'reason', 'error');
  end;
  return jsonb_build_object('ok', true, 'message_id', msg) || r;
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_bank_ingest_failed(p_org uuid, p_uid bigint, p_error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := p_org;
begin
  if not exists(select 1 from organizations where id=p_org and platform_status='active') then raise exception 'HOTEL_UNAVAILABLE';end if;
  insert into bank_messages(organization_id, raw_body, content_hash, status, reject_reason, processed_at)
  values (v_org, '[رسالة لم تُحفظ: رقمها في البريد ' || p_uid || ']', md5('failed:' || p_uid || ':' || clock_timestamp()::text), 'rejected',
          'تعذّر حفظها: ' || left(coalesce(p_error, ''), 150), now());
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_bank_mail_poll_done(p_org uuid, p_last_uid bigint, p_uid_validity bigint, p_error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists(select 1 from organizations where id=p_org and platform_status='active') then raise exception 'HOTEL_UNAVAILABLE';end if;
  update bank_mail_settings set last_uid = greatest(case when uid_validity is distinct from p_uid_validity and p_uid_validity is not null then 0 else last_uid end, coalesce(p_last_uid, 0)),
                                uid_validity = coalesce(p_uid_validity, uid_validity), last_polled_at = now(), last_error = left(p_error, 300)
   where organization_id = p_org;
end $function$
;

create or replace function fn_phone_reservation_ids(p_phone text,p_org uuid,p_branch uuid default null) returns setof uuid
language sql stable security definer set search_path=public,extensions as $$
 select distinct r.id from reservations r join reservation_guests g on g.reservation_id=r.id and g.is_primary
 left join guest_profiles gp on gp.id=g.guest_profile_id
 where exists(select 1 from organizations o where o.id=p_org and o.platform_status='active') and r.organization_id=p_org and (p_branch is null or r.branch_id=p_branch) and p_phone is not null
 and (fn_normalize_phone(g.phone)=p_phone or fn_normalize_phone(gp.phone)=p_phone)
 and r.status<>'rejected' and r.check_out>=fn_branch_today(r.branch_id)-60
$$;

create or replace function fn_phone_session(p_phone text,p_method text,p_org uuid,p_branch uuid default null) returns text
language plpgsql security definer set search_path=public,extensions as $$
declare v text;
begin
 if p_org is null or not exists(select 1 from organizations where id=p_org and platform_status='active') or (p_branch is not null and not exists(select 1 from branches where id=p_branch and organization_id=p_org)) then raise exception 'HOTEL_REQUIRED'; end if;
 insert into guest_phone_sessions(phone,method,organization_id,branch_id) values(p_phone,p_method,p_org,p_branch) returning token into v;
 return v;
end $$;

-- Existing branch credentials are unusable while their hotel is suspended.
create or replace function fn_whatsapp_channel(p_branch uuid default null, p_phone_number_id text default null, p_verify_token text default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c branch_whatsapp_channels%rowtype;
begin
  select * into c from branch_whatsapp_channels
   where exists(select 1 from organizations o where o.id=branch_whatsapp_channels.organization_id and o.platform_status='active') and ((p_branch is not null and branch_id = p_branch)
      or (p_phone_number_id is not null and phone_number_id = p_phone_number_id)
      or (p_verify_token is not null and verify_token = p_verify_token))
   limit 1;
  if not found then return null; end if;
  return jsonb_build_object(
    'branch_id', c.branch_id, 'organization_id', c.organization_id, 'mode', c.mode, 'enabled', c.enabled, 'status', c.status,
    'auto_reply', c.auto_reply, 'display_phone', c.display_phone, 'phone_number_id', c.phone_number_id, 'otp_template', c.otp_template,
    'template_lang', c.template_lang, 'verify_token', c.verify_token,
    'access_token', case when c.access_token_encrypted is null then null else pgp_sym_decrypt(c.access_token_encrypted, fn_secret('keybox_key')) end,
    'app_secret', case when c.app_secret_encrypted is null then null else pgp_sym_decrypt(c.app_secret_encrypted, fn_secret('keybox_key')) end);
end $$;

-- Existing branch credentials are unusable while their hotel is suspended.
create or replace function fn_wa_bridge_auth(p_key text) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('branch_id', c.branch_id, 'organization_id', c.organization_id, 'enabled', c.enabled,
    'auto_reply', c.auto_reply, 'status', c.status, 'display_phone', c.display_phone,
    'human_pause_minutes', c.human_pause_minutes, 'branch_name', b.name_ar)
  from branch_whatsapp_channels c join branches b on b.id = c.branch_id
  where exists(select 1 from organizations o where o.id=c.organization_id and o.platform_status='active') and coalesce(p_key, '') ~ '^zb_[0-9a-f]{64}$' and c.mode = 'web_bridge'
    and c.bridge_key_hash = encode(digest(p_key, 'sha256'), 'hex')
$$;
