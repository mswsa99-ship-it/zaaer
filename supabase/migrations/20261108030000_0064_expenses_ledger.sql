-- 0064 — A4 of the accounting stage (plan «خطة تصحيح ملاحظات التجربة», stage م٣, phase ب: «المصروفات ودفتر الحركة»):
--   · the expense voucher (سند صرف): from the branch's cash box or bank account, with a category from the owner's list,
--     a description, and its receipt (1–5 files, images or PDF, 2 MB each, kept in the database); cancelled only with a
--     reason by the management, recorded and sent to «بحاجة لمراجعة»; the account of another branch is refused;
--   · the ledger of each box and bank account: an opening balance (set by the owner with its date and reason), every
--     movement in (receipts, deposits, platform payouts) and out (refunds, deposit refunds, expenses), and on every line
--     the running balance = the opening + what came in − what went out, computed by the server;
--   · the closing of the day (0063) now subtracts the day's cash expenses from the cash box (bank expenses are shown);
--     a cash expense on a day whose closing was sent is the management's only, and goes to «بحاجة لمراجعة»;
--   · three operations join the permissions matrix: «expense.create», «expense.cancel», «ledger.view».

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The permissions matrix: the catalogue with the three operations of the expenses and the ledger
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
    ('reports.identities_usage', 'تقرير الهويات المعتمدة من المكتب وتقرير الاستعمال', 'التقارير والسجل', 530, '{owner}', null, null, false),
    ('audit.log', 'سجل الإجراءات', 'التقارير والسجل', 540, '{owner,manager,supervisor}', '{owner,manager}', 'بلا تفاصيل التغييرات', false);
$$;
grant execute on function fn_permission_catalog() to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Expense categories: the owner's list (a setting, never a constant), seeded with the usual ones
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists expense_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  name text not null,
  sort_order int not null default 0,
  is_active boolean not null default true,
  version int not null default 1,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expense_category_name_valid check (char_length(trim(name)) between 1 and 60)
);
create unique index if not exists uniq_expense_category_name on expense_categories(organization_id, lower(name));
alter table expense_categories enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'expense_categories' and policyname = 'expense_categories_read') then
    create policy "expense_categories_read" on expense_categories for select to authenticated using (organization_id = fn_user_org_id());
  end if;
end $$;
revoke all on expense_categories from anon, authenticated;
grant select on expense_categories to authenticated;
insert into expense_categories(organization_id, name, sort_order)
select o.id, c.name, c.sort from organizations o
cross join (values ('صيانة وإصلاح', 10), ('نظافة ومستلزمات', 20), ('كهرباء وماء', 30), ('إنترنت واتصالات', 40),
                   ('رواتب وأجور', 50), ('رسوم بنكية ونقاط بيع', 60), ('إيجار ومرافق', 70), ('أخرى', 90)) c(name, sort)
where not exists (select 1 from expense_categories e where e.organization_id = o.id);

create or replace function fn_admin_upsert_expense_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c expense_categories%rowtype; v_name text := trim(coalesce(p->>'name', '')); before jsonb;
begin
  perform fn_require_cap('definitions');
  if v_name = '' or char_length(v_name) > 60 then raise exception 'VALIDATION: name'; end if;
  if (p ? 'sort_order') and coalesce(p->>'sort_order', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: sort_order'; end if;
  if (p->>'id') is null then
    if exists (select 1 from expense_categories where organization_id = fn_user_org_id() and lower(name) = lower(v_name)) then raise exception 'DUPLICATE_NAME'; end if;
    insert into expense_categories(organization_id, name, sort_order, created_by)
    values (fn_user_org_id(), v_name, coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 10 from expense_categories where organization_id = fn_user_org_id())), fn_staff_id())
    returning * into c;
    perform fn_audit_change(null, 'expense_category.created', 'expense_category', c.id, null, to_jsonb(c));
  else
    select * into c from expense_categories where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_check_version_strict(c.version, (p->>'version')::int);
    if exists (select 1 from expense_categories where organization_id = c.organization_id and lower(name) = lower(v_name) and id <> c.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(c);
    update expense_categories set name = v_name, sort_order = coalesce((p->>'sort_order')::int, sort_order),
                                  is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
     where id = c.id returning * into c;
    perform fn_audit_change(null, 'expense_category.updated', 'expense_category', c.id, before, to_jsonb(c));
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version);
end $$;
revoke all on function fn_admin_upsert_expense_category(jsonb) from public, anon;
grant execute on function fn_admin_upsert_expense_category(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The expense voucher (سند صرف): from the branch's cash box or bank account, with its category and its receipt
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists expense_vouchers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  number text not null,
  account_id uuid not null references cash_accounts(id),
  category_id uuid not null references expense_categories(id),
  amount_halalas bigint not null,
  occurred_at timestamptz not null default now(),
  payee text,
  description text not null,
  reference text,
  status text not null default 'approved',
  cancel_reason text,
  cancelled_at timestamptz,
  cancelled_by uuid references staff_profiles(id),
  idempotency_key text,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  constraint expense_amount_valid check (amount_halalas > 0 and amount_halalas <= 100000000000),
  constraint expense_status_valid check (status in ('approved', 'cancelled')),
  constraint expense_cancel_shape check (status = 'approved' or (cancel_reason is not null and cancelled_at is not null))
);
create unique index if not exists uniq_expense_number on expense_vouchers(organization_id, number);
create unique index if not exists uniq_expense_idempotency on expense_vouchers(organization_id, idempotency_key) where idempotency_key is not null;
create index if not exists idx_expenses_account_time on expense_vouchers(account_id, occurred_at);
create index if not exists idx_expenses_branch_time on expense_vouchers(branch_id, occurred_at);
alter table expense_vouchers enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'expense_vouchers' and policyname = 'expense_vouchers_read') then
    create policy "expense_vouchers_read" on expense_vouchers for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and (fn_can('expense.create') or fn_can('expense.cancel') or fn_can('ledger.view')));
  end if;
end $$;
revoke all on expense_vouchers from anon, authenticated;
grant select on expense_vouchers to authenticated;
-- A1's rule on this path too: the account of an expense belongs to its branch
create or replace trigger trg_expense_account_branch before insert or update of account_id, branch_id on expense_vouchers
  for each row execute function fn_account_same_branch();

-- the receipt: kept in the database (images or PDF, 2 MB each), read only through the function below
create table if not exists expense_attachments (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references expense_vouchers(id),
  branch_id uuid not null references branches(id),
  mime text not null,
  bytes bytea not null,
  size_bytes int not null,
  sha256 text not null,
  file_name text,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  constraint expense_attachment_mime_valid check (mime in ('image/png', 'image/jpeg', 'image/webp', 'application/pdf')),
  constraint expense_attachment_size_valid check (size_bytes between 1 and 2097152)
);
create index if not exists idx_expense_attachments_expense on expense_attachments(expense_id);
alter table expense_attachments enable row level security;
revoke all on expense_attachments from anon, authenticated;

create or replace function fn_expense_create(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_branch uuid := (p->>'branch_id')::uuid; a cash_accounts%rowtype; cat expense_categories%rowtype; e expense_vouchers%rowtype;
        v_amount bigint; v_day date; v_today date; v_desc text := trim(coalesce(p->>'description', ''));
        v_payee text := nullif(trim(coalesce(p->>'payee', '')), ''); v_ref text := nullif(upper(trim(coalesce(p->>'reference', ''))), '');
        v_key text := nullif(trim(coalesce(p->>'idempotency_key', '')), ''); f jsonb; raw text; bin bytea; v_mime text; n int := 0;
        v_name text; tz text;
begin
  perform fn_require_cap('expense.create');
  perform fn_require_branch(v_branch);
  -- one write per key: the lock comes before the lookup, so a double click replays instead of failing; a key is the
  -- branch's own (another branch's voucher is never returned)
  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext('expense:' || fn_user_org_id()::text || ':' || v_key));
    select * into e from expense_vouchers where organization_id = fn_user_org_id() and idempotency_key = v_key;
    if found then
      if e.branch_id <> v_branch then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return jsonb_build_object('ok', true, 'id', e.id, 'number', e.number, 'replayed', true);
    end if;
  end if;
  select * into a from cash_accounts where id = (p->>'account_id')::uuid;
  if not found then raise exception 'VALIDATION: account_required'; end if;
  if a.branch_id <> v_branch then raise exception 'BRANCH_MISMATCH: account'; end if;
  if a.archived_at is not null or not a.is_active then raise exception 'VALIDATION: account_archived'; end if;
  select * into cat from expense_categories where id = (p->>'category_id')::uuid and organization_id = fn_user_org_id();
  if not found or not cat.is_active then raise exception 'VALIDATION: category'; end if;
  if coalesce(p->>'amount_halalas', '') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: amount'; end if;
  v_amount := (p->>'amount_halalas')::bigint;
  if v_amount <= 0 or v_amount > 100000000000 then raise exception 'VALIDATION: amount'; end if;
  if v_desc = '' or char_length(v_desc) > 500 then raise exception 'VALIDATION: description'; end if;
  if v_payee is not null and char_length(v_payee) > 120 then raise exception 'VALIDATION: payee'; end if;
  if v_ref is not null and (char_length(v_ref) > 60 or v_ref !~ '^[A-Z0-9/_.-]+$') then raise exception 'VALIDATION: reference'; end if;
  -- the day of the expense: today, or one of the last 31 days of the branch
  v_today := fn_branch_today(v_branch);
  if coalesce(p->>'occurred_on', '') <> '' and (p->>'occurred_on') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'VALIDATION: occurred_on'; end if;
  v_day := coalesce(nullif(p->>'occurred_on', '')::date, v_today);
  if v_day > v_today or v_day < v_today - 31 then raise exception 'VALIDATION: occurred_on'; end if;
  -- a cash expense dated on a day whose closing was sent would change a settled count: only the management may, and it
  -- is sent for review
  if a.kind = 'cash_box' and exists (select 1 from day_closings where branch_id = v_branch and business_date = v_day and status = 'submitted')
     and not fn_can('day.close.approve') then
    raise exception 'CLOSING_SENT_DAY';
  end if;
  -- the receipt is required: 1 to 5 files, images or PDF, 2 MB each
  if coalesce(jsonb_typeof(p->'attachments'), '') <> 'array' or jsonb_array_length(p->'attachments') = 0 then raise exception 'VALIDATION: attachment_required'; end if;
  if jsonb_array_length(p->'attachments') > 5 then raise exception 'VALIDATION: attachments_count'; end if;
  tz := coalesce((select timezone from branches where id = v_branch), 'Asia/Riyadh');
  insert into expense_vouchers(organization_id, branch_id, number, account_id, category_id, amount_halalas, occurred_at, payee, description, reference, idempotency_key, created_by)
  values (a.organization_id, v_branch, fn_next_document_number(a.organization_id, 'expense', 'EXP'), a.id, cat.id, v_amount,
          case when v_day = v_today then now() else (v_day::timestamp + interval '12 hours') at time zone tz end,
          v_payee, v_desc, v_ref, v_key, fn_staff_id())
  returning * into e;
  for f in select * from jsonb_array_elements(p->'attachments') loop
    raw := regexp_replace(coalesce(f->>'data_base64', ''), '^data:[^,]*,', '');
    begin bin := decode(regexp_replace(raw, '\s', '', 'g'), 'base64'); exception when others then raise exception 'VALIDATION: attachment'; end;
    if bin is null or length(bin) = 0 then raise exception 'VALIDATION: attachment'; end if;
    if length(bin) > 2097152 then raise exception 'VALIDATION: attachment_too_large'; end if;
    v_mime := case when substring(bin from 1 for 8) = '\x89504e470d0a1a0a'::bytea then 'image/png'
                   when substring(bin from 1 for 3) = '\xffd8ff'::bytea then 'image/jpeg'
                   when substring(bin from 1 for 4) = '\x52494646'::bytea and substring(bin from 9 for 4) = '\x57454250'::bytea then 'image/webp'
                   when substring(bin from 1 for 4) = '\x25504446'::bytea then 'application/pdf' end;
    if v_mime is null then raise exception 'VALIDATION: attachment_type'; end if;
    v_name := nullif(left(trim(coalesce(f->>'file_name', '')), 120), '');
    insert into expense_attachments(expense_id, branch_id, mime, bytes, size_bytes, sha256, file_name, created_by)
    values (e.id, v_branch, v_mime, bin, length(bin), encode(digest(bin, 'sha256'), 'hex'), v_name, fn_staff_id());
    n := n + 1;
  end loop;
  perform fn_audit_change(v_branch, 'expense.created', 'expense_voucher', e.id, null,
    jsonb_build_object('number', e.number, 'amount_halalas', e.amount_halalas, 'account_id', e.account_id, 'category', cat.name,
                       'occurred_at', e.occurred_at, 'attachments', n));
  if a.kind = 'cash_box' and exists (select 1 from day_closings where branch_id = v_branch and business_date = v_day and status = 'submitted') then
    perform fn_add_review_item(v_branch, 'expense_after_closing', 'expense_voucher', e.id, null,
                               'سند صرف ' || e.number || ' على يوم أُرسل إقفاله', v_desc, jsonb_build_object('business_date', v_day, 'amount_halalas', v_amount));
  end if;
  return jsonb_build_object('ok', true, 'id', e.id, 'number', e.number);
end $$;
revoke all on function fn_expense_create(jsonb) from public, anon;
grant execute on function fn_expense_create(jsonb) to authenticated;

create or replace function fn_expense_cancel(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e expense_vouchers%rowtype; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('expense.cancel');
  select * into e from expense_vouchers where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(e.branch_id);
  if v_reason is null or char_length(v_reason) > 500 then raise exception 'VALIDATION: reason'; end if;
  if e.status = 'cancelled' then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  update expense_vouchers set status = 'cancelled', cancel_reason = v_reason, cancelled_at = now(), cancelled_by = fn_staff_id() where id = e.id returning * into e;
  perform fn_audit_change(e.branch_id, 'expense.cancelled', 'expense_voucher', e.id, jsonb_build_object('status', 'approved'),
                          jsonb_build_object('status', 'cancelled', 'number', e.number, 'amount_halalas', e.amount_halalas), v_reason);
  perform fn_add_review_item(e.branch_id, 'expense_cancelled', 'expense_voucher', e.id, null,
                             'إلغاء سند صرف ' || e.number, v_reason, jsonb_build_object('number', e.number, 'amount_halalas', e.amount_halalas));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_expense_cancel(uuid, text) from public, anon;
grant execute on function fn_expense_cancel(uuid, text) to authenticated;

-- the expenses of a branch in a period, with their category, account and number of files
create or replace function fn_expense_list(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if not (fn_can('expense.create') or fn_can('expense.cancel') or fn_can('ledger.view')) then raise exception 'FORBIDDEN: expense' using errcode = '42501'; end if;
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  tz := coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh');
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'number', e.number, 'occurred_at', e.occurred_at, 'amount_halalas', e.amount_halalas,
                                                       'account_id', e.account_id, 'account', (select name from cash_accounts where id = e.account_id),
                                                       'account_kind', (select kind from cash_accounts where id = e.account_id),
                                                       'category_id', e.category_id, 'category', (select name from expense_categories where id = e.category_id),
                                                       'payee', e.payee, 'description', e.description, 'reference', e.reference, 'status', e.status,
                                                       'cancel_reason', e.cancel_reason, 'created_by', (select full_name from staff_profiles where id = e.created_by),
                                                       'attachments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'mime', x.mime, 'size_bytes', x.size_bytes, 'file_name', x.file_name) order by x.created_at), '[]'::jsonb)
                                                                       from expense_attachments x where x.expense_id = e.id))
                                    order by e.occurred_at desc, e.number desc)
                   from expense_vouchers e
                   where e.branch_id = p_branch and e.occurred_at >= p_from::timestamp at time zone tz and e.occurred_at < (p_to + 1)::timestamp at time zone tz), '[]'::jsonb);
end $$;
revoke all on function fn_expense_list(uuid, date, date) from public, anon;
grant execute on function fn_expense_list(uuid, date, date) to authenticated;

-- one file of an expense, to show or download (only for who may see the expense, in its branch)
create or replace function fn_expense_attachment(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare x expense_attachments%rowtype;
begin
  if not (fn_can('expense.create') or fn_can('expense.cancel') or fn_can('ledger.view')) then raise exception 'FORBIDDEN: expense' using errcode = '42501'; end if;
  select * into x from expense_attachments where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(x.branch_id);
  return jsonb_build_object('id', x.id, 'mime', x.mime, 'file_name', x.file_name, 'size_bytes', x.size_bytes, 'data_base64', encode(x.bytes, 'base64'));
end $$;
revoke all on function fn_expense_attachment(uuid) from public, anon;
grant execute on function fn_expense_attachment(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. The ledger of a box or a bank account: the opening balance, every movement in and out, and the running balance
-- ---------------------------------------------------------------------------------------------------------------
alter table cash_accounts add column if not exists opening_balance_halalas bigint not null default 0;
alter table cash_accounts add column if not exists opening_on date;

create or replace function fn_admin_set_account_opening(p_account uuid, p_halalas bigint, p_on date, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a cash_accounts%rowtype; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('cash_accounts');
  if fn_current_role() <> 'owner' then raise exception 'FORBIDDEN: owner_only' using errcode = '42501'; end if;
  select * into a from cash_accounts where id = p_account for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(a.branch_id);
  if p_halalas is null or abs(p_halalas) > 100000000000 then raise exception 'VALIDATION: amount'; end if;
  if p_on is null or p_on > fn_branch_today(a.branch_id) then raise exception 'VALIDATION: opening_on'; end if;
  if v_reason is null or char_length(v_reason) > 500 then raise exception 'VALIDATION: reason'; end if;
  update cash_accounts set opening_balance_halalas = p_halalas, opening_on = p_on, version = version + 1, updated_at = now() where id = a.id;
  perform fn_audit_change(a.branch_id, 'cash_account.opening_set', 'cash_account', a.id,
                          jsonb_build_object('opening_balance_halalas', a.opening_balance_halalas, 'opening_on', a.opening_on),
                          jsonb_build_object('opening_balance_halalas', p_halalas, 'opening_on', p_on), v_reason);
  perform fn_add_review_item(a.branch_id, 'account_opening_set', 'cash_account', a.id, null, 'تحديد الرصيد الافتتاحي لـ' || a.name, v_reason,
                             jsonb_build_object('before', a.opening_balance_halalas, 'after', p_halalas, 'opening_on', p_on));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_admin_set_account_opening(uuid, bigint, date, text) from public, anon;
grant execute on function fn_admin_set_account_opening(uuid, bigint, date, text) to authenticated;

-- every movement of an account: vouchers in (receipt, deposit) and out (refund, deposit refund), platform payouts in,
-- expenses out; cancelled ones and the deposit applied to the rent (no money moves) are not movements
create or replace function fn_account_movements(p_account uuid) returns table(at timestamptz, kind text, number text, description text, in_halalas bigint, out_halalas bigint, ref_id uuid)
language sql stable security definer set search_path = public as $$
  select fv.occurred_at, fv.kind::text, fv.number, coalesce(fv.reference, ''),
         case when fv.kind in ('receipt', 'deposit') then fv.amount_halalas else 0 end,
         case when fv.kind in ('refund', 'deposit_refund') then fv.amount_halalas else 0 end, fv.id
  from financial_vouchers fv where fv.account_id = p_account and fv.status = 'approved' and fv.kind in ('receipt', 'deposit', 'refund', 'deposit_refund')
  union all
  select (pp.received_on::timestamp + interval '12 hours') at time zone coalesce((select timezone from branches where id = pp.branch_id), 'Asia/Riyadh'),
         'platform_payout', pp.reference, 'دفعة منصة', pp.received_halalas, 0, pp.id
  from platform_payouts pp where pp.account_id = p_account and pp.status = 'confirmed'
  union all
  select ev.occurred_at, 'expense', ev.number, ev.description, 0, ev.amount_halalas, ev.id
  from expense_vouchers ev where ev.account_id = p_account and ev.status = 'approved'
$$;
revoke all on function fn_account_movements(uuid) from public, anon, authenticated;

create or replace function fn_account_ledger(p_account uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a cash_accounts%rowtype; tz text; ds timestamptz; de timestamptz; os timestamptz; opening bigint; lines jsonb; total_in bigint; total_out bigint; n int;
begin
  perform fn_require_cap('ledger.view');
  select * into a from cash_accounts where id = p_account;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(a.branch_id);
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  if a.opening_on is not null and p_to < a.opening_on then raise exception 'VALIDATION: before_opening'; end if;
  tz := coalesce((select timezone from branches where id = a.branch_id), 'Asia/Riyadh');
  ds := p_from::timestamp at time zone tz; de := (p_to + 1)::timestamp at time zone tz;
  -- the balance starts on the opening date (or the first movement) with the opening amount
  os := coalesce(a.opening_on::timestamp at time zone tz, '-infinity'::timestamptz);
  select a.opening_balance_halalas + coalesce(sum(m.in_halalas - m.out_halalas), 0) into opening
    from fn_account_movements(a.id) m where m.at >= os and m.at < greatest(ds, os);
  select count(*) into n from fn_account_movements(a.id) m where m.at >= greatest(ds, os) and m.at < de;
  if n > 3000 then raise exception 'VALIDATION: range_too_large'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('at', x.at, 'kind', x.kind, 'number', x.number, 'description', x.description,
                                               'in_halalas', x.in_halalas, 'out_halalas', x.out_halalas, 'balance_halalas', x.balance, 'ref_id', x.ref_id)
                            order by x.at, x.number, x.ref_id), '[]'::jsonb),
         coalesce(sum(x.in_halalas), 0), coalesce(sum(x.out_halalas), 0)
    into lines, total_in, total_out
    from (select m.*, opening + sum(m.in_halalas - m.out_halalas) over (order by m.at, m.number, m.ref_id rows unbounded preceding) as balance
          from fn_account_movements(a.id) m where m.at >= greatest(ds, os) and m.at < de) x;
  return jsonb_build_object('account', jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'branch_id', a.branch_id,
                                                          'opening_balance_halalas', a.opening_balance_halalas, 'opening_on', a.opening_on),
                            'from', p_from, 'to', p_to, 'opening_halalas', opening, 'in_halalas', total_in, 'out_halalas', total_out,
                            'closing_halalas', opening + total_in - total_out, 'lines', lines);
end $$;
revoke all on function fn_account_ledger(uuid, date, date) from public, anon;
grant execute on function fn_account_ledger(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. The closing of the day counts the expenses (re-created from 0063 with the expenses subtracted per box)
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_day_closing_compute(p_branch uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text; ds timestamptz; de timestamptz; rooms jsonb; matrix jsonb; boxes jsonb; expenses jsonb;
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

  -- A4 (0064): the day's cash expenses leave the cash box, so its count is less by them; bank expenses are shown for
  -- information (the transfer box counts what came in, not what the bank paid out)
  select jsonb_build_object('cash', coalesce(sum(ev.amount_halalas) filter (where ca.kind = 'cash_box'), 0),
                            'bank_transfer', coalesce(sum(ev.amount_halalas) filter (where ca.kind = 'bank_account'), 0),
                            'count', count(*))
    into expenses
    from expense_vouchers ev join cash_accounts ca on ca.id = ev.account_id
   where ev.branch_id = p_branch and ev.status = 'approved' and ev.occurred_at >= ds and ev.occurred_at < de;

  -- the boxes: cash, terminal and transfer always; one line per platform that had money that day
  select coalesce(jsonb_agg(b order by b->>'sort', b->>'label'), '[]'::jsonb) into boxes from (
    select jsonb_build_object('key', k.box, 'box', k.box, 'sort', k.sort, 'label', k.label, 'source_id', null,
             'account_id', (select id from cash_accounts where branch_id = p_branch and kind = case when k.box = 'cash' then 'cash_box' else 'bank_account' end
                              and archived_at is null order by is_default desc limit 1),
             'system_halalas', coalesce((select sum((m->>'net')::bigint) from jsonb_array_elements(matrix) m where m->>'box' = k.box), 0)
                               - case when k.box = 'cash' then coalesce((expenses->>'cash')::bigint, 0) else 0 end,
             'expenses_halalas', case when k.box = 'cash' then coalesce((expenses->>'cash')::bigint, 0) else 0 end,
             'required', k.box in ('cash', 'pos')) as b
    from (values ('cash', '1', 'النقد'), ('pos', '2', 'الشبكة'), ('bank_transfer', '3', 'التحويل')) k(box, sort, label)
    union all
    -- platform money of a booking without a source still gets its line («آجل — مباشر»), so nothing goes uncounted
    select jsonb_build_object('key', 'platform:' || coalesce(m->>'source_id', 'direct'), 'box', 'platform', 'sort', '4', 'label', 'آجل — ' || (m->>'source'),
             'source_id', m->>'source_id', 'account_id', null, 'system_halalas', (m->>'net')::bigint, 'required', false)
    from jsonb_array_elements(matrix) m where m->>'box' = 'platform'
  ) s(b);

  return jsonb_build_object('business_date', p_date, 'rooms', rooms, 'matrix', matrix, 'boxes', boxes, 'expenses', expenses);
end $$;
revoke all on function fn_day_closing_compute(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Readable names for the log
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
      when 'expense.created' then 'إصدار سند صرف'
      when 'expense.cancelled' then 'إلغاء سند صرف'
      when 'expense_category.created' then 'إضافة تصنيف مصروف'
      when 'expense_category.updated' then 'تعديل تصنيف مصروف'
      when 'cash_account.opening_set' then 'تحديد الرصيد الافتتاحي'
      else null
    end;
$$;
revoke all on function fn_audit_accounting_label(text) from public, anon;
grant execute on function fn_audit_accounting_label(text) to authenticated, service_role;
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$case p_entity when 'day_closing' then 'إقفال يوم' end$a$;
        new_e constant text := $b$case p_entity when 'day_closing' then 'إقفال يوم' when 'expense_voucher' then 'سند صرف' when 'expense_category' then 'تصنيف مصروف' end$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_entity_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0064: the closing line of fn_audit_entity_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;
