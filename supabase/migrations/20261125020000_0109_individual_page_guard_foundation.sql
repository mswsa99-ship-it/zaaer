-- Page guard contract. No activation RPC exists until full enforcement coverage is certified.
-- New rows are disabled. Existing accounts remain legacy.
create table public.staff_page_access (
 staff_id uuid primary key references public.staff_profiles(id),
 organization_id uuid not null references public.organizations(id),
 enabled boolean not null default false,
 page_grants jsonb not null default '{}' check(jsonb_typeof(page_grants)='object'),
 sensitive_grants jsonb not null default '[]' check(jsonb_typeof(sensitive_grants)='array'),
 revision bigint not null default 1 check(revision>0),
 home_page text,
 updated_at timestamptz not null default now()
);
alter table public.staff_page_access enable row level security;
revoke all on public.staff_page_access from public,anon,authenticated;
grant select on public.staff_page_access to authenticated;
create policy staff_page_access_owner_read on public.staff_page_access for select to authenticated
 using(organization_id=(select public.fn_user_org_id()) and public.fn_current_role()='owner');

create or replace function public.fn_user_page_catalog() returns table(page text) language sql immutable set search_path=public as $$ values ('/admin/ai-settings'),('/admin/assistant'),('/admin/audit-logs'),('/admin/availability'),('/admin/availability-rules'),('/admin/backups'),('/admin/bank-mail'),('/admin/booking-sources'),('/admin/branches'),('/admin/cash-accounts'),('/admin/dashboard'),('/admin/data-purge'),('/admin/facilities'),('/admin/finance'),('/admin/finance-controls'),('/admin/guests'),('/admin/guests/:id'),('/admin/integrations'),('/admin/journey'),('/admin/keyboxes'),('/admin/knowledge'),('/admin/organization'),('/admin/payment-providers'),('/admin/platform-payouts'),('/admin/policies'),('/admin/products'),('/admin/rates'),('/admin/reports'),('/admin/reservations'),('/admin/review'),('/admin/roles'),('/admin/room-categories'),('/admin/rooms'),('/admin/services'),('/admin/staff'),('/admin/structure'),('/admin/task-types'),('/admin/usage'),('/admin/whatsapp'),('/staff/access-approvals'),('/staff/account'),('/staff/accounts'),('/staff/arrivals'),('/staff/bank'),('/staff/codes'),('/staff/dashboard'),('/staff/day-close'),('/staff/day-summary'),('/staff/expenses'),('/staff/followups'),('/staff/housekeeping'),('/staff/identity-verification'),('/staff/inbox'),('/staff/journey'),('/staff/ledger'),('/staff/orders'),('/staff/payments'),('/staff/platforms'),('/staff/pos-settlement'),('/staff/reservations'),('/staff/reservations/:id'),('/staff/reservations/new'),('/staff/rooms'),('/staff/shortcuts'),('/staff/tickets') $$;
revoke all on function public.fn_user_page_catalog() from public,anon;grant execute on function public.fn_user_page_catalog() to authenticated;

create or replace function public.fn_canonical_user_page(p_page text) returns text language sql immutable set search_path=public as $$
 select case when p_page in('/staff/reservations/new','/staff/reservations/:id') then '/staff/reservations'
 when p_page='/admin/guests/:id' then '/admin/guests' else p_page end
$$;
revoke all on function public.fn_canonical_user_page(text) from public,anon;grant execute on function public.fn_canonical_user_page(text) to authenticated;

create or replace function public.fn_user_access_mode() returns text
language sql stable security definer set search_path=public as $$
 select case when fn_staff_id() is null then 'none'
 when exists(select 1 from staff_page_access a where a.staff_id=fn_staff_id() and a.organization_id=fn_user_org_id() and a.enabled) then 'individual'
 else 'legacy' end
$$;
create or replace function public.fn_user_page_can(p_page text,p_action text) returns boolean
language plpgsql stable security definer set search_path=public as $$
declare a staff_page_access%rowtype;row_grant jsonb;
begin
 if fn_staff_id() is null or p_page is null or p_action is null or p_action not in('view','add','edit','delete','export') then return false;end if;
 -- Known routes are validated against the same generated catalog as the draft save endpoint.
 if not exists(select 1 from fn_user_page_catalog() c where c.page=p_page) then return false;end if;
 if fn_current_role()='owner' then return true;end if;
 select * into a from staff_page_access where staff_id=fn_staff_id() and organization_id=fn_user_org_id() and enabled;
 if not found then return true;end if; -- legacy compatibility: existing role/capability/branch checks MUST still run
 p_page:=fn_canonical_user_page(p_page);
 row_grant:=a.page_grants->p_page;
 return coalesce(row_grant->>'view','false')='true' and coalesce(row_grant->>p_action,'false')='true';
end $$;
create or replace function public.fn_require_user_page(p_page text,p_action text) returns void
language plpgsql stable security definer set search_path=public as $$
begin
 if fn_staff_id() is null then raise exception 'FORBIDDEN: active staff required' using errcode='42501';end if;
 if not fn_user_page_can(p_page,p_action) then raise exception 'FORBIDDEN: page % action %',p_page,p_action using errcode='42501';end if;
end $$;
create or replace function public.fn_my_page_access() returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('mode',fn_user_access_mode(),'pages',coalesce((select a.page_grants from staff_page_access a where a.staff_id=fn_staff_id() and a.organization_id=fn_user_org_id() and a.enabled),'{}'::jsonb),
 'sensitive',coalesce((select a.sensitive_grants from staff_page_access a where a.staff_id=fn_staff_id() and a.organization_id=fn_user_org_id() and a.enabled),'[]'::jsonb),
 'revision',coalesce((select a.revision from staff_page_access a where a.staff_id=fn_staff_id() and a.organization_id=fn_user_org_id() and a.enabled),0),
 'home_page',(select a.home_page from staff_page_access a where a.staff_id=fn_staff_id() and a.organization_id=fn_user_org_id() and a.enabled))
$$;
revoke all on function public.fn_user_access_mode(),public.fn_user_page_can(text,text),public.fn_require_user_page(text,text),public.fn_my_page_access() from public,anon;
grant execute on function public.fn_user_access_mode(),public.fn_user_page_can(text,text),public.fn_require_user_page(text,text),public.fn_my_page_access() to authenticated;

create or replace function public.fn_my_permissions() returns jsonb
language sql stable security definer set search_path=public as $$
 select case when fn_current_role() is null then jsonb_build_object('role',null,'allowed','[]'::jsonb,'full','[]'::jsonb,'sees_money',false,'page_access',fn_my_page_access())
 else jsonb_build_object('role',fn_current_role(),
 'allowed',coalesce((select jsonb_agg(c.code order by c.sort) from fn_permission_catalog() c where fn_can(c.code)),'[]'::jsonb),
 'full',coalesce((select jsonb_agg(c.code order by c.sort) from fn_permission_catalog() c where fn_cap_full(c.code)),'[]'::jsonb),
 'sees_money',fn_sees_money(),'page_access',fn_my_page_access()) end
$$;

create trigger zz_hotel_pointers after insert or update on public.staff_page_access for each row execute function public.fn_hotel_pointers('staff_id','staff_profiles');
