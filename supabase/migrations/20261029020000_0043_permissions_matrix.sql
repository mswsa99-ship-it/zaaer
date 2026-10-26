-- =====================================================================
-- 0043 — The permissions matrix the owner approved (decision 71, 26 Oct 2026), editable from the owner's account.
--
--  The owner approved the matrix (55 operations × the roles) and asked to tick or untick its cells. Settled with the
--  owner: one matrix for the whole organisation; only editing the matrix itself stays the owner's. Settled here:
--  the owner's column is always allowed (the owner can never lock themselves out); a cell that carried a condition in
--  the approved matrix keeps it when ticked (a supervisor's discount stays within the lowest price and the highest
--  percentage; a role ticked for an operation that has a condition gets the conditioned version); no one but the
--  owner creates, edits, activates or signs out an owner (decision 44, self-escalation).
--
--  role_permissions holds only what the owner changed; every other cell reads the approved default from
--  fn_permission_catalog(). fn_can(code) answers for the person making the request, at that request, so a change
--  takes effect on everyone's next operation. Every server operation the matrix names asks fn_require_cap(code)
--  instead of a fixed list of roles; the money columns follow fn_sees_money() (a person sees money when the matrix
--  gives them any money operation — with the approved defaults exactly the four roles that saw it before).
--  Operations the matrix does not name keep their fixed roles. With the approved defaults nothing changes: every
--  earlier test passes unchanged.
--
--  Written without the words the SQL tool refuses; the audit dictionary and the capability catalogue with the new
--  entries come with the owner's paste (0044).
-- =====================================================================

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The catalogue: the approved matrix (decision 71), one row per operation
--    default_roles: who the approved matrix allows (the owner always); full_roles: who gets the operation without
--    its condition (null: everyone allowed); limit_note: the condition a ticked role outside full_roles works under.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_permission_catalog()
returns table(code text, label text, area text, sort int, default_roles role_code[], full_roles role_code[], limit_note text, locked boolean)
language sql immutable set search_path = public as $$
  values
    ('res.create', 'إنشاء حجز مفرد أو جماعي', 'الحجوزات', 10, '{owner,manager,supervisor}'::role_code[], '{owner,manager}'::role_code[], 'سعر أقل من المعروض يحتاج المدير', false),
    ('disc.before', 'خصم قبل الوصول (ضمن أدنى سعر وأقصى نسبة)', 'الحجوزات', 20, '{owner,manager,supervisor}', null, null, false),
    ('disc.after', 'خصم بعد الوصول أو فوق الحدين', 'الحجوزات', 30, '{owner,manager}', null, null, false),
    ('price.adjust', 'تسوية سعر بسبب (تصفير رصيد، مغادرة مبكرة)', 'الحجوزات', 40, '{owner,manager}', null, null, false),
    ('charges.add', 'رسوم وخدمات إضافية وخروج متأخر برسوم', 'الحجوزات', 50, '{owner,manager,supervisor}', null, null, false),
    ('stay.extend', 'تمديد يدوي (يُمنع مع ليلة غير مدفوعة إلا بسبب)', 'الحجوزات', 60, '{owner,manager,supervisor}', '{owner,manager}', 'لا يقصّر إقامة أسبوعية أو شهرية', false),
    ('room.assign', 'تخصيص وحدة ونقلها', 'الحجوزات', 70, '{owner,manager,supervisor}', null, null, false),
    ('res.cancel', 'إلغاء حجز (وبرقم المنصة دون رد) وعدم حضور', 'الحجوزات', 80, '{owner,manager,supervisor}', null, null, false),
    ('res.undo_cancel', 'التراجع عن الإلغاء خلال ساعة', 'الحجوزات', 90, '{owner,manager}', null, null, false),
    ('hold.set', 'وضع حظر على حجز', 'الحجوزات', 100, '{owner,manager,supervisor}', null, null, false),
    ('hold.lift', 'رفع الحظر عن حجز', 'الحجوزات', 110, '{owner,manager}', null, null, false),
    ('guest.enter', 'إدخال بيانات الضيف من الوثيقة الأصلية وتصحيحها بسبب', 'الضيوف', 120, '{owner,manager,supervisor}', null, null, false),
    ('identity.approve', 'اعتماد الهوية', 'الضيوف', 130, '{owner,manager,supervisor}', null, null, false),
    ('guest.ban', 'حظر ضيف ورفعه', 'الضيوف', 140, '{owner,manager}', null, null, false),
    ('guest.rate', 'تقييم الضيف وملاحظته الداخلية', 'الضيوف', 150, '{owner,manager,supervisor}', null, null, false),
    ('shomoos', 'تأكيد شموس (المرجع والتسجيل والقبول)', 'الإقامة', 160, '{owner,manager,supervisor}', null, null, false),
    ('checkin', 'تسجيل الوصول (ومهلة السداد والإقرار الورقي)', 'الإقامة', 170, '{owner,manager,supervisor}', null, null, false),
    ('code.deliver', 'تسليم الرمز (الوحدات ذات الصندوق)', 'الإقامة', 180, '{owner,manager,supervisor}', null, null, false),
    ('checkin.undo', 'التراجع عن الوصول خلال 30 دقيقة', 'الإقامة', 190, '{owner,manager}', null, null, false),
    ('checkout', 'تسجيل المغادرة (المتبقي صفر، بلا تجاوز لأحد)', 'الإقامة', 200, '{owner,manager,supervisor}', null, null, false),
    ('stay.reopen', 'إعادة فتح حجز غادر خلال ساعتين', 'الإقامة', 210, '{owner,manager}', null, null, false),
    ('inspection', 'فحص المغادرة', 'الإقامة', 220, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('voucher.receipt', 'سند قبض إيجار أو تأمين', 'المال', 230, '{owner,manager,supervisor,finance}', null, null, false),
    ('voucher.refund', 'رد مبلغ إقامة', 'المال', 240, '{owner,manager,finance}', null, null, false),
    ('deposit.refund', 'رد التأمين (بعد فحص المغادرة فقط)', 'المال', 250, '{owner,manager,supervisor,finance}', null, null, false),
    ('damage.charge', 'رسم ضرر وخصمه من التأمين', 'المال', 260, '{owner,manager,supervisor}', null, null, false),
    ('deposit.apply', 'خصم من التأمين بسبب لتصفير الرصيد', 'المال', 270, '{owner,manager,supervisor,finance}', null, null, false),
    ('voucher.correct', 'تصحيح سند (إلغاء وإصدار بسبب)', 'المال', 280, '{owner,manager,supervisor}', '{owner,manager}', 'سنداته خلال 24 ساعة', false),
    ('voucher.cancel', 'إلغاء سند', 'المال', 290, '{owner,manager}', null, null, false),
    ('pos.settle', 'تسوية الشبكة اليومية', 'المال', 300, '{owner,manager,supervisor,finance}', null, null, false),
    ('platform.payouts', 'مطابقة الآجل عبر المنصات الشهرية', 'المال', 310, '{owner,manager,finance}', '{owner,manager}', 'دون إلغاء إيداع مؤكد', false),
    ('invoice.issue', 'إصدار فاتورة جزئية', 'المال', 320, '{owner,manager,supervisor,finance}', null, null, false),
    ('invoice.edit', 'تعديل فاتورة بسبب (ينبّه الإدارة)', 'المال', 330, '{owner,manager,supervisor,finance}', null, null, false),
    ('rates', 'تقويم الأسعار وأسعار النوع (أساسي، أسبوعي، شهري، أدنى)', 'الإعدادات', 340, '{owner,manager}', null, null, false),
    ('branch.tax', 'نسبة الضريبة', 'الإعدادات', 350, '{owner}', null, null, false),
    ('branch.settings', 'إعدادات الفرع الأخرى (التأمين، أقصى خصم، الموقع، الشعار، رابط المنصة…)', 'الإعدادات', 360, '{owner,manager}', null, null, false),
    ('cash_accounts', 'الصناديق والحسابات البنكية', 'الإعدادات', 370, '{owner,manager}', null, null, false),
    ('definitions', 'الوحدات والأنواع والمرافق والخدمات وأنواع المهام ومصادر الحجز', 'الإعدادات', 380, '{owner,manager}', null, null, false),
    ('policies', 'السياسات', 'الإعدادات', 390, '{owner,manager}', null, null, false),
    ('knowledge', 'قاعدة معرفة المساعد', 'الإعدادات', 400, '{owner,manager,supervisor}', null, null, false),
    ('task.work', 'إنشاء مهمة وبدؤها وإتمامها', 'خدمة الغرف', 410, '{owner,manager,supervisor,housekeeping}', '{owner,manager,supervisor,finance}', 'مهامه المسندة إليه', false),
    ('task.manage', 'إسناد مهمة وإلغاؤها', 'خدمة الغرف', 420, '{owner,manager,supervisor}', null, null, false),
    ('cleanliness', 'تغيير النظافة يدويًا (حر)', 'خدمة الغرف', 430, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('keybox.code', 'تغيير رمز الصندوق وتجربته', 'خدمة الغرف', 440, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('maintenance.create', 'البلاغات: إنشاء', 'خدمة الغرف', 450, '{owner,manager,supervisor,housekeeping}', null, null, false),
    ('maintenance.resolve', 'البلاغات: حلّ', 'خدمة الغرف', 460, '{owner,manager,supervisor}', null, null, false),
    ('conversation.take', 'تولّي محادثة واتساب', 'المحادثات', 470, '{owner,manager,supervisor}', null, null, false),
    ('staff.manage', 'دعوة موظف وتعديله وتفعيله وتعطيله', 'الموظفون والأمان', 480, '{owner}', '{owner}', 'لا يمسّ حساب المالك', false),
    ('staff.force_logout', 'خروج إجباري', 'الموظفون والأمان', 490, '{owner,manager}', '{owner}', 'غير المالك والمدير', false),
    ('security', 'السجل الأمني ومسح البيانات وإعدادات المساعد وواتساب', 'الموظفون والأمان', 500, '{owner}', null, null, false),
    ('admin.permissions', 'تعديل مصفوفة الصلاحيات', 'الموظفون والأمان', 505, '{owner}', null, null, true),
    ('review.list', 'قائمة «بحاجة لمراجعة وتدقيق» والتأشير عليها', 'التقارير والسجل', 510, '{owner}', null, null, false),
    ('reports.finance', 'التقارير المالية وتقرير الخصومات', 'التقارير والسجل', 520, '{owner,manager,supervisor,finance}', '{owner,manager,finance}', 'ملخص الخصومات فقط', false),
    ('reports.identities_usage', 'تقرير الهويات المعتمدة من المكتب وتقرير الاستعمال', 'التقارير والسجل', 530, '{owner}', null, null, false),
    ('audit.log', 'سجل الإجراءات', 'التقارير والسجل', 540, '{owner,manager,supervisor}', '{owner,manager}', 'بلا تفاصيل التغييرات', false);
$$;
grant execute on function fn_permission_catalog() to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. What the owner changed (organisation-wide; one row per changed cell; never removed — a reset writes the default)
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists role_permissions (
  organization_id uuid not null references organizations(id),
  capability text not null,
  role role_code not null,
  allowed boolean not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references staff_profiles(id),
  primary key (organization_id, capability, role),
  constraint role_permissions_role_editable check (role in ('manager', 'supervisor', 'finance', 'housekeeping'))
);
alter table role_permissions enable row level security;
revoke all on role_permissions from anon, authenticated;
grant select on role_permissions to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'role_permissions' and policyname = 'owner_reads_permissions') then
    create policy "owner_reads_permissions" on role_permissions for select to authenticated using (organization_id = fn_user_org_id() and fn_has_role('owner'));
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The questions every operation asks
-- ---------------------------------------------------------------------------------------------------------------
/** may the person making this request do this operation? (the owner always; the matrix row otherwise) */
create or replace function fn_can(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  with me as (select fn_current_role() as r, fn_user_org_id() as org)
  select case
    when (select r from me) is null then false
    when (select r from me) = 'owner' then exists (select 1 from fn_permission_catalog() c where c.code = p_code)
    when exists (select 1 from fn_permission_catalog() c where c.code = p_code and c.locked) then false
    else coalesce(
      (select rp.allowed from role_permissions rp, me where rp.organization_id = me.org and rp.role = me.r and rp.capability = p_code),
      (select me.r = any(c.default_roles) from fn_permission_catalog() c, me where c.code = p_code),
      false)
  end;
$$;
grant execute on function fn_can(text) to authenticated;

/** allowed and without the row's condition (the owner always; a role in full_roles; every allowed role when null) */
create or replace function fn_cap_full(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select fn_can(p_code) and (fn_current_role() = 'owner'
    or coalesce((select fn_current_role() = any(c.full_roles) from fn_permission_catalog() c where c.code = p_code and c.full_roles is not null), true));
$$;
grant execute on function fn_cap_full(text) to authenticated;

create or replace function fn_require_cap(p_code text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from fn_permission_catalog() c where c.code = p_code) then raise exception 'UNKNOWN_PERMISSION: %', p_code; end if;
  if not fn_can(p_code) then raise exception 'FORBIDDEN: %', p_code using errcode = '42501'; end if;
end $$;
revoke all on function fn_require_cap(text) from public, anon;
grant execute on function fn_require_cap(text) to authenticated;

create or replace function fn_require_cap_full(p_code text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap(p_code);
  if not fn_cap_full(p_code) then raise exception 'FORBIDDEN: % (limited)', p_code using errcode = '42501'; end if;
end $$;
revoke all on function fn_require_cap_full(text) from public, anon;
grant execute on function fn_require_cap_full(text) to authenticated;

create or replace function fn_require_any_cap(p_codes text[]) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from unnest(p_codes) x where fn_can(x)) then raise exception 'FORBIDDEN: %', array_to_string(p_codes, ' / ') using errcode = '42501'; end if;
end $$;
revoke all on function fn_require_any_cap(text[]) from public, anon;
grant execute on function fn_require_any_cap(text[]) to authenticated;

/** may this person see money? — when the matrix gives them any money operation (with the approved defaults: owner,
    manager, supervisor, finance — exactly the roles that saw it before) */
create or replace function fn_sees_money() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(fn_current_role() = 'owner', false) or fn_can('voucher.receipt') or fn_can('voucher.refund') or fn_can('deposit.refund')
      or fn_can('deposit.apply') or fn_can('voucher.correct') or fn_can('voucher.cancel') or fn_can('pos.settle') or fn_can('platform.payouts')
      or fn_can('invoice.issue') or fn_can('invoice.edit') or fn_can('reports.finance');
$$;
grant execute on function fn_sees_money() to authenticated;

create or replace function fn_require_money() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_sees_money() then raise exception 'FORBIDDEN: money' using errcode = '42501'; end if;
end $$;
revoke all on function fn_require_money() from public, anon;
grant execute on function fn_require_money() to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Reading and editing the matrix
-- ---------------------------------------------------------------------------------------------------------------
/** what the person may do — the screens show and hide by it (the server decides anyway) */
create or replace function fn_my_permissions() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when fn_current_role() is null then jsonb_build_object('role', null, 'allowed', '[]'::jsonb, 'full', '[]'::jsonb, 'sees_money', false)
  else jsonb_build_object('role', fn_current_role(),
    'allowed', coalesce((select jsonb_agg(c.code order by c.sort) from fn_permission_catalog() c where fn_can(c.code)), '[]'::jsonb),
    'full', coalesce((select jsonb_agg(c.code order by c.sort) from fn_permission_catalog() c where fn_cap_full(c.code)), '[]'::jsonb),
    'sees_money', fn_sees_money()) end;
$$;
grant execute on function fn_my_permissions() to authenticated;

/** the matrix as the owner edits it: every row, every editable role, its current value, the approved default */
create or replace function fn_permissions_matrix() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare org uuid := fn_user_org_id();
begin
  perform fn_require_cap('admin.permissions');
  return jsonb_build_object(
    'roles', '["owner","manager","supervisor","finance","housekeeping"]'::jsonb,
    'editable_roles', '["manager","supervisor","finance","housekeeping"]'::jsonb,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'code', c.code, 'label', c.label, 'area', c.area, 'locked', c.locked, 'limit_note', c.limit_note,
        'full_roles', to_jsonb(c.full_roles),
        'cells', (select jsonb_object_agg(r.role, jsonb_build_object(
                    'allowed', case when r.role = 'owner' then true when c.locked then false
                                    else coalesce((select rp.allowed from role_permissions rp where rp.organization_id = org and rp.capability = c.code and rp.role = r.role), r.role = any(c.default_roles)) end,
                    'default', r.role = any(c.default_roles),
                    'limited', r.role <> 'owner' and c.full_roles is not null and not (r.role = any(c.full_roles))))
                  from unnest('{owner,manager,supervisor,finance,housekeeping}'::role_code[]) as r(role)))
      order by c.sort) from fn_permission_catalog() c), '[]'::jsonb),
    'changed', (select count(*) from role_permissions rp join fn_permission_catalog() c on c.code = rp.capability
                 where rp.organization_id = org and rp.allowed is distinct from (rp.role = any(c.default_roles))),
    'last_change', (select jsonb_build_object('at', e.created_at, 'by', (select full_name from staff_profiles where id = e.actor_id), 'reason', e.details->>'reason')
                      from audit_events e where e.organization_id = org and e.action in ('permissions.updated', 'permissions.reset')
                      order by e.created_at desc limit 1));
end $$;
grant execute on function fn_permissions_matrix() to authenticated;

/** the owner ticks or unticks cells, with a reason; one audit row with every cell before and after */
create or replace function fn_admin_set_permissions(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid := fn_user_org_id(); me uuid := fn_staff_id(); v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        ch jsonb; c record; v_role role_code; v_allowed boolean; v_before boolean; changes jsonb := '[]'::jsonb;
begin
  perform fn_require_cap('admin.permissions');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  if jsonb_typeof(p->'changes') is distinct from 'array' then raise exception 'VALIDATION: changes'; end if;
  for ch in select * from jsonb_array_elements(p->'changes') loop
    select * into c from fn_permission_catalog() x where x.code = ch->>'code';
    if not found then raise exception 'UNKNOWN_PERMISSION: %', ch->>'code'; end if;
    if c.locked then raise exception 'PERMISSION_LOCKED: %', c.code; end if;
    if coalesce(ch->>'role', '') not in ('manager', 'supervisor', 'finance', 'housekeeping') then raise exception 'VALIDATION: role'; end if;
    if jsonb_typeof(ch->'allowed') is distinct from 'boolean' then raise exception 'VALIDATION: allowed'; end if;
    v_role := (ch->>'role')::role_code; v_allowed := (ch->>'allowed')::boolean;
    v_before := coalesce((select rp.allowed from role_permissions rp where rp.organization_id = org and rp.capability = c.code and rp.role = v_role), v_role = any(c.default_roles));
    if v_before is distinct from v_allowed then
      insert into role_permissions(organization_id, capability, role, allowed, updated_at, updated_by) values (org, c.code, v_role, v_allowed, now(), me)
        on conflict (organization_id, capability, role) do update set allowed = excluded.allowed, updated_at = now(), updated_by = me;
      changes := changes || jsonb_build_object('code', c.code, 'label', c.label, 'role', v_role, 'before', v_before, 'after', v_allowed);
    end if;
  end loop;
  if jsonb_array_length(changes) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  perform fn_audit(org, null, me, 'permissions.updated', 'role_permissions', null, jsonb_build_object('changes', changes, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'changed', jsonb_array_length(changes));
end $$;
grant execute on function fn_admin_set_permissions(jsonb) to authenticated;

/** back to the approved matrix, with a reason; the audit row lists every cell that changed back */
create or replace function fn_admin_reset_permissions(p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid := fn_user_org_id(); me uuid := fn_staff_id(); changes jsonb;
begin
  perform fn_require_cap('admin.permissions');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', rp.capability, 'label', c.label, 'role', rp.role, 'before', rp.allowed, 'after', rp.role = any(c.default_roles))), '[]'::jsonb)
    into changes
    from role_permissions rp join fn_permission_catalog() c on c.code = rp.capability
   where rp.organization_id = org and rp.allowed is distinct from (rp.role = any(c.default_roles));
  if jsonb_array_length(changes) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  update role_permissions rp set allowed = (rp.role = any(c.default_roles)), updated_at = now(), updated_by = me
    from fn_permission_catalog() c
   where c.code = rp.capability and rp.organization_id = org and rp.allowed is distinct from (rp.role = any(c.default_roles));
  perform fn_audit(org, null, me, 'permissions.reset', 'role_permissions', null, jsonb_build_object('changes', changes, 'reason', trim(p_reason)));
  return jsonb_build_object('ok', true, 'changed', jsonb_array_length(changes));
end $$;
grant execute on function fn_admin_reset_permissions(text) to authenticated;

-- matrix changes are security events (the owner's log): the category follows the action's prefix
create or replace function fn_audit_enrich() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_corr text; v_src text; v_role text;
begin
  v_corr := fn_request_header('x-correlation-id');
  if v_corr is not null and v_corr !~ '^[A-Za-z0-9_-]{6,64}$' then v_corr := null; end if;
  new.correlation_id := coalesce(new.correlation_id, v_corr, 'tx-' || txid_current()::text);

  v_src := coalesce(nullif(current_setting('app.source', true), ''), fn_request_header('x-client-source'));
  if v_src is not null and v_src !~ '^[a-z][a-z_-]{1,31}$' then v_src := null; end if;

  v_role := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb ->> 'role';
  new.actor_id := coalesce(new.actor_id, fn_staff_id());
  new.actor_type := coalesce(new.actor_type,
    case when new.actor_id is not null then 'staff'
         when v_role = 'anon' then 'guest'
         when auth.uid() is not null then 'user'
         else 'system' end);
  new.source := coalesce(new.source, v_src, case when new.actor_type = 'system' then 'system' else 'screen' end);
  if new.action ~ '^(staff|membership|security|data_purge|permissions)' then new.category := 'security'; end if;
  new.result := coalesce(new.result, 'success');
  return new;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. The tables written or read directly follow the matrix too
-- ---------------------------------------------------------------------------------------------------------------
alter policy "staff_sources_all" on booking_sources
  using ((organization_id = fn_user_org_id()) and fn_can('definitions'))
  with check ((organization_id = fn_user_org_id()) and fn_can('definitions'));
alter policy "mgr_write_policies" on property_policies
  using ((branch_id in (select fn_user_branch_ids())) and fn_can('policies'))
  with check ((branch_id in (select fn_user_branch_ids())) and fn_can('policies'));
alter policy "staff_conv_update" on conversations
  using (fn_can('conversation.take') and ((branch_id is null) or (branch_id in (select fn_user_branch_ids()))));
alter policy "staff_msg_insert" on conversation_messages
  with check (fn_can('conversation.take') and (sender = 'supervisor') and (exists (select 1 from conversations c
    where c.id = conversation_messages.conversation_id and ((c.branch_id is null) or (c.branch_id in (select fn_user_branch_ids()))))));
alter policy "mgmt_audit_read" on audit_events
  using (fn_can('audit.log') and (organization_id = fn_user_org_id()) and ((category <> 'security') or fn_can('security')));
alter policy "rates_read" on rate_calendar
  using ((branch_id in (select fn_user_branch_ids())) and fn_can('rates'));
alter policy "review_items_owner_read" on review_items
  using ((organization_id = fn_user_org_id()) and fn_can('review.list'));
alter policy "money_platform_payouts_read" on platform_payouts
  using ((branch_id in (select fn_user_branch_ids())) and fn_can('platform.payouts'));
do $$
declare t record;
begin
  -- the money tables a person reads when the matrix gives them money (the four roles with the approved defaults)
  for t in select * from (values ('cash_accounts', 'money_staff_cash_accounts_read'), ('financial_vouchers', 'staff_vouchers_select'),
                                 ('invoices', 'staff_invoices_select'), ('pos_settlements', 'money_staff_pos_settlements_read'),
                                 ('reservation_charges', 'staff_charges_select'), ('reservation_nights', 'nights_read'),
                                 ('stay_payment_exceptions', 'payment_exceptions_read')) v(tbl, pol) loop
    if exists (select 1 from pg_policies where schemaname = 'public' and tablename = t.tbl and policyname = t.pol
                 and qual = '((branch_id IN ( SELECT fn_user_branch_ids() AS fn_user_branch_ids)) AND fn_has_role(VARIADIC ARRAY[''owner''::role_code, ''manager''::role_code, ''supervisor''::role_code, ''finance''::role_code]))') then
      execute format('alter policy %I on %I using ((branch_id in (select fn_user_branch_ids())) and fn_sees_money())', t.pol, t.tbl);
    else
      raise exception 'policy %.% is not the one this migration expects', t.tbl, t.pol;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Every operation the matrix names asks the matrix (the current definitions, their role checks replaced)
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_admin_archive_cash_account(p_id uuid, p_archive boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a cash_accounts%rowtype; before jsonb; used int;
begin
  perform fn_require_cap('cash_accounts');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into a from cash_accounts where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(a.branch_id);
  before := to_jsonb(a);
  select count(*) into used from financial_vouchers where account_id = a.id;
  if p_archive then
    if a.archived_at is not null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update cash_accounts set archived_at = now(), archived_by = fn_staff_id(), archive_reason = p_reason, is_default = false,
                             version = version + 1, updated_at = now() where id = a.id returning * into a;
  else
    if a.archived_at is null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    if exists (select 1 from cash_accounts where branch_id = a.branch_id and lower(name) = lower(a.name) and archived_at is null and id <> a.id) then raise exception 'DUPLICATE_NAME'; end if;
    update cash_accounts set archived_at = null, archived_by = null, archive_reason = null, version = version + 1, updated_at = now() where id = a.id returning * into a;
  end if;
  perform fn_audit_change(a.branch_id, case when p_archive then 'cash_account.archived' else 'cash_account.restored' end, 'cash_account', a.id, before, to_jsonb(a), p_reason);
  return jsonb_build_object('ok', true, 'used_by_vouchers', used,
    'default_missing', not exists (select 1 from cash_accounts where branch_id = a.branch_id and kind = a.kind and is_default and archived_at is null));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_archive_definition(p_entity text, p_id uuid, p_reason text, p_archive boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid; v_table text; before jsonb; after jsonb; open_count int := 0;
begin
  perform fn_require_cap('definitions');
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
      if fn_room_guest_in_house(p_id) then raise exception 'ROOM_HAS_GUEST: a guest is in house'; end if;
      select count(*) into open_count from reservation_allocations a join reservations r on r.id = a.reservation_id
        where a.room_id = p_id and a.status = 'active' and r.status in ('confirmed','checked_in','pending_verification') and a.to_date > fn_branch_today(v_branch);
    elsif p_entity = 'facility' then
      select count(*) into open_count from housekeeping_tasks where facility_id = p_id and status in ('pending','in_progress');
    elsif p_entity = 'task_type' then
      select count(*) into open_count from housekeeping_tasks where task_type_id = p_id and status in ('pending','in_progress');
    elsif p_entity in ('block','floor') then
      execute format('select count(*) from rooms where %I = $1 and archived_at is null', case p_entity when 'block' then 'block_id' else 'floor_id' end) into open_count using p_id;
    elsif p_entity = 'room_category' then
      -- the type's row is locked above; a booking on it waits for this (trg_reservation_category_guard), so the count is final
      select count(*) into open_count from rooms where category_id = p_id and archived_at is null;
      open_count := open_count + (select count(*) from reservations where room_category_id = p_id and status in ('confirmed','checked_in','pending_verification')
                                                                    and check_out > fn_branch_today(v_branch));
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_archive_knowledge(p_id uuid, p_reason text, p_archive boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare k knowledge_entries%rowtype;
begin
  perform fn_require_cap('knowledge');
  select * into k from knowledge_entries where id = p_id and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if k.branch_id is not null then perform fn_require_branch(k.branch_id); end if;
  if p_archive then
    if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
    update knowledge_entries set archived_at = now(), archived_by = fn_staff_id(), archive_reason = p_reason, is_active = false, version = version + 1, updated_at = now() where id = k.id;
  else
    update knowledge_entries set archived_at = null, archived_by = null, archive_reason = null, is_active = true, version = version + 1, updated_at = now() where id = k.id;
  end if;
  perform fn_audit(k.organization_id, k.branch_id, fn_staff_id(), case when p_archive then 'knowledge.archived' else 'knowledge.restored' end, 'knowledge_entry', k.id, jsonb_build_object('reason', p_reason, 'before', jsonb_build_object('archived_at', k.archived_at)));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_branch_media_info(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(p_branch);
  return coalesce((select jsonb_object_agg(kind, jsonb_build_object('mime', mime, 'size_bytes', size_bytes, 'updated_at', updated_at,
                                                                     'updated_by', (select full_name from staff_profiles where id = m.updated_by)))
                   from branch_media m where m.branch_id = p_branch and m.bytes is not null), '{}'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_force_logout(p_staff uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me staff_profiles%rowtype; sp staff_profiles%rowtype; n int;
begin
  perform fn_require_cap('staff.force_logout');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into me from staff_profiles where id = fn_staff_id();
  select * into sp from staff_profiles where id = p_staff and organization_id = me.organization_id for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if sp.id = me.id then raise exception 'SELF_NOT_ALLOWED'; end if;
  if not fn_cap_full('staff.force_logout') and sp.role in ('owner', 'manager') then raise exception 'FORBIDDEN: a manager signs out neither an owner nor a manager' using errcode = '42501'; end if;
  n := fn_end_sessions(sp.auth_user_id);
  update staff_profiles set sessions_ended_at = now() where id = sp.id;
  perform fn_audit(sp.organization_id, null, me.id, 'staff.signed_out', 'staff_profile', sp.id,
                   jsonb_build_object('reason', trim(p_reason), 'sessions_ended', n, 'role', sp.role, 'linked', sp.auth_user_id is not null));
  return jsonb_build_object('ok', true, 'sessions_ended', n);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_purge_execute(p_token text, p_phrase text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare q data_purge_requests%rowtype; v_counts jsonb; v_iat bigint;
begin
  perform fn_require_cap('security');
  select * into q from data_purge_requests
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and organization_id = fn_user_org_id()
   for update;
  if not found or q.status <> 'pending' or q.expires_at < now() then raise exception 'VALIDATION: preview_expired'; end if;
  if q.requested_by <> fn_staff_id() then raise exception 'FORBIDDEN: only the owner who previewed can confirm' using errcode = '42501'; end if;
  if regexp_replace(btrim(coalesce(p_phrase, '')), '[ًٌٍَُِّْ]', '', 'g') <> 'احذف نهائيا' then
    raise exception 'VALIDATION: confirmation_phrase';
  end if;
  v_iat := nullif(auth.jwt()->>'iat', '')::bigint;
  if v_iat is null or v_iat < extract(epoch from now())::bigint - 600 then
    raise exception 'REAUTH_REQUIRED: sign in again to confirm' using errcode = '42501';
  end if;
  v_counts := fn_purge_run(q.organization_id, q.branch_id, q.date_from, q.date_to, q.categories);
  update data_purge_requests set status = 'done', result = v_counts, executed_at = now() where id = q.id;
  perform fn_audit(q.organization_id, q.branch_id, fn_staff_id(), 'data_purge_executed', 'organization', q.organization_id,
    jsonb_build_object('branch_id', q.branch_id, 'from', q.date_from, 'to', q.date_to, 'categories', to_jsonb(q.categories),
                       'counts', v_counts, 'request_id', q.id));
  return jsonb_build_object('ok', true, 'counts', v_counts);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_purge_history()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform fn_require_cap('security');
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'branch_name', b.name_ar, 'from', q.date_from, 'to', q.date_to,
      'categories', to_jsonb(q.categories), 'counts', q.result, 'executed_at', q.executed_at, 'by', s.full_name) order by q.executed_at desc)
    from data_purge_requests q left join branches b on b.id = q.branch_id left join staff_profiles s on s.id = q.requested_by
    where q.organization_id = fn_user_org_id() and q.status = 'done'), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_resolve_unanswered(p_id uuid, p_status text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare u unanswered_questions%rowtype;
begin
  perform fn_require_cap('knowledge');
  if p_status not in ('open','ignored') then raise exception 'VALIDATION: status'; end if;
  select * into u from unanswered_questions where id = p_id and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if u.branch_id is not null then perform fn_require_branch(u.branch_id); end if;
  update unanswered_questions set status = p_status, resolved_by = case when p_status = 'open' then null else fn_staff_id() end,
    resolved_at = case when p_status = 'open' then null else now() end, resolve_note = p_note where id = u.id;
  perform fn_audit(u.organization_id, u.branch_id, fn_staff_id(), 'unanswered.' || p_status, 'unanswered_question', u.id, jsonb_build_object('before', u.status, 'after', p_status, 'reason', p_note));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_set_branch_media(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_kind text := p->>'kind'; raw text := regexp_replace(coalesce(p->>'data_base64', ''), '^data:[^,]*,', '');
        bin bytea; v_mime text; v_limit int; cur branch_media%rowtype; before jsonb; after jsonb;
begin
  perform fn_require_cap('branch.settings');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_set_source_active(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s booking_sources%rowtype; v_active boolean := (p->>'is_active')::boolean;
begin
  perform fn_require_cap('definitions');
  if v_active is null then raise exception 'VALIDATION: is_active'; end if;
  select * into s from booking_sources where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.is_active = v_active then return jsonb_build_object('ok', true, 'changed', false); end if;
  update booking_sources set is_active = v_active where id = s.id;
  perform fn_audit_change(null, case when v_active then 'source.enabled' else 'source.disabled' end, 'booking_source', s.id,
    jsonb_build_object('code', s.code, 'is_active', s.is_active), jsonb_build_object('code', s.code, 'is_active', v_active), nullif(trim(coalesce(p->>'reason', '')), ''));
  return jsonb_build_object('ok', true, 'changed', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_set_staff_active(p_staff uuid, p_active boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sp staff_profiles%rowtype; n int := 0;
begin
  perform fn_require_cap('staff.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = p_staff and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if sp.id = fn_staff_id() then raise exception 'SELF_NOT_ALLOWED'; end if;
  if sp.role = 'owner' and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if sp.is_active = coalesce(p_active, sp.is_active) then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  perform set_config('app.staff_reason', trim(p_reason), true);
  update staff_profiles set is_active = p_active, updated_at = now(), sessions_ended_at = case when p_active then sessions_ended_at else now() end where id = sp.id;
  perform set_config('app.staff_reason', '', true);
  if not p_active then n := fn_end_sessions(sp.auth_user_id); end if;
  return jsonb_build_object('ok', true, 'is_active', p_active, 'sessions_ended', n);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_staff_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when (fn_can('staff.manage') or fn_can('staff.force_logout')) then coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'full_name', s.full_name, 'email', s.email, 'phone', case when fn_can('staff.manage') then s.phone end,
      'role', s.role, 'is_active', s.is_active, 'linked', s.auth_user_id is not null, 'created_at', s.created_at,
      'sessions_ended_at', s.sessions_ended_at, 'updated_at', s.updated_at,
      'branch_ids', coalesce((select jsonb_agg(m.branch_id order by m.created_at) from branch_memberships m where m.staff_id = s.id and m.removed_at is null), '[]'::jsonb),
      'is_me', s.id = fn_staff_id()) order by s.is_active desc, s.full_name)
    from staff_profiles s where s.organization_id = fn_user_org_id()), '[]'::jsonb)
  else '[]'::jsonb end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_admin_update_ai_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_fallbacks text[]; v_previous text[];
begin
  perform fn_require_cap('security');
  if p ? 'fallback_models' then
    if jsonb_typeof(p->'fallback_models') <> 'array' then raise exception 'VALIDATION: fallback_models must be a list'; end if;
    select coalesce(array_agg(m order by i), '{}') into v_fallbacks
    from (select lower(btrim(e.v)) as m, min(e.i) as i
          from jsonb_array_elements_text(p->'fallback_models') with ordinality as e(v, i)
          where btrim(e.v) <> ''
          group by 1) s;
    if cardinality(v_fallbacks) > 3 then raise exception 'VALIDATION: at most 3 fallback models'; end if;
    if exists (select 1 from unnest(v_fallbacks) m where m !~ '^[a-z0-9][a-z0-9.-]{0,62}$') then
      raise exception 'VALIDATION: fallback_models must be model ids (a-z 0-9 . -)';
    end if;
  end if;
  insert into ai_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  select fallback_models into v_previous from ai_settings where organization_id = fn_user_org_id();
  update ai_settings set
    enabled = coalesce((p->>'enabled')::boolean, enabled),
    provider = coalesce(p->>'provider', provider),
    model = coalesce(nullif(trim(p->>'model'),''), model),
    fallback_models = coalesce(v_fallbacks, fallback_models),
    temperature = coalesce((p->>'temperature')::numeric, temperature),
    max_output_tokens = coalesce((p->>'max_output_tokens')::int, max_output_tokens),
    timeout_ms = coalesce((p->>'timeout_ms')::int, timeout_ms),
    daily_request_limit = coalesce((p->>'daily_request_limit')::int, daily_request_limit),
    daily_token_budget = coalesce((p->>'daily_token_budget')::int, daily_token_budget),
    per_session_message_limit = coalesce((p->>'per_session_message_limit')::int, per_session_message_limit),
    strict_scope = coalesce((p->>'strict_scope')::boolean, strict_scope),
    extra_instructions = coalesce(p->>'extra_instructions', extra_instructions),
    ops_enabled = coalesce((p->>'ops_enabled')::boolean, ops_enabled),
    ops_daily_request_limit = coalesce((p->>'ops_daily_request_limit')::int, ops_daily_request_limit),
    briefing_with_insights = coalesce((p->>'briefing_with_insights')::boolean, briefing_with_insights),
    updated_by = fn_staff_id(), updated_at = now()
  where organization_id = fn_user_org_id();
  perform fn_audit(fn_user_org_id(), null, fn_staff_id(), 'ai_settings_updated', 'ai_settings', fn_user_org_id(),
    (p - 'extra_instructions' - 'fallback_models')
    || case when v_fallbacks is null then '{}'::jsonb
            else jsonb_build_object('fallback_models', to_jsonb(v_fallbacks), 'previous_fallback_models', to_jsonb(v_previous)) end);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_update_staff(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sp staff_profiles%rowtype; me uuid := fn_staff_id(); v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        v_name text; v_phone text; v_role role_code; v_branches uuid[]; before_b uuid[]; after_b uuid[]; b uuid; changed text[] := '{}';
        before_j jsonb; after_j jsonb; owners int;
begin
  perform fn_require_cap('staff.manage');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = (p->>'staff_id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if (sp.role = 'owner' or coalesce(p->>'role', '') = 'owner') and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if p ? 'email' and lower(trim(p->>'email')) is distinct from sp.email then raise exception 'EMAIL_NOT_EDITABLE'; end if;

  v_name := case when p ? 'full_name' then nullif(trim(p->>'full_name'), '') else sp.full_name end;
  if v_name is null then raise exception 'VALIDATION: full_name'; end if;
  v_phone := case when p ? 'phone' then nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9+]', '', 'g'), '') else sp.phone end;
  v_role := case when p ? 'role' then (p->>'role')::role_code else sp.role end;
  if v_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into before_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  v_branches := case when p ? 'branch_ids' then coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(p->'branch_ids') x), '{}') else before_b end;

  if sp.id = me and (v_role is distinct from sp.role or not (v_branches <@ before_b and before_b <@ v_branches)) then
    raise exception 'SELF_ROLE_OR_BRANCHES';                                            -- no one changes their own role or branches
  end if;
  if sp.role = 'owner' and v_role <> 'owner' then
    select count(*) into owners from staff_profiles where organization_id = sp.organization_id and role = 'owner' and is_active and id <> sp.id;
    if owners = 0 then raise exception 'LAST_OWNER: cannot remove or demote the last active owner'; end if;
  end if;
  foreach b in array v_branches loop perform fn_require_branch(b); end loop;

  if v_name is distinct from sp.full_name then changed := array_append(changed, 'full_name'); end if;
  if v_phone is distinct from sp.phone then changed := array_append(changed, 'phone'); end if;
  if v_role is distinct from sp.role then changed := array_append(changed, 'role'); end if;
  if not (v_branches <@ before_b and before_b <@ v_branches) then changed := array_append(changed, 'branches'); end if;
  if coalesce(array_length(changed, 1), 0) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;

  perform set_config('app.staff_edit', '1', true);
  update staff_profiles set full_name = v_name, phone = v_phone, role = v_role, updated_at = now() where id = sp.id;
  -- memberships: retire what is gone, re-open or add what is new (effective from the person's next operation)
  update branch_memberships set removed_at = now(), removed_by = me where staff_id = sp.id and removed_at is null and not (branch_id = any(v_branches));
  foreach b in array v_branches loop
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into after_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  perform set_config('app.staff_edit', '', true);

  before_j := jsonb_build_object('full_name', sp.full_name, 'phone', case when sp.phone is null then null else '••••' || right(sp.phone, 4) end, 'role', sp.role, 'branch_ids', to_jsonb(before_b));
  after_j  := jsonb_build_object('full_name', v_name, 'phone', case when v_phone is null then null else '••••' || right(v_phone, 4) end, 'role', v_role, 'branch_ids', to_jsonb(after_b));
  perform fn_audit(sp.organization_id, null, me, case when 'role' = any(changed) then 'staff.role_changed' else 'staff.updated' end, 'staff_profile', sp.id,
                   jsonb_build_object('changed', to_jsonb(changed), 'before', before_j, 'after', after_j, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'changed', to_jsonb(changed));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_block(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare b blocks%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_cap('definitions');
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
    perform fn_check_version_strict(b.version, (p->>'version')::int);
    before := to_jsonb(b);
    update blocks set name = trim(p->>'name'), description = p->>'description', sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = b.id returning * into b;
    perform fn_audit_change(b.branch_id, 'block.updated', 'block', b.id, before, to_jsonb(b));
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_branch(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b branches%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb; tax_changed boolean;
        v_map text := nullif(trim(coalesce(p->>'map_url', '')), ''); v_link text := nullif(trim(coalesce(p->>'booking_platform_url', '')), '');
begin
  perform fn_require_cap('branch.settings');
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
    if tax_changed and not fn_can('branch.tax') then raise exception 'FORBIDDEN: tax settings are the owner''s'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_cash_account(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a cash_accounts%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
        v_kind text := p->>'kind'; v_name text := trim(coalesce(p->>'name', '')); v_default boolean := coalesce((p->>'is_default')::boolean, false);
        v_last4 text := nullif(trim(coalesce(p->>'account_last4', '')), ''); v_bank text := nullif(trim(coalesce(p->>'bank_name', '')), '');
begin
  perform fn_require_cap('cash_accounts');
  if v_name = '' or length(v_name) > 60 then raise exception 'VALIDATION: name'; end if;
  if v_last4 is not null and v_last4 !~ '^[0-9]{4}$' then raise exception 'VALIDATION: account_last4'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    if v_kind not in ('cash_box', 'bank_account') then raise exception 'VALIDATION: kind'; end if;
    if v_kind = 'cash_box' then v_last4 := null; v_bank := null; end if;
    if exists (select 1 from cash_accounts where branch_id = v_branch and lower(name) = lower(v_name) and archived_at is null) then raise exception 'DUPLICATE_NAME'; end if;
    if v_default then update cash_accounts set is_default = false, version = version + 1, updated_at = now() where branch_id = v_branch and kind = v_kind and is_default and archived_at is null; end if;
    insert into cash_accounts(organization_id, branch_id, kind, name, bank_name, account_last4, is_default, created_by)
    values ((select organization_id from branches where id = v_branch), v_branch, v_kind, v_name, v_bank, v_last4,
            v_default or not exists (select 1 from cash_accounts where branch_id = v_branch and kind = v_kind and is_default and archived_at is null), fn_staff_id())
    returning * into a;
    perform fn_audit_change(a.branch_id, 'cash_account.created', 'cash_account', a.id, null, to_jsonb(a));
  else
    select * into a from cash_accounts where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(a.branch_id);
    perform fn_check_version_strict(a.version, (p->>'version')::int);
    if a.archived_at is not null then raise exception 'VALIDATION: account_archived'; end if;
    if exists (select 1 from cash_accounts where branch_id = a.branch_id and lower(name) = lower(v_name) and archived_at is null and id <> a.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(a);
    if v_default and not a.is_default then
      update cash_accounts set is_default = false, version = version + 1, updated_at = now() where branch_id = a.branch_id and kind = a.kind and is_default and archived_at is null;
    end if;
    update cash_accounts set name = v_name,
      bank_name = case when kind = 'bank_account' then v_bank end, account_last4 = case when kind = 'bank_account' then v_last4 end,
      is_default = case when v_default then true when (p ? 'is_default') then false else is_default end,
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = a.id returning * into a;
    perform fn_audit_change(a.branch_id, 'cash_account.updated', 'cash_account', a.id, before, to_jsonb(a));
  end if;
  return jsonb_build_object('ok', true, 'id', a.id, 'version', a.version);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_facility(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare f facilities%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; before jsonb;
begin
  perform fn_require_cap('definitions');
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
    perform fn_check_version_strict(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update facilities set name = trim(p->>'name'), description = p->>'description', block_id = v_block, floor_id = v_floor,
      images = coalesce(p->'images', images), is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'facility.updated', 'facility', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_floor(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare f floors%rowtype; blk blocks%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb;
begin
  perform fn_require_cap('definitions');
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
    perform fn_check_version_strict(f.version, (p->>'version')::int);
    before := to_jsonb(f);
    update floors set name = trim(p->>'name'), sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now() where id = f.id returning * into f;
    perform fn_audit_change(f.branch_id, 'floor.updated', 'floor', f.id, before, to_jsonb(f));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'version', f.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_knowledge(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare k knowledge_entries%rowtype; v_org uuid; v_branch uuid; v_kw text[]; v_before jsonb; v_q text; v_a text;
begin
  perform fn_require_cap('knowledge');
  v_org := fn_user_org_id();
  v_branch := nullif(p->>'branch_id','')::uuid;
  if v_branch is not null then perform fn_require_branch(v_branch);
  elsif not fn_has_role('owner','manager') then raise exception 'FORBIDDEN: org-wide entries require manager' using errcode = '42501'; end if;
  v_q := trim(coalesce(p->>'question',''));  v_a := trim(coalesce(p->>'answer',''));
  if char_length(v_q) < 3 then raise exception 'VALIDATION: question'; end if;
  if char_length(v_a) < 2 then raise exception 'VALIDATION: answer'; end if;
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
    select * into k from knowledge_entries where id = (p->>'id')::uuid and organization_id = v_org for update;
    if not found then raise exception 'NOT_FOUND'; end if;
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

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_room(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r rooms%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid;
        v_block uuid := (p->>'block_id')::uuid; v_floor uuid := (p->>'floor_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; before jsonb; future_count int;
begin
  perform fn_require_cap('definitions');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_room_category(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c room_categories%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb; affected int := 0; low int;
begin
  perform fn_require_cap('definitions');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'base_price_halalas') and (p->>'base_price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  if (nullif(p->>'weekly_price_halalas', '')::bigint <= 0) or (nullif(p->>'monthly_price_halalas', '')::bigint <= 0)
     or (nullif(p->>'min_nightly_halalas', '')::bigint <= 0) then raise exception 'VALIDATION: amount'; end if;
  if (p ? 'price_mode') and p->>'price_mode' not in ('unified', 'by_channel') then raise exception 'VALIDATION: price_mode'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into room_categories(organization_id, branch_id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, amenities, is_public, sort_order,
                                weekly_price_halalas, monthly_price_halalas, min_nightly_halalas, price_mode)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', coalesce((p->>'base_capacity')::int,2), coalesce((p->>'max_capacity')::int,4),
            coalesce((p->>'base_price_halalas')::bigint, 0), coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'amenities','[]'::jsonb)) x), '{}'),
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
      base_price_halalas = coalesce((p->>'base_price_halalas')::bigint, base_price_halalas),
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

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_service(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s service_definitions%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; v_tt uuid := (p->>'task_type_id')::uuid; before jsonb;
        v_late time; v_unit text;
begin
  perform fn_require_cap('definitions');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'price_halalas') and (p->>'price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
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
  if v_late is not null then
    if v_late <= coalesce((select check_out_time from branches where id = v_branch), time '12:00') then raise exception 'VALIDATION: late_checkout_until'; end if;
    if v_unit <> 'once' then raise exception 'VALIDATION: late_checkout_unit'; end if;
  end if;
  if v_id is null then
    insert into service_definitions(organization_id, branch_id, name_ar, name_en, description, billing_unit, price_halalas, is_free, taxable, task_type_id, late_checkout_until)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', v_unit,
            coalesce((p->>'price_halalas')::bigint,0), coalesce((p->>'is_free')::boolean,false), coalesce((p->>'taxable')::boolean,true), v_tt, v_late) returning * into s;
    perform fn_audit_change(s.branch_id, 'service.created', 'service', s.id, null, to_jsonb(s));
  else
    perform fn_check_version_strict(s.version, (p->>'version')::int);
    before := to_jsonb(s);
    -- catalogue edits never touch historical reservation_charges (snapshots) — G27
    update service_definitions set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      billing_unit = v_unit, price_halalas = coalesce((p->>'price_halalas')::bigint, price_halalas),
      is_free = coalesce((p->>'is_free')::boolean, is_free), taxable = coalesce((p->>'taxable')::boolean, taxable), task_type_id = v_tt,
      is_active = coalesce((p->>'is_active')::boolean, is_active), late_checkout_until = v_late, version = version + 1, updated_at = now()
    where id = s.id returning * into s;
    perform fn_audit_change(s.branch_id, 'service.updated', 'service', s.id, before, to_jsonb(s));
  end if;
  return jsonb_build_object('ok', true, 'id', s.id, 'version', s.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_upsert_task_type(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t task_types%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb;
begin
  perform fn_require_cap('definitions');
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'VALIDATION: name'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into task_types(organization_id, branch_id, name, description) values (fn_user_org_id(), v_branch, trim(p->>'name'), p->>'description') returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.created', 'task_type', t.id, null, to_jsonb(t));
  else
    select * into t from task_types where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(t.branch_id);
    perform fn_check_version_strict(t.version, (p->>'version')::int);
    before := to_jsonb(t);
    -- renaming never rewrites task_type_name_snapshot on historical tasks
    update task_types set name = trim(p->>'name'), description = p->>'description', is_active = coalesce((p->>'is_active')::boolean, is_active),
      version = version + 1, updated_at = now() where id = t.id returning * into t;
    perform fn_audit_change(t.branch_id, 'task_type.updated', 'task_type', t.id, before, to_jsonb(t));
  end if;
  return jsonb_build_object('ok', true, 'id', t.id, 'version', t.version);
exception when unique_violation then raise exception 'DUPLICATE_NAME';
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_whatsapp_channels()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform fn_require_cap('security');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'branch_id', b.id, 'branch_name', b.name_ar, 'branch_phone', b.phone,
      'mode', coalesce(c.mode, 'web_bridge'),
      'enabled', coalesce(c.enabled, false), 'display_phone', c.display_phone, 'phone_number_id', c.phone_number_id,
      'waba_id', c.waba_id, 'has_token', c.access_token_encrypted is not null, 'token_last4', c.token_last4,
      'has_app_secret', c.app_secret_encrypted is not null, 'verify_token', c.verify_token,
      'otp_template', c.otp_template, 'template_lang', coalesce(c.template_lang, 'ar'),
      'status', coalesce(c.status, 'not_configured'), 'last_error', c.last_error, 'last_checked_at', c.last_checked_at,
      'verified_name', c.verified_name, 'updated_at', c.updated_at,
      'auto_reply', coalesce(c.auto_reply, true), 'human_pause_minutes', coalesce(c.human_pause_minutes, 60),
      'has_bridge_key', c.bridge_key_hash is not null, 'bridge_key_last4', c.bridge_key_last4,
      'bridge_key_created_at', c.bridge_key_created_at, 'bridge_status', c.bridge_status, 'bridge_phone', c.bridge_phone,
      'bridge_name', c.bridge_name, 'bridge_version', c.bridge_version, 'bridge_last_seen', c.bridge_last_seen,
      'bridge_online', coalesce(c.bridge_last_seen > now() - interval '90 seconds', false)) order by b.created_at)
    from branches b left join branch_whatsapp_channels c on c.branch_id = b.id
    where b.organization_id = fn_user_org_id() and b.archived_at is null), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_admin_whatsapp_save(p_branch uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_org uuid := fn_user_org_id();
  c branch_whatsapp_channels%rowtype;
  v_phone text; v_token text := nullif(btrim(coalesce(p->>'access_token', '')), '');
  v_secret text := nullif(btrim(coalesce(p->>'app_secret', '')), '');
  v_changed text[] := '{}';
  v_key text; v_pause int;
begin
  perform fn_require_cap('security');
  if not exists (select 1 from branches where id = p_branch and organization_id = v_org) then raise exception 'NOT_FOUND: branch'; end if;
  insert into branch_whatsapp_channels(branch_id, organization_id) values (p_branch, v_org) on conflict (branch_id) do nothing;
  select * into c from branch_whatsapp_channels where branch_id = p_branch for update;

  if p ? 'mode' then
    if coalesce(p->>'mode', '') not in ('cloud_api', 'web_bridge') then raise exception 'VALIDATION: mode'; end if;
    if p->>'mode' <> c.mode then c.mode := p->>'mode'; v_changed := array_append(v_changed, 'mode'); end if;
  end if;
  if p ? 'display_phone' then
    v_phone := fn_normalize_phone(p->>'display_phone');
    if nullif(btrim(coalesce(p->>'display_phone', '')), '') is not null and v_phone is null then raise exception 'VALIDATION: display_phone'; end if;
    if v_phone is distinct from c.display_phone then c.display_phone := v_phone; v_changed := array_append(v_changed, 'display_phone'); end if;
  end if;
  if p ? 'phone_number_id' then
    if nullif(btrim(coalesce(p->>'phone_number_id', '')), '') is not null and btrim(p->>'phone_number_id') !~ '^\d{5,30}$' then raise exception 'VALIDATION: phone_number_id'; end if;
    if nullif(btrim(p->>'phone_number_id'), '') is distinct from c.phone_number_id then
      if exists (select 1 from branch_whatsapp_channels where phone_number_id = btrim(p->>'phone_number_id') and branch_id <> p_branch) then
        raise exception 'VALIDATION: phone_number_id already used by another branch';
      end if;
      c.phone_number_id := nullif(btrim(p->>'phone_number_id'), ''); v_changed := array_append(v_changed, 'phone_number_id');
    end if;
  end if;
  if p ? 'waba_id' and nullif(btrim(p->>'waba_id'), '') is distinct from c.waba_id then
    if nullif(btrim(coalesce(p->>'waba_id', '')), '') is not null and btrim(p->>'waba_id') !~ '^\d{5,30}$' then raise exception 'VALIDATION: waba_id'; end if;
    c.waba_id := nullif(btrim(p->>'waba_id'), ''); v_changed := array_append(v_changed, 'waba_id');
  end if;
  if p ? 'otp_template' and nullif(lower(btrim(p->>'otp_template')), '') is distinct from c.otp_template then
    c.otp_template := nullif(lower(btrim(p->>'otp_template')), ''); v_changed := array_append(v_changed, 'otp_template');
  end if;
  if p ? 'template_lang' and coalesce(nullif(btrim(p->>'template_lang'), ''), 'ar') <> c.template_lang then
    c.template_lang := coalesce(nullif(btrim(p->>'template_lang'), ''), 'ar'); v_changed := array_append(v_changed, 'template_lang');
  end if;
  if v_token is not null then
    if length(v_token) < 20 or v_token ~ '\s' then raise exception 'VALIDATION: access_token'; end if;
    c.access_token_encrypted := pgp_sym_encrypt(v_token, fn_secret('keybox_key')); c.token_last4 := right(v_token, 4);
    v_changed := array_append(v_changed, 'access_token');
  elsif coalesce((p->>'clear_access_token')::boolean, false) then
    c.access_token_encrypted := null; c.token_last4 := null; v_changed := array_append(v_changed, 'access_token_cleared');
  end if;
  if v_secret is not null then
    if length(v_secret) < 16 or v_secret ~ '\s' then raise exception 'VALIDATION: app_secret'; end if;
    c.app_secret_encrypted := pgp_sym_encrypt(v_secret, fn_secret('keybox_key')); v_changed := array_append(v_changed, 'app_secret');
  elsif coalesce((p->>'clear_app_secret')::boolean, false) then
    c.app_secret_encrypted := null; v_changed := array_append(v_changed, 'app_secret_cleared');
  end if;
  if coalesce((p->>'regenerate_verify_token')::boolean, false) then
    c.verify_token := lower(encode(gen_random_bytes(16), 'hex')); v_changed := array_append(v_changed, 'verify_token');
  end if;

  -- reception-computer link: a new key replaces the old one at once (the old program is refused from now on)
  if coalesce((p->>'regenerate_bridge_key')::boolean, false) then
    v_key := 'zb_' || encode(gen_random_bytes(32), 'hex');
    c.bridge_key_hash := encode(digest(v_key, 'sha256'), 'hex'); c.bridge_key_last4 := right(v_key, 4); c.bridge_key_created_at := now();
    c.bridge_status := null; c.bridge_phone := null; c.bridge_name := null; c.bridge_version := null; c.bridge_last_seen := null;
    v_changed := array_append(v_changed, 'bridge_key');
  elsif coalesce((p->>'revoke_bridge_key')::boolean, false) and c.bridge_key_hash is not null then
    c.bridge_key_hash := null; c.bridge_key_last4 := null; c.bridge_key_created_at := null;
    c.bridge_status := null; c.bridge_last_seen := null;
    v_changed := array_append(v_changed, 'bridge_key_revoked');
  end if;
  if p ? 'auto_reply' then
    if jsonb_typeof(p->'auto_reply') <> 'boolean' then raise exception 'VALIDATION: auto_reply'; end if;
    if (p->>'auto_reply')::boolean <> c.auto_reply then c.auto_reply := (p->>'auto_reply')::boolean; v_changed := array_append(v_changed, 'auto_reply'); end if;
  end if;
  if p ? 'human_pause_minutes' then
    if jsonb_typeof(p->'human_pause_minutes') <> 'number' then raise exception 'VALIDATION: human_pause_minutes'; end if;
    v_pause := round((p->>'human_pause_minutes')::numeric);
    if v_pause < 5 or v_pause > 720 then raise exception 'VALIDATION: human_pause_minutes'; end if;
    if v_pause <> c.human_pause_minutes then c.human_pause_minutes := v_pause; v_changed := array_append(v_changed, 'human_pause_minutes'); end if;
  end if;

  -- any change to the connection itself needs a new test (Cloud API) or a new report from the program (bridge)
  if v_changed && array['mode', 'display_phone', 'phone_number_id', 'access_token', 'access_token_cleared', 'app_secret',
                        'app_secret_cleared', 'bridge_key', 'bridge_key_revoked'] then
    c.status := 'configured'; c.last_error := null; c.verified_name := null;
  end if;
  c.status := fn_whatsapp_status(c);
  if p ? 'enabled' and (p->>'enabled')::boolean is distinct from c.enabled then
    if (p->>'enabled')::boolean and c.status = 'not_configured' then
      raise exception 'VALIDATION: channel_incomplete';
    end if;
    c.enabled := (p->>'enabled')::boolean; v_changed := array_append(v_changed, 'enabled');
  end if;
  if c.status = 'not_configured' and c.enabled then c.enabled := false; v_changed := array_append(v_changed, 'disabled_incomplete'); end if;

  update branch_whatsapp_channels set
    mode = c.mode, enabled = c.enabled, display_phone = c.display_phone, phone_number_id = c.phone_number_id, waba_id = c.waba_id,
    access_token_encrypted = c.access_token_encrypted, token_last4 = c.token_last4, app_secret_encrypted = c.app_secret_encrypted,
    verify_token = c.verify_token, otp_template = c.otp_template, template_lang = c.template_lang, status = c.status,
    last_error = c.last_error, verified_name = c.verified_name,
    bridge_key_hash = c.bridge_key_hash, bridge_key_last4 = c.bridge_key_last4, bridge_key_created_at = c.bridge_key_created_at,
    bridge_status = c.bridge_status, bridge_phone = c.bridge_phone, bridge_name = c.bridge_name, bridge_version = c.bridge_version,
    bridge_last_seen = c.bridge_last_seen, auto_reply = c.auto_reply, human_pause_minutes = c.human_pause_minutes,
    updated_by = fn_staff_id(), updated_at = now()
  where branch_id = p_branch;
  -- audited by field name only: no token, secret, verify token or bridge key in the log
  perform fn_audit(v_org, p_branch, fn_staff_id(), 'whatsapp_channel_updated', 'branch', p_branch,
    jsonb_build_object('changed', to_jsonb(v_changed), 'mode', c.mode, 'enabled', c.enabled, 'status', c.status,
                       'auto_reply', c.auto_reply, 'display_phone_last4', right(c.display_phone, 4), 'reason', nullif(p->>'reason', '')));
  -- the bridge key is returned this once (for bridge-config.json) and never again
  return jsonb_build_object('ok', true, 'status', c.status, 'enabled', c.enabled, 'mode', c.mode, 'changed', to_jsonb(v_changed))
      || case when v_key is null then '{}'::jsonb else jsonb_build_object('bridge_key', v_key) end;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_ai_ops_context(p_branch uuid, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare ctx jsonb; strip text[] := array['balance_due','deposit_balance','payment_status'];
begin
  ctx := fn_ai_ops_context_at(p_branch, coalesce(p_date, fn_branch_today(p_branch)));
  if ctx is null or fn_sees_money() then return ctx; end if;
  ctx := ctx - 'in_house_with_balance' - 'checked_out_with_deposit';
  ctx := jsonb_set(ctx, '{summary}', (ctx->'summary') - 'finance');
  ctx := jsonb_set(ctx, '{arrivals}', coalesce((select jsonb_agg(e - strip) from jsonb_array_elements(ctx->'arrivals') e), '[]'::jsonb));
  ctx := jsonb_set(ctx, '{departures}', coalesce((select jsonb_agg(e - strip) from jsonb_array_elements(ctx->'departures') e), '[]'::jsonb));
  ctx := jsonb_set(ctx, '{overstays}', coalesce((select jsonb_agg(e - strip) from jsonb_array_elements(ctx->'overstays') e), '[]'::jsonb));
  return ctx;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_audit_list(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q jsonb := coalesce(p, '{}'::jsonb); org uuid := fn_user_org_id(); tz text; lim int; off int; is_owner boolean; is_mgmt boolean;
        v_from date; v_to date; v_branch uuid; v_actor uuid; v_action text; v_prefix boolean; v_entity text; v_entity_id uuid; v_corr text; v_cat text; v_result text; v_q text; v_source text;
        total bigint; rows jsonb;
begin
  perform fn_require_cap('audit.log');
  is_owner := fn_has_role('owner'); is_mgmt := fn_cap_full('audit.log');
  v_branch := (q->>'branch_id')::uuid;
  if v_branch is not null then perform fn_require_branch(v_branch); end if;
  tz := coalesce((select timezone from branches where id = v_branch), (select timezone from branches where organization_id = org order by created_at limit 1), 'Asia/Riyadh');
  v_from := (q->>'from')::date; v_to := (q->>'to')::date;
  if v_from is not null and v_to is not null and v_to < v_from then raise exception 'VALIDATION: period'; end if;
  v_actor := (q->>'actor_id')::uuid; v_action := nullif(q->>'action', ''); v_prefix := coalesce((q->>'action_prefix')::boolean, false);
  v_entity := nullif(q->>'entity_type', ''); v_entity_id := (q->>'entity_id')::uuid; v_corr := nullif(q->>'correlation_id', '');
  v_cat := nullif(q->>'category', ''); v_result := nullif(q->>'result', ''); v_q := nullif(trim(coalesce(q->>'q', '')), ''); v_source := nullif(q->>'source', '');
  lim := least(greatest(coalesce((q->>'limit')::int, 50), 1), 500); off := greatest(coalesce((q->>'offset')::int, 0), 0);

  with x as (
    select e.* from audit_events e
    where e.organization_id = org
      and (e.category <> 'security' or fn_can('security'))
      and (is_owner or e.branch_id is null or e.branch_id in (select fn_user_branch_ids()))
      and (v_branch is null or e.branch_id = v_branch)
      and (v_from is null or (e.created_at at time zone tz)::date >= v_from)
      and (v_to is null or (e.created_at at time zone tz)::date <= v_to)
      and (v_actor is null or e.actor_id = v_actor)
      and (v_action is null or (v_prefix and e.action like v_action || '%') or (not v_prefix and e.action = v_action))
      and (v_entity is null or e.entity_type = v_entity)
      and (v_entity_id is null or e.entity_id = v_entity_id)
      and (v_corr is null or e.correlation_id = v_corr)
      and (v_cat is null or e.category = v_cat)
      and (v_result is null or e.result = v_result)
      and (v_source is null or e.source = v_source)
      and (v_q is null or e.action ilike '%' || v_q || '%' or coalesce(e.entity_type, '') ilike '%' || v_q || '%' or coalesce(e.correlation_id, '') = v_q
           or fn_audit_action_label(e.action) ilike '%' || v_q || '%' or coalesce(e.entity_id::text, '') = v_q)
  )
  select count(*), coalesce((select jsonb_agg(jsonb_build_object(
           'id', y.id, 'created_at', y.created_at, 'action', y.action, 'action_label', fn_audit_action_label(y.action),
           'entity_type', y.entity_type, 'entity_label', fn_audit_entity_label(y.entity_type), 'entity_id', y.entity_id, 'entity_ref', fn_audit_entity_ref(y.entity_type, y.entity_id),
           'actor_id', y.actor_id, 'actor_name', case when y.actor_id is not null then (select full_name from staff_profiles where id = y.actor_id)
                                                      when y.actor_type = 'guest' then 'ضيف' when y.actor_type = 'user' then 'مستخدم' else 'النظام' end,
           'actor_type', y.actor_type, 'source', y.source, 'result', y.result, 'category', y.category, 'correlation_id', y.correlation_id,
           'branch_id', y.branch_id, 'branch_name', (select name_ar from branches where id = y.branch_id),
           'reason', y.details->>'reason', 'details', case when is_mgmt then y.details end) order by y.created_at desc, y.id desc)
         from (select * from x order by created_at desc, id desc limit lim offset off) y), '[]'::jsonb)
    into total, rows from x;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', lim, 'offset', off, 'tz', tz);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_cancel_voucher(p_voucher uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v financial_vouchers%rowtype; r reservations%rowtype; f jsonb;
begin
  perform fn_require_cap('voucher.cancel');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into v from financial_vouchers where id = p_voucher;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = v.reservation_id for update;
  perform fn_require_branch(v.branch_id);
  select * into v from financial_vouchers where id = v.id for update;
  if v.status <> 'approved' then raise exception 'VOUCHER_STATUS_INVALID'; end if;
  if v.payout_id is not null then raise exception 'VOUCHER_IN_PAYOUT'; end if;
  update financial_vouchers set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = p_reason where id = v.id;
  f := fn_reservation_finance_internal(r.id);
  if (f->>'deposit_balance')::bigint < 0 or ((f->>'received')::bigint - (f->>'refunded')::bigint) < 0 then
    raise exception 'CANCEL_WOULD_GO_NEGATIVE';
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(v.branch_id, 'voucher_cancelled', 'voucher', v.id, r.id, 'إلغاء السند ' || v.number, p_reason,
    jsonb_build_object('number', v.number, 'kind', v.kind, 'amount_halalas', v.amount_halalas, 'method', v.method));
  perform fn_audit_change(v.branch_id, 'voucher.cancelled', 'voucher', v.id, jsonb_build_object('status', 'approved'),
    jsonb_build_object('status', 'cancelled', 'number', v.number, 'amount_halalas', v.amount_halalas), p_reason);
  return jsonb_build_object('ok', true, 'finance', f, 'provider_refund_note', 'إلغاء السند محلي؛ لا يعني أن مزود الدفع ردّ المبلغ.');
end $function$;

CREATE OR REPLACE FUNCTION public.fn_category_capacity_impact(p_category uuid, p_max_capacity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c room_categories%rowtype;
begin
  perform fn_require_cap('definitions');
  select * into c from room_categories where id = p_category;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(c.branch_id);
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'check_in', r.check_in, 'check_out', r.check_out,
                                                       'guests', r.adults + r.companions, 'status', r.status) order by r.check_in)
                   from reservations r
                   where r.room_category_id = c.id and r.status in ('pending_verification', 'confirmed', 'checked_in')
                     and r.check_out > fn_branch_today(c.branch_id) and r.adults + r.companions > p_max_capacity), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_check_discount(p_category uuid, p_branch uuid, p_nights integer, p_rent bigint, p_existing bigint, p_new bigint, p_after_arrival boolean)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bp int; mn bigint;
begin
  if coalesce(p_new, 0) <= 0 then return; end if;
  if coalesce(p_existing, 0) + p_new > p_rent then raise exception 'VALIDATION: discount_exceeds_rent'; end if;
  if fn_can('disc.after') then return; end if;
  if not fn_can('disc.before') then raise exception 'FORBIDDEN: discount'; end if;
  if p_after_arrival then raise exception 'FORBIDDEN: post-arrival discount'; end if;
  select supervisor_max_discount_bp into bp from branches where id = p_branch;
  if coalesce(p_existing, 0) + p_new > floor(p_rent::numeric * coalesce(bp, 0) / 10000) then raise exception 'VALIDATION: discount_percent'; end if;
  select min_nightly_halalas into mn from room_categories where id = p_category;
  if mn is not null and p_rent - coalesce(p_existing, 0) - p_new < mn * p_nights then raise exception 'VALIDATION: discount_minimum'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_conversation_take(p_conversation uuid, p_take boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare cv conversations%rowtype; v_org uuid; v_pause int; v_until timestamptz;
begin
  perform fn_require_cap('conversation.take');
  select * into cv from conversations where id = p_conversation for update;
  if not found then raise exception 'NOT_FOUND: conversation'; end if;
  if cv.branch_id is not null and cv.branch_id not in (select fn_user_branch_ids()) then raise exception 'FORBIDDEN: branch'; end if;
  v_org := coalesce((select organization_id from branches where id = cv.branch_id), fn_user_org_id());
  if v_org is distinct from fn_user_org_id() then raise exception 'FORBIDDEN: branch'; end if;
  if p_take then
    select human_pause_minutes into v_pause from branch_whatsapp_channels where branch_id = cv.branch_id;
    v_until := case when cv.channel = 'whatsapp' then now() + make_interval(mins => coalesce(v_pause, 60)) end;
    update conversations set status = 'handed_off', handed_off_at = coalesce(handed_off_at, now()),
           human_active_until = coalesce(v_until, human_active_until) where id = cv.id;
  else
    update conversations set status = 'active', handed_off_at = null, human_active_until = null where id = cv.id;
  end if;
  perform fn_audit(v_org, cv.branch_id, fn_staff_id(), case when p_take then 'conversation_taken' else 'conversation_returned_to_assistant' end,
    'conversation', cv.id, jsonb_build_object('before', cv.status, 'after', case when p_take then 'handed_off' else 'active' end, 'channel', cv.channel));
  return jsonb_build_object('ok', true, 'status', case when p_take then 'handed_off' else 'active' end,
                            'human_active_until', case when p_take then coalesce(v_until, cv.human_active_until) end);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_create_voucher(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; prefix text; m text := p->>'method'; ref text; acc uuid;
begin
  if kind not in ('receipt', 'deposit') then raise exception 'VALIDATION: kind'; end if;
  perform fn_require_cap('voucher.receipt');
  amt := fn_parse_halalas(p->>'amount_halalas');
  if coalesce(trim(key), '') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  if m is null then raise exception 'VALIDATION: method'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- serialises money ops per reservation
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  -- the requested content (a replay with the same key must ask for exactly the same thing)
  h := md5(r.id::text || kind || amt::text || m || coalesce(p->>'reference', '') || coalesce(p->>'account_id', ''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;   -- F08
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if not fn_payment_method_active(m) then raise exception 'VALIDATION: method_retired'; end if;
  -- the deposit is held and returned by the property itself; a platform never collects it (decisions 24, 33)
  if kind = 'deposit' and m = 'ota_deferred' then raise exception 'VALIDATION: deposit_method'; end if;
  if r.status in ('cancelled', 'rejected', 'no_show') and kind = 'deposit' then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  ref := fn_check_payment_reference(m, p->>'reference');
  acc := fn_voucher_account(r.branch_id, m, (p->>'account_id')::uuid);
  prefix := case kind when 'receipt' then 'RCP' else 'DEP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc, 'approved',
          ref, p->>'note', p->>'reason', key, h, coalesce((p->>'occurred_at')::timestamptz, now()), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', v.method, 'account_id', acc, 'reference', v.reference, 'reservation_id', r.id));
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_definition_dependencies(p_entity text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d jsonb := '{}'::jsonb; v_branch uuid;
begin
  perform fn_require_cap('definitions');
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
        'tasks', (select count(*) from housekeeping_tasks where branch_id = p_id),
        'pos_settlements', (select count(*) from pos_settlements where branch_id = p_id),
        'platform_payouts', (select count(*) from platform_payouts where branch_id = p_id),
        'rate_calendar', (select count(*) from rate_calendar where branch_id = p_id and (price_halalas is not null or platform_price_halalas is not null)));
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
        'released_slots', (select count(*) from released_slots where category_id = p_id),
        'rate_calendar', (select count(*) from rate_calendar where category_id = p_id and (price_halalas is not null or platform_price_halalas is not null)));
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_discount_allowance(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; rent bigint; n int; disc bigint; bp int; mn bigint; mx bigint; after_arrival boolean;
begin
  perform fn_require_any_cap(array['disc.before', 'disc.after']);
  select * into r from reservations where id = p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select coalesce(sum(price_halalas), 0), count(*) into rent, n from reservation_nights where reservation_id = r.id and status = 'active';
  if n = 0 then rent := r.rent_amount_halalas; n := r.check_out - r.check_in; end if;
  disc := coalesce((select sum(round(abs(quantity * unit_price_halalas)))::bigint from reservation_charges where reservation_id = r.id and kind = 'discount'), 0);
  after_arrival := r.status in ('checked_in', 'checked_out');
  select supervisor_max_discount_bp into bp from branches where id = r.branch_id;
  select min_nightly_halalas into mn from room_categories where id = r.room_category_id;
  if fn_can('disc.after') then mx := greatest(0, rent - disc);
  elsif after_arrival or r.status not in ('confirmed', 'pending_verification') then mx := 0;
  else mx := greatest(0, least(floor(rent::numeric * bp / 10000)::bigint - disc, rent - disc - coalesce(mn * n, 0)));
  end if;
  return jsonb_build_object('rent', rent, 'discounts', disc, 'nights', n, 'after_arrival', after_arrival, 'max', mx,
                            'percent_bp', bp, 'min_nightly', mn, 'unlimited', fn_can('disc.after'));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_guest_ban(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare gp guest_profiles%rowtype; b guest_bans%rowtype; v_ban boolean := (p->>'ban')::boolean; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        v_branch uuid; v_phones text[]; v_fps text[];
begin
  perform fn_require_cap('guest.ban');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_guest_rate(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare gp guest_profiles%rowtype; v_rating smallint; v_note text := nullif(trim(coalesce(p->>'note', '')), '');
begin
  perform fn_require_cap('guest.rate');
  begin v_rating := nullif(p->>'rating', '')::smallint; exception when others then raise exception 'VALIDATION: rating'; end;
  if v_rating is not null and (v_rating < 1 or v_rating > 5) then raise exception 'VALIDATION: rating'; end if;
  if length(coalesce(v_note, '')) > 500 then raise exception 'VALIDATION: note'; end if;
  select * into gp from guest_profiles where id = (p->>'profile_id')::uuid and organization_id = fn_user_org_id() for update;
  if not found or not fn_profile_visible(gp.id) then raise exception 'NOT_FOUND'; end if;
  update guest_profiles set rating = v_rating, rating_note = v_note, rated_by = fn_staff_id(), rated_at = now(), updated_at = now() where id = gp.id;
  perform fn_audit_change(null, 'guest.rated', 'guest_profile', gp.id, jsonb_build_object('rating', gp.rating, 'note', gp.rating_note),
                          jsonb_build_object('rating', v_rating, 'note', v_note));
  return jsonb_build_object('ok', true, 'rating', v_rating);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_hk_assign_task(p_task uuid, p_assignee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_cap('task.manage');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  if p_assignee is not null and not fn_is_member(p_assignee, t.branch_id) then raise exception 'ASSIGNEE_NOT_IN_BRANCH'; end if;
  update housekeeping_tasks set assignee_id = p_assignee, version = version + 1, updated_at = now() where id = t.id;
  perform fn_audit_change(t.branch_id, 'task.assigned', 'housekeeping_task', t.id, jsonb_build_object('assignee_id', t.assignee_id), jsonb_build_object('assignee_id', p_assignee));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_hk_cancel_task(p_task uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_cap('task.manage');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_hk_complete_task(p_task uuid, p_note text DEFAULT NULL::text, p_expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t housekeeping_tasks%rowtype; st room_status; is_cleaning boolean; occ text;
begin
  perform fn_require_cap('task.work');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  perform fn_check_version_strict(t.version, p_expected_version);
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_hk_create_task(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t housekeeping_tasks%rowtype; v_room uuid := (p->>'room_id')::uuid; v_fac uuid := (p->>'facility_id')::uuid; v_branch uuid; tt task_types%rowtype; v_assignee uuid := (p->>'assignee_id')::uuid;
        v_start timestamptz := coalesce((p->>'scheduled_start')::timestamptz, now()); v_end timestamptz := (p->>'scheduled_end')::timestamptz;
begin
  perform fn_require_cap('task.work');
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
  if v_assignee is not null and not fn_is_member(v_assignee, v_branch) then raise exception 'ASSIGNEE_NOT_IN_BRANCH'; end if;   -- H02
  if v_end is not null and v_end < v_start then raise exception 'VALIDATION: schedule'; end if;                                  -- decision 28
  insert into housekeeping_tasks(organization_id, branch_id, room_id, facility_id, task_type_id, task_type_name_snapshot, reservation_id, priority, assignee_id, scheduled_start, scheduled_end, description, created_by)
  values (fn_user_org_id(), v_branch, v_room, v_fac, tt.id, tt.name, (p->>'reservation_id')::uuid, coalesce(p->>'priority','medium'), v_assignee,
          v_start, v_end, p->>'description', fn_staff_id()) returning * into t;
  if v_room is not null and tt.code = 'room_cleaning' then update rooms set cleanliness = 'dirty' where id = v_room and cleanliness = 'clean'; perform fn_recompute_room_ready(v_room); end if;
  perform fn_audit_change(v_branch, 'task.created', 'housekeeping_task', t.id, null, to_jsonb(t));
  return jsonb_build_object('ok', true, 'id', t.id);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_hk_set_cleanliness(p_room uuid, p_state text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rm rooms%rowtype; st room_status;
begin
  perform fn_require_cap('cleanliness');
  if p_state is null or p_state not in ('clean','dirty') then raise exception 'VALIDATION: cleanliness'; end if;
  select * into rm from rooms where id = p_room for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  update rooms set cleanliness = p_state, updated_at = now() where id = p_room;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit_change(rm.branch_id, 'room.cleanliness_changed', 'room', p_room, jsonb_build_object('cleanliness', rm.cleanliness),
    jsonb_build_object('cleanliness', p_state, 'open_cleaning_task', exists (select 1 from housekeeping_tasks h join task_types t on t.id = h.task_type_id
                                                                            where h.room_id = p_room and h.status in ('pending','in_progress') and t.code = 'room_cleaning')), p_reason);
  return jsonb_build_object('ok', true, 'room_status', (select status from rooms where id = p_room));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_hk_start_task(p_task uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_cap('task.work');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  if t.status <> 'pending' then raise exception 'TASK_STATUS_INVALID'; end if;
  if fn_has_role('housekeeping') and t.assignee_id is not null and t.assignee_id <> fn_staff_id() then raise exception 'FORBIDDEN: not assignee'; end if;
  update housekeeping_tasks set status = 'in_progress', started_at = now(), assignee_id = coalesce(assignee_id, fn_staff_id()), version = version + 1, updated_at = now() where id = t.id;
  if t.room_id is not null and t.task_type_id in (select id from task_types where code = 'room_cleaning') then update rooms set cleanliness = 'in_progress' where id = t.room_id; end if;
  perform fn_audit_change(t.branch_id, 'task.started', 'housekeeping_task', t.id, null, null);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_invoice_preview(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; inv invoices%rowtype; pf date := nullif(p->>'from', '')::date; pt date := nullif(p->>'to', '')::date;
        lines jsonb; sub bigint; tax bigint; n int; problems text[] := '{}'; scope text; gname text;
begin
  perform fn_require_cap('invoice.issue');
  if p ? 'invoice_id' and nullif(p->>'invoice_id', '') is not null then
    select * into inv from invoices where id = (p->>'invoice_id')::uuid;
    if not found then raise exception 'NOT_FOUND'; end if;
    select * into r from reservations where id = inv.reservation_id;
    scope := inv.scope;
    if scope = 'period' then pf := coalesce(pf, inv.period_from); pt := coalesce(pt, inv.period_to); else pf := null; pt := null; end if;
  else
    select * into r from reservations where id = (p->>'reservation_id')::uuid;
    if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
    if (pf is null) <> (pt is null) then raise exception 'VALIDATION: period'; end if;
    scope := case when pf is null then 'remaining' else 'period' end;
  end if;
  perform fn_require_branch(r.branch_id);
  if scope = 'period' then
    if pt <= pf then problems := array_append(problems, 'نهاية الفترة يجب أن تكون بعد بدايتها');
    elsif exists (select 1 from invoices i where i.reservation_id = r.id and i.status = 'issued' and i.scope = 'period'
                                           and (inv.id is null or i.id <> inv.id) and i.period_from < pt and pf < i.period_to) then
      problems := array_append(problems, 'فاتورة أخرى لهذا الحجز تغطي جزءًا من الفترة');
    end if;
  end if;
  if coalesce(array_length(problems, 1), 0) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object('charge_id', s.charge_id, 'kind', s.kind, 'description', s.description, 'quantity', s.quantity,
                                                 'unit_price_halalas', s.unit_price_halalas, 'total_halalas', s.total_halalas,
                                                 'invoiced_halalas', s.invoiced_halalas, 'amount_halalas', s.share_halalas,
                                                 'service_from', s.service_from, 'service_to', s.service_to) order by s.created_at, s.kind = 'tax', s.charge_id), '[]'::jsonb),
           coalesce(sum(s.share_halalas) filter (where s.kind <> 'tax'), 0), coalesce(sum(s.share_halalas) filter (where s.kind = 'tax'), 0), count(*)
      into lines, sub, tax, n
      from fn_invoice_shares(r.id, case when scope = 'period' then pf end, case when scope = 'period' then pt end, inv.id) s;
    if n = 0 then problems := array_append(problems, 'لا شيء لم يُفوتر في هذه الفترة');
    elsif sub + tax <= 0 then problems := array_append(problems, 'ما بقي يخفّض الفاتورة فقط؛ يُضاف إلى فاتورة صادرة بتعديلها'); end if;
  end if;
  select full_name into gname from reservation_guests where reservation_id = r.id and is_primary limit 1;
  return jsonb_build_object('ok', coalesce(array_length(problems, 1), 0) = 0, 'problems', to_jsonb(problems), 'scope', scope, 'from', pf, 'to', pt,
                            'lines', coalesce(lines, '[]'::jsonb), 'subtotal_halalas', coalesce(sub, 0), 'tax_halalas', coalesce(tax, 0),
                            'total_halalas', coalesce(sub, 0) + coalesce(tax, 0),
                            'reservation', jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref, 'guest', gname,
                                                              'check_in', r.check_in, 'check_out', r.check_out, 'status', r.status),
                            'uninvoiced_halalas', fn_uninvoiced_value(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_keybox_alerts(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform fn_require_cap('keybox.code');
  perform fn_require_branch(p_branch);
  return (
    select jsonb_build_object('count', count(*), 'oldest_since', min(kb.needs_change_since),
             'rooms', coalesce(jsonb_agg(rm.room_number order by kb.needs_change_since nulls last, rm.room_number), '[]'::jsonb))
      from keyboxes kb join rooms rm on rm.id = kb.room_id
     where kb.branch_id = p_branch and rm.archived_at is null and rm.is_active
       and (kb.code_status <> 'active' or kb.code_encrypted is null));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_keybox_board(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_full boolean;
begin
  perform fn_require_cap('keybox.code');
  perform fn_require_branch(p_branch);
  v_full := fn_has_role('owner','manager','supervisor');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'room_id', u.id, 'room_number', u.room_number, 'block', u.block_name, 'floor', u.floor_name,
             'room_status', u.status, 'cleanliness', u.cleanliness, 'guest_in_house', u.in_house,
             'state', u.state, 'has_code', u.has_code, 'code_version', u.code_version, 'field_tested', u.field_tested,
             'needs_change_since', u.needs_change_since, 'last_changed_at', u.last_changed_at, 'last_changed_by', u.changed_by,
             'can_change', v_full or not u.in_house,
             'can_view', u.has_code and (v_full or not u.in_house))
           order by u.room_number)
    from (
      select rm.id, rm.room_number, b.name as block_name, f.name as floor_name, rm.status, rm.cleanliness,
             fn_room_guest_in_house(rm.id) as in_house,
             case when kb.id is null then 'none'
                  when kb.code_status <> 'active' or kb.code_encrypted is null then 'change'
                  when not kb.field_tested then 'untested'
                  else 'ok' end as state,
             kb.code_encrypted is not null as has_code, kb.code_version, coalesce(kb.field_tested, false) as field_tested,
             kb.needs_change_since, kb.last_changed_at, s.full_name as changed_by
        from rooms rm
        left join keyboxes kb on kb.room_id = rm.id
        left join blocks b on b.id = rm.block_id
        left join floors f on f.id = rm.floor_id
        left join staff_profiles s on s.id = kb.last_changed_by
       where rm.branch_id = p_branch and rm.archived_at is null and rm.is_active
    ) u), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_keybox_reveal(p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare rm rooms%rowtype; kb keyboxes%rowtype; v_in_house boolean;
begin
  perform fn_require_cap('keybox.code');
  select * into rm from rooms where id = p_room and archived_at is null;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  v_in_house := fn_room_guest_in_house(p_room);
  if v_in_house and not fn_has_role('owner','manager','supervisor') then
    raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
  end if;
  select * into kb from keyboxes where room_id = p_room limit 1;
  if not found or kb.code_encrypted is null then raise exception 'NO_KEYBOX_CODE'; end if;
  perform fn_audit_change(rm.branch_id, 'keybox.code_viewed', 'room', p_room, null,
    jsonb_build_object('code_version', kb.code_version, 'code_status', kb.code_status, 'guest_in_house', v_in_house), null);
  return jsonb_build_object('ok', true, 'code', pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key')), 'code_version', kb.code_version);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_platform_payout_cancel(p_payout uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare pay platform_payouts%rowtype; before jsonb;
begin
  perform fn_require_cap_full('platform.payouts');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into pay from platform_payouts where id = p_payout for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(pay.branch_id);
  if pay.status <> 'confirmed' then raise exception 'VALIDATION: payout_status'; end if;
  before := to_jsonb(pay);
  update financial_vouchers set payout_id = null where payout_id = pay.id;
  update platform_payouts set status = 'cancelled', cancelled_by = fn_staff_id(), cancelled_at = now(), cancel_reason = p_reason where id = pay.id returning * into pay;
  perform fn_audit_change(pay.branch_id, 'platform.payout_cancelled', 'platform_payout', pay.id, before, to_jsonb(pay), p_reason);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_platform_payout_confirm(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_source uuid := (p->>'source_id')::uuid; ids uuid[]; n int; good int; expected bigint; received bigint;
        acc uuid; pay platform_payouts%rowtype; v_note text := nullif(trim(coalesce(p->>'note', '')), ''); v_ref text := nullif(trim(coalesce(p->>'reference', '')), '');
begin
  perform fn_require_cap('platform.payouts');
  perform fn_require_branch(v_branch);
  ids := array(select (x)::uuid from jsonb_array_elements_text(coalesce(p->'voucher_ids', '[]'::jsonb)) x);
  n := coalesce(array_length(ids, 1), 0);
  if n = 0 then raise exception 'VALIDATION: vouchers'; end if;
  received := fn_parse_halalas(p->>'received_halalas');
  if v_ref is null then raise exception 'VALIDATION: reference_required'; end if;
  if (p->>'received_on') is null or (p->>'received_on')::date > fn_branch_today(v_branch) then raise exception 'VALIDATION: received_on'; end if;
  acc := fn_voucher_account(v_branch, 'bank_transfer', (p->>'account_id')::uuid);
  -- lock the vouchers; every one must be an unmatched deferred payment of this branch and platform
  perform 1 from financial_vouchers where id = any(ids) for update;
  select count(*), coalesce(sum(case when v.kind = 'receipt' then v.amount_halalas else -v.amount_halalas end), 0) into good, expected
  from financial_vouchers v join reservations r on r.id = v.reservation_id
  where v.id = any(ids) and v.branch_id = v_branch and v.method = 'ota_deferred' and v.status = 'approved' and v.payout_id is null
    and v.kind in ('receipt', 'refund') and r.source_id = v_source;
  if good <> n then raise exception 'VALIDATION: payout_vouchers'; end if;
  if received <> expected and v_note is null then raise exception 'VALIDATION: note_required'; end if;   -- e.g. the platform's commission
  insert into platform_payouts(organization_id, branch_id, source_id, account_id, expected_halalas, received_halalas, difference_halalas, voucher_count, received_on, reference, note, created_by)
  values ((select organization_id from branches where id = v_branch), v_branch, v_source, acc, expected, received, received - expected, n, (p->>'received_on')::date, v_ref, v_note, fn_staff_id())
  returning * into pay;
  update financial_vouchers set payout_id = pay.id where id = any(ids);
  perform fn_audit_change(v_branch, 'platform.payout_confirmed', 'platform_payout', pay.id, null, to_jsonb(pay), v_note);
  return jsonb_build_object('ok', true, 'payout', to_jsonb(pay));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_platform_unsettled(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform fn_require_cap('platform.payouts');
  perform fn_require_branch(p_branch);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', v.id, 'number', v.number, 'kind', v.kind, 'amount_halalas', v.amount_halalas,
                                        'signed_halalas', case when v.kind = 'receipt' then v.amount_halalas else -v.amount_halalas end,
                                        'occurred_at', v.occurred_at, 'reservation_id', r.id, 'internal_ref', r.internal_ref, 'external_ref', r.external_ref,
                                        'check_in', r.check_in, 'source_id', r.source_id, 'source_name', s.name) order by s.name, v.occurred_at)
    from financial_vouchers v join reservations r on r.id = v.reservation_id left join booking_sources s on s.id = r.source_id
    where v.branch_id = p_branch and v.method = 'ota_deferred' and v.status = 'approved' and v.payout_id is null and v.kind in ('receipt', 'refund')), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_pos_settle(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_account uuid := (p->>'account_id')::uuid; v_date date := (p->>'business_date')::date;
        a cash_accounts%rowtype; s pos_settlements%rowtype; t jsonb; terminal bigint; sys bigint; diff bigint; v_note text := nullif(trim(coalesce(p->>'note', '')), ''); before jsonb;
begin
  perform fn_require_cap('pos.settle');
  perform fn_require_branch(v_branch);
  select * into a from cash_accounts where id = v_account and branch_id = v_branch and kind = 'bank_account';
  if not found then raise exception 'BRANCH_MISMATCH: account'; end if;
  if v_date is null or v_date > fn_branch_today(v_branch) then raise exception 'VALIDATION: business_date'; end if;
  if (p->>'terminal_total_halalas') is null or (p->>'terminal_total_halalas') !~ '^-?[0-9]{1,15}$' then raise exception 'VALIDATION: amount'; end if;
  terminal := (p->>'terminal_total_halalas')::bigint;
  t := fn_pos_day_total(v_branch, v_account, v_date);
  sys := (t->>'system_total_halalas')::bigint;
  diff := terminal - sys;
  if diff <> 0 and v_note is null then raise exception 'VALIDATION: note_required'; end if;   -- a difference is always explained
  select * into s from pos_settlements where account_id = v_account and business_date = v_date for update;
  if found then
    perform fn_check_version_strict(s.version, (p->>'version')::int);
    before := to_jsonb(s);
    update pos_settlements set terminal_total_halalas = terminal, system_total_halalas = sys, difference_halalas = diff,
      voucher_count = (t->>'voucher_count')::int, status = case when diff = 0 then 'matched' else 'difference' end, note = v_note,
      version = version + 1, updated_by = fn_staff_id(), updated_at = now()
    where id = s.id returning * into s;
  else
    insert into pos_settlements(organization_id, branch_id, account_id, business_date, terminal_total_halalas, system_total_halalas, difference_halalas, voucher_count, status, note, created_by, updated_by)
    values (a.organization_id, v_branch, v_account, v_date, terminal, sys, diff, (t->>'voucher_count')::int, case when diff = 0 then 'matched' else 'difference' end, v_note, fn_staff_id(), fn_staff_id())
    returning * into s;
  end if;
  perform fn_audit_change(v_branch, 'pos.settled', 'pos_settlement', s.id, before, to_jsonb(s), v_note);
  return jsonb_build_object('ok', true, 'settlement', to_jsonb(s));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_pos_settlement_preview(p_branch uuid, p_account uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a cash_accounts%rowtype; s pos_settlements%rowtype;
begin
  perform fn_require_cap('pos.settle');
  perform fn_require_branch(p_branch);
  select * into a from cash_accounts where id = p_account and branch_id = p_branch and kind = 'bank_account';
  if not found then raise exception 'BRANCH_MISMATCH: account'; end if;
  select * into s from pos_settlements where account_id = p_account and business_date = p_date;
  return fn_pos_day_total(p_branch, p_account, p_date) || jsonb_build_object('settlement', case when s.id is null then null else to_jsonb(s) end);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_purge_validate(p_branch uuid, p_from date, p_to date, p_cats text[])
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_cats text[];
begin
  perform fn_require_cap('security');
  if p_from is null or p_to is null or p_from > p_to then raise exception 'VALIDATION: period'; end if;
  if p_to > fn_branch_today(coalesce(p_branch, (select id from branches where organization_id = fn_user_org_id() order by created_at limit 1))) then
    raise exception 'VALIDATION: period_after_today';
  end if;
  if p_branch is not null and not exists (select 1 from branches where id = p_branch and organization_id = fn_user_org_id()) then
    raise exception 'NOT_FOUND: branch';
  end if;
  select array_agg(distinct x order by x) into v_cats from unnest(p_cats) x;
  if v_cats is null or cardinality(v_cats) = 0 then raise exception 'VALIDATION: choose_category'; end if;
  if not v_cats <@ fn_purge_categories() then raise exception 'VALIDATION: unknown_category'; end if;
  return v_cats;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_quote_stay(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date;
        c room_categories%rowtype; b branches%rowtype; src booking_sources%rowtype; platform boolean := false;
        ovr bigint := nullif(p->>'nightly_rate_halalas', '')::bigint; disc bigint := coalesce(nullif(p->>'discount_halalas', '')::bigint, 0);
        runs jsonb; x jsonb; n int; rent_gross bigint := 0; rent_net bigint := 0; tax bigint := 0; net bigint; t bigint; disc_net bigint := 0; disc_tax bigint := 0;
        computed bigint; min_total bigint; sup_max bigint; my_max bigint;
begin
  perform fn_require_branch(v_branch);
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if co - ci > 366 then raise exception 'VALIDATION: dates'; end if;
  select * into c from room_categories where id = v_cat and branch_id = v_branch;
  if not found then raise exception 'BRANCH_MISMATCH: category'; end if;
  select * into b from branches where id = v_branch;
  if nullif(p->>'source_id', '') is not null then
    select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id();
    platform := found and src.kind <> 'direct';
  end if;
  if disc < 0 then raise exception 'VALIDATION: amount'; end if;
  n := co - ci;
  runs := fn_stay_runs(v_cat, ci, co, platform, ovr, true);
  for x in select * from jsonb_array_elements(runs) loop
    rent_gross := rent_gross + (x->>'nights')::bigint * (x->>'price')::bigint;
    select * into net, t from fn_apply_tax(v_branch, (x->>'nights')::bigint * (x->>'price')::bigint, true);
    rent_net := rent_net + net; tax := tax + t;
  end loop;
  if disc > rent_gross then raise exception 'VALIDATION: discount_exceeds_rent'; end if;
  if disc > 0 then select * into disc_net, disc_tax from fn_apply_tax(v_branch, -disc, true); end if;
  computed := (select coalesce(sum(s.price_halalas), 0) from fn_stay_prices(v_cat, ci, co, platform, null, true) s);
  min_total := c.min_nightly_halalas * n;
  sup_max := greatest(0, least(floor(rent_gross::numeric * b.supervisor_max_discount_bp / 10000)::bigint, rent_gross - coalesce(min_total, 0)));
  my_max := case when fn_can('disc.after') then rent_gross when fn_can('disc.before') then sup_max else 0 end;
  return jsonb_build_object('nights', n, 'runs', runs, 'channel', case when platform then 'platform' else 'system' end,
    'basis', case when ovr is not null then 'manual' when n >= 30 and c.monthly_price_halalas is not null then 'monthly'
                  when n >= 7 and c.weekly_price_halalas is not null then 'weekly' else 'daily' end,
    'nightly_rate', round(rent_gross::numeric / n)::bigint, 'rent_gross', rent_gross, 'computed_rent', computed,
    'rent', rent_net, 'discount', disc_net, 'tax', tax + disc_tax, 'total', rent_net + disc_net + tax + disc_tax,
    'tax_rate_bp', b.tax_rate_bp, 'prices_include_tax', b.prices_include_tax,
    'min_nightly', c.min_nightly_halalas, 'discount_max', my_max, 'supervisor_discount_max', sup_max,
    'supervisor_max_discount_bp', b.supervisor_max_discount_bp);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_rate_calendar(p_branch uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare today date;
begin
  perform fn_require_cap('rates');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then raise exception 'VALIDATION: range'; end if;
  today := fn_branch_today(p_branch);
  return jsonb_build_object('today', today, 'from', p_from, 'to', p_to,
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name_ar, 'base_price', c.base_price_halalas, 'weekly_price', c.weekly_price_halalas,
        'monthly_price', c.monthly_price_halalas, 'min_nightly', c.min_nightly_halalas, 'price_mode', c.price_mode, 'units', u.total,
        'days', (select jsonb_agg(jsonb_build_object('night', g::date, 'price', rc.price_halalas, 'platform_price', rc.platform_price_halalas,
                   'available', greatest(0, u.total - (select count(*) from reservations r
                                                       where r.room_category_id = c.id and r.status in ('confirmed', 'checked_in')
                                                         and g::date >= r.check_in and g::date < r.check_out))) order by g)
                 from generate_series(p_from, p_to, interval '1 day') g
                 left join rate_calendar rc on rc.category_id = c.id and rc.night = g::date)
      ) order by c.sort_order, c.name_ar)
      from room_categories c
      cross join lateral (select count(*)::int as total from rooms rm where rm.category_id = c.id and rm.archived_at is null and coalesce(rm.is_active, true)) u
      where c.branch_id = p_branch and c.archived_at is null), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_rate_calendar_set(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; today date; cats uuid[]; wd int[]; d0 date := nullif(p->>'from', '')::date; d1 date := nullif(p->>'to', '')::date;
        v_cells jsonb := p->'cells'; v_clear text := case when p->>'clear' = 'true' then 'both' when p->>'clear' in ('price', 'platform') then p->>'clear' end;
        set_p boolean := nullif(p->>'price_halalas', '') is not null; set_pp boolean := nullif(p->>'platform_price_halalas', '') is not null;
        v_p bigint := nullif(p->>'price_halalas', '')::bigint; v_pp bigint := nullif(p->>'platform_price_halalas', '')::bigint;
        x record; old_p bigint; old_pp bigint; new_p bigint; new_pp bigint; n int := 0; seen int := 0; before jsonb := '[]'::jsonb;
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

CREATE OR REPLACE FUNCTION public.fn_refund(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; v financial_vouchers%rowtype; kind text := p->>'kind'; amt bigint; key text := p->>'idempotency_key';
        h text; existing financial_vouchers%rowtype; f jsonb; available bigint; prefix text; m text; ref text; acc uuid; orig uuid; inv_no text;
begin
  if kind is null or kind not in ('refund', 'deposit_refund', 'deposit_apply') then raise exception 'VALIDATION: kind'; end if;
  if kind = 'refund' then perform fn_require_cap('voucher.refund');
  elsif kind = 'deposit_apply' then perform fn_require_cap('deposit.apply');
  else perform fn_require_cap('deposit.refund'); end if;
  amt := fn_parse_halalas(p->>'amount_halalas');
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'VALIDATION: reason'; end if;
  if coalesce(trim(key), '') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  -- applying the deposit to the stay moves money between two balances of the same guest: no method, no account
  m := case when kind = 'deposit_apply' then 'cash' else p->>'method' end;
  if m is null then raise exception 'VALIDATION: method'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;      -- concurrent refunds are serialised here
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  h := md5(r.id::text || kind || amt::text || coalesce(p->>'method', '') || coalesce(p->>'reference', '') || coalesce(p->>'account_id', ''));
  select * into existing from financial_vouchers where organization_id = r.organization_id and idempotency_key = key;
  if found then
    if existing.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;
    if existing.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', existing.number; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  orig := nullif(p->>'original_voucher_id', '')::uuid;
  if orig is not null and not exists (select 1 from financial_vouchers where id = orig and reservation_id = r.id) then raise exception 'VALIDATION: original_voucher'; end if;
  if kind = 'deposit_refund' and (r.actual_check_in is not null or r.status in ('checked_in', 'checked_out', 'closed')) then
    if r.status not in ('checked_out', 'closed') then raise exception 'VALIDATION: deposit_refund_before_checkout'; end if;
    if not exists (select 1 from checkout_inspections i where i.reservation_id = r.id and i.status = 'active') then
      raise exception 'INSPECTION_REQUIRED: record the check-out inspection first';
    end if;
  end if;
  if kind <> 'deposit_apply' then
    if not fn_payment_method_active(m) then raise exception 'VALIDATION: method_retired'; end if;
    if kind = 'deposit_refund' and m = 'ota_deferred' then raise exception 'VALIDATION: deposit_method'; end if;
    ref := fn_check_payment_reference(m, p->>'reference');
    acc := fn_voucher_account(r.branch_id, m, (p->>'account_id')::uuid);
  end if;
  f := fn_reservation_finance_internal(r.id);
  available := case kind when 'refund' then (f->>'received')::bigint - (f->>'refunded')::bigint else (f->>'deposit_balance')::bigint end;
  if amt > available then raise exception 'REFUND_EXCEEDS_AVAILABLE: available % halalas', available; end if;
  if kind = 'deposit_apply' and amt > (f->>'balance_due')::bigint then raise exception 'REFUND_EXCEEDS_AVAILABLE: nothing due'; end if;
  prefix := case kind when 'refund' then 'RFD' when 'deposit_refund' then 'DRF' else 'DAP' end;
  insert into financial_vouchers(organization_id, branch_id, reservation_id, number, kind, amount_halalas, method, account_id, status, reference, note, reason, original_voucher_id, idempotency_key, content_hash, occurred_at, created_by)
  values (r.organization_id, r.branch_id, r.id, fn_next_document_number(r.organization_id, 'voucher', prefix), kind, amt, m::payment_method, acc,
          'approved', ref, p->>'note', p->>'reason', orig, key, h, now(), fn_staff_id()) returning * into v;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'voucher.' || kind || '_created', 'voucher', v.id, null,
    jsonb_build_object('number', v.number, 'amount_halalas', amt, 'method', case when kind = 'deposit_apply' then null else m end, 'account_id', acc, 'reservation_id', r.id, 'available_before', available), p->>'reason');
  if kind in ('deposit_refund', 'deposit_apply') and r.status in ('checked_out', 'closed')
     and (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint = 0 then
    inv_no := fn_auto_invoice(r.id, 'deposit_settled');
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', v.id, 'number', v.number, 'finance', fn_reservation_finance_internal(r.id), 'invoice', inv_no);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reports_capability_usage(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q jsonb := coalesce(p, '{}'::jsonb); org uuid := fn_user_org_id(); weeks int; win_start timestamptz; horizon timestamptz; purge_in_window boolean; now_ts timestamptz := now();
begin
  perform fn_require_cap('reports.identities_usage');
  weeks := least(greatest(coalesce((q->>'weeks')::int, 4), 1), 26);
  win_start := now_ts - make_interval(weeks => weeks);
  select min(created_at) into horizon from audit_events where organization_id = org;
  -- a purge of the log inside the window breaks the measure for everything (the rows may have been there)
  purge_in_window := exists (select 1 from audit_events where organization_id = org and action = 'data_purge_executed' and created_at >= win_start
                               and (details->'categories') ? 'audit');
  return (with ev as (
    select e.action, e.created_at, e.result,
           case when e.actor_type = 'system' or e.source in ('system', 'scheduler') then 'automation'
                when e.source = 'ops_assistant' then 'assistant'
                when e.actor_type = 'guest' then 'guest' else 'human' end as who
    from audit_events e where e.organization_id = org and e.created_at >= win_start - interval '1 year'
  ), cat as (select * from fn_capability_catalog()),
  per as (
    select c.code, c.label, c.area, c.core, c.coverage,
           (select max(created_at) from ev where ev.action = any(c.actions) and ev.result = 'success') as last_success_at,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= now_ts - interval '7 days') as week_count,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start) as window_count,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'human') as by_human,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'assistant') as by_assistant,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'automation') as by_automation,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'guest') as by_guest,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'rejected' and ev.created_at >= win_start) as rejected
    from cat c)
  select jsonb_build_object(
    'weeks', weeks, 'window_start', win_start, 'generated_at', now_ts, 'log_since', horizon,
    'log_covers_window', horizon is not null and horizon <= win_start and not purge_in_window,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'code', code, 'label', label, 'area', area, 'core', core, 'coverage', coverage,
        'last_success_at', last_success_at, 'week_count', week_count, 'window_count', window_count,
        'by', jsonb_build_object('human', by_human, 'assistant', by_assistant, 'automation', by_automation, 'guest', by_guest), 'rejected', rejected,
        'status', case when coverage = 'none' then 'unmeasured'
                       when window_count > 0 then 'used'
                       when coverage = 'partial' or horizon is null or horizon > win_start or purge_in_window then 'undetermined'
                       else 'idle' end) order by area, core desc, label) from per), '[]'::jsonb),
    'other_actions', coalesce((select jsonb_agg(jsonb_build_object('action', action, 'label', fn_audit_action_label(action), 'window_count', n, 'last_at', last_at) order by n desc)
                               from (select action, count(*) n, max(created_at) last_at from ev where created_at >= win_start and result = 'success'
                                       and not exists (select 1 from cat where ev.action = any(cat.actions)) group by action) o), '[]'::jsonb),
    'note', 'القياس من سجل الإجراءات وحده. «غير محسوم»: قدرة لا يسجّل السجل كل مساراتها، أو نافذة لا يغطيها السجل. لا يُحذف شيء آليًا بقلة الاستعمال (القرار 53).'));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reports_discounts(p_branch uuid, p_from date, p_to date, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text; full_view boolean; res jsonb; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_source uuid; v_cat uuid; v_after boolean;
begin
  perform fn_require_cap('reports.finance');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  select timezone into tz from branches where id = p_branch;
  full_view := fn_cap_full('reports.finance');
  v_staff := (f->>'staff_id')::uuid; v_source := (f->>'source_id')::uuid; v_cat := (f->>'category_id')::uuid; v_after := (f->>'after_arrival')::boolean;
  with d as (
    select ch.id, r.id as reservation_id, r.internal_ref, ch.description, ch.reason, round(abs(ch.quantity * ch.unit_price_halalas))::bigint as amount,
           ch.created_at, ch.created_by, sp.full_name as staff_name, sp.role::text as staff_role,
           (r.actual_check_in is not null and ch.created_at >= r.actual_check_in) as after_arrival
    from reservation_charges ch
    join reservations r on r.id = ch.reservation_id
    left join staff_profiles sp on sp.id = ch.created_by
    where ch.branch_id = p_branch and ch.kind = 'discount' and (ch.created_at at time zone tz)::date between p_from and p_to
      and (v_staff is null or ch.created_by = v_staff) and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat)
      and (v_after is null or (r.actual_check_in is not null and ch.created_at >= r.actual_check_in) = v_after)
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to),
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'source_id', v_source, 'category_id', v_cat, 'after_arrival', v_after)),
    'total_halalas', coalesce(sum(amount), 0), 'count', count(*),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', s.staff_name, 'role', s.staff_role, 'count', s.n, 'total_halalas', s.total) order by s.total desc)
                          from (select staff_name, staff_role, count(*) as n, sum(amount) as total from d group by staff_name, staff_role) s), '[]'::jsonb),
    'rows', case when full_view then coalesce((select jsonb_agg(jsonb_build_object('id', d2.id, 'reservation_id', d2.reservation_id, 'internal_ref', d2.internal_ref,
              'amount_halalas', d2.amount, 'reason', coalesce(d2.reason, d2.description), 'staff', d2.staff_name, 'role', d2.staff_role,
              'created_at', d2.created_at, 'after_arrival', d2.after_arrival) order by d2.created_at desc) from d d2), '[]'::jsonb) end)
  into res from d;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reports_finance(p_branch uuid, p_from date, p_to date, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_from date; v_to date; tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_method text; v_account text; v_acc uuid; v_acc_none boolean; v_source uuid; v_cat uuid;
        l record; c record; rs record; open_dep bigint; total_charged bigint; net bigint; v_filtered boolean;
begin
  perform fn_require_cap_full('reports.finance');
  perform fn_require_branch(p_branch);
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_from := coalesce(p_from, fn_branch_today(p_branch) - 29);
  v_to   := coalesce(p_to, fn_branch_today(p_branch));
  if v_to < v_from then raise exception 'VALIDATION: period'; end if;
  v_staff := (f->>'staff_id')::uuid; v_method := nullif(f->>'method', ''); v_account := nullif(f->>'account_id', ''); v_source := (f->>'source_id')::uuid; v_cat := (f->>'category_id')::uuid;
  v_filtered := v_staff is not null or v_method is not null or v_account is not null or v_source is not null or v_cat is not null;
  v_acc_none := v_account = 'none'; v_acc := case when v_account is not null and v_account <> 'none' then v_account::uuid end;

  -- the vouchers of the period that pass the filters (a source or unit-type filter follows the voucher's booking)
  with fv as (
    select v.* from financial_vouchers v
    where v.branch_id = p_branch and v.status = 'approved' and (v.occurred_at at time zone tz)::date between v_from and v_to
      and (v_staff is null or v.created_by = v_staff)
      and (v_method is null or v.method::text = v_method)
      and (v_account is null or (v_acc_none and v.account_id is null) or v.account_id = v_acc)
      and (v_source is null or exists (select 1 from reservations r where r.id = v.reservation_id and r.source_id = v_source))
      and (v_cat is null or exists (select 1 from reservations r where r.id = v.reservation_id and r.room_category_id = v_cat)))
  select coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0)::bigint        as receipts,
         coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint         as refunds,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit'), 0)::bigint        as deposits_received,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_refund'), 0)::bigint as deposits_refunded,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_apply'), 0)::bigint  as deposits_applied,
         coalesce((select jsonb_agg(jsonb_build_object('method', method, 'amount_halalas', amount) order by amount desc, method)
                   from (select method::text as method, sum(amount_halalas)::bigint as amount from fv where kind = 'receipt' group by method) m), '[]'::jsonb) as by_method,
         coalesce((select jsonb_agg(jsonb_build_object('day', day, 'receipts', receipts, 'refunds', refunds) order by day)
                   from (select (occurred_at at time zone tz)::date as day,
                                coalesce(sum(amount_halalas) filter (where kind in ('receipt','deposit_apply')), 0)::bigint as receipts,
                                coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint as refunds
                         from fv group by 1) d), '[]'::jsonb) as by_day,
         coalesce((select jsonb_agg(jsonb_build_object('staff_id', sid, 'staff', coalesce((select full_name from staff_profiles where id = sid), '—'), 'receipts', rc, 'refunds', rf, 'count', n) order by rc desc)
                   from (select created_by sid, coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0)::bigint rc, coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint rf, count(*) n
                         from fv where kind in ('receipt', 'refund') group by created_by) s), '[]'::jsonb) as by_staff,
         coalesce((select jsonb_agg(jsonb_build_object('account_id', acc, 'account', coalesce((select name from cash_accounts where id = acc), '—'), 'in_halalas', i, 'out_halalas', o) order by i desc)
                   from (select account_id acc, coalesce(sum(amount_halalas) filter (where kind in ('receipt','deposit')), 0)::bigint i, coalesce(sum(amount_halalas) filter (where kind in ('refund','deposit_refund')), 0)::bigint o
                         from fv where account_id is not null group by account_id) a), '[]'::jsonb) as by_account
    into l from fv;
  net := l.receipts - l.refunds + l.deposits_applied;

  select coalesce(sum(total_halalas) filter (where kind = 'rent'), 0)::bigint as rent,
         coalesce(sum(total_halalas) filter (where kind in ('addon','penalty','adjustment')), 0)::bigint as addons,
         coalesce(sum(total_halalas) filter (where kind = 'discount'), 0)::bigint as discounts,
         coalesce(sum(total_halalas) filter (where kind = 'tax'), 0)::bigint as tax
    into c
    from reservation_charges ch
    where ch.branch_id = p_branch and ch.reservation_id in (
      select r.id from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from and r.status not in ('cancelled','rejected','no_show')
        and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat));
  total_charged := c.rent + c.addons + c.discounts + c.tax;

  select count(*)::bigint as cnt,
         coalesce(sum(greatest(check_out - check_in, 0)) filter (where status not in ('cancelled','rejected','no_show')), 0)::bigint as nights,
         count(*) filter (where status = 'cancelled') as cancelled,
         count(*) filter (where status = 'no_show') as no_show
    into rs
    from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from
      and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat);

  select coalesce(sum(greatest(deposit_balance_halalas, 0)), 0)::bigint into open_dep from reservations where branch_id = p_branch;

  return jsonb_build_object(
    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'method', v_method, 'account_id', v_account, 'source_id', v_source, 'category_id', v_cat)),
    'filtered', v_filtered,
    'ledger', jsonb_build_object('receipts', l.receipts, 'refunds', l.refunds, 'net_collected', net,
                                 'deposits_received', l.deposits_received, 'deposits_refunded', l.deposits_refunded, 'deposits_applied', l.deposits_applied,
                                 'deposit_balance_open', open_dep),
    'charges', jsonb_build_object('total_charged', total_charged, 'rent', c.rent, 'addons', c.addons, 'discounts', c.discounts, 'tax', c.tax),
    'collection_rate_pct', case when total_charged > 0 and v_staff is null and v_method is null and v_account is null then round(net::numeric * 100 / total_charged, 1) end,
    'by_method', l.by_method, 'by_day', l.by_day, 'by_staff', l.by_staff, 'by_account', l.by_account,
    'reservations', jsonb_build_object('count', rs.cnt, 'nights', rs.nights, 'cancelled', rs.cancelled, 'no_show', rs.no_show,
      'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'count', cnt, 'total_halalas', total) order by cnt desc, source), '[]'::jsonb)
                    from (select coalesce(bs.name, '—') as source, count(*)::bigint as cnt, coalesce(sum(r.total_halalas), 0)::bigint as total
                          from reservations r left join booking_sources bs on bs.id = r.source_id
                          where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from
                            and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat)
                          group by coalesce(bs.name, '—')) s)),
    'definitions', jsonb_build_object(
      'revenue', 'صافي التحصيل = سندات قبض الإقامة − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند. التأمين المقبوض ليس إيرادًا.',
      'collection_rate', 'نسبة التحصيل = صافي التحصيل ÷ إجمالي الرسوم (إيجار + إضافات − خصومات + ضريبة) للإقامات المتقاطعة مع الفترة؛ لا تُحسب مع مرشح الموظف أو الطريقة أو الحساب.')
  );
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reports_identities(p_branch uuid, p_from date, p_to date, p_path text, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid;
begin
  perform fn_require_cap('reports.identities_usage');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  if coalesce(p_path, 'office') not in ('office', 'guest', 'all') then raise exception 'VALIDATION: path'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_staff := (f->>'staff_id')::uuid;
  return (with x as (
    select g.id, r.id as reservation_id, r.internal_ref, g.full_name, g.is_primary, g.identity_type, g.identity_number_last4, g.entry_path,
           g.entered_at, g.verified_at, (select full_name from staff_profiles where id = g.entered_by) as entered_by,
           (select full_name from staff_profiles where id = g.verified_by) as verified_by
    from reservation_guests g join reservations r on r.id = g.reservation_id
    where r.branch_id = p_branch and g.verification_status = 'verified' and g.verified_at is not null
      and (g.verified_at at time zone tz)::date between p_from and p_to
      and (coalesce(p_path, 'office') = 'all' or g.entry_path = coalesce(p_path, 'office'))
      and (v_staff is null or g.verified_by = v_staff)
  )
  select jsonb_build_object(
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'path', coalesce(p_path, 'office'))),
    'count', (select count(*) from x),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', coalesce(verified_by, '—'), 'office', o, 'guest', gu) order by o + gu desc)
                          from (select verified_by, count(*) filter (where entry_path = 'office') o, count(*) filter (where entry_path is distinct from 'office') gu
                                  from x group by verified_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('guest_id', id, 'reservation_id', reservation_id, 'internal_ref', internal_ref, 'full_name', full_name,
                                                         'is_primary', is_primary, 'identity_type', identity_type, 'identity_last4', identity_number_last4,
                                                         'entry_path', entry_path, 'entered_by', entered_by, 'entered_at', entered_at,
                                                         'verified_by', verified_by, 'verified_at', verified_at) order by verified_at desc) from x), '[]'::jsonb)));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reservation_calendar(p_branch uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare money boolean;
begin
  if p_branch is null or p_branch not in (select fn_user_branch_ids()) then raise exception 'FORBIDDEN: branch not permitted' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then raise exception 'VALIDATION: range'; end if;
  money := fn_sees_money();
  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', fn_branch_today(p_branch),
    'units', coalesce((select jsonb_agg(jsonb_build_object('room_id', r.id, 'room_number', r.room_number, 'category_id', r.category_id,
                        'category', (select name_ar from room_categories where id = r.category_id), 'floor_id', r.floor_id,
                        'floor', (select name from floors where id = r.floor_id), 'block', (select name from blocks where id = r.block_id),
                        'status', r.status, 'cleanliness', r.cleanliness, 'is_active', r.is_active)
                        order by (select sort_order from floors where id = r.floor_id) nulls last, r.room_number)
                       from rooms r where r.branch_id = p_branch and r.archived_at is null), '[]'::jsonb),
    'segments', coalesce((select jsonb_agg(jsonb_build_object('room_id', a.room_id, 'reservation_id', r.id, 'internal_ref', r.internal_ref, 'status', r.status,
                           'from_date', greatest(a.from_date, p_from), 'to_date', least(a.to_date, p_to + 1), 'starts_before', a.from_date < p_from, 'ends_after', a.to_date > p_to + 1,
                           'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
                           'source', (select name from booking_sources where id = r.source_id), 'group_ref', r.group_ref,
                           'payment_status', case when money then r.payment_status end, 'balance_due_halalas', case when money then r.balance_due_halalas end)
                           order by a.room_id, a.from_date)
                          from reservation_allocations a join reservations r on r.id = a.reservation_id
                          where a.branch_id = p_branch and a.status in ('active', 'closed') and r.status not in ('cancelled', 'rejected', 'no_show')
                            and a.from_date <= p_to and a.to_date > p_from), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reservation_detail(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when r.branch_id in (select fn_user_branch_ids()) then jsonb_build_object(
    'reservation', case when fn_sees_money() then to_jsonb(r) - 'notes'
                        else to_jsonb(r) - 'notes' - 'total_halalas' - 'paid_halalas' - 'rent_amount_halalas' - 'discount_halalas' - 'addons_halalas' - 'taxes_halalas'
                             - 'balance_due_halalas' - 'deposit_balance_halalas' - 'refunded_halalas' - 'nightly_rate_halalas' - 'payment_status' - 'company_name' - 'gov_registration_ref'
                             - 'platform_collects' end,
    'notes', r.notes,
    'source', (select jsonb_build_object('name', name, 'code', code, 'kind', kind) from booking_sources where id = r.source_id),
    'category', (select name_ar from room_categories where id = r.room_category_id),
    'room', (select jsonb_build_object('id', id, 'room_number', room_number, 'status', status, 'cleanliness', cleanliness) from rooms where id = r.room_id),
    'guests', case when fn_sees_money() then (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'is_primary', g.is_primary, 'full_name', g.full_name,
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
                  'booked_on', r.platform_booked_on, 'collects', case when fn_sees_money() then r.platform_collects end,
                  'verified_at', r.platform_verified_at, 'verified_by', (select full_name from staff_profiles where id = r.platform_verified_by),
                  'cancel_reference', r.cancel_reference) end,
    'acknowledgements', case when fn_sees_money() then fn_ack_list(r.id) end,
    'allocations', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'room_number', rm.room_number, 'from_date', a.from_date, 'to_date', a.to_date, 'status', a.status, 'reason', a.reason, 'created_at', a.created_at) order by a.from_date, a.created_at), '[]'::jsonb)
                    from reservation_allocations a join rooms rm on rm.id = a.room_id where a.reservation_id = r.id),
    'charges', case when fn_sees_money() then
                 (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('invoiced_halalas', coalesce((
                      select sum((l->>'amount_halalas')::bigint) from invoices i cross join lateral jsonb_array_elements(i.snapshot->'lines') l
                       where i.reservation_id = r.id and i.status = 'issued' and (l->>'charge_id')::uuid = c.id), 0)) order by c.created_at), '[]'::jsonb)
                    from reservation_charges c where c.reservation_id = r.id) end,
    'vouchers', case when fn_sees_money() then
                 (select coalesce(jsonb_agg((to_jsonb(v) - 'content_hash') || jsonb_build_object(
                      'created_by_name', (select full_name from staff_profiles where id = v.created_by),
                      'original_number', (select number from financial_vouchers o where o.id = v.original_voucher_id),
                      'replaced_by_number', (select x.number from financial_vouchers x where x.original_voucher_id = v.id order by x.created_at desc limit 1))
                    order by v.occurred_at), '[]'::jsonb) from financial_vouchers v where v.reservation_id = r.id) end,
    'invoices', case when fn_sees_money() then
                 (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number, 'status', i.status, 'scope', i.scope, 'origin', i.origin, 'version', i.version,
                      'subtotal_halalas', i.subtotal_halalas, 'tax_halalas', i.tax_halalas, 'total_halalas', i.total_halalas,
                      'issued_at', i.issued_at, 'issued_by', (select full_name from staff_profiles where id = i.issued_by),
                      'updated_at', i.updated_at, 'updated_by', (select full_name from staff_profiles where id = i.updated_by),
                      'cancelled_at', i.cancelled_at, 'cancel_reason', i.cancel_reason,
                      'period_from', i.period_from, 'period_to', i.period_to, 'bill_to', i.bill_to, 'lines', i.snapshot->'lines', 'versions', i.versions)
                    order by i.issued_at), '[]'::jsonb) from invoices i where i.reservation_id = r.id) end,
    'invoicing', case when fn_sees_money() then jsonb_build_object('uninvoiced_halalas', fn_uninvoiced_value(r.id)) end,
    'finance', case when fn_sees_money() then fn_reservation_finance_internal(r.id) end,
    'history', case when fn_has_role('owner','manager','supervisor') then (select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'at', e.created_at, 'actor', (select full_name from staff_profiles where id = e.actor_id), 'details', e.details) order by e.created_at desc), '[]'::jsonb)
                from (select * from audit_events where entity_id = r.id order by created_at desc limit 50) e) end
  ) end
  from reservations r where r.id = p_reservation;
$function$;

CREATE OR REPLACE FUNCTION public.fn_reservation_finance(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select case when fn_sees_money()
               and exists (select 1 from reservations r where r.id = p_reservation and r.branch_id in (select fn_user_branch_ids()))
         then fn_reservation_finance_internal(p_reservation) end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_reservation_flags(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform fn_require_money();
  perform fn_require_branch(p_branch);
  return coalesce((
    select jsonb_object_agg(x.id, jsonb_build_object('ban', x.ban, 'hold', x.hold, 'rating', x.rating))
    from (select r.id, jsonb_array_length(fn_reservation_ban_matches(r.id)) > 0 as ban, coalesce(r.security_hold, false) as hold,
                 (select gp.rating from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id where g.reservation_id = r.id and g.is_primary limit 1) as rating
            from reservations r
           where r.branch_id = p_branch and r.status in ('draft', 'pending_verification', 'confirmed', 'checked_in')) x
    where x.ban or x.hold or x.rating is not null), '{}'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reservation_group_summary(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; m boolean := fn_sees_money(); units jsonb;
begin
  perform fn_require_role('owner','manager','supervisor','finance','housekeeping');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_reservation_list(p_branch uuid, p_filters jsonb DEFAULT '{}'::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  with f as (select coalesce(p_filters, '{}'::jsonb) j, coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh') tz),
  base as (
    select r.*, (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1) as guest_name,
           (select room_number from rooms where id = r.room_id) as room_number, (select name from booking_sources where id = r.source_id) as source_name,
           (select name_ar from room_categories where id = r.room_category_id) as category_name,
           (select full_name from staff_profiles where id = r.created_by) as created_by_name,
           fn_sees_money() as money
    from reservations r, f
    where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
      and (coalesce(f.j->>'status','') = '' or r.status::text = any(string_to_array(f.j->>'status', ',')))
      and (coalesce(f.j->>'open_only','false') <> 'true' or r.status in ('pending_verification','confirmed','checked_in'))
      and (f.j->>'check_in_from' is null or r.check_in >= (f.j->>'check_in_from')::date)
      and (f.j->>'check_in_to' is null or r.check_in <= (f.j->>'check_in_to')::date)
      and (f.j->>'check_out_from' is null or r.check_out >= (f.j->>'check_out_from')::date)
      and (f.j->>'check_out_to' is null or r.check_out <= (f.j->>'check_out_to')::date)
      and (f.j->>'created_from' is null or (r.created_at at time zone f.tz)::date >= (f.j->>'created_from')::date)
      and (f.j->>'created_to' is null or (r.created_at at time zone f.tz)::date <= (f.j->>'created_to')::date)
      and (f.j->>'stay_on' is null or (r.check_in <= (f.j->>'stay_on')::date and r.check_out > (f.j->>'stay_on')::date))
      and (f.j->>'source_id' is null or r.source_id = (f.j->>'source_id')::uuid)
      and (f.j->>'category_id' is null or r.room_category_id = (f.j->>'category_id')::uuid)
      and (f.j->>'room_id' is null or r.room_id = (f.j->>'room_id')::uuid)
      and (coalesce(f.j->>'room_number','') = '' or exists (select 1 from rooms rm where rm.id = r.room_id and rm.room_number = f.j->>'room_number'))
      and (coalesce(f.j->>'booking_type','') = '' or r.booking_type = f.j->>'booking_type')
      and (coalesce(f.j->>'company','') = '' or coalesce(r.company_name,'') ilike '%' || (f.j->>'company') || '%')
      and (coalesce(f.j->>'price_basis','') = '' or r.price_basis = f.j->>'price_basis')
      and (coalesce(f.j->>'payment_status','') = '' or r.payment_status::text = f.j->>'payment_status')
      and (coalesce(f.j->>'identity_status','') = '' or r.identity_status::text = f.j->>'identity_status')
      and (coalesce(f.j->>'access_status','') = '' or r.access_status::text = f.j->>'access_status')
      and (coalesce(f.j->>'group_ref','') = '' or r.group_ref = f.j->>'group_ref')
      and (coalesce(f.j->>'has_discount','false') <> 'true' or r.discount_halalas > 0)
      and (coalesce(f.j->>'platform_collects','') = '' or r.platform_collects = (f.j->>'platform_collects')::boolean)
      and (coalesce(f.j->>'has_balance','false') <> 'true' or (fn_sees_money() and r.balance_due_halalas > 0))
      and (coalesce(f.j->>'q','') = '' or r.internal_ref ilike '%' || (f.j->>'q') || '%' or coalesce(r.external_ref,'') ilike '%' || (f.j->>'q') || '%'
           or coalesce(r.cancel_reference,'') ilike '%' || (f.j->>'q') || '%' or coalesce(r.company_name,'') ilike '%' || (f.j->>'q') || '%'
           or exists (select 1 from reservation_guests g where g.reservation_id = r.id and (g.full_name ilike '%' || (f.j->>'q') || '%' or g.phone like '%' || (f.j->>'q') || '%')))
  ),
  ordered as (
    select b.*, row_number() over (order by
      case when (select j->>'sort' from f) = 'check_in_asc' then b.check_in end asc,
      case when (select j->>'sort' from f) = 'check_out' then b.check_out end desc,
      case when (select j->>'sort' from f) = 'created' then b.created_at end desc,
      case when (select j->>'sort' from f) = 'ref' then b.internal_ref end asc,
      b.check_in desc, b.created_at desc) as rn
    from base b)
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'status', status, 'check_in', check_in, 'check_out', check_out,
               'nights', check_out - check_in, 'guest_name', guest_name, 'room_number', room_number, 'source_name', source_name, 'category_name', category_name,
               'booking_type', booking_type, 'company_name', company_name, 'price_basis', price_basis, 'adults', adults, 'companions', companions,
               'platform_booked_on', platform_booked_on, 'platform_collects', platform_collects, 'created_by_name', created_by_name,
               'actual_check_in', actual_check_in, 'actual_check_out', actual_check_out, 'cancelled_at', cancelled_at, 'cancel_reference', cancel_reference,
               'total_halalas', case when money then total_halalas end, 'paid_halalas', case when money then paid_halalas end,
               'discount_halalas', case when money then discount_halalas end, 'nightly_rate_halalas', case when money then nightly_rate_halalas end,
               'balance_due_halalas', case when money then balance_due_halalas end, 'deposit_balance_halalas', case when money then deposit_balance_halalas end,
               'payment_status', payment_status, 'identity_status', identity_status, 'access_status', access_status, 'created_at', created_at,
               'group_ref', group_ref, 'hold', coalesce(security_hold, false),
               'ban', case when fn_sees_money() then jsonb_array_length(fn_reservation_ban_matches(id)) > 0 end,
               'rating', case when fn_has_role('owner','manager','supervisor') then (select gp.rating from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id
                                                                                     where g.reservation_id = b.id and g.is_primary limit 1) end) order by rn), '[]'::jsonb)
             from (select * from ordered where rn > coalesce(p_offset, 0) and rn <= coalesce(p_offset, 0) + least(greatest(coalesce(p_limit, 50), 1), 1000)) b));
$function$;

CREATE OR REPLACE FUNCTION public.fn_reservation_nights(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when fn_sees_money()
               and exists (select 1 from reservations r where r.id = p_reservation and r.branch_id in (select fn_user_branch_ids()))
         then coalesce((select jsonb_agg(jsonb_build_object('night', n.night, 'price', n.price_halalas, 'basis', n.basis, 'status', n.status,
                                                            'removed_at', n.removed_at, 'removed_reason', n.removed_reason) order by n.night, n.created_at)
                        from reservation_nights n where n.reservation_id = p_reservation), '[]'::jsonb) end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_review_list(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st text := coalesce(nullif(p->>'status', ''), 'open'); lim int := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500); items jsonb;
begin
  perform fn_require_cap('review.list');
  if st not in ('open', 'reviewed', 'all') then raise exception 'VALIDATION: status'; end if;
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) into items from (
    select jsonb_build_object('id', ri.id, 'kind', ri.kind, 'entity_type', ri.entity_type, 'entity_id', ri.entity_id, 'reservation_id', ri.reservation_id,
             'internal_ref', (select internal_ref from reservations where id = ri.reservation_id),
             'branch_id', ri.branch_id, 'branch_name', (select name_ar from branches where id = ri.branch_id),
             'summary', ri.summary, 'reason', ri.reason, 'details', ri.details,
             'created_at', ri.created_at, 'created_by', (select full_name from staff_profiles where id = ri.created_by),
             'reviewed_at', ri.reviewed_at, 'reviewed_by', (select full_name from staff_profiles where id = ri.reviewed_by), 'review_note', ri.review_note) as x
      from review_items ri
     where ri.organization_id = fn_user_org_id()
       and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))
       and (st = 'all' or (st = 'open') = (ri.reviewed_at is null))
       and (nullif(p->>'kind', '') is null or ri.kind = p->>'kind' or (p->>'kind' = 'monitor' and ri.kind like 'monitor:%'))
       and (nullif(p->>'branch_id', '') is null or ri.branch_id = (p->>'branch_id')::uuid)
       and (nullif(p->>'before', '') is null or ri.created_at < (p->>'before')::timestamptz)
     order by ri.created_at desc
     limit lim) s;
  return jsonb_build_object('items', items, 'open_count',
    (select count(*) from review_items ri where ri.organization_id = fn_user_org_id() and ri.reviewed_at is null
        and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_review_mark(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ids uuid[]; note text := nullif(trim(coalesce(p->>'note', '')), ''); n int;
begin
  perform fn_require_cap('review.list');
  select coalesce(array_agg(x::uuid), '{}') into ids
    from jsonb_array_elements_text(case when jsonb_typeof(p->'ids') = 'array' then p->'ids' else '[]'::jsonb end) x;
  if coalesce(array_length(ids, 1), 0) = 0 then raise exception 'VALIDATION: ids'; end if;
  update review_items set reviewed_at = now(), reviewed_by = fn_staff_id(), review_note = note
   where id = any(ids) and reviewed_at is null and organization_id = fn_user_org_id()
     and (branch_id is null or branch_id in (select fn_user_branch_ids()));
  get diagnostics n = row_count;
  perform fn_audit_change(null, 'review.marked', 'review_items', null, null, jsonb_build_object('count', n, 'ids', to_jsonb(ids)), note);
  return jsonb_build_object('ok', true, 'marked', n);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_review_summary()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when fn_can('review.list') then (
    select jsonb_build_object('open', count(*), 'oldest_at', min(ri.created_at),
                              'monitors', count(*) filter (where ri.kind like 'monitor:%'),
                              'by_kind', coalesce((select jsonb_object_agg(k, c) from (select kind as k, count(*) as c from review_items
                                                    where organization_id = fn_user_org_id() and reviewed_at is null
                                                      and (branch_id is null or branch_id in (select fn_user_branch_ids())) group by kind) g), '{}'::jsonb))
      from review_items ri
     where ri.organization_id = fn_user_org_id() and ri.reviewed_at is null
       and (ri.branch_id is null or ri.branch_id in (select fn_user_branch_ids()))) end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_staff_add_damage(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; amt bigint; key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); descr text := nullif(trim(coalesce(p->>'description', '')), '');
        reason text := nullif(trim(coalesce(p->>'reason', '')), ''); cid uuid; f jsonb; apply_amt bigint := 0; v jsonb; existing uuid; inv_no text;
begin
  perform fn_require_cap('damage.charge');
  amt := fn_parse_halalas(p->>'amount_halalas');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  if key is null then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select id into existing from reservation_charges where reservation_id = r.id and idempotency_key = key;
  if existing is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'charge_id', existing, 'finance', fn_reservation_finance_internal(r.id));
  end if;
  if r.status not in ('checked_in', 'checked_out', 'closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  cid := fn_add_charge(r.id, 'penalty', 'رسم ضرر — ' || coalesce(descr, reason), 1, amt, false, reason);
  update reservation_charges set purpose = 'damage', idempotency_key = key where id = cid;
  if coalesce((p->>'apply_deposit')::boolean, true) then
    f := fn_reservation_finance_internal(r.id);
    apply_amt := least(amt, (f->>'deposit_balance')::bigint, (f->>'balance_due')::bigint);
    if apply_amt > 0 then
      v := fn_refund(jsonb_build_object('reservation_id', r.id, 'kind', 'deposit_apply', 'amount_halalas', apply_amt,
                                        'reason', 'رسم ضرر: ' || reason, 'idempotency_key', key || ':apply'));
    end if;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  if r.status in ('checked_out', 'closed') and (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint = 0 then
    inv_no := coalesce(v->>'invoice', fn_auto_invoice(r.id, 'deposit_settled'));
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.damage_charged', 'reservation', r.id, null,
    jsonb_build_object('amount_halalas', amt, 'description', descr, 'from_deposit_halalas', apply_amt, 'voucher', v->>'number', 'invoice', inv_no), reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'charge_id', cid, 'from_deposit_halalas', apply_amt, 'invoice', inv_no,
                            'finance', fn_reservation_finance_internal(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_add_service(p_reservation uuid, p_service uuid, p_quantity numeric DEFAULT 1, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; s service_definitions%rowtype; qty numeric; price bigint; cid uuid;
begin
  perform fn_require_cap('charges.add');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  select * into s from service_definitions where id = p_service and branch_id = r.branch_id and archived_at is null and is_active;
  if not found then raise exception 'SERVICE_NOT_AVAILABLE'; end if;
  if r.status = 'checked_in' and fn_overdue_blocked(r.id) then
    raise exception 'PAYMENT_OVERDUE: a night is unpaid past its deadline';
  end if;
  if s.late_checkout_until is not null and r.status not in ('pending_verification', 'confirmed', 'checked_in') then
    raise exception 'RESERVATION_STATUS_INVALID';
  end if;
  qty := case s.billing_unit when 'night' then (r.check_out - r.check_in) when 'person' then (r.adults + r.companions) when 'quantity' then coalesce(p_quantity,1) else 1 end;
  if qty <= 0 then raise exception 'VALIDATION: quantity'; end if;
  price := case when s.is_free then 0 else s.price_halalas end;
  -- snapshot name/price/tax at the time of adding (G27)
  cid := fn_add_charge(r.id, 'addon', s.name_ar || case when p_note is not null then ' — ' || p_note else '' end, qty, price, s.taxable, null, s.id,
                       case when s.billing_unit = 'night' then r.check_in end, case when s.billing_unit = 'night' then r.check_out end);
  if s.late_checkout_until is not null then
    update reservation_charges set purpose = 'late_checkout' where id = cid;
    update reservations set late_checkout_until = greatest(coalesce(late_checkout_until, s.late_checkout_until), s.late_checkout_until) where id = r.id;
  end if;
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.service_added', 'reservation', r.id, null,
    jsonb_build_object('service_id', s.id, 'name', s.name_ar, 'quantity', qty, 'unit_price', price, 'late_checkout_until', to_char(s.late_checkout_until, 'HH24:MI')));
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id), 'late_checkout_until', to_char(s.late_checkout_until, 'HH24:MI'));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_adjust_price(p_reservation uuid, p_kind text, p_amount_halalas bigint, p_description text, p_reason text, p_expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; before jsonb; rent bigint; n int; disc bigint;
begin
  if p_kind not in ('discount','adjustment','penalty','addon') then raise exception 'VALIDATION: kind'; end if;
  if p_kind = 'adjustment' then perform fn_require_cap('price.adjust'); elsif p_kind = 'discount' then perform fn_require_any_cap(array['disc.before', 'disc.after']); else perform fn_require_cap('charges.add'); end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_amount_halalas = 0 or (p_kind in ('discount','penalty','addon') and p_amount_halalas < 0) then raise exception 'VALIDATION: amount'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_kind = 'discount' then
    perform fn_ensure_nights(r.id);
    select coalesce(sum(price_halalas), 0), count(*) into rent, n from reservation_nights where reservation_id = r.id and status = 'active';
    disc := coalesce((select sum(round(abs(quantity * unit_price_halalas)))::bigint from reservation_charges where reservation_id = r.id and kind = 'discount'), 0);
    perform fn_check_discount(r.room_category_id, r.branch_id, n, rent, disc, p_amount_halalas, r.status in ('checked_in','checked_out'));
  end if;
  before := jsonb_build_object('total_halalas', r.total_halalas);
  perform fn_add_charge(r.id, p_kind, coalesce(nullif(trim(p_description),''), p_kind), 1, p_amount_halalas, true, p_reason);
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.total_changed', 'reservation', r.id, before, jsonb_build_object('total_halalas', (select total_halalas from reservations where id = r.id), 'kind', p_kind, 'amount_halalas', p_amount_halalas), p_reason);
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_amend_stay(p_reservation uuid, p_new_check_out date, p_pricing_mode text, p_reason text, p_expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; a reservation_allocations%rowtype; delta int; before jsonb; runs jsonb; platform boolean; last_price bigint; refund bigint;
begin
  perform fn_require_cap('stay.extend');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_pricing_mode not in ('keep_rate','reprice') then raise exception 'VALIDATION: pricing_mode'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_new_check_out <= r.check_in then raise exception 'VALIDATION: dates'; end if;
  if r.status = 'checked_in' and p_new_check_out <= fn_branch_today(r.branch_id) and p_new_check_out < r.check_out then raise exception 'VALIDATION: checkout_in_past'; end if;
  delta := p_new_check_out - r.check_out;
  if delta = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  -- decision 3: a night unpaid past its deadline stops the extension until it is paid or a reason is recorded
  if delta > 0 and r.status = 'checked_in' and fn_overdue_blocked(r.id) then
    raise exception 'PAYMENT_OVERDUE: a night is unpaid past its deadline';
  end if;
  -- leaving a weekly or monthly stay early is settled by the owner or a manager (decision 15)
  if delta < 0 and r.price_basis in ('weekly', 'monthly') and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: shortening a weekly or monthly stay requires manager';
  end if;
  before := jsonb_build_object('check_out', r.check_out, 'total_halalas', r.total_halalas);
  perform fn_ensure_nights(r.id);

  -- allocation: extend the current active allocation (exclusion constraint guards the added period)
  select * into a from reservation_allocations where reservation_id = r.id and status = 'active' order by to_date desc limit 1 for update;
  if found then
    if a.to_date <> r.check_out then raise exception 'ALLOCATION_MISMATCH: active allocation does not end at check_out'; end if;
    if a.to_date = r.check_out then
      if p_new_check_out <= a.from_date then raise exception 'VALIDATION: dates'; end if;
      begin
        update reservation_allocations set to_date = p_new_check_out where id = a.id;
      exception when exclusion_violation then
        raise exception 'ALLOCATION_CONFLICT: room is allocated during the added period' using errcode = '23P01';
      end;
    end if;
  end if;

  if delta > 0 then
    -- keep_rate: the added nights at the stay's last night's price; reprice: the calendar's prices for those nights
    -- (an extension is never re-priced as a weekly or monthly stay — that price is fixed when the stay is made)
    if p_pricing_mode = 'keep_rate' then
      select price_halalas into last_price from reservation_nights where reservation_id = r.id and status = 'active' order by night desc limit 1;
      runs := jsonb_build_array(jsonb_build_object('from', r.check_out, 'to', p_new_check_out, 'nights', delta,
                                                   'price', coalesce(last_price, r.nightly_rate_halalas), 'basis', 'kept'));
    else
      platform := exists (select 1 from booking_sources s where s.id = r.source_id and s.kind <> 'direct');
      runs := fn_stay_runs(r.room_category_id, r.check_out, p_new_check_out, platform, null, false);
    end if;
    perform fn_book_nights(r.id, runs, 'تمديد', p_reason);
  else
    -- the refund is exactly the removed nights' prices; the nights keep their rows, marked removed
    select coalesce(sum(price_halalas), 0) into refund from reservation_nights
    where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
    update reservation_nights set status = 'removed', removed_at = now(), removed_by = fn_staff_id(), removed_reason = p_reason
    where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
    perform fn_add_charge(r.id, 'adjustment', 'تقصير الإقامة ' || abs(delta) || ' ليلة', 1, -refund, true, p_reason, null, p_new_check_out, r.check_out);
  end if;
  update reservations set check_out = p_new_check_out,
         nightly_rate_halalas = coalesce((select round(avg(price_halalas))::bigint from reservation_nights where reservation_id = r.id and status = 'active'), nightly_rate_halalas),
         version = version + 1, updated_at = now()
  where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.departure_changed', 'reservation', r.id, before,
    jsonb_build_object('check_out', p_new_check_out, 'total_halalas', (select total_halalas from reservations where id = r.id), 'delta_nights', delta,
                       'pricing_mode', p_pricing_mode, 'nights', case when delta > 0 then runs else jsonb_build_object('refunded_halalas', refund) end), p_reason);
  return jsonb_build_object('ok', true, 'delta_nights', delta, 'finance', fn_reservation_finance_internal(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_approve_identity(p_guest_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare g reservation_guests%rowtype; r reservations%rowtype; st guest_verification_status;
begin
  perform fn_require_cap('identity.approve');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_assign_room(p_reservation uuid, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype;
begin
  perform fn_require_cap('room.assign');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('confirmed','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if exists (select 1 from reservation_allocations where reservation_id = r.id and status = 'active') then
    raise exception 'ALREADY_ALLOCATED: use switch_room';
  end if;
  if not fn_room_available(p_room, r.check_in, r.check_out) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
  perform fn_allocate(r.id, p_room, r.check_in, r.check_out, 'assign');
  update reservations set version = version + 1 where id = r.id;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'assign_room', 'reservation', r.id, jsonb_build_object('room_id', p_room));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_cancel(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; src booking_sources%rowtype; t reservations%rowtype; ev integration_events%rowtype;
        v_reason text := nullif(trim(coalesce(p->>'reason', '')), ''); v_number text := nullif(trim(coalesce(p->>'cancel_number', '')), '');
        v_group boolean := coalesce((p->>'whole_group')::boolean, false); by_platform boolean; v_source text; ids uuid[]; n int := 0;
        v_money boolean := false; v_collected boolean := false; fin jsonb;
begin
  perform fn_require_cap('res.cancel');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_cancel_reservation(p_reservation uuid, p_reason text, p_source text DEFAULT 'staff'::text, p_external_event_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; ev integration_events%rowtype;
begin
  perform fn_require_cap('res.cancel');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if p_external_event_id is not null then
    insert into integration_events(organization_id, source, external_event_id, kind, reference, state)
    values (r.organization_id, coalesce(p_source,'ota'), p_external_event_id, 'reservation.cancelled', r.external_ref, 'received')
    on conflict (organization_id, source, external_event_id) do nothing;
    select * into ev from integration_events where organization_id = r.organization_id and source = coalesce(p_source,'ota') and external_event_id = p_external_event_id;
    if ev.state = 'processed' then
      update integration_events set attempts = attempts + 1 where id = ev.id;
      return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status);
    end if;
  end if;
  if r.status in ('cancelled','rejected','no_show') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status); end if;
  if r.status in ('checked_in','checked_out','closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  perform fn_release_allocations(r.id, 'cancel');
  update reservations set status = 'cancelled', status_before_cancel = r.status::text, cancelled_at = now(), cancel_reason = p_reason, cancel_source = p_source,
         access_status = 'locked', version = version + 1, updated_at = now() where id = r.id;
  if ev.id is not null then update integration_events set state = 'processed', processed_at = now(), result = jsonb_build_object('reservation_id', r.id) where id = ev.id; end if;
  perform fn_audit_change(r.branch_id, 'reservation.cancelled', 'reservation', r.id, jsonb_build_object('status', r.status), jsonb_build_object('status', 'cancelled', 'source', p_source, 'external_event_id', p_external_event_id), p_reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'status', 'cancelled', 'refund_required_separately', (select (fn_reservation_finance_internal(r.id)->>'net_collected')::bigint > 0 or (fn_reservation_finance_internal(r.id)->>'deposit_balance')::bigint > 0));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_check_in(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; reasons text[]; add_rent bigint := 0; add_dep bigint := 0; reason text := nullif(trim(coalesce(p->>'deposit_reason', '')), '');
        d jsonb; dep_short bigint; has_kb boolean; v_rent jsonb; v_dep jsonb; released int;
begin
  perform fn_require_cap('checkin');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status = 'checked_in' then
    return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status);     -- R13: one transition, one arrival time
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  if jsonb_typeof(p->'rent') = 'object' then add_rent := fn_parse_halalas(p->'rent'->>'amount_halalas'); end if;
  if jsonb_typeof(p->'deposit') = 'object' then add_dep := fn_parse_halalas(p->'deposit'->>'amount_halalas'); end if;
  reasons := fn_checkin_core_blockers(r.id) || fn_checkin_money_blockers(r.id, add_rent, add_dep, reason);
  if coalesce(array_length(reasons, 1), 0) > 0 then
    return jsonb_build_object('ok', false, 'reasons', to_jsonb(reasons));
  end if;
  -- the two entries of the arrival screen, each its own voucher (decision 3)
  if add_rent > 0 then v_rent := fn_create_voucher((p->'rent') || jsonb_build_object('reservation_id', r.id, 'kind', 'receipt')); end if;
  if add_dep > 0 then v_dep := fn_create_voucher((p->'deposit') || jsonb_build_object('reservation_id', r.id, 'kind', 'deposit')); end if;
  d := fn_stay_due_internal(r.id);
  if (d->>'collected')::bigint < (d->>'first_night')::bigint then raise exception 'VALIDATION: first_night_unpaid'; end if;
  dep_short := greatest((d->>'deposit_required')::bigint - (d->>'deposit_balance')::bigint, 0);
  if dep_short > 0 and reason is null then raise exception 'VALIDATION: deposit_reason'; end if;
  has_kb := exists (select 1 from keyboxes where room_id = r.room_id);
  update reservations set status = 'checked_in', actual_check_in = now(), checked_in_by = fn_staff_id(),
         checkin_approved_by = fn_staff_id(), checkin_approved_at = now(),
         access_status = case when has_kb then 'approved' else 'key_handed' end::access_status, keybox_delivered = false,
         deposit_waiver_reason = case when dep_short > 0 then reason end,
         deposit_waiver_by = case when dep_short > 0 then fn_staff_id() end,
         deposit_waiver_at = case when dep_short > 0 then now() end,
         version = version + 1, updated_at = now()
   where id = r.id;
  update rooms set status = 'occupied', updated_at = now() where id = r.room_id;
  update access_release_requests set status = 'approved', approved_by = fn_staff_id(), approved_at = now(), evaluated_at = now()
   where reservation_id = r.id and status in ('locked', 'eligibility_review');
  released := fn_release_next_slot(r.branch_id, r.room_category_id, r.check_in);
  perform fn_audit_change(r.branch_id, 'reservation.checked_in', 'reservation', r.id,
    jsonb_build_object('status', r.status, 'access_status', r.access_status),
    jsonb_build_object('status', 'checked_in', 'room_id', r.room_id, 'key_box', has_kb, 'rent_voucher', v_rent->>'number',
                       'deposit_voucher', v_dep->>'number', 'deposit_short_halalas', nullif(dep_short, 0)),
    case when dep_short > 0 then reason end);
  return jsonb_build_object('ok', true, 'duplicate', false, 'has_keybox', has_kb, 'released_count', released,
                            'rent_voucher', v_rent->>'number', 'deposit_voucher', v_dep->>'number', 'finance', fn_reservation_finance_internal(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_check_out(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; f jsonb; tt uuid; existing_task uuid; has_kb boolean; st text; inv_no text;
begin
  perform fn_require_cap('checkout');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('checked_out', 'closed') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', r.status); end if;   -- R14
  if r.status <> 'checked_in' then raise exception 'NOT_CHECKED_IN'; end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  f := fn_recompute_reservation_finance(r.id);
  -- nothing owed, for anyone: no override (decision 8)
  if (f->>'balance_due')::bigint > 0 then
    return jsonb_build_object('ok', false, 'balance_due', (f->>'balance_due')::bigint, 'reasons', jsonb_build_array(
      'على الحجز مبلغ مستحق ' || fn_sar_text((f->>'balance_due')::bigint)
      || '. يُصفَّر بسند قبض، أو بالخصم من التأمين بسبب، أو بتسوية سعر من المالك أو المدير بسبب.'));
  end if;
  update reservations set status = 'checked_out', actual_check_out = now(), checked_out_by = fn_staff_id(), version = version + 1, updated_at = now() where id = r.id;
  perform fn_release_allocations(r.id, 'close');
  if r.room_id is not null then
    update rooms set status = 'cleaning', cleanliness = 'dirty', updated_at = now() where id = r.room_id;
    tt := fn_room_cleaning_type(r.branch_id);
    select id into existing_task from housekeeping_tasks where room_id = r.room_id and reservation_id = r.id and status in ('pending', 'in_progress') limit 1;
    if existing_task is null then
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      values (r.organization_id, r.branch_id, r.room_id, tt, 'تنظيف الوحدة وتعقيمها', r.id, 'high', 'تنظيف بعد المغادرة', fn_staff_id());
    end if;
    has_kb := exists (select 1 from keyboxes where room_id = r.room_id);
    update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id;
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', case when has_kb then 'مغادرة — تنظيف وتغيير رمز مطلوب' else 'مغادرة — تنظيف مطلوب' end,
            'غرفة ' || (select room_number from rooms where id = r.room_id), '/staff/housekeeping');
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.checked_out', 'reservation', r.id, jsonb_build_object('status', 'checked_in'),
    jsonb_build_object('status', 'checked_out', 'deposit_balance_halalas', (f->>'deposit_balance')::bigint, 'credit_halalas', (f->>'credit')::bigint));
  inv_no := fn_auto_invoice(r.id, 'checkout');
  st := fn_sync_closed(r.id);
  return jsonb_build_object('ok', true, 'duplicate', false, 'status', st, 'deposit_to_settle_halalas', (f->>'deposit_balance')::bigint,
                            'credit_halalas', (f->>'credit')::bigint, 'invoice', inv_no, 'missing', to_jsonb(fn_closure_missing(r.id)));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_confirm_payment(p_reservation uuid, p_method payment_method, p_amount_halalas bigint, p_reference text, p_idempotency_key text, p_provider text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype; existing payment_transactions%rowtype; ev financial_vouchers%rowtype; pt uuid; res jsonb; h text;
begin
  perform fn_require_cap('voucher.receipt');
  select * into r from reservations where id = p_reservation for update;      -- serialises replays and races per reservation (X03)
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if p_amount_halalas is null or p_amount_halalas <= 0 then raise exception 'VALIDATION: amount'; end if;
  if coalesce(trim(p_reference),'') = '' then raise exception 'VALIDATION: reference_required'; end if;
  if coalesce(trim(p_idempotency_key),'') = '' then raise exception 'VALIDATION: idempotency_key'; end if;
  if p_method is null then raise exception 'VALIDATION: method'; end if;
  -- same formula as fn_create_voucher, so both entry points agree on what "same content" means
  h := md5(r.id::text || 'receipt' || p_amount_halalas::text || p_method::text || coalesce(p_reference,''));
  select * into existing from payment_transactions where idempotency_key = p_idempotency_key;
  select * into ev from financial_vouchers where organization_id = r.organization_id and idempotency_key = p_idempotency_key;
  if existing.id is not null or ev.id is not null then
    if (existing.id is not null and existing.reservation_id <> r.id) or (ev.id is not null and ev.reservation_id <> r.id) then
      raise exception 'IDEMPOTENCY_CONFLICT: key already used for another reservation';
    end if;
    if ev.id is not null then
      if ev.content_hash <> h then raise exception 'IDEMPOTENCY_CONFLICT: same key, different content'; end if;
      if ev.status = 'cancelled' then raise exception 'IDEMPOTENCY_CANCELLED: voucher % was cancelled; use a new key', ev.number; end if;
    elsif existing.amount_halalas <> p_amount_halalas or existing.method <> p_method or coalesce(existing.provider_ref, existing.pos_ref, '') <> p_reference then
      raise exception 'IDEMPOTENCY_CONFLICT: same key, different content';
    end if;
    -- the duplicate answer describes what is STORED, never what was just sent
    return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', existing.id, 'voucher_id', ev.id, 'voucher', ev.number,
                              'amount_halalas', coalesce(ev.amount_halalas, existing.amount_halalas), 'method', coalesce(ev.method, existing.method),
                              'reference', coalesce(ev.reference, existing.provider_ref, existing.pos_ref),
                              'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas);
  end if;
  insert into payment_transactions(reservation_id, method, amount_halalas, status, provider, provider_ref, pos_ref, verified_by, verified_at, idempotency_key)
  values (r.id, p_method, p_amount_halalas, 'paid', p_provider, case when p_method <> 'pos' then p_reference end, case when p_method = 'pos' then p_reference end, fn_staff_id(), now(), p_idempotency_key)
  returning id into pt;
  res := fn_create_voucher(jsonb_build_object('reservation_id', r.id, 'kind', 'receipt', 'amount_halalas', p_amount_halalas, 'method', p_method, 'reference', p_reference, 'idempotency_key', p_idempotency_key));
  update financial_vouchers set payment_transaction_id = pt where id = (res->>'voucher_id')::uuid;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'confirm_payment', 'reservation', r.id,
                   jsonb_build_object('method', p_method, 'amount_halalas', p_amount_halalas, 'reference', p_reference, 'voucher', res->>'number'));
  select * into r from reservations where id = r.id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'transaction_id', pt, 'voucher_id', (res->>'voucher_id')::uuid, 'voucher', res->>'number',
                            'amount_halalas', p_amount_halalas, 'method', p_method, 'reference', p_reference, 'payment_status', r.payment_status, 'paid_halalas', r.paid_halalas);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_correct_voucher(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v financial_vouchers%rowtype; r reservations%rowtype; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); existing financial_vouchers%rowtype; payload jsonb; res jsonb;
        nv financial_vouchers%rowtype; f jsonb; amt text; m text; ref text; acc text; note text;
begin
  perform fn_require_cap('voucher.correct');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  if key is null then raise exception 'VALIDATION: idempotency_key'; end if;
  select * into v from financial_vouchers where id = (p->>'voucher_id')::uuid;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = v.reservation_id for update;      -- money operations on a stay are serialised here
  perform fn_require_branch(v.branch_id);
  select * into v from financial_vouchers where id = v.id for update;
  -- the same correction again answers with its replacement
  select * into existing from financial_vouchers where organization_id = v.organization_id and idempotency_key = key;
  if found then
    if existing.original_voucher_id is distinct from v.id then raise exception 'IDEMPOTENCY_CONFLICT: key already used'; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'voucher_id', existing.id, 'number', existing.number, 'original_number', v.number,
                              'finance', fn_reservation_finance_internal(r.id));
  end if;
  if v.status <> 'approved' then raise exception 'VOUCHER_STATUS_INVALID'; end if;
  if v.payout_id is not null then raise exception 'VOUCHER_IN_PAYOUT'; end if;
  if not fn_cap_full('voucher.correct') then
    if v.created_by is distinct from fn_staff_id() then raise exception 'FORBIDDEN: a supervisor corrects only the vouchers they issued'; end if;
    if v.created_at < now() - interval '24 hours' then raise exception 'CORRECTION_WINDOW_PASSED: after 24 hours a voucher is corrected by a manager'; end if;
  end if;
  amt := coalesce(nullif(p->>'amount_halalas', ''), v.amount_halalas::text);
  m := coalesce(nullif(p->>'method', ''), v.method::text);
  ref := case when p ? 'reference' then nullif(trim(coalesce(p->>'reference', '')), '') else v.reference end;
  -- another method takes its own account: the one given, or that method's default
  acc := case when p ? 'account_id' then nullif(p->>'account_id', '') when m <> v.method::text then null else v.account_id::text end;
  note := case when p ? 'note' then nullif(trim(coalesce(p->>'note', '')), '') else v.note end;
  if amt = v.amount_halalas::text and (v.kind = 'deposit_apply' or m = v.method::text) and ref is not distinct from v.reference
     and acc is not distinct from v.account_id::text and note is not distinct from v.note then
    raise exception 'VALIDATION: nothing_changed';
  end if;
  update financial_vouchers set status = 'cancelled', cancelled_at = now(), cancelled_by = fn_staff_id(), cancel_reason = 'تصحيح: ' || v_reason where id = v.id;
  payload := jsonb_strip_nulls(jsonb_build_object('reservation_id', r.id, 'kind', v.kind, 'idempotency_key', key, 'amount_halalas', amt,
                                                  'method', m, 'reference', ref, 'account_id', acc, 'note', note,
                                                  'reason', coalesce(v.reason, 'تصحيح السند ' || v.number), 'original_voucher_id', v.id));
  if v.kind in ('receipt', 'deposit') then res := fn_create_voucher(payload); else res := fn_refund(payload); end if;
  update financial_vouchers set original_voucher_id = v.id where id = (res->>'voucher_id')::uuid and original_voucher_id is null;
  select * into nv from financial_vouchers where id = (res->>'voucher_id')::uuid;
  f := fn_reservation_finance_internal(r.id);
  if (f->>'deposit_balance')::bigint < 0 or ((f->>'received')::bigint - (f->>'refunded')::bigint) < 0 then
    raise exception 'CANCEL_WOULD_GO_NEGATIVE';
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(v.branch_id, 'voucher_corrected', 'voucher', nv.id, r.id, 'تصحيح السند ' || v.number || ' بالسند ' || nv.number, v_reason,
    jsonb_build_object('original', v.number, 'replacement', nv.number, 'kind', v.kind,
                       'before', jsonb_build_object('amount_halalas', v.amount_halalas, 'method', v.method, 'reference', v.reference, 'account_id', v.account_id),
                       'after', jsonb_build_object('amount_halalas', nv.amount_halalas, 'method', nv.method, 'reference', nv.reference, 'account_id', nv.account_id),
                       'issued_by_self', v.created_by is not distinct from fn_staff_id()));
  perform fn_audit_change(v.branch_id, 'voucher.corrected', 'voucher', nv.id,
    jsonb_build_object('number', v.number, 'amount_halalas', v.amount_halalas, 'method', v.method, 'reference', v.reference, 'account_id', v.account_id),
    jsonb_build_object('number', nv.number, 'amount_halalas', nv.amount_halalas, 'method', nv.method, 'reference', nv.reference, 'account_id', nv.account_id,
                       'original_voucher_id', v.id), v_reason);
  return jsonb_build_object('ok', true, 'duplicate', false, 'voucher_id', nv.id, 'number', nv.number, 'original_number', v.number,
                            'finance', fn_reservation_finance_internal(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_create_maintenance(p_room uuid, p_title text, p_description text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare rm rooms%rowtype; tid uuid;
begin
  perform fn_require_cap('maintenance.create');
  select * into rm from rooms where id = p_room for update; if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  if coalesce(trim(p_title),'') = '' then raise exception 'VALIDATION: title'; end if;
  insert into maintenance_tickets(room_id, branch_id, title, description, status, created_by) values (p_room, rm.branch_id, p_title, p_description, 'open', fn_staff_id()) returning id into tid;
  if rm.status not in ('occupied') then update rooms set status = 'maintenance' where id = p_room; end if;
  perform fn_audit(fn_user_org_id(), rm.branch_id, fn_staff_id(), 'maintenance_opened', 'room', p_room, jsonb_build_object('ticket_id', tid));
  return jsonb_build_object('ok', true, 'ticket_id', tid);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_create_reservation(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare units jsonb := p->'units'; u jsonb; res jsonb; first jsonb; ids jsonb := '[]'::jsonb; refs jsonb := '[]'::jsonb; g text; n int;
begin
  perform fn_require_cap('res.create');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_create_reservation_unit(p jsonb, p_group_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; v_room uuid := (p->>'room_id')::uuid;
        ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date; src booking_sources%rowtype; q jsonb; r reservations%rowtype; b branches%rowtype;
        gp guest_profiles%rowtype; v_phone text := nullif(trim(p->>'guest_phone'),''); v_name text := trim(p->>'guest_name'); v_status reservation_status; ext text := nullif(trim(p->>'external_ref'),'');
        v_adults int := coalesce((p->>'adults')::int, 1); v_comp int := coalesce((p->>'companions')::int, 0); cap int;
        v_details jsonb := coalesce(p->'companions_details', '[]'::jsonb); d jsonb; v_arr time; v_dep time;
        v_disc bigint := coalesce(nullif(p->>'discount_halalas', '')::bigint, 0); v_ovr bigint := nullif(p->>'nightly_rate_halalas', '')::bigint;
        v_profile uuid := nullif(p->>'guest_profile_id', '')::uuid; v_new_profile boolean := coalesce((p->>'new_profile')::boolean, false);
        v_collects boolean; v_booked date; platform boolean; f jsonb; vch jsonb; v_con text;
begin
  perform fn_require_cap('res.create');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_day_summary(p_branch uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text; ds timestamptz; de timestamptz; everyone boolean; v jsonb;
begin
  perform fn_require_money();
  perform fn_require_branch(p_branch);
  if p_date is null then raise exception 'VALIDATION: business_date'; end if;
  everyone := fn_has_role('owner','manager','finance');
  tz := coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
  ds := p_date::timestamp at time zone tz;
  de := (p_date + 1)::timestamp at time zone tz;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id', t.staff_id, 'staff_name', t.staff_name, 'kind', t.kind, 'method', t.method,
                                              'count', t.n, 'total', t.total) order by t.staff_name, t.kind, t.method), '[]'::jsonb) into v
  from (select v2.created_by as staff_id, coalesce(s.full_name, '—') as staff_name, v2.kind, case when v2.kind = 'deposit_apply' then null else v2.method::text end as method,
               count(*) as n, sum(v2.amount_halalas) as total
        from financial_vouchers v2 left join staff_profiles s on s.id = v2.created_by
        where v2.branch_id = p_branch and v2.status = 'approved' and v2.occurred_at >= ds and v2.occurred_at < de
          and (everyone or v2.created_by = fn_staff_id())
        group by 1, 2, 3, 4) t;
  return jsonb_build_object('date', p_date, 'everyone', everyone, 'rows', v);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_deliver_access_code(p_reservation uuid, p_channel text DEFAULT 'screen'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype; kb keyboxes%rowtype; v text[]; v_code text;
begin
  perform fn_require_cap('code.deliver');
  if p_channel is null or p_channel not in ('screen', 'whatsapp', 'supervisor') then raise exception 'VALIDATION: channel'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.access_status in ('delivered', 'acknowledged') then
    return jsonb_build_object('ok', false, 'reasons', jsonb_build_array('تم تسليم الرمز مسبقًا لهذا الحجز'));
  end if;
  v := fn_code_blockers(r.id);
  if coalesce(array_length(v, 1), 0) > 0 then return jsonb_build_object('ok', false, 'reasons', to_jsonb(v)); end if;
  select * into kb from keyboxes where room_id = r.room_id limit 1 for update;
  update reservations set access_status = 'delivered', keybox_delivered = true, version = version + 1, updated_at = now() where id = r.id;
  update keyboxes set last_reservation_id = r.id, last_delivered_at = now() where id = kb.id;
  update access_release_requests set status = 'delivered', delivered_at = now() where reservation_id = r.id and status = 'approved';
  insert into access_delivery_events(reservation_id, keybox_id, channel, delivered_by) values (r.id, kb.id, p_channel, fn_staff_id());
  perform fn_audit_change(r.branch_id, 'deliver_access_code', 'reservation', r.id, jsonb_build_object('access_status', r.access_status),
    jsonb_build_object('access_status', 'delivered', 'channel', p_channel, 'code_version', kb.code_version));
  if p_channel = 'supervisor' then
    v_code := pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key'));
    return jsonb_build_object('ok', true, 'code', v_code);
  end if;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_edit_invoice(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare inv invoices%rowtype; r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); pf date; pt date; bt jsonb;
        lines jsonb; sub bigint; tax bigint; n int; prev jsonb; old_lines jsonb; new_lines jsonb;
begin
  perform fn_require_cap('invoice.edit');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into inv from invoices where id = (p->>'invoice_id')::uuid;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into r from reservations where id = inv.reservation_id for update;      -- the stay first, as every money operation
  perform fn_require_branch(inv.branch_id);
  select * into inv from invoices where id = inv.id for update;
  if inv.status <> 'issued' then raise exception 'INVOICE_STATUS_INVALID'; end if;
  if inv.scope = 'period' then
    pf := coalesce(nullif(p->>'from', '')::date, inv.period_from); pt := coalesce(nullif(p->>'to', '')::date, inv.period_to);
    if pt <= pf then raise exception 'VALIDATION: period'; end if;
    if exists (select 1 from invoices i where i.reservation_id = r.id and i.status = 'issued' and i.scope = 'period' and i.id <> inv.id
                                         and i.period_from < pt and pf < i.period_to) then
      raise exception 'INVOICE_PERIOD_OVERLAP: another invoice of this stay covers part of the period';
    end if;
  end if;
  bt := inv.bill_to;
  if jsonb_typeof(p->'bill_to') = 'object' then
    -- a key sent empty is cleared (merged as null, then stripped)
    if p->'bill_to' ? 'name' then bt := bt || jsonb_build_object('name', nullif(trim(coalesce(p->'bill_to'->>'name', '')), '')); end if;
    if p->'bill_to' ? 'note' then bt := bt || jsonb_build_object('note', nullif(trim(coalesce(p->'bill_to'->>'note', '')), '')); end if;
    bt := jsonb_strip_nulls(bt);
    if coalesce(bt->>'name', '') = '' then raise exception 'VALIDATION: bill_to_name'; end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('charge_id', s.charge_id, 'kind', s.kind, 'description', s.description, 'quantity', s.quantity,
                                               'unit_price_halalas', s.unit_price_halalas, 'total_halalas', s.total_halalas,
                                               'amount_halalas', s.share_halalas, 'service_from', s.service_from, 'service_to', s.service_to)
                            order by s.created_at, s.kind = 'tax', s.charge_id), '[]'::jsonb),
         coalesce(sum(s.share_halalas) filter (where s.kind <> 'tax'), 0), coalesce(sum(s.share_halalas) filter (where s.kind = 'tax'), 0), count(*)
    into lines, sub, tax, n
    from fn_invoice_shares(r.id, case when inv.scope = 'period' then pf end, case when inv.scope = 'period' then pt end, inv.id) s;
  if n = 0 then raise exception 'NOTHING_TO_INVOICE'; end if;
  if sub + tax <= 0 then raise exception 'INVOICE_NOT_POSITIVE'; end if;
  if inv.scope = 'remaining' then pf := inv.period_from; pt := inv.period_to; end if;
  -- unchanged: the same shares, the same period and the same bill-to
  select coalesce(jsonb_agg(jsonb_build_array(x->>'charge_id', x->>'amount_halalas') order by x->>'charge_id'), '[]'::jsonb) into old_lines from jsonb_array_elements(inv.snapshot->'lines') x;
  select coalesce(jsonb_agg(jsonb_build_array(x->>'charge_id', x->>'amount_halalas') order by x->>'charge_id'), '[]'::jsonb) into new_lines from jsonb_array_elements(lines) x;
  if old_lines = new_lines and pf = inv.period_from and pt = inv.period_to and bt = inv.bill_to then
    return jsonb_build_object('ok', true, 'unchanged', true, 'id', inv.id, 'number', inv.number, 'version', inv.version);
  end if;
  prev := jsonb_build_object('version', inv.version, 'period_from', inv.period_from, 'period_to', inv.period_to, 'bill_to', inv.bill_to,
                             'subtotal_halalas', inv.subtotal_halalas, 'tax_halalas', inv.tax_halalas, 'total_halalas', inv.total_halalas,
                             'lines', inv.snapshot->'lines', 'since', coalesce(inv.updated_at, inv.issued_at),
                             'by', (select full_name from staff_profiles where id = coalesce(inv.updated_by, inv.issued_by)),
                             'replaced_at', now(), 'replaced_by', (select full_name from staff_profiles where id = fn_staff_id()), 'reason', reason);
  update invoices set versions = versions || jsonb_build_array(prev), version = version + 1, period_from = pf, period_to = pt, bill_to = bt,
         snapshot = snapshot || jsonb_build_object('lines', lines, 'bill_to', bt,
                                                   'period', jsonb_build_object('from', pf, 'to', pt, 'scope', inv.scope, 'requested', inv.scope = 'period'),
                                                   'charge_ids', (select coalesce(jsonb_agg(x->'charge_id'), '[]'::jsonb) from jsonb_array_elements(lines) x)),
         subtotal_halalas = sub, tax_halalas = tax, total_halalas = sub + tax, updated_at = now(), updated_by = fn_staff_id()
   where id = inv.id
   returning * into inv;
  perform fn_sync_invoice_markers(r.id);
  perform fn_add_review_item(inv.branch_id, 'invoice_edited', 'invoice', inv.id, r.id, 'تعديل الفاتورة ' || inv.number || ' (الإصدار ' || inv.version || ')', reason,
    jsonb_build_object('number', inv.number, 'version', inv.version, 'before_total_halalas', (prev->>'total_halalas')::bigint, 'after_total_halalas', inv.total_halalas,
                       'before_period', jsonb_build_array(prev->>'period_from', prev->>'period_to'), 'after_period', jsonb_build_array(pf, pt)));
  perform fn_audit_change(inv.branch_id, 'invoice.edited', 'invoice', inv.id,
    jsonb_build_object('version', (prev->>'version')::int, 'total_halalas', (prev->>'total_halalas')::bigint, 'period_from', prev->>'period_from', 'period_to', prev->>'period_to', 'bill_to', prev->'bill_to'),
    jsonb_build_object('version', inv.version, 'total_halalas', inv.total_halalas, 'period_from', pf, 'period_to', pt, 'bill_to', bt), reason);
  return jsonb_build_object('ok', true, 'unchanged', false, 'id', inv.id, 'number', inv.number, 'version', inv.version, 'total_halalas', inv.total_halalas);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_enter_guest(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype; g reservation_guests%rowtype; v_guest uuid := nullif(p->>'guest_id', '')::uuid;
        v_name text := trim(coalesce(p->>'full_name', '')); v_type identity_type; v_number text := regexp_replace(coalesce(p->>'identity_number', ''), '\s', '', 'g');
        v_nat text := trim(coalesce(p->>'nationality', '')); v_birth date; v_phone text := nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9+]', '', 'g'), '');
        v_rel text := nullif(trim(coalesce(p->>'relationship', '')), ''); v_issue text := nullif(trim(coalesce(p->>'identity_issue_number', '')), '');
        v_reason text := nullif(trim(coalesce(p->>'reason', '')), ''); fp text; before jsonb; correcting boolean := false; cnt int; new_id uuid; st guest_verification_status;
begin
  perform fn_require_cap('guest.enter');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_invite(p_email text, p_full_name text, p_role role_code, p_branch_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sp staff_profiles%rowtype; b uuid;
begin
  perform fn_require_cap('staff.manage');
  if p_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  if p_role = 'owner' and not fn_has_role('owner') then raise exception 'FORBIDDEN: only the owner changes an owner' using errcode = '42501'; end if;
  if coalesce(trim(p_email), '') = '' or coalesce(trim(p_full_name), '') = '' then raise exception 'VALIDATION: email_and_name'; end if;
  insert into staff_profiles(organization_id, full_name, email, role, is_active) values (fn_user_org_id(), trim(p_full_name), lower(trim(p_email)), p_role, true) returning * into sp;
  foreach b in array coalesce(p_branch_ids, '{}') loop
    perform fn_require_branch(b);
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  perform fn_audit(sp.organization_id, null, fn_staff_id(), 'staff_invited', 'staff_profile', sp.id,
                   jsonb_build_object('role', p_role, 'branch_ids', to_jsonb(coalesce(p_branch_ids, '{}'))));
  return jsonb_build_object('ok', true, 'staff_id', sp.id);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_issue_invoice(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; pf date := nullif(p->>'from', '')::date; pt date := nullif(p->>'to', '')::date; inv invoices%rowtype;
begin
  perform fn_require_cap('invoice.issue');
  if (pf is null) <> (pt is null) then raise exception 'VALIDATION: period'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  -- a period that overlaps another invoice is the first thing to say
  if pf is not null then
    if pt <= pf then raise exception 'VALIDATION: period'; end if;
    if exists (select 1 from invoices i where i.reservation_id = r.id and i.status = 'issued' and i.scope = 'period' and i.period_from < pt and pf < i.period_to) then
      raise exception 'INVOICE_PERIOD_OVERLAP: another invoice of this stay covers part of the period';
    end if;
  end if;
  if pf is not null and (select coalesce(sum(share_halalas), 0) from fn_invoice_shares(r.id, pf, pt)) <= 0
     or pf is null and (select coalesce(sum(share_halalas), 0) from fn_invoice_shares(r.id, null, null)) <= 0 then
    -- nothing, or only lines that lower the bill: those go into an existing invoice by editing it
    if exists (select 1 from fn_invoice_shares(r.id, pf, pt)) then raise exception 'INVOICE_NOT_POSITIVE'; end if;
    raise exception 'NOTHING_TO_INVOICE';
  end if;
  inv := fn_issue_invoice(r.id, case when pf is null then 'remaining' else 'period' end, pf, pt, 'manual', p->'bill_to');
  return jsonb_build_object('ok', true, 'id', inv.id, 'number', inv.number, 'total_halalas', inv.total_halalas, 'period_from', inv.period_from,
                            'period_to', inv.period_to, 'scope', inv.scope, 'line_count', jsonb_array_length(inv.snapshot->'lines'),
                            'charge_count', jsonb_array_length(inv.snapshot->'lines'));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_mark_delivery_failed(p_reservation uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype;
begin
  perform fn_require_cap('code.deliver');
  select * into r from reservations where id = p_reservation for update;
  perform fn_require_branch(r.branch_id);
  if r.access_status <> 'delivered' then raise exception 'NOT_IN_DELIVERED_STATE'; end if;
  update reservations set access_status = 'delivery_pending', updated_at = now() where id = r.id;
  perform fn_audit(r.organization_id, r.branch_id, fn_staff_id(), 'delivery_failed', 'reservation', r.id, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_mark_keybox_tested(p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare rm rooms%rowtype; kb keyboxes%rowtype; st room_status; v_in_house boolean;
begin
  perform fn_require_cap('keybox.code');
  select * into rm from rooms where id = p_room;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  v_in_house := fn_room_guest_in_house(p_room);
  if v_in_house and not fn_has_role('owner','manager','supervisor') then
    raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
  end if;
  select * into kb from keyboxes where room_id = p_room limit 1 for update;
  if not found or kb.code_encrypted is null then raise exception 'NO_KEYBOX_CODE'; end if;
  if kb.code_status <> 'active' then raise exception 'CODE_NEEDS_CHANGE'; end if;   -- the test is of the new code
  update keyboxes set field_tested = true where id = kb.id;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit_change(rm.branch_id, 'keybox_field_tested', 'room', p_room, jsonb_build_object('field_tested', kb.field_tested),
    jsonb_build_object('field_tested', true, 'code_version', kb.code_version, 'room_status', st), null);
  return jsonb_build_object('ok', true, 'room_status', st);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_no_show(p_reservation uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype;
begin
  perform fn_require_cap('res.cancel');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('confirmed','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;   -- R10
  if r.check_in > fn_branch_today(r.branch_id) then raise exception 'VALIDATION: arrival_not_due'; end if;
  perform fn_release_allocations(r.id, 'cancel');
  update reservations set status = 'no_show', no_show_at = now(), cancel_reason = p_reason, access_status = 'locked', version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, 'reservation.no_show', 'reservation', r.id, jsonb_build_object('status', r.status), jsonb_build_object('status', 'no_show'), p_reason);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_payment_exception(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; d jsonb; reason text := nullif(trim(coalesce(p->>'reason', '')), '');
begin
  perform fn_require_cap('checkin');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  d := fn_stay_due_internal(r.id);
  if not coalesce((d->>'overdue')::boolean, false) then raise exception 'VALIDATION: not_overdue'; end if;
  insert into stay_payment_exceptions(organization_id, branch_id, reservation_id, through_night, shortfall_halalas, reason, created_by)
  values (r.organization_id, r.branch_id, r.id, (d->>'overdue_through')::date, (d->>'overdue_amount')::bigint, reason, fn_staff_id());
  perform fn_audit_change(r.branch_id, 'reservation.payment_exception', 'reservation', r.id, null,
    jsonb_build_object('through_night', d->>'overdue_through', 'overdue_halalas', (d->>'overdue_amount')::bigint), reason);
  return jsonb_build_object('ok', true, 'through_night', d->>'overdue_through');
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_record_inspection(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; res text := p->>'result'; v_notes text := nullif(trim(coalesce(p->>'notes', '')), ''); sug bigint := 0; iid uuid;
begin
  perform fn_require_cap('inspection');
  if res is null or res not in ('ok', 'notes') then raise exception 'VALIDATION: inspection_result'; end if;
  if res = 'notes' and v_notes is null then raise exception 'VALIDATION: inspection_notes'; end if;
  if res = 'notes' and coalesce(p->>'suggested_deduction_halalas', '') not in ('', '0') then sug := fn_parse_halalas(p->>'suggested_deduction_halalas'); end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  -- the inspection is of the departure: after check-out, or on the departure day (or later) of a guest still in
  if not (r.status = 'checked_out' or (r.status = 'checked_in' and fn_branch_today(r.branch_id) >= r.check_out)) then
    raise exception 'VALIDATION: inspection_not_due';
  end if;
  update checkout_inspections set status = 'superseded', superseded_at = now(), superseded_by = fn_staff_id() where reservation_id = r.id and status = 'active';
  insert into checkout_inspections(organization_id, branch_id, reservation_id, room_id, result, notes, suggested_deduction_halalas, inspected_by)
  values (r.organization_id, r.branch_id, r.id, r.room_id, res, v_notes, sug, fn_staff_id()) returning id into iid;
  if res = 'notes' then
    insert into notifications(branch_id, audience, title, body, link)
    values (r.branch_id, 'supervisor', 'ملاحظات في فحص المغادرة',
            'الحجز ' || r.internal_ref || coalesce(' — خصم مقترح ' || fn_sar_text(nullif(sug, 0)), ''), '/staff/reservations/' || r.id);
  end if;
  perform fn_audit_change(r.branch_id, 'reservation.inspected', 'reservation', r.id, null,
    jsonb_build_object('result', res, 'suggested_deduction_halalas', sug, 'room_id', r.room_id));
  return jsonb_build_object('ok', true, 'id', iid);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_record_paper_ack(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; res jsonb;
begin
  perform fn_require_cap('checkin');
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status in ('cancelled', 'rejected', 'no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  res := fn_record_ack(r.id, (select id from reservation_guests where reservation_id = r.id and is_primary order by created_at limit 1), 'paper', p->>'text_hash', fn_staff_id());
  if not (res->>'duplicate')::boolean then
    perform fn_audit_change(r.branch_id, 'reservation.summary_signed', 'reservation', r.id, null, jsonb_build_object('method', 'paper', 'text_hash', p->>'text_hash'));
  end if;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_reopen_stay(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); rm rooms%rowtype; kb keyboxes%rowtype;
        has_kb boolean := false; keep_code boolean := false; v_access access_status;
begin
  perform fn_require_cap('stay.reopen');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('checked_out', 'closed') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.actual_check_out is null or now() - r.actual_check_out > interval '2 hours' then
    raise exception 'CORRECTION_WINDOW_PASSED: a departure is reopened within 2 hours';
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  if r.room_id is not null then
    select * into rm from rooms where id = r.room_id for update;
    if not rm.is_active or rm.archived_at is not null or rm.status in ('blocked', 'out_of_service') then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    if exists (select 1 from reservations o where o.room_id = rm.id and o.status = 'checked_in' and o.id <> r.id) then
      raise exception 'ALLOCATION_CONFLICT: another guest is in the unit' using errcode = '23P01';
    end if;
  end if;
  -- the allocations this departure closed come back; if the unit was booked for someone else meanwhile, it is a conflict
  begin
    update reservation_allocations set status = 'active', closed_at = null
     where reservation_id = r.id and status = 'closed' and closed_at = r.actual_check_out;
  exception when exclusion_violation then
    raise exception 'ALLOCATION_CONFLICT: the unit is booked for someone else in this stay''s period' using errcode = '23P01';
  end;
  if r.room_id is not null then
    update rooms set status = 'occupied', updated_at = now() where id = r.room_id;
    -- the departure's cleaning is no longer due
    update housekeeping_tasks set status = 'cancelled', cancelled_at = now(), cancel_reason = 'أُعيد فتح الإقامة: ' || reason, version = version + 1, updated_at = now()
     where reservation_id = r.id and room_id = r.room_id and status in ('pending', 'in_progress') and description = 'تنظيف بعد المغادرة';
    update rooms set cleanliness = 'dirty' where id = r.room_id and cleanliness = 'in_progress';
    select * into kb from keyboxes where room_id = r.room_id limit 1 for update;
    has_kb := found;
    if has_kb and kb.code_status = 'needs_change' and kb.last_reservation_id = r.id then
      -- the guest's code was not changed since: it stays theirs
      update keyboxes set code_status = 'active', field_tested = true where id = kb.id;
      keep_code := true;
    end if;
  end if;
  v_access := case when not has_kb then 'key_handed' when keep_code then r.access_status else 'approved' end;
  update reservations set status = 'checked_in', actual_check_out = null, checked_out_by = null, closed_at = null,
         access_status = v_access, keybox_delivered = case when keep_code then keybox_delivered else false end,
         version = version + 1, updated_at = now()
   where id = r.id;
  update checkout_inspections set status = 'superseded', superseded_at = now(), superseded_by = fn_staff_id() where reservation_id = r.id and status = 'active';
  perform fn_recompute_reservation_finance(r.id);
  perform fn_add_review_item(r.branch_id, 'stay_reopened', 'reservation', r.id, r.id, 'إعادة فتح إقامة ' || r.internal_ref, reason,
    jsonb_build_object('checked_out_at', r.actual_check_out, 'was_closed', r.status = 'closed', 'code_kept', keep_code));
  perform fn_audit_change(r.branch_id, 'reservation.stay_reopened', 'reservation', r.id,
    jsonb_build_object('status', r.status, 'actual_check_out', r.actual_check_out), jsonb_build_object('status', 'checked_in', 'access_status', v_access), reason);
  return jsonb_build_object('ok', true, 'access_status', v_access);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_resolve_maintenance(p_ticket uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare t maintenance_tickets%rowtype; st room_status;
begin
  perform fn_require_cap('maintenance.resolve');
  select * into t from maintenance_tickets where id = p_ticket for update;
  if not found then raise exception 'TICKET_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  update maintenance_tickets set status = 'resolved' where id = t.id;
  st := fn_recompute_room_ready(t.room_id);
  perform fn_audit(fn_user_org_id(), t.branch_id, fn_staff_id(), 'maintenance_resolved', 'room', t.room_id, jsonb_build_object('ticket_id', t.id, 'room_status', st));
  return jsonb_build_object('ok', true, 'room_status', st);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_resolve_ticket(p_ticket uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform fn_require_cap('maintenance.resolve');
  update human_handoff_tickets set status = 'resolved', resolved_by = fn_staff_id(), resolved_at = now()
   where id = p_ticket and (branch_id is null or branch_id in (select fn_user_branch_ids()));
  return jsonb_build_object('ok', found);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_rotate_keybox_code(p_room uuid, p_new_code text, p_field_tested boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare kb keyboxes%rowtype; rm rooms%rowtype; st room_status; v_in_house boolean; v_tested boolean := coalesce(p_field_tested, false);
        v_before jsonb; v_version int;
begin
  perform fn_require_cap('keybox.code');
  select * into rm from rooms where id = p_room;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  perform fn_require_branch(rm.branch_id);
  v_in_house := fn_room_guest_in_house(p_room);
  if v_in_house and not fn_has_role('owner','manager','supervisor') then
    raise exception 'GUEST_IN_HOUSE' using errcode = '42501';
  end if;
  if p_new_code is null or p_new_code !~ '^\d{4,8}$' then raise exception 'VALIDATION: code_must_be_4_to_8_digits'; end if;

  select * into kb from keyboxes where room_id = p_room limit 1 for update;
  if not found then
    v_before := jsonb_build_object('code_status', 'none');
    insert into keyboxes(room_id, branch_id, code_encrypted, code_version, code_status, last_changed_at, last_changed_by, field_tested, requires_rotation)
    values (p_room, rm.branch_id, pgp_sym_encrypt(p_new_code, fn_secret('keybox_key')), 1, 'active', now(), fn_staff_id(), v_tested, true)
    returning * into kb;
    v_version := 1;
    insert into code_rotation_events(keybox_id, room_id, from_version, to_version, rotated_by, field_tested) values (kb.id, p_room, null, 1, fn_staff_id(), v_tested);
  else
    v_before := jsonb_build_object('code_version', kb.code_version, 'code_status', kb.code_status, 'field_tested', kb.field_tested,
                                   'needs_change_since', kb.needs_change_since);
    if kb.code_encrypted is not null and pgp_sym_decrypt(kb.code_encrypted, fn_secret('keybox_key')) = p_new_code then
      raise exception 'CODE_MUST_DIFFER_FROM_PREVIOUS';
    end if;
    v_version := kb.code_version + 1;
    update keyboxes set code_encrypted = pgp_sym_encrypt(p_new_code, fn_secret('keybox_key')), code_version = v_version,
      code_status = 'active', last_changed_at = now(), last_changed_by = fn_staff_id(), field_tested = v_tested, last_reservation_id = null
    where id = kb.id;
    insert into code_rotation_events(keybox_id, room_id, from_version, to_version, rotated_by, field_tested) values (kb.id, p_room, kb.code_version, v_version, fn_staff_id(), v_tested);
  end if;
  st := fn_recompute_room_ready(p_room);
  perform fn_audit_change(rm.branch_id, 'rotate_keybox_code', 'room', p_room, v_before,
    jsonb_build_object('code_version', v_version, 'code_status', 'active', 'field_tested', v_tested, 'room_status', st, 'guest_in_house', v_in_house), null);
  return jsonb_build_object('ok', true, 'room_status', st, 'code_version', v_version);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_set_hold(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; v_hold boolean := (p->>'hold')::boolean; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
begin
  if v_hold is null then raise exception 'VALIDATION: hold'; end if;
  if v_hold then perform fn_require_cap('hold.set'); else perform fn_require_cap('hold.lift'); end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_shomoos(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; act text := p->>'action'; ref text := nullif(trim(coalesce(p->>'reference', '')), ''); cnt int; before jsonb;
begin
  perform fn_require_cap('shomoos');
  if act is null or act not in ('register', 'accept') then raise exception 'VALIDATION: action'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status not in ('pending_verification', 'confirmed', 'checked_in') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  cnt := r.adults + r.companions;
  before := jsonb_build_object('reference', r.gov_registration_ref, 'guest_count', r.shomoos_guest_count, 'accepted', r.shomoos_accepted_at is not null);
  if act = 'register' then
    if r.identity_status <> 'verified' then raise exception 'IDENTITY_NOT_VERIFIED'; end if;
    if ref is null then raise exception 'VALIDATION: shomoos_reference'; end if;
    if length(ref) < 3 or length(ref) > 60 then raise exception 'VALIDATION: shomoos_reference'; end if;
    if coalesce((p->>'all_guests')::boolean, false) is not true then raise exception 'VALIDATION: shomoos_all_guests'; end if;
    if coalesce(r.government_registration, false) and r.gov_registration_ref = ref and r.shomoos_guest_count = cnt then
      return jsonb_build_object('ok', true, 'unchanged', true);
    end if;
    -- a new or corrected registration waits for Shomoos's acceptance again
    update reservations set government_registration = true, gov_registration_ref = ref, gov_registration_by = fn_staff_id(), gov_registration_at = now(),
           shomoos_guest_count = cnt, shomoos_accepted_at = null, shomoos_accepted_by = null, version = version + 1, updated_at = now()
     where id = r.id;
    perform fn_audit_change(r.branch_id, 'reservation.shomoos_registered', 'reservation', r.id, before,
      jsonb_build_object('reference', ref, 'guest_count', cnt, 'accepted', false));
  else
    if not coalesce(r.government_registration, false) or r.gov_registration_ref is null then raise exception 'VALIDATION: shomoos_not_registered'; end if;
    if r.shomoos_guest_count is distinct from cnt then raise exception 'VALIDATION: shomoos_guest_count'; end if;
    if r.shomoos_accepted_at is not null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update reservations set shomoos_accepted_at = now(), shomoos_accepted_by = fn_staff_id(), version = version + 1, updated_at = now() where id = r.id;
    perform fn_audit_change(r.branch_id, 'reservation.shomoos_accepted', 'reservation', r.id, before,
      jsonb_build_object('reference', r.gov_registration_ref, 'guest_count', cnt, 'accepted', true));
  end if;
  return jsonb_build_object('ok', true, 'unchanged', false);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_switch_room(p_reservation uuid, p_room uuid, p_effective date, p_reason text, p_expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r reservations%rowtype; old reservation_allocations%rowtype; eff date; old_room uuid; new_rm rooms%rowtype; new_kb boolean;
begin
  perform fn_require_cap('room.assign');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  eff := coalesce(p_effective, greatest(fn_branch_today(r.branch_id), r.check_in));
  if eff < r.check_in or eff >= r.check_out then raise exception 'VALIDATION: effective_date'; end if;
  if r.status = 'checked_in' and eff > fn_branch_today(r.branch_id) then raise exception 'VALIDATION: effective_date'; end if;   -- a resident moves now, not in the future
  select * into new_rm from rooms where id = p_room;
  if not found or new_rm.branch_id <> r.branch_id then raise exception 'ROOM_NOT_FOUND'; end if;            -- R06
  if r.room_id = p_room then raise exception 'SAME_ROOM'; end if;
  if r.status = 'checked_in' and new_rm.cleanliness <> 'clean' then raise exception 'ROOM_NOT_CLEAN'; end if;
  if r.adults + r.companions > (select max_capacity from room_categories where id = new_rm.category_id) then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- lock rooms in a fixed order to avoid deadlocks when two switches cross
  perform 1 from rooms where id in (p_room, r.room_id) order by id for update;

  select * into old from reservation_allocations where reservation_id = r.id and status = 'active' and daterange(from_date, to_date, '[)') @> eff for update;
  if found then
    if old.room_id = p_room then raise exception 'SAME_ROOM'; end if;
    old_room := old.room_id;
    if old.from_date = eff then
      update reservation_allocations set status = 'cancelled', closed_at = now(), reason = coalesce(reason,'') || ' | switched' where id = old.id;
    else
      update reservation_allocations set to_date = eff, status = case when eff <= fn_branch_today(r.branch_id) and r.status = 'checked_in' then 'closed' else 'active' end,
             closed_at = case when eff <= fn_branch_today(r.branch_id) and r.status = 'checked_in' then now() end where id = old.id;
    end if;
    if r.status = 'checked_in' then
      update rooms set status = 'cleaning', cleanliness = 'dirty' where id = old_room;
      insert into housekeeping_tasks(organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot, reservation_id, priority, description, created_by)
      select r.organization_id, r.branch_id, old_room, t.id, t.name, r.id, 'high', 'تبديل وحدة', fn_staff_id() from task_types t where t.id = fn_room_cleaning_type(r.branch_id);
      update keyboxes set code_status = 'needs_change', field_tested = false where room_id = old_room;
    else
      update rooms set status = 'available' where id = old_room and status = 'reserved';
    end if;
  end if;

  -- category may differ on switch (upgrade/downgrade): price difference is a separate explicit adjustment
  update reservations set room_category_id = new_rm.category_id where id = r.id and r.room_category_id <> new_rm.category_id;
  perform fn_allocate(r.id, p_room, eff, r.check_out, 'switch: ' || p_reason);
  new_kb := exists (select 1 from keyboxes where room_id = p_room);
  if r.status = 'checked_in' then
    update rooms set status = 'occupied' where id = p_room;
    update reservations set access_status = case when new_kb then 'approved' else 'key_handed' end::access_status, keybox_delivered = false where id = r.id;
  end if;
  update reservations set version = version + 1, updated_at = now() where id = r.id;
  perform fn_audit_change(r.branch_id, 'reservation.room_switched', 'reservation', r.id, jsonb_build_object('room_id', old_room), jsonb_build_object('room_id', p_room, 'effective', eff), p_reason);
  return jsonb_build_object('ok', true, 'from_room', old_room, 'to_room', p_room, 'effective', eff,
                            'entry_code_review_required', r.status = 'checked_in', 'code_delivery_required', r.status = 'checked_in' and new_kb);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_undo_cancel(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); a record; back reservation_status; today date; n int := 0;
begin
  perform fn_require_cap('res.undo_cancel');
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_staff_undo_check_in(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; reason text := nullif(trim(coalesce(p->>'reason', '')), ''); shown boolean;
begin
  perform fn_require_cap('checkin.undo');
  if reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into r from reservations where id = (p->>'reservation_id')::uuid for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status <> 'checked_in' then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if r.actual_check_in is null or now() - r.actual_check_in > interval '30 minutes' then
    raise exception 'CORRECTION_WINDOW_PASSED: an arrival is undone within 30 minutes';
  end if;
  if p ? 'expected_version' then perform fn_check_version(r.version, (p->>'expected_version')::int); end if;
  shown := r.access_status in ('delivered', 'acknowledged');
  update reservations set status = 'confirmed', actual_check_in = null, checked_in_by = null, checkin_approved_by = null, checkin_approved_at = null,
         access_status = 'locked', keybox_delivered = false, version = version + 1, updated_at = now()
   where id = r.id;
  if r.room_id is not null then
    update rooms set status = 'reserved', updated_at = now() where id = r.room_id and status = 'occupied';
    -- a code already given out is no longer the guest's to keep: it must change before anyone gets it
    if shown then update keyboxes set code_status = 'needs_change', field_tested = false where room_id = r.room_id and last_reservation_id = r.id; end if;
  end if;
  perform fn_add_review_item(r.branch_id, 'check_in_undone', 'reservation', r.id, r.id, 'تراجع عن تسجيل وصول ' || r.internal_ref, reason,
    jsonb_build_object('checked_in_at', r.actual_check_in, 'code_was_given', shown));
  perform fn_audit_change(r.branch_id, 'reservation.check_in_undone', 'reservation', r.id,
    jsonb_build_object('status', 'checked_in', 'actual_check_in', r.actual_check_in), jsonb_build_object('status', 'confirmed', 'code_needs_change', shown), reason);
  return jsonb_build_object('ok', true, 'code_needs_change', shown);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_stay_followups(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare loc timestamp; cot time; v_over jsonb; v_open jsonb; v_late jsonb;
begin
  perform fn_require_money();
  perform fn_require_branch(p_branch);
  loc := fn_branch_local_now(p_branch);
  cot := coalesce((select check_out_time from branches where id = p_branch), time '12:00');
  select coalesce(jsonb_agg(x order by x->>'overdue_since'), '[]'::jsonb) into v_over from (
    select jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', (select room_number from rooms where id = r.room_id),
             'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
             'overdue_amount', (dd.d->>'overdue_amount')::bigint, 'overdue_since', dd.d->>'overdue_since', 'check_out', r.check_out,
             'excused', not fn_overdue_blocked(r.id)) as x
    from reservations r cross join lateral (select fn_stay_due_internal(r.id) as d) dd
    where r.branch_id = p_branch and r.status = 'checked_in' and coalesce((dd.d->>'overdue')::boolean, false)) s;
  select coalesce(jsonb_agg(x order by x->>'checked_out_at'), '[]'::jsonb) into v_open from (
    select jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', (select room_number from rooms where id = r.room_id),
             'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
             'checked_out_at', r.actual_check_out, 'missing', to_jsonb(fn_closure_missing(r.id)),
             'inspected', exists (select 1 from checkout_inspections i where i.reservation_id = r.id and i.status = 'active'),
             'deposit_balance', r.deposit_balance_halalas) as x
    from reservations r where r.branch_id = p_branch and r.status = 'checked_out') s;
  select coalesce(jsonb_agg(x order by x->>'check_out'), '[]'::jsonb) into v_late from (
    select jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'room_number', (select room_number from rooms where id = r.room_id),
             'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
             'check_out', r.check_out, 'departure_time', to_char(coalesce(r.late_checkout_until, cot), 'HH24:MI')) as x
    from reservations r where r.branch_id = p_branch and r.status = 'checked_in' and loc > (r.check_out + coalesce(r.late_checkout_until, cot))) s;
  return jsonb_build_object('generated_at', now(), 'overdue', v_over, 'departed_open', v_open, 'late_departures', v_late);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_stay_status(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r reservations%rowtype; br branches%rowtype; money boolean; mgr boolean; kb keyboxes%rowtype; has_kb boolean := false; d jsonb; dep time; loc timestamp;
        insp record; exc record; missing text[]; stayed boolean; refund_blocker text; checkin jsonb; code jsonb;
begin
  select * into r from reservations where id = p_reservation;
  if not found or not fn_has_role('owner','manager','supervisor','finance','housekeeping')
     or not (r.branch_id in (select fn_user_branch_ids())) then return null; end if;
  money := fn_sees_money();
  mgr := fn_has_role('owner','manager');
  select * into br from branches where id = r.branch_id;
  if r.room_id is not null then select * into kb from keyboxes where room_id = r.room_id limit 1; has_kb := found; end if;
  dep := coalesce(r.late_checkout_until, br.check_out_time, time '12:00');
  loc := fn_branch_local_now(r.branch_id);
  if money then d := fn_stay_due_internal(r.id); end if;
  select i.result, i.notes, i.suggested_deduction_halalas, i.inspected_at, s.full_name as by_name into insp
    from checkout_inspections i left join staff_profiles s on s.id = i.inspected_by
   where i.reservation_id = r.id and i.status = 'active' order by i.inspected_at desc limit 1;
  select e.reason, e.through_night, e.created_at, s.full_name as by_name into exc
    from stay_payment_exceptions e left join staff_profiles s on s.id = e.created_by
   where e.reservation_id = r.id order by e.created_at desc limit 1;
  if r.status in ('checked_out', 'closed') then missing := fn_closure_missing(r.id); end if;
  stayed := r.actual_check_in is not null or r.status in ('checked_in', 'checked_out', 'closed');
  refund_blocker := case when not stayed then null
                         when r.status not in ('checked_out', 'closed') then 'يُرد التأمين بعد تسجيل المغادرة'
                         when insp.result is null then 'سجّل فحص المغادرة أولًا'
                         else null end;
  if r.status in ('draft', 'pending_verification', 'confirmed') then
    checkin := jsonb_build_object('blockers', to_jsonb(fn_checkin_core_blockers(r.id)));
    if money then
      checkin := checkin || jsonb_build_object('money_blockers', to_jsonb(fn_checkin_money_blockers(r.id, 0, 0, null)),
        'first_night', (d->>'first_night')::bigint, 'collected', (d->>'collected')::bigint,
        'first_night_short', greatest((d->>'first_night')::bigint - (d->>'collected')::bigint, 0),
        'deposit_required', (d->>'deposit_required')::bigint, 'deposit_balance', (d->>'deposit_balance')::bigint,
        'deposit_short', greatest((d->>'deposit_required')::bigint - (d->>'deposit_balance')::bigint, 0));
    end if;
  end if;
  if r.status = 'checked_in' then
    code := jsonb_build_object('blockers', to_jsonb(fn_code_blockers(r.id)), 'delivered', r.access_status in ('delivered', 'acknowledged'));
  end if;
  return jsonb_build_object(
    'status', r.status, 'version', r.version, 'access_status', r.access_status,
    'room_number', (select room_number from rooms where id = r.room_id), 'has_keybox', has_kb,
    'keybox_state', case when not has_kb then 'none' when kb.code_encrypted is null then 'unset' when kb.code_status <> 'active' then 'needs_change'
                         when not kb.field_tested then 'untested' else 'ready' end,
    'departure_time', to_char(dep, 'HH24:MI'), 'late_checkout_until', to_char(r.late_checkout_until, 'HH24:MI'),
    'late_departure', r.status = 'checked_in' and loc > (r.check_out + dep),
    'checked_in_at', r.actual_check_in, 'checked_in_by', (select full_name from staff_profiles where id = r.checked_in_by),
    'checked_out_at', r.actual_check_out, 'checked_out_by', (select full_name from staff_profiles where id = r.checked_out_by),
    'checkin', checkin, 'code', code,
    'due', case when money then d end,
    'overdue_blocked', case when money and r.status = 'checked_in' then fn_overdue_blocked(r.id) end,
    'payment_exception', case when money and exc.reason is not null then jsonb_build_object('reason', exc.reason, 'through_night', exc.through_night, 'by', exc.by_name, 'at', exc.created_at) end,
    'deposit_waiver', case when money and r.deposit_waiver_reason is not null then jsonb_build_object('reason', r.deposit_waiver_reason, 'at', r.deposit_waiver_at,
                                                                                                  'by', (select full_name from staff_profiles where id = r.deposit_waiver_by)) end,
    'shomoos', jsonb_build_object('registered', coalesce(r.government_registration, false) and r.gov_registration_ref is not null,
                                  'reference', case when money then r.gov_registration_ref end, 'registered_at', r.gov_registration_at,
                                  'registered_by', (select full_name from staff_profiles where id = r.gov_registration_by),
                                  'guest_count', r.shomoos_guest_count, 'guests_now', r.adults + r.companions,
                                  'accepted_at', r.shomoos_accepted_at, 'accepted_by', (select full_name from staff_profiles where id = r.shomoos_accepted_by)),
    'inspection', case when insp.result is not null then jsonb_build_object('result', insp.result, 'notes', insp.notes,
                                                                            'suggested', case when money then insp.suggested_deduction_halalas end,
                                                                            'by', insp.by_name, 'at', insp.inspected_at) end,
    'inspection_due', r.status = 'checked_out' or (r.status = 'checked_in' and loc::date >= r.check_out),
    'deposit_refund_blocker', case when money then refund_blocker end,
    'corrections', jsonb_build_object(
        'allowed', mgr,
        'undo_check_in_until', case when r.status = 'checked_in' and r.actual_check_in > now() - interval '30 minutes' then r.actual_check_in + interval '30 minutes' end,
        'reopen_until', case when r.status in ('checked_out', 'closed') and r.actual_check_out > now() - interval '2 hours' then r.actual_check_out + interval '2 hours' end,
        'undo_cancel_until', case when r.status = 'cancelled' and r.cancelled_at > now() - interval '1 hour' then r.cancelled_at + interval '1 hour' end),
    'closure', case when r.status in ('checked_out', 'closed') then jsonb_build_object('closed', r.status = 'closed', 'closed_at', r.closed_at,
                                                                                       'missing', case when money then to_jsonb(missing) else '[]'::jsonb end) end);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_stay_summary(p_reservation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_branch uuid;
begin
  perform fn_require_money();
  select branch_id into v_branch from reservations where id = p_reservation;
  if v_branch is null then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  return fn_stay_summary_internal(p_reservation) || jsonb_build_object('acknowledgements', fn_ack_list(p_reservation));
end $function$;

CREATE OR REPLACE FUNCTION public.fn_voucher_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q jsonb := coalesce(p, '{}'::jsonb); v_branch uuid := (q->>'branch_id')::uuid; tz text; v_from date; v_to date; v_kind text; v_method text; v_account text; v_acc uuid; v_acc_none boolean; v_status text;
        v_staff uuid; v_res uuid; v_q text; lim int; off int; total bigint; rows jsonb; totals jsonb;
begin
  perform fn_require_money();
  if v_branch is null then raise exception 'VALIDATION: branch_id'; end if;
  perform fn_require_branch(v_branch);
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = v_branch;
  v_from := (q->>'from')::date; v_to := (q->>'to')::date;
  if v_from is not null and v_to is not null and v_to < v_from then raise exception 'VALIDATION: period'; end if;
  v_kind := nullif(q->>'kind', ''); v_method := nullif(q->>'method', ''); v_account := nullif(q->>'account_id', ''); v_status := coalesce(nullif(q->>'status', ''), 'approved');
  v_acc_none := v_account = 'none'; v_acc := case when v_account is not null and v_account <> 'none' then v_account::uuid end;   -- 'none': the vouchers of no box or account
  v_staff := (q->>'staff_id')::uuid; v_res := (q->>'reservation_id')::uuid; v_q := nullif(trim(coalesce(q->>'q', '')), '');
  if v_status not in ('approved', 'cancelled', 'all') then raise exception 'VALIDATION: status'; end if;
  lim := least(greatest(coalesce((q->>'limit')::int, 100), 1), 1000); off := greatest(coalesce((q->>'offset')::int, 0), 0);
  with x as (
    select v.* from financial_vouchers v
    where v.branch_id = v_branch
      and (v_from is null or (v.occurred_at at time zone tz)::date >= v_from)
      and (v_to is null or (v.occurred_at at time zone tz)::date <= v_to)
      and (v_kind is null or v.kind = v_kind)
      and (v_method is null or v.method::text = v_method)
      and (v_account is null or (v_acc_none and v.account_id is null) or v.account_id = v_acc)
      and (v_status = 'all' or v.status = v_status)
      and (v_staff is null or v.created_by = v_staff)
      and (v_res is null or v.reservation_id = v_res)
      and (v_q is null or v.number ilike '%' || v_q || '%' or coalesce(v.reference, '') ilike '%' || v_q || '%'
           or exists (select 1 from reservations r where r.id = v.reservation_id and r.internal_ref ilike '%' || v_q || '%'))
  )
  select count(*),
         coalesce((select jsonb_agg(jsonb_build_object('id', y.id, 'number', y.number, 'kind', y.kind, 'amount_halalas', y.amount_halalas, 'method', y.method, 'status', y.status,
                    'reference', y.reference, 'reason', y.reason, 'note', y.note, 'occurred_at', y.occurred_at, 'cancel_reason', y.cancel_reason, 'cancelled_at', y.cancelled_at,
                    'created_by', y.created_by, 'creator_name', (select full_name from staff_profiles where id = y.created_by),
                    'account_id', y.account_id, 'account_name', (select name from cash_accounts where id = y.account_id), 'payout_id', y.payout_id,
                    'original_voucher_id', y.original_voucher_id, 'original_number', (select number from financial_vouchers o where o.id = y.original_voucher_id),
                    'reservation', case when y.reservation_id is not null then jsonb_build_object('id', y.reservation_id, 'internal_ref', (select internal_ref from reservations where id = y.reservation_id)) end)
                    order by y.occurred_at desc, y.number desc)
                   from (select * from x order by occurred_at desc, number desc limit lim offset off) y), '[]'::jsonb),
         jsonb_build_object(
           'receipts', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'receipt'), 0),
           'refunds', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'refund'), 0),
           'deposits', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'deposit'), 0),
           'deposit_refunds', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'deposit_refund'), 0),
           'deposit_applied', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'deposit_apply'), 0),
           'approved', count(*) filter (where status = 'approved'), 'cancelled', count(*) filter (where status = 'cancelled'),
           'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', m, 'amount_halalas', a) order by a desc) from (select method::text m, sum(amount_halalas) a from x where status = 'approved' and kind = 'receipt' group by method) z), '[]'::jsonb),
           'by_account', coalesce((select jsonb_agg(jsonb_build_object('account_id', acc, 'account_name', (select name from cash_accounts where id = acc), 'in_halalas', i, 'out_halalas', o) order by i desc)
                                   from (select account_id acc, coalesce(sum(amount_halalas) filter (where kind in ('receipt', 'deposit')), 0) i, coalesce(sum(amount_halalas) filter (where kind in ('refund', 'deposit_refund')), 0) o
                                         from x where status = 'approved' and account_id is not null group by account_id) z), '[]'::jsonb))
    into total, rows, totals from x;
  return jsonb_build_object('total', total, 'rows', rows, 'totals', totals, 'limit', lim, 'offset', off, 'tz', tz);
end $function$;
