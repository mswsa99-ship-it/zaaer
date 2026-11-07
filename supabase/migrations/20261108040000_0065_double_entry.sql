-- 0065 — A5 of the accounting stage (plan «خطة تصحيح ملاحظات التجربة», stage م٣, phase ج: «القيد المزدوج والتقارير»):
--   · a numbered chart of accounts (1 assets, 2 liabilities, 3 equity, 4 revenue, 5 expenses); the account of each box,
--     bank account, platform and expense category is opened under its parent on first use;
--   · every approved voucher, expense, platform payout, closing difference and opening balance makes its balanced entry
--     automatically (the database refuses an unbalanced one); a cancellation makes the reversing entry; the guest's
--     deposit is a liability (21), never revenue — it becomes revenue only when it is applied to the rent;
--   · the trial balance, the account statement, the income statement and the balance sheet, computed by the server;
--   · the owner locks a month: every entry dated in it is refused, whatever path writes it (an opened month is recorded);
--   · two operations join the permissions matrix: «accounts.view», «accounts.close_month».

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The permissions matrix: the catalogue with the two operations of the accounts
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
    ('expense.create', 'سند صرف بتصنيفه ومرفقه من صندوق الفرع أو حسابه البنكي', 'المال', 337, '{owner,manager,supervisor,finance}', null, null, false),
    ('expense.cancel', 'إلغاء سند صرف بسبب', 'المال', 338, '{owner,manager}', null, null, false),
    ('ledger.view', 'دفتر حركة الصندوق والحساب البنكي برصيده الجاري', 'المال', 339, '{owner,manager,supervisor,finance}', null, null, false),
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
    ('accounts.view', 'دليل الحسابات والقيود وميزان المراجعة وقائمة الدخل والميزانية', 'التقارير والسجل', 524, '{owner,manager,finance}', null, null, false),
    ('accounts.close_month', 'قفل الشهر المحاسبي وفتحه', 'التقارير والسجل', 526, '{owner}', null, null, false),
    ('reports.identities_usage', 'تقرير الهويات المعتمدة من المكتب وتقرير الاستعمال', 'التقارير والسجل', 530, '{owner}', null, null, false),
    ('audit.log', 'سجل الإجراءات', 'التقارير والسجل', 540, '{owner,manager,supervisor}', '{owner,manager}', 'بلا تفاصيل التغييرات', false);
$$;
grant execute on function fn_permission_catalog() to authenticated;

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
      when 'expense.created' then 'إصدار سند صرف'
      when 'expense.cancelled' then 'إلغاء سند صرف'
      when 'expense_category.created' then 'إضافة تصنيف مصروف'
      when 'expense_category.updated' then 'تعديل تصنيف مصروف'
      when 'cash_account.opening_set' then 'تحديد الرصيد الافتتاحي'
      when 'accounting.month_locked' then 'قفل شهر محاسبي'
      when 'accounting.month_opened' then 'فتح شهر محاسبي'
      else null
    end;
$$;
revoke all on function fn_audit_accounting_label(text) from public, anon;
grant execute on function fn_audit_accounting_label(text) to authenticated, service_role;
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$when 'expense_category' then 'تصنيف مصروف' end$a$;
        new_e constant text := $b$when 'expense_category' then 'تصنيف مصروف' when 'accounting_period' then 'شهر محاسبي' end$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_entity_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0065: the closing line of fn_audit_entity_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The chart of accounts: a numbered tree; the accounts of a box, a bank account, a platform and an expense category
--    are created on first use under their parents, so the chart grows with the system and is never typed twice
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists gl_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  code text not null,
  name text not null,
  type text not null,                         -- asset | liability | equity | revenue | expense
  parent_id uuid references gl_accounts(id),
  is_postable boolean not null default true,
  system_key text,                            -- the fixed accounts the postings use (cash_parent, rent_revenue, …)
  cash_account_id uuid references cash_accounts(id),
  source_id uuid references booking_sources(id),
  expense_category_id uuid references expense_categories(id),
  branch_id uuid references branches(id),
  created_at timestamptz not null default now(),
  constraint gl_account_type_valid check (type in ('asset', 'liability', 'equity', 'revenue', 'expense')),
  constraint gl_account_code_valid check (code ~ '^[0-9]{1,8}$')
);
create unique index if not exists uniq_gl_account_code on gl_accounts(organization_id, code);
create unique index if not exists uniq_gl_account_system on gl_accounts(organization_id, system_key) where system_key is not null;
create unique index if not exists uniq_gl_account_cash on gl_accounts(cash_account_id) where cash_account_id is not null;
create unique index if not exists uniq_gl_account_source on gl_accounts(organization_id, source_id) where source_id is not null;
create unique index if not exists uniq_gl_account_category on gl_accounts(expense_category_id) where expense_category_id is not null;
alter table gl_accounts enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'gl_accounts' and policyname = 'gl_accounts_read') then
    create policy "gl_accounts_read" on gl_accounts for select to authenticated
      using (organization_id = fn_user_org_id() and fn_can('accounts.view') and (branch_id is null or branch_id in (select fn_user_branch_ids())));
  end if;
end $$;
revoke all on gl_accounts from anon, authenticated;
grant select on gl_accounts to authenticated;

-- the fixed part of the chart (standard numbering: 1 assets, 2 liabilities, 3 equity, 4 revenue, 5 expenses)
create or replace function fn_gl_seed(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_parent uuid;
begin
  perform pg_advisory_xact_lock(hashtext('gl_seed:' || p_org::text));
  for r in select * from (values
      ('1',    'الأصول',                     'asset',     null,  false, 'assets'),
      ('11',   'النقد وما في حكمه',           'asset',     '1',   false, 'cash_group'),
      ('111',  'صناديق الفروع',              'asset',     '11',  false, 'cash_parent'),
      ('112',  'الحسابات البنكية',            'asset',     '11',  false, 'bank_parent'),
      ('12',   'الذمم المدينة',              'asset',     '1',   false, 'receivables'),
      ('121',  'مستحقات المنصات',            'asset',     '12',  false, 'platform_parent'),
      ('129',  'حساب معلّق',                 'asset',     '12',  true,  'suspense'),
      ('2',    'الالتزامات',                 'liability', null,  false, 'liabilities'),
      ('21',   'تأمينات الضيوف',             'liability', '2',   true,  'deposits'),
      ('3',    'حقوق الملكية',               'equity',    null,  false, 'equity'),
      ('31',   'الأرصدة الافتتاحية',          'equity',    '3',   true,  'opening'),
      ('4',    'الإيرادات',                  'revenue',   null,  false, 'revenue'),
      ('41',   'إيراد الإيجار',               'revenue',   '4',   true,  'rent_revenue'),
      ('42',   'مردودات الإيجار',             'revenue',   '4',   true,  'rent_returns'),
      ('49',   'إيرادات أخرى وزيادات',        'revenue',   '4',   true,  'other_income'),
      ('5',    'المصروفات',                  'expense',   null,  false, 'expenses'),
      ('51',   'المصروفات التشغيلية',         'expense',   '5',   false, 'expense_parent'),
      ('58',   'عمولات المنصات',             'expense',   '5',   true,  'platform_commission'),
      ('59',   'عجز الصندوق',                'expense',   '5',   true,  'cash_shortage')
    ) t(code, name, type, parent, postable, key)
  loop
    if not exists (select 1 from gl_accounts where organization_id = p_org and system_key = r.key) then
      select id into v_parent from gl_accounts where organization_id = p_org and code = r.parent;
      insert into gl_accounts(organization_id, code, name, type, parent_id, is_postable, system_key)
      values (p_org, r.code, r.name, r.type, v_parent, r.postable, r.key);
    end if;
  end loop;
end $$;
revoke all on function fn_gl_seed(uuid) from public, anon, authenticated;
select fn_gl_seed(id) from organizations;

create or replace function fn_gl_system(p_org uuid, p_key text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from gl_accounts where organization_id = p_org and system_key = p_key;
  if v is null then perform fn_gl_seed(p_org); select id into v from gl_accounts where organization_id = p_org and system_key = p_key; end if;
  return v;
end $$;
revoke all on function fn_gl_system(uuid, text) from public, anon, authenticated;

-- the next free code under a parent: parent code followed by two digits (11101, 11102, …)
create or replace function fn_gl_child(p_org uuid, p_parent_key text, p_name text, p_type text) returns uuid
language plpgsql security definer set search_path = public as $$
declare p gl_accounts%rowtype; n int; v uuid;
begin
  select * into p from gl_accounts where id = fn_gl_system(p_org, p_parent_key);
  perform pg_advisory_xact_lock(hashtext('gl_child:' || p.id::text));
  select coalesce(max(right(code, 2)::int), 0) + 1 into n from gl_accounts where parent_id = p.id and code ~ ('^' || p.code || '[0-9]{2}$');
  if n > 99 then raise exception 'GL_CHART_FULL'; end if;
  insert into gl_accounts(organization_id, code, name, type, parent_id, is_postable)
  values (p_org, p.code || lpad(n::text, 2, '0'), left(p_name, 120), p_type, p.id, true) returning id into v;
  return v;
end $$;
revoke all on function fn_gl_child(uuid, text, text, text) from public, anon, authenticated;

create or replace function fn_gl_for_cash(p_cash uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; v uuid;
begin
  select id into v from gl_accounts where cash_account_id = p_cash;
  if v is not null then return v; end if;
  perform pg_advisory_xact_lock(hashtext('gl_for:' || p_cash::text));
  select id into v from gl_accounts where cash_account_id = p_cash;
  if v is not null then return v; end if;
  select * into a from cash_accounts where id = p_cash;
  v := fn_gl_child(a.organization_id, case when a.kind = 'cash_box' then 'cash_parent' else 'bank_parent' end,
                   a.name || ' — ' || (select name_ar from branches where id = a.branch_id), 'asset');
  update gl_accounts set cash_account_id = a.id, branch_id = a.branch_id where id = v;
  return v;
end $$;
revoke all on function fn_gl_for_cash(uuid) from public, anon, authenticated;

create or replace function fn_gl_for_source(p_org uuid, p_source uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if p_source is null then return fn_gl_system(p_org, 'suspense'); end if;
  select id into v from gl_accounts where organization_id = p_org and source_id = p_source;
  if v is not null then return v; end if;
  perform pg_advisory_xact_lock(hashtext('gl_for:' || p_source::text));
  select id into v from gl_accounts where organization_id = p_org and source_id = p_source;
  if v is not null then return v; end if;
  v := fn_gl_child(p_org, 'platform_parent', 'مستحقات ' || coalesce((select name from booking_sources where id = p_source), 'منصة'), 'asset');
  update gl_accounts set source_id = p_source where id = v;
  return v;
end $$;
revoke all on function fn_gl_for_source(uuid, uuid) from public, anon, authenticated;

create or replace function fn_gl_for_category(p_category uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare c expense_categories%rowtype; v uuid;
begin
  select id into v from gl_accounts where expense_category_id = p_category;
  if v is not null then return v; end if;
  perform pg_advisory_xact_lock(hashtext('gl_for:' || p_category::text));
  select id into v from gl_accounts where expense_category_id = p_category;
  if v is not null then return v; end if;
  select * into c from expense_categories where id = p_category;
  v := fn_gl_child(c.organization_id, 'expense_parent', c.name, 'expense');
  update gl_accounts set expense_category_id = c.id where id = v;
  return v;
end $$;
revoke all on function fn_gl_for_category(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The journal: an entry and its lines, always balanced; a locked month refuses every entry dated in it
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists accounting_periods (
  organization_id uuid not null references organizations(id),
  month date not null,                         -- the first day of the month
  locked boolean not null default true,      -- opened again → false (the row and its history stay)
  changed_at timestamptz not null default now(),
  changed_by uuid references staff_profiles(id),
  reason text not null,
  primary key (organization_id, month),
  constraint accounting_period_month_valid check (extract(day from month) = 1)
);
alter table accounting_periods enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'accounting_periods' and policyname = 'accounting_periods_read') then
    create policy "accounting_periods_read" on accounting_periods for select to authenticated using (organization_id = fn_user_org_id() and fn_can('accounts.view'));
  end if;
end $$;
revoke all on accounting_periods from anon, authenticated;
grant select on accounting_periods to authenticated;

create table if not exists journal_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid references branches(id),
  number text not null,
  entry_date date not null,
  source_type text not null,                   -- voucher | expense | payout | day_closing | opening
  source_id uuid not null,
  posting text not null,                       -- what produced it (post, reverse, repost:<n>) — one each per source
  description text not null,
  reversal_of uuid references journal_entries(id),
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now()
);
create unique index if not exists uniq_journal_number on journal_entries(organization_id, number);
create unique index if not exists uniq_journal_posting on journal_entries(source_type, source_id, posting);
create index if not exists idx_journal_date on journal_entries(organization_id, entry_date);
create index if not exists idx_journal_branch_date on journal_entries(branch_id, entry_date);
alter table journal_entries enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'journal_entries' and policyname = 'journal_entries_read') then
    create policy "journal_entries_read" on journal_entries for select to authenticated
      using (organization_id = fn_user_org_id() and fn_can('accounts.view') and (branch_id is null or branch_id in (select fn_user_branch_ids())));
  end if;
end $$;
revoke all on journal_entries from anon, authenticated;
grant select on journal_entries to authenticated;

create table if not exists journal_lines (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references journal_entries(id),
  account_id uuid not null references gl_accounts(id),
  debit_halalas bigint not null default 0,
  credit_halalas bigint not null default 0,
  memo text,
  constraint journal_line_one_side check ((debit_halalas > 0 and credit_halalas = 0) or (credit_halalas > 0 and debit_halalas = 0))
);
create index if not exists idx_journal_lines_entry on journal_lines(entry_id);
create index if not exists idx_journal_lines_account on journal_lines(account_id);
alter table journal_lines enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'journal_lines' and policyname = 'journal_lines_read') then
    create policy "journal_lines_read" on journal_lines for select to authenticated using (entry_id in (select id from journal_entries));
  end if;
end $$;
revoke all on journal_lines from anon, authenticated;
grant select on journal_lines to authenticated;

-- the database checks every entry at the end of its transaction: debits equal credits, and at least two lines
create or replace function fn_trg_journal_balanced() returns trigger
language plpgsql security definer set search_path = public as $$
declare d bigint; c bigint; n int;
begin
  select coalesce(sum(debit_halalas), 0), coalesce(sum(credit_halalas), 0), count(*) into d, c, n from journal_lines where entry_id = new.entry_id;
  if d <> c or n < 2 then raise exception 'JOURNAL_UNBALANCED: % debit, % credit, % lines', d, c, n; end if;
  return null;
end $$;
revoke all on function fn_trg_journal_balanced() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_journal_balanced' and tgrelid = 'public.journal_lines'::regclass) then
    create constraint trigger trg_journal_balanced after insert or update on journal_lines deferrable initially deferred
      for each row execute function fn_trg_journal_balanced();
  end if;
end $$;

-- the month lock: no entry is dated in a locked month, whatever path writes it
create or replace function fn_trg_journal_period() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- shared with the other writers, exclusive against the owner locking this month (no entry slips in while it locks)
  perform pg_advisory_xact_lock_shared(hashtext('period:' || new.organization_id::text || ':' || to_char(new.entry_date, 'YYYY-MM')));
  if exists (select 1 from accounting_periods where organization_id = new.organization_id and month = date_trunc('month', new.entry_date)::date and locked) then
    raise exception 'PERIOD_LOCKED: %', to_char(new.entry_date, 'YYYY-MM');
  end if;
  return new;
end $$;
revoke all on function fn_trg_journal_period() from public, anon, authenticated;
create or replace trigger trg_journal_period before insert or update of entry_date on journal_entries for each row execute function fn_trg_journal_period();

-- one entry: p_lines = [{account_id, debit, credit, memo}], amounts in halalas; skipped when the posting exists already
create or replace function fn_gl_post(p_org uuid, p_branch uuid, p_date date, p_source_type text, p_source uuid, p_posting text,
                                      p_description text, p_lines jsonb, p_reversal_of uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e uuid; l jsonb; dr bigint; cr bigint;
begin
  select id into e from journal_entries where source_type = p_source_type and source_id = p_source and posting = p_posting;
  if e is not null then return e; end if;
  insert into journal_entries(organization_id, branch_id, number, entry_date, source_type, source_id, posting, description, reversal_of, created_by)
  values (p_org, p_branch, fn_next_document_number(p_org, 'journal', 'JE'), p_date, p_source_type, p_source, p_posting, left(p_description, 300), p_reversal_of, fn_staff_id())
  returning id into e;
  for l in select * from jsonb_array_elements(p_lines) loop
    dr := coalesce((l->>'debit')::bigint, 0); cr := coalesce((l->>'credit')::bigint, 0);
    if dr = 0 and cr = 0 then continue; end if;
    -- a negative amount is the other side
    if dr < 0 then cr := cr - dr; dr := 0; end if;
    if cr < 0 then dr := dr - cr; cr := 0; end if;
    if dr > 0 and cr > 0 then
      if dr >= cr then dr := dr - cr; cr := 0; else cr := cr - dr; dr := 0; end if;
      if dr = 0 and cr = 0 then continue; end if;
    end if;
    insert into journal_lines(entry_id, account_id, debit_halalas, credit_halalas, memo) values (e, (l->>'account_id')::uuid, dr, cr, l->>'memo');
  end loop;
  return e;
end $$;
revoke all on function fn_gl_post(uuid, uuid, date, text, uuid, text, text, jsonb, uuid) from public, anon, authenticated;

-- the reversal of a source's entries (every posting not yet reversed), dated on the given day
create or replace function fn_gl_reverse(p_source_type text, p_source uuid, p_date date, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare e journal_entries%rowtype;
begin
  for e in select * from journal_entries je where je.source_type = p_source_type and je.source_id = p_source and je.reversal_of is null
            and not exists (select 1 from journal_entries r where r.reversal_of = je.id) order by je.created_at loop
    perform fn_gl_post(e.organization_id, e.branch_id, p_date, e.source_type, e.source_id, 'reverse:' || e.id::text,
                       'عكس ' || e.number || ': ' || coalesce(p_reason, ''),
                       (select jsonb_agg(jsonb_build_object('account_id', account_id, 'debit', credit_halalas, 'credit', debit_halalas, 'memo', memo))
                          from journal_lines where entry_id = e.id), e.id);
  end loop;
end $$;
revoke all on function fn_gl_reverse(text, uuid, date, text) from public, anon, authenticated;

create or replace function fn_branch_date(p_branch uuid, p_at timestamptz) returns date
language sql stable set search_path = public as $$
  select (p_at at time zone coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh'))::date
$$;
revoke all on function fn_branch_date(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. The postings: every voucher, expense, platform payout, closing difference and opening balance makes its entry
-- ---------------------------------------------------------------------------------------------------------------
-- a voucher (rent on cash basis; the deposit is a liability, never revenue):
--   receipt          Dr box/bank (or the platform's receivable)   Cr rent revenue
--   refund           Dr rent returns                              Cr box/bank (or the platform's receivable)
--   deposit          Dr box/bank                                  Cr guest deposits (liability)
--   deposit_refund   Dr guest deposits                            Cr box/bank
--   deposit_apply    Dr guest deposits                            Cr rent revenue (the deposit pays the rent, no money moves)
create or replace function fn_gl_post_voucher(p_id uuid, p_posting text default 'post') returns void
language plpgsql security definer set search_path = public as $$
declare v financial_vouchers%rowtype; v_org uuid; money uuid; src uuid; d date; label text;
begin
  select * into v from financial_vouchers where id = p_id;
  v_org := v.organization_id;
  select source_id into src from reservations where id = v.reservation_id;
  money := case when v.account_id is not null then fn_gl_for_cash(v.account_id)
                when v.method::text in ('ota_deferred', 'booking_platform') then fn_gl_for_source(v_org, src)
                else fn_gl_system(v_org, 'suspense') end;
  d := fn_branch_date(v.branch_id, v.occurred_at);
  label := v.number || ' — ' || case v.kind when 'receipt' then 'قبض إيجار' when 'refund' then 'رد مبلغ' when 'deposit' then 'قبض تأمين'
                                            when 'deposit_refund' then 'رد تأمين' else 'خصم من التأمين' end;
  perform fn_gl_post(v_org, v.branch_id, d, 'voucher', v.id, p_posting, label, case v.kind
    when 'receipt' then jsonb_build_array(jsonb_build_object('account_id', money, 'debit', v.amount_halalas),
                                          jsonb_build_object('account_id', fn_gl_system(v_org, 'rent_revenue'), 'credit', v.amount_halalas))
    when 'refund' then jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v_org, 'rent_returns'), 'debit', v.amount_halalas),
                                         jsonb_build_object('account_id', money, 'credit', v.amount_halalas))
    when 'deposit' then jsonb_build_array(jsonb_build_object('account_id', money, 'debit', v.amount_halalas),
                                          jsonb_build_object('account_id', fn_gl_system(v_org, 'deposits'), 'credit', v.amount_halalas))
    when 'deposit_refund' then jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v_org, 'deposits'), 'debit', v.amount_halalas),
                                                 jsonb_build_object('account_id', money, 'credit', v.amount_halalas))
    else jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v_org, 'deposits'), 'debit', v.amount_halalas),
                           jsonb_build_object('account_id', fn_gl_system(v_org, 'rent_revenue'), 'credit', v.amount_halalas)) end);
end $$;
revoke all on function fn_gl_post_voucher(uuid, text) from public, anon, authenticated;

create or replace function fn_trg_gl_voucher() returns trigger
language plpgsql security definer set search_path = public as $$
declare e journal_entries%rowtype; n int;
begin
  select count(*) into n from journal_entries where source_type = 'voucher' and source_id = new.id and reversal_of is null;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    perform fn_gl_post_voucher(new.id, case when n = 0 then 'post' else 'post:' || (n + 1) end);
  elsif tg_op = 'UPDATE' and old.status = 'approved' and new.status <> 'approved' then
    perform fn_gl_reverse('voucher', new.id, fn_branch_today(new.branch_id), 'إلغاء السند ' || new.number);
  elsif tg_op = 'UPDATE' and new.status = 'approved' and fn_branch_date(new.branch_id, new.occurred_at) <> fn_branch_date(old.branch_id, old.occurred_at) then
    -- the voucher's business day changed (a correction keeps the original's day): the entry follows it. Made in this
    -- transaction → re-dated (the month lock is checked again); made earlier → reversed today and booked again on its day
    select * into e from journal_entries je where je.source_type = 'voucher' and je.source_id = new.id and je.reversal_of is null
      and not exists (select 1 from journal_entries r where r.reversal_of = je.id) order by je.created_at desc limit 1;
    if e.id is not null and e.created_at = now() then
      update journal_entries set entry_date = fn_branch_date(new.branch_id, new.occurred_at) where id = e.id;
    elsif e.id is not null then
      perform fn_gl_reverse('voucher', new.id, fn_branch_today(new.branch_id), 'تغيير تاريخ السند ' || new.number);
      perform fn_gl_post_voucher(new.id, 'post:' || (n + 1));
    end if;
  end if;
  return null;
end $$;
revoke all on function fn_trg_gl_voucher() from public, anon, authenticated;
create or replace trigger trg_gl_voucher after insert or update of status, occurred_at on financial_vouchers for each row execute function fn_trg_gl_voucher();

-- an expense: Dr its category's account, Cr the box or the bank account
create or replace function fn_trg_gl_expense() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.status = 'approved' then
    perform fn_gl_post(new.organization_id, new.branch_id, fn_branch_date(new.branch_id, new.occurred_at), 'expense', new.id, 'post',
                       new.number || ' — ' || new.description,
                       jsonb_build_array(jsonb_build_object('account_id', fn_gl_for_category(new.category_id), 'debit', new.amount_halalas),
                                         jsonb_build_object('account_id', fn_gl_for_cash(new.account_id), 'credit', new.amount_halalas)));
  elsif tg_op = 'UPDATE' and old.status = 'approved' and new.status = 'cancelled' then
    perform fn_gl_reverse('expense', new.id, fn_branch_today(new.branch_id), 'إلغاء ' || new.number);
  end if;
  return null;
end $$;
revoke all on function fn_trg_gl_expense() from public, anon, authenticated;
create or replace trigger trg_gl_expense after insert or update of status on expense_vouchers for each row execute function fn_trg_gl_expense();

-- the platform's commission (0051) is booked alone in 58; what arrived short of the net is a shortage (59), over it other income (49)
create or replace function fn_gl_post_payout(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p platform_payouts%rowtype; gap bigint;
begin
  select * into p from platform_payouts where id = p_id;
  gap := p.expected_halalas - coalesce(p.commission_halalas, 0) - p.received_halalas;
  perform fn_gl_post(p.organization_id, p.branch_id, p.received_on, 'payout', p.id, 'post', 'دفعة منصة ' || p.reference,
                     jsonb_build_array(jsonb_build_object('account_id', fn_gl_for_cash(p.account_id), 'debit', p.received_halalas),
                                       jsonb_build_object('account_id', fn_gl_system(p.organization_id, 'platform_commission'), 'debit', coalesce(p.commission_halalas, 0)),
                                       jsonb_build_object('account_id', fn_gl_system(p.organization_id, case when gap >= 0 then 'cash_shortage' else 'other_income' end), 'debit', gap),
                                       jsonb_build_object('account_id', fn_gl_for_source(p.organization_id, p.source_id), 'credit', p.expected_halalas)));
end $$;
revoke all on function fn_gl_post_payout(uuid) from public, anon, authenticated;

-- a platform payout: Dr the bank what arrived, Cr the platform's receivable what was expected; the gap is the commission
-- (less arrived) or other income (more arrived)
create or replace function fn_trg_gl_payout() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.status = 'confirmed' then
    perform fn_gl_post_payout(new.id);
  elsif tg_op = 'UPDATE' and old.status = 'confirmed' and new.status = 'cancelled' then
    perform fn_gl_reverse('payout', new.id, fn_branch_today(new.branch_id), 'إلغاء دفعة المنصة ' || new.reference);
  end if;
  return null;
end $$;
revoke all on function fn_trg_gl_payout() from public, anon, authenticated;
create or replace trigger trg_gl_payout after insert or update of status on platform_payouts for each row execute function fn_trg_gl_payout();

-- the closing of a day: the cash counted differs from the system → the box takes the count (Dr shortage / Cr box, or
-- Dr box / Cr other income); the other boxes are matched with the bank (A8), not booked here. An amendment reposts.
create or replace function fn_gl_post_closing(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c day_closings%rowtype; l day_closing_lines%rowtype; n int; v_org uuid;
begin
  select * into c from day_closings where id = p_id;
  if c.status <> 'submitted' then return; end if;
  v_org := c.organization_id;
  select * into l from day_closing_lines where closing_id = c.id and line_key = 'cash';
  -- already booked as it stands (an approval that opens the edit window changes nothing) → nothing to do
  if l.id is not null and l.account_id is not null
     and coalesce((select sum(jl.debit_halalas - jl.credit_halalas) from journal_entries e join journal_lines jl on jl.entry_id = e.id
                   where e.source_type = 'day_closing' and e.source_id = c.id and jl.account_id = fn_gl_for_cash(l.account_id)), 0) = coalesce(l.difference_halalas, 0) then
    return;
  end if;
  -- what is booked now replaces what was booked before
  perform fn_gl_reverse('day_closing', c.id, c.business_date, 'تعديل إقفال يوم ' || to_char(c.business_date, 'YYYY-MM-DD'));
  if l.id is null or coalesce(l.difference_halalas, 0) = 0 or l.account_id is null then return; end if;
  select count(*) into n from journal_entries where source_type = 'day_closing' and source_id = c.id and reversal_of is null;
  perform fn_gl_post(v_org, c.branch_id, c.business_date, 'day_closing', c.id, 'post:' || (n + 1),
                     'فرق الصندوق في إقفال يوم ' || to_char(c.business_date, 'YYYY-MM-DD') || coalesce(': ' || l.reason, ''),
                     case when l.difference_halalas < 0 then
                       jsonb_build_array(jsonb_build_object('account_id', fn_gl_system(v_org, 'cash_shortage'), 'debit', -l.difference_halalas),
                                         jsonb_build_object('account_id', fn_gl_for_cash(l.account_id), 'credit', -l.difference_halalas))
                     else
                       jsonb_build_array(jsonb_build_object('account_id', fn_gl_for_cash(l.account_id), 'debit', l.difference_halalas),
                                         jsonb_build_object('account_id', fn_gl_system(v_org, 'other_income'), 'credit', l.difference_halalas)) end);
end $$;
revoke all on function fn_gl_post_closing(uuid) from public, anon, authenticated;

create or replace function fn_trg_gl_closing() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'submitted' and (old.status is distinct from 'submitted' or old.version is distinct from new.version) then
    perform fn_gl_post_closing(new.id);
  end if;
  return null;
end $$;
revoke all on function fn_trg_gl_closing() from public, anon, authenticated;
create or replace trigger trg_gl_closing after update on day_closings for each row execute function fn_trg_gl_closing();

-- the opening balance of a box or bank account is what was counted on its date (the ledger of 0064 starts there and
-- ignores what came before): the entry is the gap between that count and what the books held the day before, so the
-- account stands at the count on that day, as in the ledger. Dr/Cr the account against opening balances (31); reposted
-- when the owner changes it.
create or replace function fn_gl_post_opening(p_cash uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; before bigint := 0; amt bigint; n int; acc uuid;
begin
  select * into a from cash_accounts where id = p_cash;
  if coalesce(a.opening_balance_halalas, 0) = 0 and a.opening_on is null then return; end if;
  acc := fn_gl_for_cash(a.id);
  if a.opening_on is not null then
    select coalesce(sum(l.debit_halalas - l.credit_halalas), 0) into before from journal_lines l join journal_entries e on e.id = l.entry_id
     where l.account_id = acc and e.entry_date < a.opening_on and e.source_type <> 'opening';
  end if;
  amt := coalesce(a.opening_balance_halalas, 0) - before;
  if amt = 0 then return; end if;
  select count(*) into n from journal_entries where source_type = 'opening' and source_id = a.id and reversal_of is null;
  perform fn_gl_post(a.organization_id, a.branch_id, coalesce(a.opening_on, fn_branch_today(a.branch_id)), 'opening', a.id, 'post:' || (n + 1),
                     'الرصيد الافتتاحي لـ' || a.name || case when before <> 0 then ' (الفرق عن الدفاتر قبله)' else '' end,
                     jsonb_build_array(jsonb_build_object('account_id', acc, 'debit', amt),
                                       jsonb_build_object('account_id', fn_gl_system(a.organization_id, 'opening'), 'credit', amt)));
end $$;
revoke all on function fn_gl_post_opening(uuid) from public, anon, authenticated;

-- the opening balance changes: the earlier entry is reversed and the new one booked
create or replace function fn_trg_gl_opening() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (old.opening_balance_halalas is distinct from new.opening_balance_halalas or old.opening_on is distinct from new.opening_on) then
    perform fn_gl_reverse('opening', new.id, coalesce(old.opening_on, new.opening_on, fn_branch_today(new.branch_id)), 'تغيير الرصيد الافتتاحي');
    perform fn_gl_post_opening(new.id);
  end if;
  return null;
end $$;
revoke all on function fn_trg_gl_opening() from public, anon, authenticated;
create or replace trigger trg_gl_opening after update of opening_balance_halalas, opening_on on cash_accounts for each row execute function fn_trg_gl_opening();

-- what exists already gets its entries (in date order); a cancelled one gets its entry and its reversal
do $$
declare r record;
begin
  for r in select id, status, branch_id, number, occurred_at, cancelled_at from financial_vouchers where status in ('approved', 'cancelled') order by occurred_at loop
    perform fn_gl_post_voucher(r.id);
    if r.status = 'cancelled' then perform fn_gl_reverse('voucher', r.id, fn_branch_date(r.branch_id, coalesce(r.cancelled_at, r.occurred_at)), 'إلغاء السند ' || r.number); end if;
  end loop;
  for r in select * from expense_vouchers order by occurred_at loop
    perform fn_gl_post(r.organization_id, r.branch_id, fn_branch_date(r.branch_id, r.occurred_at), 'expense', r.id, 'post', r.number || ' — ' || r.description,
                       jsonb_build_array(jsonb_build_object('account_id', fn_gl_for_category(r.category_id), 'debit', r.amount_halalas),
                                         jsonb_build_object('account_id', fn_gl_for_cash(r.account_id), 'credit', r.amount_halalas)));
    if r.status = 'cancelled' then perform fn_gl_reverse('expense', r.id, fn_branch_date(r.branch_id, coalesce(r.cancelled_at, r.occurred_at)), 'إلغاء ' || r.number); end if;
  end loop;
  for r in select * from platform_payouts order by received_on, created_at loop
    perform fn_gl_post_payout(r.id);
    if r.status = 'cancelled' then perform fn_gl_reverse('payout', r.id, fn_branch_date(r.branch_id, coalesce(r.cancelled_at, r.created_at)), 'إلغاء دفعة المنصة ' || r.reference); end if;
  end loop;
  for r in select id from day_closings where status = 'submitted' order by business_date loop
    perform fn_gl_post_closing(r.id);
  end loop;
  for r in select id from cash_accounts where opening_balance_halalas <> 0 or opening_on is not null loop
    perform fn_gl_post_opening(r.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. The reports: trial balance, account statement, income statement, balance sheet; and the month lock
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_locked_months() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_char(month, 'YYYY-MM') order by month), '[]'::jsonb) from accounting_periods where organization_id = fn_user_org_id() and locked
$$;
revoke all on function fn_locked_months() from public, anon, authenticated;

-- the balances of every account over a period (or up to a day), for a branch or all of the owner's branches
create or replace function fn_gl_balances(p_from date, p_to date, p_branch uuid default null) returns table(account_id uuid, debit bigint, credit bigint)
language sql stable security definer set search_path = public as $$
  select l.account_id, sum(l.debit_halalas)::bigint, sum(l.credit_halalas)::bigint
  from journal_lines l join journal_entries e on e.id = l.entry_id
  where e.organization_id = fn_user_org_id() and e.entry_date between coalesce(p_from, '-infinity'::date) and p_to
    and (p_branch is null or e.branch_id = p_branch)
    and (e.branch_id is null or e.branch_id in (select fn_user_branch_ids()))
  group by l.account_id
$$;
revoke all on function fn_gl_balances(date, date, uuid) from public, anon, authenticated;

create or replace function fn_accounts_check(p_branch uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_can('accounts.view') then raise exception 'FORBIDDEN: accounts.view' using errcode = '42501'; end if;
  if p_branch is not null then perform fn_require_branch(p_branch); end if;
end $$;
revoke all on function fn_accounts_check(uuid) from public, anon, authenticated;

create or replace function fn_trial_balance(p_from date, p_to date, p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare rows jsonb; td bigint; tc bigint;
begin
  perform fn_accounts_check(p_branch);
  if p_from is null or p_to is null or p_from > p_to then raise exception 'VALIDATION: range'; end if;
  with opening as (select * from fn_gl_balances(null, p_from - 1, p_branch)),
       period as (select * from fn_gl_balances(p_from, p_to, p_branch)),
       x as (select a.id, a.code, a.name, a.type,
                    coalesce(o.debit, 0) - coalesce(o.credit, 0) as opening_net,
                    coalesce(p.debit, 0) as period_debit, coalesce(p.credit, 0) as period_credit
             from gl_accounts a left join opening o on o.account_id = a.id left join period p on p.account_id = a.id
             where a.organization_id = fn_user_org_id() and a.is_postable)
  select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'type', type,
                                               'opening_halalas', opening_net, 'debit_halalas', period_debit, 'credit_halalas', period_credit,
                                               'closing_halalas', opening_net + period_debit - period_credit) order by code)
                    filter (where opening_net <> 0 or period_debit <> 0 or period_credit <> 0), '[]'::jsonb),
         coalesce(sum(period_debit), 0), coalesce(sum(period_credit), 0)
    into rows, td, tc from x;
  return jsonb_build_object('from', p_from, 'to', p_to, 'branch_id', p_branch, 'rows', rows,
                            'total_debit_halalas', td, 'total_credit_halalas', tc, 'difference_halalas', td - tc,
                            'locked_months', fn_locked_months());
end $$;
revoke all on function fn_trial_balance(date, date, uuid) from public, anon;
grant execute on function fn_trial_balance(date, date, uuid) to authenticated;

create or replace function fn_account_statement(p_account uuid, p_from date, p_to date, p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a gl_accounts%rowtype; opening bigint; lines jsonb;
begin
  perform fn_accounts_check(p_branch);
  select * into a from gl_accounts where id = p_account and organization_id = fn_user_org_id();
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  select coalesce(debit, 0) - coalesce(credit, 0) into opening from fn_gl_balances(null, p_from - 1, p_branch) where account_id = a.id;
  opening := coalesce(opening, 0);
  select coalesce(jsonb_agg(jsonb_build_object('entry_id', x.id, 'number', x.number, 'entry_date', x.entry_date, 'description', x.description,
                                               'debit_halalas', x.debit_halalas, 'credit_halalas', x.credit_halalas, 'balance_halalas', x.balance)
                            order by x.entry_date, x.created_at, x.number), '[]'::jsonb)
    into lines
    from (select e.id, e.number, e.entry_date, e.created_at, e.description, l.debit_halalas, l.credit_halalas,
                 opening + sum(l.debit_halalas - l.credit_halalas) over (order by e.entry_date, e.created_at, e.number, l.id rows unbounded preceding) as balance
          from journal_lines l join journal_entries e on e.id = l.entry_id
          where l.account_id = a.id and e.entry_date between p_from and p_to and (p_branch is null or e.branch_id = p_branch)
            and (e.branch_id is null or e.branch_id in (select fn_user_branch_ids()))) x;
  return jsonb_build_object('account', jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'type', a.type),
                            'from', p_from, 'to', p_to, 'opening_halalas', opening, 'lines', lines);
end $$;
revoke all on function fn_account_statement(uuid, date, date, uuid) from public, anon;
grant execute on function fn_account_statement(uuid, date, date, uuid) to authenticated;

-- revenue and expenses over a period: the net income (revenue credit-positive, expenses debit-positive)
create or replace function fn_income_statement(p_from date, p_to date, p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare rows jsonb; rev bigint; exp bigint;
begin
  perform fn_accounts_check(p_branch);
  if p_from is null or p_to is null or p_from > p_to then raise exception 'VALIDATION: range'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'type', a.type,
                                               'amount_halalas', case when a.type = 'revenue' then b.credit - b.debit else b.debit - b.credit end) order by a.code), '[]'::jsonb),
         coalesce(sum(b.credit - b.debit) filter (where a.type = 'revenue'), 0), coalesce(sum(b.debit - b.credit) filter (where a.type = 'expense'), 0)
    into rows, rev, exp
    from fn_gl_balances(p_from, p_to, p_branch) b join gl_accounts a on a.id = b.account_id where a.type in ('revenue', 'expense');
  return jsonb_build_object('from', p_from, 'to', p_to, 'rows', rows, 'revenue_halalas', rev, 'expenses_halalas', exp, 'net_income_halalas', rev - exp);
end $$;
revoke all on function fn_income_statement(date, date, uuid) from public, anon;
grant execute on function fn_income_statement(date, date, uuid) to authenticated;

-- assets = liabilities + equity + the income not yet closed into equity
create or replace function fn_balance_sheet(p_as_of date, p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare rows jsonb; assets bigint; liab bigint; eq bigint; income bigint;
begin
  perform fn_accounts_check(p_branch);
  if p_as_of is null then raise exception 'VALIDATION: range'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'type', a.type,
                                               'amount_halalas', case when a.type = 'asset' then b.debit - b.credit else b.credit - b.debit end) order by a.code)
                    filter (where a.type in ('asset', 'liability', 'equity') and b.debit <> b.credit), '[]'::jsonb),
         coalesce(sum(b.debit - b.credit) filter (where a.type = 'asset'), 0),
         coalesce(sum(b.credit - b.debit) filter (where a.type = 'liability'), 0),
         coalesce(sum(b.credit - b.debit) filter (where a.type = 'equity'), 0),
         coalesce(sum(b.credit - b.debit) filter (where a.type in ('revenue', 'expense')), 0)
    into rows, assets, liab, eq, income
    from fn_gl_balances(null, p_as_of, p_branch) b join gl_accounts a on a.id = b.account_id;
  return jsonb_build_object('as_of', p_as_of, 'rows', rows, 'assets_halalas', assets, 'liabilities_halalas', liab, 'equity_halalas', eq,
                            'retained_income_halalas', income, 'difference_halalas', assets - liab - eq - income);
end $$;
revoke all on function fn_balance_sheet(date, uuid) from public, anon;
grant execute on function fn_balance_sheet(date, uuid) to authenticated;

-- today for the organisation: the latest local date among its branches (they share a time zone in practice)
create or replace function fn_org_today() returns date
language sql stable security definer set search_path = public as $$
  select coalesce(max(fn_branch_today(id)), fn_branch_today(null)) from branches where organization_id = fn_user_org_id()
$$;
revoke all on function fn_org_today() from public, anon, authenticated;

-- the chart as a tree with each account's balance (for the chart page)
create or replace function fn_gl_chart(p_as_of date, p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_accounts_check(p_branch);
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'type', a.type, 'parent_id', a.parent_id,
                                                       'is_postable', a.is_postable, 'balance_halalas',
                                                       case when a.type in ('asset', 'expense') then coalesce(b.debit - b.credit, 0) else coalesce(b.credit - b.debit, 0) end)
                                    order by a.code)
                   from gl_accounts a left join fn_gl_balances(null, coalesce(p_as_of, fn_org_today()), p_branch) b on b.account_id = a.id
                   where a.organization_id = fn_user_org_id() and (a.branch_id is null or a.branch_id in (select fn_user_branch_ids()))), '[]'::jsonb);
end $$;
revoke all on function fn_gl_chart(date, uuid) from public, anon;
grant execute on function fn_gl_chart(date, uuid) to authenticated;

-- the locked months (for the month-lock screen: who may lock reads them without the books)
create or replace function fn_accounting_months() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (fn_can('accounts.view') or fn_can('accounts.close_month')) then raise exception 'FORBIDDEN: accounts' using errcode = '42501'; end if;
  return jsonb_build_object('locked_months', fn_locked_months(), 'today', fn_org_today());
end $$;
revoke all on function fn_accounting_months() from public, anon;
grant execute on function fn_accounting_months() to authenticated;

-- the owner locks a month (every entry dated in it is then refused) or opens it again, with a reason
create or replace function fn_accounting_lock_month(p_month date, p_lock boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m date := date_trunc('month', p_month)::date; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('accounts.close_month');
  if p_month is null or m > date_trunc('month', fn_org_today())::date then raise exception 'VALIDATION: month'; end if;
  if v_reason is null or char_length(v_reason) > 500 then raise exception 'VALIDATION: reason'; end if;
  perform pg_advisory_xact_lock(hashtext('period:' || fn_user_org_id()::text || ':' || to_char(m, 'YYYY-MM')));
  if exists (select 1 from accounting_periods where organization_id = fn_user_org_id() and month = m and locked = p_lock)
     or (not p_lock and not exists (select 1 from accounting_periods where organization_id = fn_user_org_id() and month = m)) then
    return jsonb_build_object('ok', true, 'unchanged', true, 'month', to_char(m, 'YYYY-MM'), 'locked', p_lock);
  end if;
  insert into accounting_periods(organization_id, month, locked, changed_by, reason) values (fn_user_org_id(), m, p_lock, fn_staff_id(), v_reason)
  on conflict (organization_id, month) do update set locked = excluded.locked, changed_at = now(), changed_by = excluded.changed_by, reason = excluded.reason;
  perform fn_audit_change(null, case when p_lock then 'accounting.month_locked' else 'accounting.month_opened' end, 'accounting_period', null,
                          null, jsonb_build_object('month', to_char(m, 'YYYY-MM')), v_reason);
  return jsonb_build_object('ok', true, 'month', to_char(m, 'YYYY-MM'), 'locked', p_lock);
end $$;
revoke all on function fn_accounting_lock_month(date, boolean, text) from public, anon;
grant execute on function fn_accounting_lock_month(date, boolean, text) to authenticated;

-- the names follow the owner's renames of a box, a bank account or an expense category
create or replace function fn_trg_gl_rename() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.name is distinct from old.name then
    if tg_table_name = 'cash_accounts' then
      update gl_accounts set name = left(new.name || ' — ' || (select name_ar from branches where id = new.branch_id), 120) where cash_account_id = new.id;
    else
      update gl_accounts set name = left(new.name, 120) where expense_category_id = new.id;
    end if;
  end if;
  return null;
end $$;
revoke all on function fn_trg_gl_rename() from public, anon, authenticated;
create or replace trigger trg_gl_rename_cash after update of name on cash_accounts for each row execute function fn_trg_gl_rename();
create or replace trigger trg_gl_rename_category after update of name on expense_categories for each row execute function fn_trg_gl_rename();
