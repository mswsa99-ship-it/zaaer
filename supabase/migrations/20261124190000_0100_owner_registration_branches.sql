-- 0098: confirmed users create their own hotel, never by an owner invitation.
-- Atomic and idempotent by authenticated identity. No client-selected owner/email/organization.
create or replace function fn_owner_create_hotel(p jsonb) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare u uuid:=auth.uid(); em text; confirmed timestamptz; v uuid; b uuid; s staff_profiles%rowtype; br jsonb; branch_rows jsonb:=p->'branches'; first_b uuid;
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
 if n is null or length(n) not between 2 and 120 or (branch_rows is null and (bn is null or length(bn) not between 2 and 120)) or nm is null or length(nm) not between 3 and 120 or slug is null or slug !~ '^[a-z0-9][a-z0-9-]{2,62}$' then raise exception 'VALIDATION: hotel_fields';end if;
 if branch_rows is not null then
  if jsonb_typeof(branch_rows)<>'array' or jsonb_array_length(branch_rows) not between 1 and 20 then raise exception 'VALIDATION: branches';end if;
  for br in select value from jsonb_array_elements(branch_rows) loop
   if length(coalesce(btrim(br->>'name_ar'),'')) not between 2 and 120 or length(coalesce(btrim(br->>'city'),'')) not between 2 and 120 or length(coalesce(btrim(br->>'address'),'')) not between 2 and 200 or length(coalesce(br->>'map_url',''))>500 or (coalesce(br->>'map_url','')<>'' and br->>'map_url' !~ '^https://[^[:space:]]+$') then raise exception 'VALIDATION: branch_location';end if;
  end loop;
 end if;
 perform pg_advisory_xact_lock(hashtext('hotel-slug:'||slug));
 if exists(select 1 from organizations where guest_slug=slug) then raise exception 'VALIDATION: slug_unavailable';end if;
 insert into organizations(name_ar,guest_slug) values(n,slug) returning id into v;
 -- The normal organization trigger seeds fresh per-hotel settings, not another hotel's mutable values.
 update system_settings set demo_mode=false where organization_id=v;
 if branch_rows is null then insert into branches(organization_id,name_ar) values(v,bn) returning id into first_b;
 else
  for br in select value from jsonb_array_elements(branch_rows) loop
   insert into branches(organization_id,name_ar,city,address,map_url) values(v,btrim(br->>'name_ar'),btrim(br->>'city'),btrim(br->>'address'),nullif(br->>'map_url','')) returning id into b;
   first_b:=coalesce(first_b,b);
  end loop;
 end if;
 b:=first_b;
 insert into staff_profiles(auth_user_id,organization_id,full_name,email,role,is_active) values(u,v,nm,em,'owner',true) returning * into s;
 insert into branch_memberships(staff_id,branch_id) select s.id,id from branches where organization_id=v;
 perform fn_audit(v,b,s.id,'hotel.owner_self_registered','organization',v,jsonb_build_object('branch_id',b,'owner_profile_id',s.id));
 return jsonb_build_object('ok',true,'id',v,'branch_id',b,'owner_profile_id',s.id,'existing',false);
end $$;
revoke all on function fn_owner_create_hotel(jsonb) from public,anon;
grant execute on function fn_owner_create_hotel(jsonb) to authenticated;

