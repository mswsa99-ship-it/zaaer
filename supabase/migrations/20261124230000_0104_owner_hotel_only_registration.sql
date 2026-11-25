-- 0098: confirmed users create their own hotel, never by an owner invitation.
-- Atomic and idempotent by authenticated identity. No client-selected owner/email/organization.
create or replace function fn_owner_register_hotel(p jsonb) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare u uuid:=auth.uid(); em text; confirmed timestamptz; v uuid; b uuid; s staff_profiles%rowtype;
 n text:=btrim(p->>'name_ar'); bn text:=btrim(p->>'branch_name'); nm text:=btrim(p->>'full_name'); slug text;
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
 slug:='hotel-'||replace(u::text,'-','');
 if n is null or length(n) not between 2 and 120 or nm is null or length(nm) not between 3 and 120 or slug is null or slug !~ '^[a-z0-9][a-z0-9-]{2,62}$' then raise exception 'VALIDATION: hotel_fields';end if;
 perform pg_advisory_xact_lock(hashtext('hotel-slug:'||slug));
 if exists(select 1 from organizations where guest_slug=slug) then raise exception 'VALIDATION: slug_unavailable';end if;
 insert into organizations(name_ar,guest_slug) values(n,slug) returning id into v;
 -- The normal organization trigger seeds fresh per-hotel settings, not another hotel's mutable values.
 update system_settings set demo_mode=false where organization_id=v;

 insert into staff_profiles(auth_user_id,organization_id,full_name,email,role,is_active) values(u,v,nm,em,'owner',true) returning * into s;

 perform fn_audit(v,b,s.id,'hotel.owner_self_registered','organization',v,jsonb_build_object('branch_id',b,'owner_profile_id',s.id));
 return jsonb_build_object('ok',true,'id',v,'branch_id',b,'owner_profile_id',s.id,'existing',false);
end $$;
revoke all on function fn_owner_register_hotel(jsonb) from public,anon;
grant execute on function fn_owner_register_hotel(jsonb) to authenticated;


revoke all on function fn_owner_create_hotel(jsonb) from public,anon,authenticated;
