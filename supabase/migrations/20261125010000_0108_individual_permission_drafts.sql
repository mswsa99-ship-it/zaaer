-- Individual permission foundation. Draft-only until full data-plane enforcement is certified.
-- Existing role matrix and accounts are not modified by this migration.
create table public.staff_permission_drafts (
 staff_id uuid primary key references public.staff_profiles(id),
 organization_id uuid not null references public.organizations(id),
 revision bigint not null default 1 check(revision>0),
 page_grants jsonb not null default '{}' check(jsonb_typeof(page_grants)='object'),
 sensitive_grants jsonb not null default '[]' check(jsonb_typeof(sensitive_grants)='array'),
 home_page text,
 updated_by uuid not null references public.staff_profiles(id),
 updated_at timestamptz not null default now()
);
alter table public.staff_permission_drafts enable row level security;
revoke all on public.staff_permission_drafts from public,anon,authenticated;
grant select on public.staff_permission_drafts to authenticated;
create policy permission_drafts_owner_read on public.staff_permission_drafts for select to authenticated
 using(organization_id=(select public.fn_user_org_id()) and public.fn_current_role()='owner');

create or replace function public.fn_owner_save_permission_draft(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare target staff_profiles%rowtype; me uuid:=fn_staff_id(); org uuid:=fn_user_org_id();
 grants jsonb:=p->'pages'; caps jsonb:=p->'sensitive'; page record; cap jsonb; action text; expected bigint;
 old staff_permission_drafts%rowtype; saved staff_permission_drafts%rowtype;
begin
 if me is null or fn_current_role() is distinct from 'owner'::role_code then raise exception 'FORBIDDEN: owner required' using errcode='42501'; end if;
 if nullif(trim(p->>'reason'),'') is null then raise exception 'VALIDATION: reason'; end if;
 select * into target from staff_profiles where id=(p->>'staff_id')::uuid and organization_id=org for update;
 if not found then raise exception 'NOT_FOUND: staff'; end if;
 if target.id=me or target.role='owner' then raise exception 'FORBIDDEN: owner grants immutable' using errcode='42501'; end if;
 if not target.is_active then raise exception 'FORBIDDEN: inactive staff' using errcode='42501'; end if;
 if jsonb_typeof(grants) is distinct from 'object' or jsonb_typeof(caps) is distinct from 'array' then raise exception 'VALIDATION: grant shape'; end if;
 for page in select key,value from jsonb_each(grants) loop
  if page.key <> all(array['/admin/ai-settings','/admin/assistant','/admin/audit-logs','/admin/availability','/admin/availability-rules','/admin/backups','/admin/bank-mail','/admin/booking-sources','/admin/branches','/admin/cash-accounts','/admin/dashboard','/admin/data-purge','/admin/facilities','/admin/finance','/admin/finance-controls','/admin/guests','/admin/guests/:id','/admin/integrations','/admin/journey','/admin/keyboxes','/admin/knowledge','/admin/organization','/admin/payment-providers','/admin/platform-payouts','/admin/policies','/admin/products','/admin/rates','/admin/reports','/admin/reservations','/admin/review','/admin/roles','/admin/room-categories','/admin/rooms','/admin/services','/admin/staff','/admin/structure','/admin/task-types','/admin/usage','/admin/whatsapp','/staff/access-approvals','/staff/account','/staff/accounts','/staff/arrivals','/staff/bank','/staff/codes','/staff/dashboard','/staff/day-close','/staff/day-summary','/staff/expenses','/staff/followups','/staff/housekeeping','/staff/identity-verification','/staff/inbox','/staff/journey','/staff/ledger','/staff/orders','/staff/payments','/staff/platforms','/staff/pos-settlement','/staff/reservations','/staff/reservations/:id','/staff/reservations/new','/staff/rooms','/staff/shortcuts','/staff/tickets']::text[]) or jsonb_typeof(page.value)<>'object' then raise exception 'VALIDATION: page'; end if;
  if exists(select 1 from jsonb_each(page.value) a where a.key not in('view','add','edit','delete','export') or jsonb_typeof(a.value)<>'boolean') then raise exception 'VALIDATION: action'; end if;
  if coalesce((page.value->>'view')::boolean,false)=false and exists(select 1 from jsonb_each(page.value) a where a.key<>'view' and a.value='true'::jsonb) then raise exception 'VALIDATION: action requires view'; end if;
 end loop;
 if p->>'home_page' is not null and coalesce((grants->(p->>'home_page')->>'view')::boolean,false)=false then raise exception 'VALIDATION: home requires view'; end if;
 for cap in select value from jsonb_array_elements(caps) loop
  if jsonb_typeof(cap)<>'string' or not exists(select 1 from fn_permission_catalog() c where c.code=cap#>>'{}' and not c.locked) then raise exception 'VALIDATION: sensitive capability'; end if;
 end loop;
 select * into old from staff_permission_drafts where staff_id=target.id for update;
 expected:=coalesce((p->>'expected_revision')::bigint,0);
 if expected<>coalesce(old.revision,0) then raise exception 'CONFLICT: stale revision'; end if;
 insert into staff_permission_drafts(staff_id,organization_id,page_grants,sensitive_grants,home_page,updated_by)
 values(target.id,org,grants,caps,p->>'home_page',me)
 on conflict(staff_id) do update set page_grants=excluded.page_grants,sensitive_grants=excluded.sensitive_grants,
 home_page=excluded.home_page,updated_by=me,updated_at=now(),revision=staff_permission_drafts.revision+1 returning * into saved;
 perform fn_audit(org,null,me,'permissions.individual_draft_saved','staff_profile',target.id,
 jsonb_build_object('reason',p->>'reason','before',to_jsonb(old),'after',to_jsonb(saved),'active',false));
 return jsonb_build_object('ok',true,'revision',saved.revision,'active',false);
end $$;
revoke all on function public.fn_owner_save_permission_draft(jsonb) from public,anon;
grant execute on function public.fn_owner_save_permission_draft(jsonb) to authenticated;

create trigger zz_hotel_pointers after insert or update on public.staff_permission_drafts for each row execute function public.fn_hotel_pointers('staff_id','staff_profiles','updated_by','staff_profiles');
