-- 0098: confirmed users create their own hotel, never by an owner invitation.
-- Atomic and idempotent by authenticated identity. No client-selected owner/email/organization.
create or replace function fn_owner_create_hotel(p jsonb) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare u uuid:=auth.uid(); em text; confirmed timestamptz; v uuid; b uuid; s staff_profiles%rowtype;
 n text:=btrim(p->>'name_ar'); bn text:=btrim(p->>'branch_name'); nm text:=btrim(p->>'full_name'); slug text:=lower(btrim(p->>'slug'));
begin
 if u is null then raise exception 'NOT_AUTHENTICATED' using errcode='42501';end if;
 select lower(email),email_confirmed_at into em,confirmed from auth.users where id=u;
 if em is null or confirmed is null then raise exception 'EMAIL_NOT_CONFIRMED' using errcode='42501';end if;
 if exists(select 1 from platform_operators where auth_user_id=u) then raise exception 'PLATFORM_ACCOUNT' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtext('owner-signup:'||u::text));
 select * into s from staff_profiles where auth_user_id=u;
 if found then
  if s.role='owner' and s.is_active then return jsonb_build_object('ok',true,'id',s.organization_id,'existing',true);end if;
  raise exception 'ACCOUNT_ALREADY_LINKED' using errcode='42501';
 end if;
 -- Existing staff invitations are resolved by the staff claim flow, never promoted into a second hotel.
 if exists(select 1 from staff_profiles where lower(email)=em and is_active) then raise exception 'ACCOUNT_PENDING_LINK' using errcode='42501';end if;
 if n is null or length(n) not between 2 and 120 or bn is null or length(bn) not between 2 and 120 or nm is null or length(nm) not between 3 and 120 or slug is null or slug !~ '^[a-z0-9][a-z0-9-]{2,62}$' then raise exception 'VALIDATION: hotel_fields';end if;
 perform pg_advisory_xact_lock(hashtext('hotel-slug:'||slug));
 if exists(select 1 from organizations where guest_slug=slug) then raise exception 'VALIDATION: slug_unavailable';end if;
 insert into organizations(name_ar,guest_slug) values(n,slug) returning id into v;
 -- The normal organization trigger seeds fresh per-hotel settings, not another hotel's mutable values.
 update system_settings set demo_mode=false where organization_id=v;
 insert into branches(organization_id,name_ar) values(v,bn) returning id into b;
 insert into staff_profiles(auth_user_id,organization_id,full_name,email,role,is_active) values(u,v,nm,em,'owner',true) returning * into s;
 insert into branch_memberships(staff_id,branch_id) values(s.id,b);
 perform fn_audit(v,b,s.id,'hotel.owner_self_registered','organization',v,jsonb_build_object('branch_id',b,'owner_profile_id',s.id));
 return jsonb_build_object('ok',true,'id',v,'branch_id',b,'owner_profile_id',s.id,'existing',false);
end $$;
revoke all on function fn_owner_create_hotel(jsonb) from public,anon;
grant execute on function fn_owner_create_hotel(jsonb) to authenticated;

-- Retire both operator owner-creation and owner-invitation APIs, including service-role callers.
create or replace function fn_platform_create_hotel(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$begin raise exception 'OWNER_SELF_SIGNUP_REQUIRED' using errcode='42501';end$$;
create or replace function fn_platform_owner_invite_target(p_staff uuid) returns jsonb language plpgsql security definer set search_path=public as $$begin raise exception 'OWNER_SELF_SIGNUP_REQUIRED' using errcode='42501';end$$;
revoke all on function fn_platform_create_hotel(jsonb),fn_platform_owner_invite_target(uuid) from public,anon,authenticated,service_role;

-- Staff invitations remain hotel-owned. They can never grant ownership.
create or replace function fn_admin_staff_invite_target(p_staff uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare s staff_profiles%rowtype;
begin
 if not fn_has_role('owner') then raise exception 'FORBIDDEN' using errcode='42501';end if;
 select * into s from staff_profiles where id=p_staff and organization_id=fn_user_org_id() and role<>'owner';
 if not found then raise exception 'NOT_FOUND';end if;
 return jsonb_build_object('staff_id',s.id,'email',s.email,'full_name',s.full_name,'is_active',s.is_active,'linked',s.auth_user_id is not null);
end$$;
create or replace function fn_claim_staff_profile(p_full_name text default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare em text; sp staff_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='42501';end if;
 select lower(email) into em from auth.users where id=auth.uid();
 if exists(select 1 from platform_operators where auth_user_id=auth.uid()) then return jsonb_build_object('ok',false,'error','PLATFORM_ACCOUNT');end if;
 select * into sp from staff_profiles where auth_user_id=auth.uid();
 if found then return jsonb_build_object('ok',true,'role',sp.role,'claimed',false);end if;
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'EMAIL_NOT_CONFIRMED' using errcode='42501';end if;

 select * into sp from staff_profiles where lower(email)=em and auth_user_id is null and is_active and role<>'owner'
 and exists(select 1 from organizations o where o.id=staff_profiles.organization_id and o.platform_status='active') for update;
 if not found then return jsonb_build_object('ok',false,'error','NO_INVITATION');end if;
 update staff_profiles set auth_user_id=auth.uid(),full_name=coalesce(nullif(btrim(p_full_name),''),full_name) where id=sp.id;
 return jsonb_build_object('ok',true,'role',sp.role,'claimed',true);
end$$;

create or replace function fn_admin_invite_staff(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp staff_profiles%rowtype; b uuid; v_email text := lower(trim(coalesce(p->>'email', ''))); v_name text := trim(coalesce(p->>'full_name', ''));
        v_role role_code; v_branches uuid[]; v_phone_in text := nullif(trim(coalesce(p->>'phone', '')), ''); v_phone text;
begin
  perform fn_require_cap('staff.manage');
  begin v_role := (p->>'role')::role_code; exception when others then raise exception 'INVALID_ROLE'; end;
  if v_role is null or v_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  if v_role = 'owner' and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if v_role = 'owner' then raise exception 'OWNER_SELF_SIGNUP_REQUIRED' using errcode='42501';end if;
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

