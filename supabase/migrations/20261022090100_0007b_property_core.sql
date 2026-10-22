/*
# 0007b — Property core (Zaaer knowledge base → this app)

Adds the facility-management backbone on top of the existing schema WITHOUT
creating a parallel system:

  branch → block → floor → room / facility
  task_type → housekeeping_task (exactly one target: room OR facility)
  service_definition (optional paid-service catalogue, snapshotted into charges)

Rules enforced here (see ZAAER-TESTING-AND-CONTROL-RULES G01, G09, G16–G18, G23–G27):
  * every cross-table relation is checked for branch/organization consistency
  * three independent room dimensions: is_active (admin), cleanliness, status (occupancy/ops)
  * used definitions are ARCHIVED (archived_at/by/reason); hard delete only when unused
  * completing a cleaning task never frees an occupied room
  * optimistic locking via `version` on editable definitions
  * all writes go through SECURITY DEFINER RPCs; RLS has no write policies for staff

Legacy `cleaning_tasks` rows are migrated into `housekeeping_tasks` and the old
table is kept as a read-only compatibility view.
*/

-- =====================================================================
-- 1. Branch operational settings (tax / timezone are settings, not constants)
-- =====================================================================
alter table branches add column if not exists timezone text not null default 'Asia/Riyadh';
alter table branches add column if not exists tax_rate_bp int not null default 1500;        -- basis points: 1500 = 15%
alter table branches add column if not exists prices_include_tax boolean not null default false;
alter table branches add column if not exists default_deposit_halalas bigint not null default 0;
alter table branches add column if not exists tax_number text;
alter table branches add column if not exists commercial_register text;
alter table branches add column if not exists archived_at timestamptz;
alter table branches add column if not exists archived_by uuid;
alter table branches add column if not exists archive_reason text;
alter table branches add column if not exists version int not null default 1;
alter table branches add column if not exists updated_at timestamptz default now();
alter table branches drop constraint if exists branches_tax_rate_valid;
alter table branches add constraint branches_tax_rate_valid check (tax_rate_bp between 0 and 10000);

-- =====================================================================
-- 2. Blocks & floors
-- =====================================================================
create table if not exists blocks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  name text not null,
  description text,
  sort_order int not null default 0,
  is_active boolean not null default true,
  archived_at timestamptz,
  archived_by uuid,
  archive_reason text,
  version int not null default 1,
  created_by uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (branch_id, name)
);

create table if not exists floors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  block_id uuid not null references blocks(id) on delete restrict,
  name text not null,                       -- textual: "B", "الأرضي", "1"
  sort_order int not null default 0,
  is_active boolean not null default true,
  archived_at timestamptz,
  archived_by uuid,
  archive_reason text,
  version int not null default 1,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (block_id, name)
);
create index if not exists idx_floors_block on floors(block_id, sort_order);

-- =====================================================================
-- 3. Rooms: structure + three independent dimensions
-- =====================================================================
alter table rooms add column if not exists block_id uuid references blocks(id) on delete restrict;
alter table rooms add column if not exists floor_id uuid references floors(id) on delete restrict;
alter table rooms add column if not exists is_active boolean not null default true;          -- admin activity
alter table rooms add column if not exists cleanliness text not null default 'clean';          -- clean | dirty | in_progress
alter table rooms add column if not exists notes text;
alter table rooms add column if not exists archived_at timestamptz;
alter table rooms add column if not exists archived_by uuid;
alter table rooms add column if not exists archive_reason text;
alter table rooms add column if not exists version int not null default 1;
alter table rooms add column if not exists updated_at timestamptz default now();
alter table rooms drop constraint if exists rooms_cleanliness_valid;
alter table rooms add constraint rooms_cleanliness_valid check (cleanliness in ('clean','dirty','in_progress'));

alter table room_categories add column if not exists archived_at timestamptz;
alter table room_categories add column if not exists archived_by uuid;
alter table room_categories add column if not exists archive_reason text;
alter table room_categories add column if not exists version int not null default 1;
alter table room_categories add column if not exists updated_at timestamptz default now();
alter table room_categories add column if not exists images jsonb not null default '[]'::jsonb;

-- =====================================================================
-- 4. Facilities (shared spaces/items — NOT rentable rooms)
-- =====================================================================
create table if not exists facilities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  block_id uuid references blocks(id) on delete restrict,
  floor_id uuid references floors(id) on delete restrict,
  name text not null,
  description text,
  images jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  archived_at timestamptz,
  archived_by uuid,
  archive_reason text,
  version int not null default 1,
  created_by uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (branch_id, name)
);

-- =====================================================================
-- 5. Task types & housekeeping tasks
-- =====================================================================
create table if not exists task_types (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  code text,                                   -- system codes: room_cleaning (used by checkout)
  name text not null,
  description text,
  is_active boolean not null default true,
  archived_at timestamptz,
  archived_by uuid,
  archive_reason text,
  version int not null default 1,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (branch_id, name)
);
create unique index if not exists uniq_task_type_code on task_types(branch_id, code) where code is not null;

create table if not exists housekeeping_tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  room_id uuid references rooms(id) on delete restrict,
  facility_id uuid references facilities(id) on delete restrict,
  task_type_id uuid not null references task_types(id) on delete restrict,
  task_type_name_snapshot text not null,
  reservation_id uuid references reservations(id) on delete set null,
  priority text not null default 'medium',
  status text not null default 'pending',
  assignee_id uuid references staff_profiles(id) on delete set null,
  scheduled_start timestamptz not null default now(),
  scheduled_end timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  completed_by uuid,
  cancelled_at timestamptz,
  cancel_reason text,
  description text,
  result_note text,
  images jsonb not null default '[]'::jsonb,
  version int not null default 1,
  created_by uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  constraint hk_one_target check ((room_id is null) <> (facility_id is null)),
  constraint hk_priority_valid check (priority in ('low','medium','high')),
  constraint hk_status_valid check (status in ('pending','in_progress','completed','cancelled')),
  constraint hk_schedule_valid check (scheduled_end is null or scheduled_end >= scheduled_start)
);
create index if not exists idx_hk_branch_status on housekeeping_tasks(branch_id, status);
create index if not exists idx_hk_room on housekeeping_tasks(room_id) where room_id is not null;
create index if not exists idx_hk_facility on housekeeping_tasks(facility_id) where facility_id is not null;
create index if not exists idx_hk_assignee on housekeeping_tasks(assignee_id, status);

-- =====================================================================
-- 6. Service catalogue (optional paid services; snapshotted into charges)
-- =====================================================================
create table if not exists service_definitions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete restrict,
  name_ar text not null,
  name_en text,
  description text,
  billing_unit text not null default 'once',       -- once | night | person | quantity
  price_halalas bigint not null default 0,
  is_free boolean not null default false,
  taxable boolean not null default true,
  task_type_id uuid references task_types(id) on delete set null,
  is_active boolean not null default true,
  archived_at timestamptz,
  archived_by uuid,
  archive_reason text,
  version int not null default 1,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (branch_id, name_ar),
  constraint svc_unit_valid check (billing_unit in ('once','night','person','quantity')),
  constraint svc_price_valid check (price_halalas >= 0)
);

-- =====================================================================
-- 7. Booking sources: stable code, kind, external reference requirement
-- =====================================================================
alter table booking_sources add column if not exists code text;
alter table booking_sources add column if not exists kind text not null default 'external';   -- direct | external
alter table booking_sources add column if not exists external_reference_required boolean not null default true;
alter table booking_sources add column if not exists archived_at timestamptz;
update booking_sources set code = coalesce(code, lower(regexp_replace(name, '[^A-Za-z0-9]+', '_', 'g')));
update booking_sources set kind = 'direct', external_reference_required = false where id = '00000000-0000-0000-0000-000000000021';
update booking_sources set code = 'reception' where id = '00000000-0000-0000-0000-000000000021';
update booking_sources set code = 'booking_com' where id = '00000000-0000-0000-0000-000000000020';
create unique index if not exists uniq_booking_source_code on booking_sources(organization_id, code);

-- =====================================================================
-- 8. Seed structure for the demo branch (synthetic; not Zaaer data)
-- =====================================================================
insert into blocks(id, organization_id, branch_id, name, description, sort_order)
values ('00000000-0000-0000-0000-000000000400','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','المبنى الرئيسي','البلوك الافتراضي للوحدات الحالية',1)
on conflict (id) do nothing;
insert into floors(id, organization_id, branch_id, block_id, name, sort_order)
values ('00000000-0000-0000-0000-000000000410','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000400','1',1),
       ('00000000-0000-0000-0000-000000000411','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000400','2',2)
on conflict (id) do nothing;
update rooms r set block_id = '00000000-0000-0000-0000-000000000400',
  floor_id = case when coalesce(r.floor,1) >= 2 then '00000000-0000-0000-0000-000000000411'::uuid else '00000000-0000-0000-0000-000000000410'::uuid end
where r.branch_id = '00000000-0000-0000-0000-000000000010' and r.block_id is null;
update rooms set is_active = (status <> 'out_of_service'), cleanliness = case when status = 'cleaning' then 'dirty' else 'clean' end;

insert into task_types(id, organization_id, branch_id, code, name, description) values
 ('00000000-0000-0000-0000-000000000420','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','room_cleaning','تنظيف الوحدة وتعقيمها','يُنشأ تلقائيًا بعد المغادرة'),
 ('00000000-0000-0000-0000-000000000421','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010',null,'تنظيف دورات المياه المشتركة',null),
 ('00000000-0000-0000-0000-000000000422','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010',null,'تنظيف الممرات والجلسات',null)
on conflict (id) do nothing;

insert into facilities(id, organization_id, branch_id, block_id, floor_id, name, description) values
 ('00000000-0000-0000-0000-000000000430','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000400','00000000-0000-0000-0000-000000000410','الممر الرئيسي','ممر الطابق الأول'),
 ('00000000-0000-0000-0000-000000000431','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000400',null,'البوابة الرئيسية',null)
on conflict (id) do nothing;

-- migrate legacy cleaning tasks → housekeeping tasks, keep a compat view
insert into housekeeping_tasks(id, organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, status, assignee_id, scheduled_start, completed_at, created_at)
select c.id, r.organization_id, c.branch_id, c.room_id, t.id, t.name, c.reservation_id,
       case c.status when 'done' then 'completed' when 'in_progress' then 'in_progress' else 'pending' end,
       c.assigned_to, c.created_at, c.completed_at, c.created_at
from cleaning_tasks c
join rooms r on r.id = c.room_id
join task_types t on t.branch_id = c.branch_id and t.code = 'room_cleaning'
on conflict (id) do nothing;
update rooms set cleanliness = 'dirty' where id in (select room_id from housekeeping_tasks where status in ('pending','in_progress') and room_id is not null);
drop table if exists cleaning_tasks cascade;
create view cleaning_tasks with (security_invoker = true) as
  select id, room_id, branch_id, reservation_id,
         case status when 'completed' then 'done' else status end as status,
         assignee_id as assigned_to, completed_at, created_at
  from housekeeping_tasks where room_id is not null;
grant select on cleaning_tasks to authenticated;

-- =====================================================================
-- 9. RLS for new tables (read within branch scope; writes only via RPC)
-- =====================================================================
alter table blocks enable row level security;
alter table floors enable row level security;
alter table facilities enable row level security;
alter table task_types enable row level security;
alter table housekeeping_tasks enable row level security;
alter table service_definitions enable row level security;

create policy "staff_blocks_select" on blocks for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "staff_floors_select" on floors for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "staff_facilities_select" on facilities for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "staff_tasktypes_select" on task_types for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "staff_services_select" on service_definitions for select to authenticated using (branch_id in (select fn_user_branch_ids()));
-- housekeeping staff only see tasks in their branches; (assignment filtering happens in UI; data is operational, not personal)
create policy "staff_hk_select" on housekeeping_tasks for select to authenticated using (branch_id in (select fn_user_branch_ids()));
-- block the legacy direct-write policies on rooms/categories: everything goes through RPC now
drop policy if exists "mgr_rooms_write" on rooms;
drop policy if exists "mgr_cat_write" on room_categories;
drop policy if exists "owner_write_branches" on branches;

-- =====================================================================
-- 10. Helpers: branch-local date, audit with before/after, version check, dependency counting
-- =====================================================================
-- "Today" for a branch is its own calendar day, not the server's UTC day (after-midnight arrivals in Riyadh are still "today").
create or replace function fn_branch_today(p_branch uuid) returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh'))::date;
$$;
grant execute on function fn_branch_today(uuid) to authenticated;

-- The system task type used by checkout / room switch. Created on demand so every branch has one.
create or replace function fn_room_cleaning_type(p_branch uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from task_types where branch_id = p_branch and code = 'room_cleaning';
  if v is null then
    insert into task_types(organization_id, branch_id, code, name, description)
    select organization_id, id, 'room_cleaning', 'تنظيف الوحدة وتعقيمها', 'يُنشأ تلقائيًا بعد المغادرة' from branches where id = p_branch
    returning id into v;
  end if;
  if v is null then raise exception 'TASK_TYPE_MISSING: room_cleaning'; end if;
  return v;
end $$;
revoke all on function fn_room_cleaning_type(uuid) from public, anon, authenticated;

create or replace function fn_audit_change(p_branch uuid, p_action text, p_entity text, p_entity_id uuid, p_before jsonb, p_after jsonb, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb; v_after jsonb;
begin
  -- redact anything that must never be in the audit trail
  v_before := p_before - 'code_encrypted' - 'identity_number_encrypted' - 'token' - 'guest_token';
  v_after  := p_after  - 'code_encrypted' - 'identity_number_encrypted' - 'token' - 'guest_token';
  insert into audit_events(organization_id, branch_id, actor_id, action, entity_type, entity_id, details)
  values (fn_user_org_id(), p_branch, fn_staff_id(), p_action, p_entity, p_entity_id,
          jsonb_strip_nulls(jsonb_build_object('before', v_before, 'after', v_after, 'reason', p_reason)));
end $$;
revoke all on function fn_audit_change(uuid, text, text, uuid, jsonb, jsonb, text) from public, anon, authenticated;

create or replace function fn_check_version(p_current int, p_expected int) returns void
language plpgsql immutable as $$
begin
  if p_expected is not null and p_current <> p_expected then
    raise exception 'VERSION_CONFLICT: record changed by another user' using errcode = '40001';
  end if;
end $$;

-- Dependencies that block hard delete of a definition. Returns {entity: count}.
create or replace function fn_definition_dependencies(p_entity text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d jsonb := '{}'::jsonb; v_branch uuid;
begin
  perform fn_require_role('owner','manager');
  v_branch := case p_entity
    when 'branch' then p_id
    when 'block' then (select branch_id from blocks where id = p_id)
    when 'floor' then (select branch_id from floors where id = p_id)
    when 'room_category' then (select branch_id from room_categories where id = p_id)
    when 'room' then (select branch_id from rooms where id = p_id)
    when 'facility' then (select branch_id from facilities where id = p_id)
    when 'task_type' then (select branch_id from task_types where id = p_id)
    when 'service' then (select branch_id from service_definitions where id = p_id) end;
  if v_branch is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  case p_entity
    when 'branch' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where branch_id = p_id),
        'room_categories', (select count(*) from room_categories where branch_id = p_id),
        'reservations', (select count(*) from reservations where branch_id = p_id),
        'staff', (select count(*) from branch_memberships where branch_id = p_id),
        'blocks', (select count(*) from blocks where branch_id = p_id),
        'floors', (select count(*) from floors where branch_id = p_id),
        'facilities', (select count(*) from facilities where branch_id = p_id),
        'task_types', (select count(*) from task_types where branch_id = p_id and code is null),
        'services', (select count(*) from service_definitions where branch_id = p_id),
        'vouchers', (select count(*) from financial_vouchers where branch_id = p_id),
        'invoices', (select count(*) from invoices where branch_id = p_id),
        'keyboxes', (select count(*) from keyboxes where branch_id = p_id),
        'policies', (select count(*) from property_policies where branch_id = p_id),
        'conversations', (select count(*) from conversations where branch_id = p_id),
        'tasks', (select count(*) from housekeeping_tasks where branch_id = p_id));
    when 'block' then
      d := jsonb_build_object(
        'floors', (select count(*) from floors where block_id = p_id),
        'rooms', (select count(*) from rooms where block_id = p_id),
        'facilities', (select count(*) from facilities where block_id = p_id));
    when 'floor' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where floor_id = p_id),
        'facilities', (select count(*) from facilities where floor_id = p_id));
    when 'room_category' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where category_id = p_id),
        'reservations', (select count(*) from reservations where room_category_id = p_id),
        'inventory_periods', (select count(*) from inventory_periods where category_id = p_id),
        'release_rules', (select count(*) from release_rules where category_id = p_id),
        'released_slots', (select count(*) from released_slots where category_id = p_id));
    when 'room' then
      d := jsonb_build_object(
        'reservations', (select count(*) from reservations where room_id = p_id),
        'allocations', (select count(*) from reservation_allocations where room_id = p_id),
        'tasks', (select count(*) from housekeeping_tasks where room_id = p_id),
        'keyboxes', (select count(*) from keyboxes where room_id = p_id),
        'maintenance_tickets', (select count(*) from maintenance_tickets where room_id = p_id),
        'code_rotation_events', (select count(*) from code_rotation_events where room_id = p_id));
    when 'facility' then
      d := jsonb_build_object('tasks', (select count(*) from housekeeping_tasks where facility_id = p_id));
    when 'task_type' then
      d := jsonb_build_object(
        'tasks', (select count(*) from housekeeping_tasks where task_type_id = p_id),
        'services', (select count(*) from service_definitions where task_type_id = p_id));
    when 'service' then
      d := jsonb_build_object('charges', (select count(*) from reservation_charges where service_definition_id = p_id));
    else raise exception 'VALIDATION: entity';
  end case;
  return d;
end $$;
revoke all on function fn_definition_dependencies(text, uuid) from public, anon;
grant execute on function fn_definition_dependencies(text, uuid) to authenticated;

create or replace function fn_dependency_total(d jsonb) returns bigint language sql immutable as $$
  select coalesce(sum((v)::bigint), 0) from jsonb_each_text(d) as e(k, v);
$$;

-- =====================================================================
-- 11. Definition CRUD (owner/manager) — branch-scoped, version-checked, audited
-- =====================================================================
create or replace function fn_admin_upsert_branch(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if p ? 'timezone' then
    begin perform now() at time zone (p->>'timezone'); exception when others then raise exception 'VALIDATION: timezone'; end;
  end if;
  if v_id is null then
    perform fn_require_role('owner');
    insert into branches(organization_id, name_ar, name_en, city, address, map_url, phone, email, check_in_time, check_out_time, timezone, tax_rate_bp, prices_include_tax, default_deposit_halalas, tax_number, commercial_register, is_active)
    values (fn_user_org_id(), p->>'name_ar', p->>'name_en', p->>'city', p->>'address', p->>'map_url', p->>'phone', p->>'email',
            coalesce((p->>'check_in_time')::time, '16:00'), coalesce((p->>'check_out_time')::time, '12:00'),
            coalesce(p->>'timezone','Asia/Riyadh'), coalesce((p->>'tax_rate_bp')::int, 1500), coalesce((p->>'prices_include_tax')::boolean, false),
            coalesce((p->>'default_deposit_halalas')::bigint, 0), p->>'tax_number', p->>'commercial_register', coalesce((p->>'is_active')::boolean, true))
    returning * into b;
    perform fn_room_cleaning_type(b.id);   -- every branch gets its system cleaning task type
    perform fn_audit_change(b.id, 'branch.created', 'branch', b.id, null, to_jsonb(b));
  else
    select * into b from branches where id = v_id and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.id);
    perform fn_check_version(b.version, (p->>'version')::int);
    before := to_jsonb(b);
    update branches set
      name_ar = p->>'name_ar', name_en = coalesce(p->>'name_en', name_en), city = coalesce(p->>'city', city), address = coalesce(p->>'address', address),
      map_url = coalesce(p->>'map_url', map_url), phone = coalesce(p->>'phone', phone), email = coalesce(p->>'email', email),
      check_in_time = coalesce((p->>'check_in_time')::time, check_in_time), check_out_time = coalesce((p->>'check_out_time')::time, check_out_time),
      timezone = coalesce(p->>'timezone', timezone), tax_rate_bp = coalesce((p->>'tax_rate_bp')::int, tax_rate_bp),
      prices_include_tax = coalesce((p->>'prices_include_tax')::boolean, prices_include_tax),
      default_deposit_halalas = coalesce((p->>'default_deposit_halalas')::bigint, default_deposit_halalas),
      tax_number = coalesce(p->>'tax_number', tax_number), commercial_register = coalesce(p->>'commercial_register', commercial_register),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = b.id returning * into b;
    perform fn_audit_change(b.id, 'branch.updated', 'branch', b.id, before, to_jsonb(b));
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
end $$;
grant execute on function fn_admin_upsert_branch(jsonb) to authenticated;

create or replace function fn_admin_upsert_block(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b blocks%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into blocks(organization_id, branch_id, name, description, sort_order, created_by)
    values (fn_user_org_id(), v_branch, trim(p->>'name'), p->>'description', coalesce((p->>'sort_order')::int,0), fn_staff_id()) returning * into b;
    perform fn_audit_change(b.branch_id, 'block.created', 'block', b.id, null, to_jsonb(b));
  else
    select * into b from blocks where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.branch_id);
    perform fn_check_version(b.version, (p->>'version')::int);
    before := to_jsonb(b);
    update blocks set name = trim(p->>'name'), description = p->>'description', sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = b.id returning * into b;
    perform fn_audit_change(b.branch_id, 'block.updated', 'block', b.id, before, to_jsonb(b));
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_block(jsonb) to authenticated;

create or replace function fn_admin_upsert_floor(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f floors%rowtype; blk blocks%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    select * into blk from blocks where id = (p->>'block_id')::uuid;
    if not found then raise exception 'NOT_FOUND: block'; end if;
    perform fn_require_branch(blk.branch_id);
    insert into floors(organization_id, branch_id, block_id, name, sort_order)
    values (blk.organization_id, blk.branch_id, blk.id, trim(p->>'name'), coalesce((p->>'sort_order')::int,0)) returning * into f;
    perform fn_audit_change(f.branch_id, 'floor.created', 'floor', f.id, null, to_jsonb(f));
  else
    select * into f from floors where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(f.branch_id);
    perform fn_check_version(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update floors set name = trim(p->>'name'), sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'floor.updated', 'floor', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_floor(jsonb) to authenticated;

create or replace function fn_admin_upsert_room_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c room_categories%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'base_price_halalas') and (p->>'base_price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into room_categories(organization_id, branch_id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, amenities, is_public, sort_order)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', coalesce((p->>'base_capacity')::int,2), coalesce((p->>'max_capacity')::int,4),
            coalesce((p->>'base_price_halalas')::bigint, 0), coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'amenities','[]'::jsonb)) x), '{}'),
            coalesce((p->>'is_public')::boolean, true), coalesce((p->>'sort_order')::int, 0)) returning * into c;
    perform fn_audit_change(c.branch_id, 'room_category.created', 'room_category', c.id, null, to_jsonb(c));
  else
    select * into c from room_categories where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(c.branch_id);
    perform fn_check_version(c.version, (p->>'version')::int);
    before := to_jsonb(c);
    -- changing base price never reprices existing reservations (charges are snapshots)
    update room_categories set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      base_capacity = coalesce((p->>'base_capacity')::int, base_capacity), max_capacity = coalesce((p->>'max_capacity')::int, max_capacity),
      base_price_halalas = coalesce((p->>'base_price_halalas')::bigint, base_price_halalas),
      amenities = case when p ? 'amenities' then (select array_agg(x) from jsonb_array_elements_text(p->'amenities') x) else amenities end,
      is_public = coalesce((p->>'is_public')::boolean, is_public), is_active = coalesce((p->>'is_active')::boolean, is_active),
      sort_order = coalesce((p->>'sort_order')::int, sort_order), version = version + 1, updated_at = now()
    where id = c.id returning * into c;
    if c.max_capacity < c.base_capacity then raise exception 'VALIDATION: capacity'; end if;
    perform fn_audit_change(c.branch_id, 'room_category.updated', 'room_category', c.id, before, to_jsonb(c));
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version);
end $$;
grant execute on function fn_admin_upsert_room_category(jsonb) to authenticated;

create or replace function fn_admin_upsert_room(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rooms%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid;
        v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; before jsonb; future_count int;
begin
  perform fn_require_role('owner','manager');
  if v_id is not null then
    select * into r from rooms where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := r.branch_id;
    v_block := coalesce(v_block, r.block_id); v_floor := coalesce(v_floor, r.floor_id); v_cat := coalesce(v_cat, r.category_id);
  end if;
  perform fn_require_branch(v_branch);
  if coalesce(trim(p->>'room_number'),'') = '' and v_id is null then raise exception 'VALIDATION: room_number'; end if;
  -- cross-relation consistency: every parent must belong to the same branch (A02)
  if v_cat is null or not exists (select 1 from room_categories where id = v_cat and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_block is not null and not exists (select 1 from blocks where id = v_block and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if v_floor is not null and not exists (select 1 from floors where id = v_floor and branch_id = v_branch and (v_block is null or block_id = v_block)) then raise exception 'BRANCH_MISMATCH: floor'; end if;

  if v_id is null then
    insert into rooms(organization_id, branch_id, category_id, block_id, floor_id, room_number, floor, status, notes, is_active)
    values (fn_user_org_id(), v_branch, v_cat, v_block, v_floor, trim(p->>'room_number'), coalesce((p->>'floor')::int,1), 'available', p->>'notes', coalesce((p->>'is_active')::boolean, true))
    returning * into r;
    perform fn_audit_change(r.branch_id, 'room.created', 'room', r.id, null, to_jsonb(r));
  else
    perform fn_check_version(r.version, (p->>'version')::int);
    before := to_jsonb(r);
    -- deactivating a room with future/active commitments is blocked until they are resolved (A09 / G17)
    if (p->>'is_active')::boolean is false and r.is_active then
      select count(*) into future_count from reservation_allocations a join reservations rs on rs.id = a.reservation_id
        where a.room_id = r.id and a.status = 'active' and rs.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(r.branch_id);
      if future_count > 0 then
        raise exception 'HAS_FUTURE_COMMITMENTS: % allocation(s)', future_count;
      end if;
    end if;
    update rooms set room_number = coalesce(nullif(trim(p->>'room_number'),''), room_number), category_id = v_cat, block_id = v_block, floor_id = v_floor,
      floor = coalesce((p->>'floor')::int, floor), notes = coalesce(p->>'notes', notes), is_active = coalesce((p->>'is_active')::boolean, is_active),
      status = case when coalesce((p->>'is_active')::boolean, is_active) = false then 'out_of_service'
                    when coalesce((p->>'is_active')::boolean, is_active) and status = 'out_of_service' then 'available' else status end,
      version = version + 1, updated_at = now()
    where id = r.id returning * into r;
    perform fn_audit_change(r.branch_id, 'room.updated', 'room', r.id, before, to_jsonb(r));
  end if;
  return jsonb_build_object('ok', true, 'id', r.id, 'version', r.version);
exception when unique_violation then raise exception 'DUPLICATE_ROOM_NUMBER';
end $$;
grant execute on function fn_admin_upsert_room(jsonb) to authenticated;

create or replace function fn_admin_upsert_facility(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f facilities%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is not null then
    select * into f from facilities where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := f.branch_id;
    if p ? 'block_id' then v_block := (p->>'block_id')::uuid; else v_block := f.block_id; end if;
    if p ? 'floor_id' then v_floor := (p->>'floor_id')::uuid; else v_floor := f.floor_id; end if;
  end if;
  perform fn_require_branch(v_branch);
  if v_block is not null and not exists (select 1 from blocks where id = v_block and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: block'; end if;
  if v_floor is not null and not exists (select 1 from floors where id = v_floor and branch_id = v_branch and (v_block is null or block_id = v_block)) then raise exception 'BRANCH_MISMATCH: floor'; end if;
  if v_id is null then
    insert into facilities(organization_id, branch_id, block_id, floor_id, name, description, images, created_by)
    values (fn_user_org_id(), v_branch, v_block, v_floor, trim(p->>'name'), p->>'description', coalesce(p->'images','[]'::jsonb), fn_staff_id()) returning * into f;
    perform fn_audit_change(f.branch_id, 'facility.created', 'facility', f.id, null, to_jsonb(f));
  else
    perform fn_check_version(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update facilities set name = trim(p->>'name'), description = p->>'description', block_id = v_block, floor_id = v_floor,
      images = coalesce(p->'images', images), is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'facility.updated', 'facility', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_facility(jsonb) to authenticated;

create or replace function fn_admin_upsert_task_type(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t task_types%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into task_types(organization_id, branch_id, name, description) values (fn_user_org_id(), v_branch, trim(p->>'name'), p->>'description') returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.created', 'task_type', t.id, null, to_jsonb(t));
  else
    select * into t from task_types where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(t.branch_id);
    perform fn_check_version(t.version, (p->>'version')::int);
    before := to_jsonb(t);
    -- renaming never rewrites task_type_name_snapshot on historical tasks
    update task_types set name = trim(p->>'name'), description = p->>'description', is_active = coalesce((p->>'is_active')::boolean, is_active),
      version = version + 1, updated_at = now() where id = t.id returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.updated', 'task_type', t.id, before, to_jsonb(t));
  end if;
  return jsonb_build_object('ok', true, 'id', t.id, 'version', t.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_task_type(jsonb) to authenticated;

create or replace function fn_admin_upsert_service(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s service_definitions%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_tt uuid := (p->>'task_type_id')::uuid; before jsonb;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'price_halalas') and (p->>'price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  if v_id is not null then
    select * into s from service_definitions where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_branch := s.branch_id;
    if not (p ? 'task_type_id') then v_tt := s.task_type_id; end if;
  end if;
  perform fn_require_branch(v_branch);
  if v_tt is not null and not exists (select 1 from task_types where id = v_tt and branch_id = v_branch) then raise exception 'BRANCH_MISMATCH: task_type'; end if;
  if v_id is null then
    insert into service_definitions(organization_id, branch_id, name_ar, name_en, description, billing_unit, price_halalas, is_free, taxable, task_type_id)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', coalesce(p->>'billing_unit','once'),
            coalesce((p->>'price_halalas')::bigint,0), coalesce((p->>'is_free')::boolean,false), coalesce((p->>'taxable')::boolean,true), v_tt) returning * into s;
    perform fn_audit_change(s.branch_id, 'service.created', 'service', s.id, null, to_jsonb(s));
  else
    perform fn_check_version(s.version, (p->>'version')::int);
    before := to_jsonb(s);
    -- catalogue edits never touch historical reservation_charges (snapshots) — G27
    update service_definitions set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      billing_unit = coalesce(p->>'billing_unit', billing_unit), price_halalas = coalesce((p->>'price_halalas')::bigint, price_halalas),
      is_free = coalesce((p->>'is_free')::boolean, is_free), taxable = coalesce((p->>'taxable')::boolean, taxable), task_type_id = v_tt,
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = s.id returning * into s;
    perform fn_audit_change(s.branch_id, 'service.updated', 'service', s.id, before, to_jsonb(s));
  end if;
  return jsonb_build_object('ok', true, 'id', s.id, 'version', s.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $$;
grant execute on function fn_admin_upsert_service(jsonb) to authenticated;

-- Archive / restore / safe delete ------------------------------------------------
create or replace function fn_admin_archive_definition(p_entity text, p_id uuid, p_reason text, p_archive boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid; v_table text; before jsonb; after jsonb; open_count int := 0;
begin
  perform fn_require_role('owner','manager');
  if p_archive and coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  v_table := case p_entity when 'branch' then 'branches' when 'block' then 'blocks' when 'floor' then 'floors' when 'room_category' then 'room_categories'
                           when 'room' then 'rooms' when 'facility' then 'facilities' when 'task_type' then 'task_types' when 'service' then 'service_definitions' end;
  if v_table is null then raise exception 'VALIDATION: entity'; end if;
  execute format('select %s, to_jsonb(t) from %I t where id = $1 for update', case when p_entity = 'branch' then 'id' else 'branch_id' end, v_table) into v_branch, before using p_id;
  if before is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  if p_entity = 'branch' then perform fn_require_role('owner'); end if;

  if p_archive then
    -- open commitments block archiving (G17)
    if p_entity = 'room' then
      select count(*) into open_count from reservation_allocations a join reservations r on r.id = a.reservation_id
        where a.room_id = p_id and a.status = 'active' and r.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(v_branch);
    elsif p_entity = 'facility' then
      select count(*) into open_count from housekeeping_tasks where facility_id = p_id and status in ('pending','in_progress');
    elsif p_entity = 'task_type' then
      select count(*) into open_count from housekeeping_tasks where task_type_id = p_id and status in ('pending','in_progress');
    elsif p_entity in ('block','floor') then
      execute format('select count(*) from rooms where %I = $1 and archived_at is null', case p_entity when 'block' then 'block_id' else 'floor_id' end) into open_count using p_id;
    elsif p_entity = 'room_category' then
      select count(*) into open_count from rooms where category_id = p_id and archived_at is null;
    elsif p_entity = 'branch' then
      select count(*) into open_count from reservations where branch_id = p_id and status in ('confirmed','checked_in','pending_verification') and check_out > fn_branch_today(p_id);
      if (select count(*) from branches where organization_id = fn_user_org_id() and archived_at is null and is_active) <= 1 then raise exception 'LAST_ACTIVE_BRANCH'; end if;
    end if;
    if open_count > 0 then raise exception 'HAS_OPEN_COMMITMENTS: %', open_count; end if;
    execute format('update %I set archived_at = now(), archived_by = $2, archive_reason = $3, is_active = false, version = version + 1, updated_at = now() where id = $1 returning to_jsonb(%I)', v_table, v_table)
      into after using p_id, fn_staff_id(), p_reason;
    if p_entity = 'room' then update rooms set status = 'out_of_service' where id = p_id; end if;
  else
    execute format('update %I set archived_at = null, archived_by = null, archive_reason = null, is_active = true, version = version + 1, updated_at = now() where id = $1 returning to_jsonb(%I)', v_table, v_table)
      into after using p_id;
    if p_entity = 'room' then update rooms set status = 'available' where id = p_id and status = 'out_of_service'; end if;
  end if;
  perform fn_audit_change(v_branch, p_entity || case when p_archive then '.archived' else '.restored' end, p_entity, p_id, before, after, p_reason);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_archive_definition(text, uuid, text, boolean) to authenticated;

-- Hard delete ONLY for definitions with zero dependencies; otherwise tells the caller to archive (G16)
create or replace function fn_admin_delete_definition(p_entity text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare deps jsonb; v_branch uuid; v_table text; before jsonb;
begin
  perform fn_require_role('owner','manager');
  v_table := case p_entity when 'branch' then 'branches' when 'block' then 'blocks' when 'floor' then 'floors' when 'room_category' then 'room_categories'
                           when 'room' then 'rooms' when 'facility' then 'facilities' when 'task_type' then 'task_types' when 'service' then 'service_definitions' end;
  if v_table is null then raise exception 'VALIDATION: entity'; end if;
  execute format('select %s, to_jsonb(t) from %I t where id = $1 for update', case when p_entity = 'branch' then 'id' else 'branch_id' end, v_table) into v_branch, before using p_id;
  if before is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  if p_entity = 'branch' then perform fn_require_role('owner'); end if;
  deps := fn_definition_dependencies(p_entity, p_id);
  if fn_dependency_total(deps) > 0 then
    return jsonb_build_object('ok', false, 'error', 'HAS_DEPENDENCIES', 'dependencies', deps);
  end if;
  if p_entity = 'task_type' and (before->>'code') is not null then return jsonb_build_object('ok', false, 'error', 'SYSTEM_DEFINITION'); end if;
  -- audit first: the audit row must survive the entity
  perform fn_audit_change(v_branch, p_entity || '.deleted', p_entity, p_id, before, null);
  if p_entity = 'branch' then delete from task_types where branch_id = p_id and code is not null; end if;   -- the auto-seeded system type is not user data
  execute format('delete from %I where id = $1', v_table) using p_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_admin_delete_definition(text, uuid) to authenticated;

-- =====================================================================
-- 12. Room readiness (recomputed; cleanliness is independent of occupancy)
-- =====================================================================
create or replace function fn_recompute_room_ready(p_room uuid) returns room_status
language plpgsql security definer set search_path = public as $$
declare rm rooms%rowtype; kb keyboxes%rowtype; open_maint int; st room_status;
begin
  select * into rm from rooms where id = p_room for update;
  if not rm.is_active or rm.archived_at is not null then update rooms set status = 'out_of_service' where id = p_room; return 'out_of_service'; end if;
  if rm.status in ('occupied','reserved','blocked') then return rm.status; end if;
  select count(*) into open_maint from maintenance_tickets where room_id = p_room and status <> 'resolved';
  select * into kb from keyboxes where room_id = p_room limit 1;
  if open_maint > 0 then st := 'maintenance';
  elsif rm.cleanliness <> 'clean' then st := 'cleaning';
  elsif kb.id is null or kb.code_status <> 'active' or not kb.field_tested then st := 'cleaning';   -- clean but entry not ready (H06)
  else st := 'ready'; end if;
  update rooms set status = st where id = p_room;
  return st;
end $$;
revoke all on function fn_recompute_room_ready(uuid) from public, anon, authenticated;

-- =====================================================================
-- 13. Housekeeping task lifecycle
-- =====================================================================
create or replace function fn_hk_create_task(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype; v_room uuid := (p->>'room_id')::uuid; v_fac uuid := (p->>'facility_id')::uuid; v_branch uuid; tt task_types%rowtype; v_assignee uuid := (p->>'assignee_id')::uuid;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  if (v_room is null) = (v_fac is null) then raise exception 'VALIDATION: one_target'; end if;    -- H01
  if v_room is not null then select branch_id into v_branch from rooms where id = v_room and archived_at is null; end if;
  if v_fac  is not null then select branch_id into v_branch from facilities where id = v_fac and archived_at is null; end if;
  if v_branch is null then raise exception 'NOT_FOUND: target'; end if;
  perform fn_require_branch(v_branch);
  select * into tt from task_types where id = (p->>'task_type_id')::uuid and branch_id = v_branch and archived_at is null;
  if not found then raise exception 'BRANCH_MISMATCH: task_type'; end if;
  if (p->>'reservation_id') is not null and not exists (select 1 from reservations where id = (p->>'reservation_id')::uuid and branch_id = v_branch) then
    raise exception 'BRANCH_MISMATCH: reservation';
  end if;
  if v_assignee is not null and not exists (select 1 from staff_profiles s join branch_memberships m on m.staff_id = s.id where s.id = v_assignee and s.is_active and m.branch_id = v_branch)
     and not exists (select 1 from staff_profiles s where s.id = v_assignee and s.is_active and s.role = 'owner' and s.organization_id = fn_user_org_id()) then
    raise exception 'ASSIGNEE_NOT_IN_BRANCH';                                                      -- H02
  end if;
  insert into housekeeping_tasks(organization_id, branch_id, room_id, facility_id, task_type_id, task_type_name_snapshot, reservation_id, priority, assignee_id, scheduled_start, scheduled_end, description, created_by)
  values (fn_user_org_id(), v_branch, v_room, v_fac, tt.id, tt.name, (p->>'reservation_id')::uuid, coalesce(p->>'priority','medium'), v_assignee,
          coalesce((p->>'scheduled_start')::timestamptz, now()), (p->>'scheduled_end')::timestamptz, p->>'description', fn_staff_id()) returning * into t;
  if v_room is not null and tt.code = 'room_cleaning' then update rooms set cleanliness = 'dirty' where id = v_room and cleanliness = 'clean'; perform fn_recompute_room_ready(v_room); end if;
  perform fn_audit_change(v_branch, 'task.created', 'housekeeping_task', t.id, null, to_jsonb(t));
  return jsonb_build_object('ok', true, 'id', t.id);
end $$;
grant execute on function fn_hk_create_task(jsonb) to authenticated;

create or replace function fn_hk_start_task(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  if t.status <> 'pending' then raise exception 'TASK_STATUS_INVALID'; end if;
  if fn_has_role('housekeeping') and t.assignee_id is not null and t.assignee_id <> fn_staff_id() then raise exception 'FORBIDDEN: not assignee'; end if;
  update housekeeping_tasks set status = 'in_progress', started_at = now(), assignee_id = coalesce(assignee_id, fn_staff_id()), version = version + 1, updated_at = now() where id = t.id;
  if t.room_id is not null and t.task_type_id in (select id from task_types where code = 'room_cleaning') then update rooms set cleanliness = 'in_progress' where id = t.room_id; end if;
  perform fn_audit_change(t.branch_id, 'task.started', 'housekeeping_task', t.id, null, null);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_hk_start_task(uuid) to authenticated;

-- Completing a task updates cleanliness + readiness in the SAME transaction and NEVER frees an occupied room (H03–H05)
create or replace function fn_hk_complete_task(p_task uuid, p_note text default null, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype; st room_status; is_cleaning boolean; occ text;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  perform fn_check_version(t.version, p_expected_version);
  if t.status not in ('pending','in_progress') then raise exception 'TASK_STATUS_INVALID'; end if;
  if fn_has_role('housekeeping') and t.assignee_id is not null and t.assignee_id <> fn_staff_id() then raise exception 'FORBIDDEN: not assignee'; end if;
  update housekeeping_tasks set status = 'completed', completed_at = now(), completed_by = fn_staff_id(), assignee_id = coalesce(assignee_id, fn_staff_id()),
    result_note = p_note, version = version + 1, updated_at = now() where id = t.id;
  if t.room_id is not null then
    select (code = 'room_cleaning') into is_cleaning from task_types where id = t.task_type_id;
    if coalesce(is_cleaning, false) then
      update rooms set cleanliness = 'clean', updated_at = now() where id = t.room_id;
    end if;
    st := fn_recompute_room_ready(t.room_id);           -- occupied stays occupied
    select status::text into occ from rooms where id = t.room_id;
  end if;
  perform fn_audit_change(t.branch_id, 'task.completed', 'housekeeping_task', t.id, null, jsonb_build_object('room_status', st, 'note', p_note));
  return jsonb_build_object('ok', true, 'room_status', coalesce(occ, st::text));
end $$;
grant execute on function fn_hk_complete_task(uuid, text, int) to authenticated;

create or replace function fn_hk_cancel_task(p_task uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  if t.status not in ('pending','in_progress') then raise exception 'TASK_STATUS_INVALID'; end if;
  update housekeeping_tasks set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason, version = version + 1, updated_at = now() where id = t.id;
  if t.room_id is not null and t.task_type_id in (select id from task_types where code = 'room_cleaning') then
    -- a cancelled cleaning never leaves the room "in progress": it is still dirty until another task completes
    update rooms set cleanliness = 'dirty', updated_at = now() where id = t.room_id and cleanliness = 'in_progress';
    perform fn_recompute_room_ready(t.room_id);
  end if;
  perform fn_audit_change(t.branch_id, 'task.cancelled', 'housekeeping_task', t.id, null, null, p_reason);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_hk_cancel_task(uuid, text) to authenticated;

create or replace function fn_hk_assign_task(p_task uuid, p_assignee uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  if p_assignee is not null and not exists (select 1 from staff_profiles s join branch_memberships m on m.staff_id = s.id where s.id = p_assignee and s.is_active and m.branch_id = t.branch_id)
     and not exists (select 1 from staff_profiles s where s.id = p_assignee and s.is_active and s.role = 'owner' and s.organization_id = fn_user_org_id()) then
    raise exception 'ASSIGNEE_NOT_IN_BRANCH';
  end if;
  update housekeeping_tasks set assignee_id = p_assignee, version = version + 1, updated_at = now() where id = t.id;
  perform fn_audit_change(t.branch_id, 'task.assigned', 'housekeeping_task', t.id, jsonb_build_object('assignee_id', t.assignee_id), jsonb_build_object('assignee_id', p_assignee));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_hk_assign_task(uuid, uuid) to authenticated;

-- Manual cleanliness change (the "mark dirty / mark clean" action, separate from the state label)
create or replace function fn_hk_set_cleanliness(p_room uuid, p_state text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rm rooms%rowtype; st room_status;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  if p_state not in ('clean','dirty') then raise exception 'VALIDATION: cleanliness'; end if;
  select * into rm from rooms where id = p_room for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  if p_state = 'clean' and exists (select 1 from housekeeping_tasks h join task_types t on t.id = h.task_type_id where h.room_id = p_room and h.status in ('pending','in_progress') and t.code = 'room_cleaning') then
    raise exception 'OPEN_CLEANING_TASK';   -- complete the task instead, so the task log stays truthful
  end if;
  update rooms set cleanliness = p_state, updated_at = now() where id = p_room;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit_change(rm.branch_id, 'room.cleanliness_changed', 'room', p_room, jsonb_build_object('cleanliness', rm.cleanliness), jsonb_build_object('cleanliness', p_state), p_reason);
  return jsonb_build_object('ok', true, 'room_status', (select status from rooms where id = p_room));
end $$;
grant execute on function fn_hk_set_cleanliness(uuid, text, text) to authenticated;

-- Legacy wrapper kept for the existing UI/tests
create or replace function fn_staff_complete_cleaning(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return fn_hk_complete_task(p_task, null, null);
end $$;
grant execute on function fn_staff_complete_cleaning(uuid) to authenticated;

-- Maintenance resolution must go through readiness recompute
create or replace function fn_staff_resolve_maintenance(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t maintenance_tickets%rowtype; st room_status;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into t from maintenance_tickets where id = p_ticket for update;
  if not found then raise exception 'TICKET_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  update maintenance_tickets set status = 'resolved' where id = t.id;
  st := fn_recompute_room_ready(t.room_id);
  perform fn_audit(fn_user_org_id(), t.branch_id, fn_staff_id(), 'maintenance_resolved', 'room', t.room_id, jsonb_build_object('ticket_id', t.id, 'room_status', st));
  return jsonb_build_object('ok', true, 'room_status', st);
end $$;
grant execute on function fn_staff_resolve_maintenance(uuid) to authenticated;
