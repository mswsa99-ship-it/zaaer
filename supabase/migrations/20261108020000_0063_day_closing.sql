-- 0063 — A2 and A3 of the accounting stage (plan «خطة تصحيح ملاحظات التجربة», stage م٣, phase أ; notes 15 and 17;
-- decision 4: after the window, a request to the management):
--   A2 «إقفال اليوم»: for a branch-local day the system computes the units (rented, arrivals, departures, out of service)
--      and the table «طريقة الدفع × مصدر الحجز» (rent in, deposit in, paid back) from the approved vouchers, and a box for
--      cash, the terminal, transfers and each platform with money that day. The supervisor enters what was counted and
--      the reason of every difference; a summary must be reviewed before sending (its hash travels with the send, so a
--      voucher that arrives meanwhile asks for a new review); every closing is kept with its state (draft, open, closed).
--   A3 «قاعدة التعديل»: after sending, a free edit window (30 minutes by default, a setting of the branch) where every
--      edit is recorded (before, after, reason) and lands in «بحاجة لمراجعة»; after it every edit is refused until the
--      management approves a request with its reason, which opens a new window.
--   The figures sent are frozen; if a voucher of that day changes later, the closing says so.
--   Two operations join the permissions matrix: «day.close» and «day.close.approve».

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The permissions matrix: the catalogue with the two operations of the closing (the owner can change both)
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
    ('day.close', 'إقفال اليوم: العدّ والفروق والإرسال والتعديل خلال المهلة وطلب التعديل بعدها', 'المال', 334, '{owner,manager,supervisor,finance}', null, null, false),
    ('day.close.approve', 'الموافقة على طلب تعديل إقفال بعد مهلته', 'المال', 336, '{owner,manager}', null, null, false),
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
-- 2. The edit window after sending, per branch (the owner's principle: what can change is a setting, not a constant)
-- ---------------------------------------------------------------------------------------------------------------
alter table branches add column if not exists day_close_edit_minutes int not null default 30;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'branches_day_close_edit_minutes_valid') then
    alter table branches add constraint branches_day_close_edit_minutes_valid check (day_close_edit_minutes between 5 and 240);
  end if;
end $$;

create or replace function fn_admin_set_day_close_minutes(p_branch uuid, p_minutes int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare before int;
begin
  perform fn_require_cap('branch.settings');
  perform fn_require_branch(p_branch);
  if p_minutes is null or p_minutes < 5 or p_minutes > 240 then raise exception 'VALIDATION: edit_minutes'; end if;
  select day_close_edit_minutes into before from branches where id = p_branch for update;
  if before is distinct from p_minutes then
    update branches set day_close_edit_minutes = p_minutes, updated_at = now() where id = p_branch;
    perform fn_audit_change(p_branch, 'branch.day_close_rules_changed', 'branch', p_branch,
                            jsonb_build_object('day_close_edit_minutes', before), jsonb_build_object('day_close_edit_minutes', p_minutes));
  end if;
  return jsonb_build_object('ok', true, 'minutes', p_minutes);
end $$;
revoke all on function fn_admin_set_day_close_minutes(uuid, int) from public, anon;
grant execute on function fn_admin_set_day_close_minutes(uuid, int) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The closing of a day: one per branch and day; its lines are the boxes of the day
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists day_closings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  business_date date not null,
  status text not null default 'draft',
  figures jsonb,                       -- what the system computed, frozen when sent (counts, the method × source table, boxes)
  review_hash text,                    -- the money of the summary the sender reviewed (boxes and lines)
  review_token text,                   -- issued by the review only, required once by the send: a send without a review fails
  note text,
  submitted_at timestamptz,
  submitted_by uuid references staff_profiles(id),
  edit_until timestamptz,              -- the free edit window: sending + the branch's minutes, or an approval + the minutes
  version int not null default 1,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  updated_by uuid references staff_profiles(id),
  updated_at timestamptz not null default now(),
  constraint day_closing_status_valid check (status in ('draft', 'submitted')),
  constraint day_closing_sent_shape check (status = 'draft' or (submitted_at is not null and edit_until is not null and figures is not null))
);
create unique index if not exists uniq_day_closing_day on day_closings(branch_id, business_date);
create index if not exists idx_day_closings_branch on day_closings(branch_id, business_date desc);
alter table day_closings enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'day_closings' and policyname = 'day_closings_read') then
    create policy "day_closings_read" on day_closings for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and (fn_can('day.close') or fn_can('day.close.approve')));
  end if;
end $$;
revoke insert, update on day_closings from anon, authenticated;

create table if not exists day_closing_lines (
  id uuid primary key default gen_random_uuid(),
  closing_id uuid not null references day_closings(id),
  line_key text not null,              -- cash | pos | bank_transfer | platform:<source id>
  box text not null,                   -- cash | pos | bank_transfer | platform
  account_id uuid references cash_accounts(id),
  source_id uuid references booking_sources(id),
  system_halalas bigint not null default 0,
  entered_halalas bigint,             -- the day's net as counted: what came in less what was paid back (may be below zero)
  difference_halalas bigint,
  reason text,
  updated_at timestamptz not null default now(),
  constraint day_closing_line_box_valid check (box in ('cash', 'pos', 'bank_transfer', 'platform'))
);
create unique index if not exists uniq_day_closing_line on day_closing_lines(closing_id, line_key);
alter table day_closing_lines enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'day_closing_lines' and policyname = 'day_closing_lines_read') then
    create policy "day_closing_lines_read" on day_closing_lines for select to authenticated
      using (closing_id in (select id from day_closings));
  end if;
end $$;
revoke insert, update on day_closing_lines from anon, authenticated;

create table if not exists day_closing_requests (
  id uuid primary key default gen_random_uuid(),
  closing_id uuid not null references day_closings(id),
  branch_id uuid not null references branches(id),
  reason text not null,
  status text not null default 'pending',
  requested_by uuid references staff_profiles(id),
  requested_at timestamptz not null default now(),
  decided_by uuid references staff_profiles(id),
  decided_at timestamptz,
  decision_note text,
  constraint day_closing_request_status_valid check (status in ('pending', 'approved', 'rejected'))
);
create unique index if not exists uniq_day_closing_request_pending on day_closing_requests(closing_id) where status = 'pending';
alter table day_closing_requests enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'day_closing_requests' and policyname = 'day_closing_requests_read') then
    create policy "day_closing_requests_read" on day_closing_requests for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and (fn_can('day.close') or fn_can('day.close.approve')));
  end if;
end $$;
revoke insert, update on day_closing_requests from anon, authenticated;

-- the state a person sees: a draft; sent and still in its edit window; or closed (after the window)
create or replace function fn_day_closing_state(p_status text, p_edit_until timestamptz) returns text
language sql stable set search_path = public as $$
  select case when p_status = 'draft' then 'draft' when p_edit_until > now() then 'open' else 'locked' end
$$;
revoke all on function fn_day_closing_state(text, timestamptz) from public, anon;
grant execute on function fn_day_closing_state(text, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. What the system recorded for a branch-local day (A2: «محسوبة تلقائيًا»)
-- ---------------------------------------------------------------------------------------------------------------
-- the box a payment method lands in (older methods stay readable on their vouchers)
create or replace function fn_closing_box(p_method text) returns text language sql immutable set search_path = public as $$
  select case when p_method = 'cash' then 'cash' when p_method in ('pos', 'mada', 'card', 'payment_link') then 'pos'
              when p_method = 'bank_transfer' then 'bank_transfer' when p_method in ('ota_deferred', 'booking_platform') then 'platform' end
$$;
revoke all on function fn_closing_box(text) from public, anon;
grant execute on function fn_closing_box(text) to authenticated;

create or replace function fn_day_closing_compute(p_branch uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text; ds timestamptz; de timestamptz; rooms jsonb; matrix jsonb; boxes jsonb;
begin
  tz := coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
  ds := p_date::timestamp at time zone tz;
  de := (p_date + 1)::timestamp at time zone tz;
  select jsonb_build_object(
    'units', count(*) filter (where r.is_active and r.archived_at is null),
    'out_of_service', count(*) filter (where r.is_active and r.archived_at is null and r.status in ('maintenance', 'out_of_service', 'blocked')),
    'rented', (select count(*) from reservations x where x.branch_id = p_branch and x.check_in <= p_date and x.check_out > p_date
                 and x.status in ('checked_in', 'checked_out', 'closed')),
    'arrivals', (select count(*) from reservations x where x.branch_id = p_branch and x.actual_check_in >= ds and x.actual_check_in < de),
    'departures', (select count(*) from reservations x where x.branch_id = p_branch and x.actual_check_out >= ds and x.actual_check_out < de))
  into rooms from rooms r where r.branch_id = p_branch;

  with v as (
    select fv.method::text as method, fn_closing_box(fv.method::text) as box, rs.source_id, fv.kind, fv.amount_halalas
    from financial_vouchers fv join reservations rs on rs.id = fv.reservation_id
    where fv.branch_id = p_branch and fv.status = 'approved' and fv.kind <> 'deposit_apply' and fv.occurred_at >= ds and fv.occurred_at < de
      and fn_closing_box(fv.method::text) is not null
  ), cell as (
    select box, source_id,
           coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0)::bigint as rent_in,
           coalesce(sum(amount_halalas) filter (where kind = 'deposit'), 0)::bigint as deposit_in,
           coalesce(sum(amount_halalas) filter (where kind in ('refund', 'deposit_refund')), 0)::bigint as paid_out,
           count(*) as vouchers
    from v group by box, source_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('box', c.box, 'source_id', c.source_id,
                                                'source', coalesce((select name from booking_sources where id = c.source_id), 'مباشر'),
                                                'rent_in', c.rent_in, 'deposit_in', c.deposit_in, 'paid_out', c.paid_out,
                                                'net', c.rent_in + c.deposit_in - c.paid_out, 'vouchers', c.vouchers)
                    order by c.box, coalesce((select name from booking_sources where id = c.source_id), '')), '[]'::jsonb)
  into matrix from cell c;

  -- the boxes: cash, terminal and transfer always; one line per platform that had money that day
  select coalesce(jsonb_agg(b order by b->>'sort', b->>'label'), '[]'::jsonb) into boxes from (
    select jsonb_build_object('key', k.box, 'box', k.box, 'sort', k.sort, 'label', k.label, 'source_id', null,
             'account_id', (select id from cash_accounts where branch_id = p_branch and kind = case when k.box = 'cash' then 'cash_box' else 'bank_account' end
                              and archived_at is null order by is_default desc limit 1),
             'system_halalas', coalesce((select sum((m->>'net')::bigint) from jsonb_array_elements(matrix) m where m->>'box' = k.box), 0),
             'required', k.box in ('cash', 'pos')) as b
    from (values ('cash', '1', 'النقد'), ('pos', '2', 'الشبكة'), ('bank_transfer', '3', 'التحويل')) k(box, sort, label)
    union all
    -- platform money of a booking without a source still gets its line («آجل — مباشر»), so nothing goes uncounted
    select jsonb_build_object('key', 'platform:' || coalesce(m->>'source_id', 'direct'), 'box', 'platform', 'sort', '4', 'label', 'آجل — ' || (m->>'source'),
             'source_id', m->>'source_id', 'account_id', null, 'system_halalas', (m->>'net')::bigint, 'required', false)
    from jsonb_array_elements(matrix) m where m->>'box' = 'platform'
  ) s(b);

  return jsonb_build_object('business_date', p_date, 'rooms', rooms, 'matrix', matrix, 'boxes', boxes);
end $$;
revoke all on function fn_day_closing_compute(uuid, date) from public, anon, authenticated;

-- the money of the summary the sender confirms: each box's system amount and what was entered (not the room counts or
-- the labels, which may change without changing the money)
create or replace function fn_day_closing_summary_hash(p_figures jsonb, p_lines jsonb) returns text
language sql immutable set search_path = public as $$
  select md5(coalesce((select jsonb_agg(jsonb_build_array(b->>'key', b->'system_halalas') order by b->>'key')
                       from jsonb_array_elements(coalesce(p_figures->'boxes', '[]'::jsonb)) b), '[]'::jsonb)::text
             || '|' || coalesce((select jsonb_agg(jsonb_build_array(l->>'key', l->'entered_halalas', l->>'reason') order by l->>'key')
                                 from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) l), '[]'::jsonb)::text)
$$;
revoke all on function fn_day_closing_summary_hash(jsonb, jsonb) from public, anon, authenticated;

create or replace function fn_day_closing_lines_json(p_closing uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', line_key, 'box', box, 'account_id', account_id, 'source_id', source_id,
                                               'system_halalas', system_halalas, 'entered_halalas', entered_halalas,
                                               'difference_halalas', difference_halalas, 'reason', reason) order by line_key), '[]'::jsonb)
  from day_closing_lines where closing_id = p_closing
$$;
revoke all on function fn_day_closing_lines_json(uuid) from public, anon, authenticated;

-- the day's lines against the system: entered − system (null while not entered)
create or replace function fn_day_closing_put_lines(p_closing uuid, p_figures jsonb, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare b jsonb; l jsonb; v_entered bigint; v_reason text; v_sys bigint;
begin
  for b in select * from jsonb_array_elements(coalesce(p_figures->'boxes', '[]'::jsonb)) loop
    select x into l from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x where x->>'key' = b->>'key' limit 1;
    v_sys := (b->>'system_halalas')::bigint;
    v_entered := null; v_reason := null;
    if l is not null then
      if nullif(l->>'entered_halalas', '') is not null then
        if (l->>'entered_halalas') !~ '^-?[0-9]{1,15}$' then raise exception 'VALIDATION: entered_amount'; end if;
        v_entered := (l->>'entered_halalas')::bigint;
      end if;
      v_reason := nullif(trim(coalesce(l->>'reason', '')), '');
      if v_reason is not null and char_length(v_reason) > 500 then raise exception 'VALIDATION: reason'; end if;
    else
      select entered_halalas, reason into v_entered, v_reason from day_closing_lines where closing_id = p_closing and line_key = b->>'key';
    end if;
    insert into day_closing_lines(closing_id, line_key, box, account_id, source_id, system_halalas, entered_halalas, difference_halalas, reason, updated_at)
    values (p_closing, b->>'key', b->>'box', nullif(b->>'account_id', '')::uuid, nullif(b->>'source_id', '')::uuid, v_sys, v_entered,
            case when v_entered is null then null else v_entered - v_sys end, v_reason, now())
    on conflict (closing_id, line_key) do update set account_id = excluded.account_id, system_halalas = excluded.system_halalas,
      entered_halalas = excluded.entered_halalas, difference_halalas = excluded.difference_halalas, reason = excluded.reason, updated_at = now();
  end loop;
  -- a platform line whose money left the day (a voucher cancelled) keeps what was entered against a system of zero
  update day_closing_lines set system_halalas = 0, difference_halalas = case when entered_halalas is null then null else entered_halalas end, updated_at = now()
   where closing_id = p_closing and system_halalas <> 0
     and line_key not in (select b2->>'key' from jsonb_array_elements(coalesce(p_figures->'boxes', '[]'::jsonb)) b2);
end $$;
revoke all on function fn_day_closing_put_lines(uuid, jsonb, jsonb) from public, anon, authenticated;

-- the closing of a day as a person sees it: the stored one (with its frozen figures once sent) and the live figures
create or replace function fn_day_closing_get(p_branch uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c day_closings%rowtype; live jsonb; v_state text;
begin
  if not (fn_can('day.close') or fn_can('day.close.approve')) then raise exception 'FORBIDDEN: day.close' using errcode = '42501'; end if;
  perform fn_require_branch(p_branch);
  if p_date is null or p_date > fn_branch_today(p_branch) then raise exception 'VALIDATION: business_date'; end if;
  live := fn_day_closing_compute(p_branch, p_date);
  select * into c from day_closings where branch_id = p_branch and business_date = p_date;
  if c.id is null then
    return jsonb_build_object('closing', null, 'state', 'none', 'live', live, 'lines', '[]'::jsonb, 'requests', '[]'::jsonb,
                              'edit_minutes', (select day_close_edit_minutes from branches where id = p_branch), 'changed_since_sent', false);
  end if;
  v_state := fn_day_closing_state(c.status, c.edit_until);
  return jsonb_build_object(
    'closing', jsonb_build_object('id', c.id, 'status', c.status, 'version', c.version, 'note', c.note, 'submitted_at', c.submitted_at,
                                  'submitted_by', (select full_name from staff_profiles where id = c.submitted_by), 'edit_until', c.edit_until,
                                  'figures', c.figures),
    'state', v_state, 'live', live, 'lines', fn_day_closing_lines_json(c.id),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'reason', r.reason, 'requested_at', r.requested_at,
                                                              'requested_by', (select full_name from staff_profiles where id = r.requested_by),
                                                              'decided_at', r.decided_at, 'decision_note', r.decision_note,
                                                              'decided_by', (select full_name from staff_profiles where id = r.decided_by)) order by r.requested_at desc)
                          from day_closing_requests r where r.closing_id = c.id), '[]'::jsonb),
    'edit_minutes', (select day_close_edit_minutes from branches where id = p_branch),
    -- a voucher of that day changed after sending: the frozen figures and today's differ (the owner sees it)
    'changed_since_sent', c.status = 'submitted'
      and (select coalesce(jsonb_agg(jsonb_build_array(b->>'key', b->'system_halalas') order by b->>'key'), '[]'::jsonb) from jsonb_array_elements(c.figures->'boxes') b)
          is distinct from (select coalesce(jsonb_agg(jsonb_build_array(b->>'key', b->'system_halalas') order by b->>'key'), '[]'::jsonb) from jsonb_array_elements(live->'boxes') b));
end $$;
revoke all on function fn_day_closing_get(uuid, date) from public, anon;
grant execute on function fn_day_closing_get(uuid, date) to authenticated;

-- save a draft: the counts entered and the reasons; the system lines are recomputed every time
create or replace function fn_day_closing_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_date date := (p->>'business_date')::date; c day_closings%rowtype; live jsonb;
        v_note text := nullif(trim(coalesce(p->>'note', '')), '');
begin
  perform fn_require_cap('day.close');
  perform fn_require_branch(v_branch);
  if v_date is null or v_date > fn_branch_today(v_branch) then raise exception 'VALIDATION: business_date'; end if;
  if v_note is not null and char_length(v_note) > 1000 then raise exception 'VALIDATION: note'; end if;
  perform pg_advisory_xact_lock(hashtext('day_closing:' || v_branch::text || ':' || v_date::text));
  select * into c from day_closings where branch_id = v_branch and business_date = v_date for update;
  if c.id is null then
    insert into day_closings(organization_id, branch_id, business_date, note, created_by, updated_by)
    values ((select organization_id from branches where id = v_branch), v_branch, v_date, v_note, fn_staff_id(), fn_staff_id()) returning * into c;
    perform fn_audit_change(v_branch, 'day_closing.created', 'day_closing', c.id, null, jsonb_build_object('business_date', v_date));
  else
    perform fn_check_version_strict(c.version, (p->>'version')::int);
    if c.status <> 'draft' then raise exception 'CLOSING_SENT'; end if;
    update day_closings set note = case when p ? 'note' then v_note else note end, review_token = null, version = version + 1, updated_by = fn_staff_id(), updated_at = now()
     where id = c.id returning * into c;
  end if;
  live := fn_day_closing_compute(v_branch, v_date);
  perform fn_day_closing_put_lines(c.id, live, p->'lines');
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version);
end $$;
revoke all on function fn_day_closing_save(jsonb) from public, anon;
grant execute on function fn_day_closing_save(jsonb) to authenticated;

-- the mandatory review: the summary to confirm and its hash (A2: «مراجعة إلزامية قبل الإرسال»)
create or replace function fn_day_closing_review(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c day_closings%rowtype; live jsonb; lines jsonb; missing jsonb; unexplained jsonb;
begin
  perform fn_require_cap('day.close');
  select * into c from day_closings where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(c.branch_id);
  if c.status <> 'draft' then raise exception 'CLOSING_SENT'; end if;
  live := fn_day_closing_compute(c.branch_id, c.business_date);
  perform fn_day_closing_put_lines(c.id, live, null);    -- the system lines as of now; what was entered stays
  lines := fn_day_closing_lines_json(c.id);
  select coalesce(jsonb_agg(b->>'key'), '[]'::jsonb) into missing from jsonb_array_elements(live->'boxes') b
   where (b->>'required')::boolean and not exists (select 1 from jsonb_array_elements(lines) l where l->>'key' = b->>'key' and l->>'entered_halalas' is not null);
  select coalesce(jsonb_agg(l->>'key'), '[]'::jsonb) into unexplained from jsonb_array_elements(lines) l
   where coalesce((l->>'difference_halalas')::bigint, 0) <> 0 and coalesce(l->>'reason', '') = '';
  -- the review issues the one token a send accepts, bound to the money shown here
  update day_closings set review_hash = fn_day_closing_summary_hash(live, lines), review_token = md5(gen_random_uuid()::text || clock_timestamp()::text)
   where id = c.id returning * into c;
  return jsonb_build_object('id', c.id, 'version', c.version, 'figures', live, 'lines', lines, 'missing', missing, 'unexplained', unexplained,
                            'hash', c.review_token, 'edit_minutes', (select day_close_edit_minutes from branches where id = c.branch_id));
end $$;
revoke all on function fn_day_closing_review(uuid) from public, anon;
grant execute on function fn_day_closing_review(uuid) to authenticated;

-- send: only the summary that was reviewed (its hash), every required count entered, every difference explained
create or replace function fn_day_closing_submit(p_id uuid, p_version int, p_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c day_closings%rowtype; live jsonb; lines jsonb; v_minutes int;
begin
  perform fn_require_cap('day.close');
  select * into c from day_closings where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(c.branch_id);
  perform fn_check_version_strict(c.version, p_version);
  if c.status <> 'draft' then raise exception 'CLOSING_SENT'; end if;
  live := fn_day_closing_compute(c.branch_id, c.business_date);
  perform fn_day_closing_put_lines(c.id, live, null);
  lines := fn_day_closing_lines_json(c.id);
  -- the token of a review, and the money still as it was reviewed
  if p_hash is null or c.review_token is null or p_hash <> c.review_token or c.review_hash is distinct from fn_day_closing_summary_hash(live, lines) then
    raise exception 'REVIEW_STALE';
  end if;
  if exists (select 1 from jsonb_array_elements(live->'boxes') b where (b->>'required')::boolean
             and not exists (select 1 from jsonb_array_elements(lines) l where l->>'key' = b->>'key' and l->>'entered_halalas' is not null)) then
    raise exception 'VALIDATION: closing_counts';
  end if;
  if exists (select 1 from jsonb_array_elements(lines) l where coalesce((l->>'difference_halalas')::bigint, 0) <> 0 and coalesce(l->>'reason', '') = '') then
    raise exception 'VALIDATION: closing_reason';
  end if;
  select day_close_edit_minutes into v_minutes from branches where id = c.branch_id;
  update day_closings set status = 'submitted', figures = live, review_token = null, submitted_at = now(), submitted_by = fn_staff_id(),
                          edit_until = now() + make_interval(mins => v_minutes), version = version + 1, updated_by = fn_staff_id(), updated_at = now()
   where id = c.id returning * into c;
  perform fn_audit_change(c.branch_id, 'day_closing.submitted', 'day_closing', c.id, null,
                          jsonb_build_object('business_date', c.business_date, 'lines', lines, 'edit_until', c.edit_until));
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version, 'edit_until', c.edit_until);
end $$;
revoke all on function fn_day_closing_submit(uuid, int, text) from public, anon;
grant execute on function fn_day_closing_submit(uuid, int, text) to authenticated;

-- A3: inside the window an edit is free but recorded (before, after, reason) and lands in «بحاجة لمراجعة»;
-- after it the closing refuses every edit until a request is approved
create or replace function fn_day_closing_amend(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c day_closings%rowtype; before jsonb; after jsonb; v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
begin
  perform fn_require_cap('day.close');
  select * into c from day_closings where id = (p->>'id')::uuid for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(c.branch_id);
  perform fn_check_version_strict(c.version, (p->>'version')::int);
  if c.status <> 'submitted' then raise exception 'CLOSING_NOT_SENT'; end if;
  if c.edit_until <= now() then raise exception 'CLOSING_LOCKED'; end if;
  if v_reason is null or char_length(v_reason) > 500 then raise exception 'VALIDATION: reason'; end if;
  before := fn_day_closing_lines_json(c.id);
  perform fn_day_closing_put_lines(c.id, c.figures, p->'lines');   -- against the figures that were sent
  after := fn_day_closing_lines_json(c.id);
  if exists (select 1 from jsonb_array_elements(after) l join jsonb_array_elements(c.figures->'boxes') b on b->>'key' = l->>'key'
             where (b->>'required')::boolean and l->>'entered_halalas' is null) then
    raise exception 'VALIDATION: closing_counts';
  end if;
  if exists (select 1 from jsonb_array_elements(after) l where coalesce((l->>'difference_halalas')::bigint, 0) <> 0 and coalesce(l->>'reason', '') = '') then
    raise exception 'VALIDATION: closing_reason';
  end if;
  if after = before then return jsonb_build_object('ok', true, 'unchanged', true, 'version', c.version); end if;
  update day_closings set version = version + 1, updated_by = fn_staff_id(), updated_at = now() where id = c.id returning * into c;
  perform fn_audit_change(c.branch_id, 'day_closing.amended', 'day_closing', c.id, jsonb_build_object('lines', before), jsonb_build_object('lines', after), v_reason);
  perform fn_add_review_item(c.branch_id, 'day_closing_amended', 'day_closing', c.id, null,
                             'تعديل إقفال يوم ' || to_char(c.business_date, 'YYYY-MM-DD') || ' بعد إرساله', v_reason,
                             jsonb_build_object('business_date', c.business_date, 'before', before, 'after', after));
  return jsonb_build_object('ok', true, 'version', c.version);
end $$;
revoke all on function fn_day_closing_amend(jsonb) from public, anon;
grant execute on function fn_day_closing_amend(jsonb) to authenticated;

-- after the window: a request with its reason, one at a time
create or replace function fn_day_closing_request_edit(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c day_closings%rowtype; r day_closing_requests%rowtype; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('day.close');
  select * into c from day_closings where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(c.branch_id);
  if c.status <> 'submitted' then raise exception 'CLOSING_NOT_SENT'; end if;
  if c.edit_until > now() then raise exception 'CLOSING_OPEN'; end if;
  if v_reason is null or char_length(v_reason) > 500 then raise exception 'VALIDATION: reason'; end if;
  if exists (select 1 from day_closing_requests where closing_id = c.id and status = 'pending') then raise exception 'REQUEST_PENDING'; end if;
  insert into day_closing_requests(closing_id, branch_id, reason, requested_by) values (c.id, c.branch_id, v_reason, fn_staff_id()) returning * into r;
  perform fn_audit_change(c.branch_id, 'day_closing.edit_requested', 'day_closing', c.id, null, jsonb_build_object('request_id', r.id), v_reason);
  return jsonb_build_object('ok', true, 'request_id', r.id);
end $$;
revoke all on function fn_day_closing_request_edit(uuid, text) from public, anon;
grant execute on function fn_day_closing_request_edit(uuid, text) to authenticated;

-- the management decides: approval opens a new window of the branch's minutes; a refusal says why
create or replace function fn_day_closing_decide(p_request uuid, p_approve boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r day_closing_requests%rowtype; c day_closings%rowtype; v_note text := nullif(trim(coalesce(p_note, '')), ''); v_minutes int;
begin
  perform fn_require_cap('day.close.approve');
  select * into r from day_closing_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  if r.status <> 'pending' then raise exception 'REQUEST_DECIDED'; end if;
  -- the one who asked does not decide (the owner excepted): the control stays with the management
  if r.requested_by = fn_staff_id() and fn_current_role() <> 'owner' then raise exception 'SELF_DECISION'; end if;
  if p_approve is null then raise exception 'VALIDATION: decision'; end if;
  if not p_approve and v_note is null then raise exception 'VALIDATION: note_required'; end if;
  if v_note is not null and char_length(v_note) > 500 then raise exception 'VALIDATION: note'; end if;
  update day_closing_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = fn_staff_id(), decided_at = now(),
                                  decision_note = v_note where id = r.id returning * into r;
  select * into c from day_closings where id = r.closing_id for update;
  if p_approve then
    select day_close_edit_minutes into v_minutes from branches where id = c.branch_id;
    update day_closings set edit_until = now() + make_interval(mins => v_minutes), version = version + 1, updated_at = now() where id = c.id returning * into c;
  end if;
  perform fn_audit_change(c.branch_id, case when p_approve then 'day_closing.edit_approved' else 'day_closing.edit_rejected' end, 'day_closing', c.id, null,
                          jsonb_build_object('request_id', r.id, 'edit_until', case when p_approve then c.edit_until end), coalesce(v_note, r.reason));
  return jsonb_build_object('ok', true, 'status', r.status, 'edit_until', case when p_approve then c.edit_until end);
end $$;
revoke all on function fn_day_closing_decide(uuid, boolean, text) from public, anon;
grant execute on function fn_day_closing_decide(uuid, boolean, text) to authenticated;

-- the archive: every closing of a branch in a period with its state and totals; the pending requests first
create or replace function fn_day_closing_list(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (fn_can('day.close') or fn_can('day.close.approve')) then raise exception 'FORBIDDEN: day.close' using errcode = '42501'; end if;
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  return jsonb_build_object(
    'closings', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'business_date', c.business_date, 'state', fn_day_closing_state(c.status, c.edit_until),
                                                              'submitted_at', c.submitted_at, 'submitted_by', (select full_name from staff_profiles where id = c.submitted_by),
                                                              'edit_until', c.edit_until,
                                                              'system_halalas', (select coalesce(sum(system_halalas), 0) from day_closing_lines where closing_id = c.id),
                                                              'difference_halalas', (select coalesce(sum(difference_halalas), 0) from day_closing_lines where closing_id = c.id),
                                                              'pending_request', exists (select 1 from day_closing_requests r where r.closing_id = c.id and r.status = 'pending'))
                                           order by c.business_date desc)
                          from day_closings c where c.branch_id = p_branch and c.business_date between p_from and p_to), '[]'::jsonb),
    'pending_requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'closing_id', r.closing_id, 'business_date', c.business_date, 'reason', r.reason,
                                                                      'requested_at', r.requested_at, 'requested_by', (select full_name from staff_profiles where id = r.requested_by))
                                                   order by r.requested_at)
                                  from day_closing_requests r join day_closings c on c.id = r.closing_id
                                  where r.branch_id = p_branch and r.status = 'pending'), '[]'::jsonb),
    -- the days before today with no sent closing, from the branch's first closing on (none before the first)
    'missing_days', coalesce((select jsonb_agg(d::date order by d desc)
                              from generate_series(greatest(p_from, coalesce((select min(business_date) from day_closings where branch_id = p_branch), fn_branch_today(p_branch))),
                                                   least(p_to, fn_branch_today(p_branch) - 1), interval '1 day') d
                              where not exists (select 1 from day_closings c where c.branch_id = p_branch and c.business_date = d::date and c.status = 'submitted')), '[]'::jsonb));
end $$;
revoke all on function fn_day_closing_list(uuid, date, date) from public, anon;
grant execute on function fn_day_closing_list(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Readable names for the log (the dictionary in force stays 0048's; the accounting names live in their own function)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_audit_accounting_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select case p_action
      when 'day_closing.created' then 'بدء إقفال يوم'
      when 'day_closing.submitted' then 'إرسال إقفال يوم'
      when 'day_closing.amended' then 'تعديل إقفال يوم خلال المهلة'
      when 'day_closing.edit_requested' then 'طلب تعديل إقفال بعد المهلة'
      when 'day_closing.edit_approved' then 'الموافقة على تعديل إقفال'
      when 'day_closing.edit_rejected' then 'رفض تعديل إقفال'
      when 'branch.day_close_rules_changed' then 'تغيير مهلة تعديل الإقفال'
      else null
    end;
$$;
revoke all on function fn_audit_accounting_label(text) from public, anon;
grant execute on function fn_audit_accounting_label(text) to authenticated, service_role;
do $$
declare fn oid; def text; n int;
        old_p constant text := $a$    fn_audit_removal_label(p_action),$a$;
        new_p constant text := $b$    fn_audit_removal_label(p_action),
    fn_audit_accounting_label(p_action),$b$;
        old_e constant text := $a$    end, replace(p_entity, '_', ' ')) end;$a$;
        new_e constant text := $b$    end, case p_entity when 'day_closing' then 'إقفال يوم' end, replace(p_entity, '_', ' ')) end;$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_action_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_p, ''))) / length(old_p);
  if n <> 1 then raise exception '0063: the removal line of fn_audit_action_label was found % times, not once', n; end if;
  execute replace(def, old_p, new_p);
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_entity_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0063: the last line of fn_audit_entity_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;
