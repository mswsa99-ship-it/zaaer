-- 0066 — A6 and A7 of the accounting stage (plan «خطة تصحيح ملاحظات التجربة», stage م٣, phase د: «الحركات البنكية»):
--   · the bank's messages reach the system by mail: the phone app (A9) relays each SMS or notification as it is, signed
--     with the relay key, to the app's mailbox; the edge function bank-mail reads that mailbox (IMAP) and hands every
--     email to fn_bank_ingest;
--   · A6: the raw text is kept first, whatever it is; the same message twice is one message; only mail from the app's
--     mailbox, signed with its key, of a bank sender the owner allows, is read further — the rest stays «rejected»
--     with its reason;
--   · A7: every movement in or out is read — deposit, incoming and outgoing transfer, withdrawal, fees, POS fees, POS
--     settlement, purchase — by the owner's list of words, with its amount, balance, reference, time, and the branch's
--     bank account whose number rule (starts with … ends with …, A1) the digits fit; the SMS and the notification of
--     the same movement make one movement; what cannot be read stays «unparsed» and is read again after a rule changes;
--   · the mailbox, its password (kept encrypted), the relay key and the senders are the owner's settings; two operations
--     join the permissions matrix: «bank.view», «bank.manage».

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The permissions matrix: the catalogue with the two operations of the bank's messages
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
    ('bank.view', 'الرسائل البنكية والحركات المستخرجة منها', 'التقارير والسجل', 527, '{owner,manager,finance}', null, null, false),
    ('bank.manage', 'بريد البنك وقواعد قراءة الرسائل وإعادة قراءتها', 'التقارير والسجل', 528, '{owner}', null, null, false),
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
      when 'bank_mail.settings_changed' then 'تعديل بريد البنك'
      when 'bank_rule.created' then 'إضافة قاعدة قراءة رسائل البنك'
      when 'bank_rule.updated' then 'تعديل قاعدة قراءة رسائل البنك'
      when 'bank_message.reparsed' then 'إعادة قراءة رسالة بنكية'
      when 'bank_movement.assigned' then 'نسبة حركة بنكية لحساب فرع'
      else null
    end;
$$;
revoke all on function fn_audit_accounting_label(text) from public, anon;
grant execute on function fn_audit_accounting_label(text) to authenticated, service_role;
do $$
declare fn oid; def text; n int;
        old_e constant text := $a$when 'accounting_period' then 'شهر محاسبي' end$a$;
        new_e constant text := $b$when 'accounting_period' then 'شهر محاسبي' when 'bank_mail' then 'بريد البنك' when 'bank_rule' then 'قاعدة قراءة رسائل البنك' when 'bank_message' then 'رسالة بنكية' when 'bank_movement' then 'حركة بنكية' end$b$;
begin
  select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'fn_audit_entity_label';
  def := pg_get_functiondef(fn);
  n := (length(def) - length(replace(def, old_e, ''))) / length(old_e);
  if n <> 1 then raise exception '0066: the closing line of fn_audit_entity_label was found % times, not once', n; end if;
  execute replace(def, old_e, new_e);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The mailbox: the owner's settings (the address, the mail server, its password kept encrypted, the phone app's
--    relay key, the bank senders the app may relay); nothing is read until it is complete and switched on
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists bank_mail_settings (
  organization_id uuid primary key references organizations(id),
  mailbox_address text,                         -- the app's mailbox: the only address whose mail is accepted
  imap_host text not null default 'imap.gmail.com',
  imap_port int not null default 993,
  imap_user text,
  password_encrypted bytea,
  relay_key_encrypted bytea,                    -- the key the phone app signs every relayed message with
  relay_key_last4 text,
  allowed_senders text[] not null default array['AlRajhiBank', 'Alrajhi', 'الراجحي'],
  enabled boolean not null default false,
  last_uid bigint not null default 0,
  uid_validity bigint,
  last_polled_at timestamptz,
  last_error text,
  version int not null default 1,
  updated_at timestamptz not null default now(),
  constraint bank_mail_port_valid check (imap_port between 1 and 65535),
  constraint bank_mail_address_valid check (mailbox_address is null or mailbox_address ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);
alter table bank_mail_settings enable row level security;
revoke all on bank_mail_settings from anon, authenticated;     -- read only through fn_admin_bank_mail_get (no secret leaves)

-- what turns a message into a kind of movement: the owner's list of words (the first that appears, by priority)
create table if not exists bank_parse_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  keyword text not null,
  kind text not null,
  direction text not null,
  priority int not null default 100,
  is_active boolean not null default true,
  version int not null default 1,
  updated_at timestamptz not null default now(),
  constraint bank_rule_keyword_valid check (char_length(trim(keyword)) between 2 and 60),
  constraint bank_rule_kind_valid check (kind in ('deposit', 'transfer_in', 'pos_settlement', 'other_in', 'transfer_out', 'withdrawal', 'fee', 'pos_fee', 'purchase', 'other_out')),
  constraint bank_rule_direction_valid check (direction in ('in', 'out'))
);
create unique index if not exists uniq_bank_rule_keyword on bank_parse_rules(organization_id, lower(keyword));
alter table bank_parse_rules enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_parse_rules' and policyname = 'bank_parse_rules_read') then
    create policy "bank_parse_rules_read" on bank_parse_rules for select to authenticated using (organization_id = fn_user_org_id() and (fn_can('bank.view') or fn_can('bank.manage')));
  end if;
end $$;
revoke all on bank_parse_rules from anon, authenticated;
grant select on bank_parse_rules to authenticated;
insert into bank_parse_rules(organization_id, keyword, kind, direction, priority)
select o.id, r.k, r.kind, r.dir, r.p from organizations o
cross join (values ('استرداد', 'other_in', 'in', 5), ('رسوم نقاط البيع', 'pos_fee', 'out', 10), ('عمولة نقاط البيع', 'pos_fee', 'out', 11), ('POS fee', 'pos_fee', 'out', 12),
                   ('تسوية نقاط البيع', 'pos_settlement', 'in', 20), ('مبيعات نقاط البيع', 'pos_settlement', 'in', 21), ('تسوية مدى', 'pos_settlement', 'in', 22), ('POS settlement', 'pos_settlement', 'in', 23),
                   ('حوالة واردة', 'transfer_in', 'in', 30), ('تحويل وارد', 'transfer_in', 'in', 31), ('Incoming transfer', 'transfer_in', 'in', 32), ('واردة', 'transfer_in', 'in', 35),
                   ('حوالة صادرة', 'transfer_out', 'out', 40), ('تحويل صادر', 'transfer_out', 'out', 41), ('Outgoing transfer', 'transfer_out', 'out', 42), ('صادرة', 'transfer_out', 'out', 45),
                   ('إيداع', 'deposit', 'in', 50), ('ايداع', 'deposit', 'in', 51), ('Deposit', 'deposit', 'in', 52),
                   ('سحب', 'withdrawal', 'out', 60), ('Withdrawal', 'withdrawal', 'out', 61),
                   ('رسوم', 'fee', 'out', 70), ('Fees', 'fee', 'out', 71),
                   ('شراء', 'purchase', 'out', 80), ('Purchase', 'purchase', 'out', 81)) r(k, kind, dir, p)
where not exists (select 1 from bank_parse_rules x where x.organization_id = o.id);

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The messages (raw, kept first) and the movements read from them
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists bank_messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  mail_message_id text,                         -- the email's Message-ID
  mail_from text,
  mail_date timestamptz,
  subject text,
  raw_body text not null,                       -- the email's text exactly as it arrived (cut at 20,000 characters)
  content_hash text not null,                   -- of the relayed text: the same message twice is one message
  sms_sender text,
  sms_received_at timestamptz,
  channel text,                                 -- sms | notification
  sms_text text,
  status text not null default 'received',      -- received → rejected | unparsed | parsed | duplicate_movement
  reject_reason text,
  movement_id uuid,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  constraint bank_message_status_valid check (status in ('received', 'rejected', 'unparsed', 'parsed', 'duplicate_movement'))
);
create unique index if not exists uniq_bank_message_hash on bank_messages(organization_id, content_hash);
create index if not exists idx_bank_messages_time on bank_messages(organization_id, received_at desc);
alter table bank_messages enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_messages' and policyname = 'bank_messages_read') then
    create policy "bank_messages_read" on bank_messages for select to authenticated using (organization_id = fn_user_org_id() and fn_can('bank.manage'));
  end if;
end $$;
revoke all on bank_messages from anon, authenticated;
grant select on bank_messages to authenticated;

create table if not exists bank_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid references branches(id),       -- null: no bank account of a branch matched the digits (the owner assigns it)
  cash_account_id uuid references cash_accounts(id),
  message_id uuid not null references bank_messages(id),
  kind text not null,
  direction text not null,
  amount_halalas bigint not null,
  occurred_at timestamptz not null,
  reference text,
  balance_halalas bigint,
  account_hint text,                            -- the account digits as the message shows them (masked)
  dedupe_key text not null,
  status text not null default 'pending',       -- pending (A8 matches it) | matched | converted
  created_at timestamptz not null default now(),
  constraint bank_movement_amount_valid check (amount_halalas > 0),
  constraint bank_movement_direction_valid check (direction in ('in', 'out')),
  constraint bank_movement_kind_valid check (kind in ('deposit', 'transfer_in', 'pos_settlement', 'other_in', 'transfer_out', 'withdrawal', 'fee', 'pos_fee', 'purchase', 'other_out')),
  constraint bank_movement_status_valid check (status in ('pending', 'matched', 'converted'))
);
create unique index if not exists uniq_bank_movement_dedupe on bank_movements(organization_id, dedupe_key);
create index if not exists idx_bank_movements_branch_time on bank_movements(branch_id, occurred_at desc);
create index if not exists idx_bank_movements_message on bank_movements(message_id);
alter table bank_movements enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_movements' and policyname = 'bank_movements_read') then
    create policy "bank_movements_read" on bank_movements for select to authenticated
      using (organization_id = fn_user_org_id() and (fn_can('bank.manage') or (fn_can('bank.view') and branch_id in (select fn_user_branch_ids()))));
  end if;
end $$;
revoke all on bank_movements from anon, authenticated;
grant select on bank_movements to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Reading a message: the text the phone app relayed, its signature, and what it says
-- ---------------------------------------------------------------------------------------------------------------
-- digits as the bank writes them (Arabic-Indic or Persian) → 0–9; the Arabic decimal and thousands marks
create or replace function fn_bank_normalize(p text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(translate(coalesce(p, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹٫٬', '01234567890123456789.,'), '[ ' || chr(9) || chr(160) || ']+', ' ', 'g')
$$;
revoke all on function fn_bank_normalize(text) from public, anon, authenticated;

-- an amount as halalas: "1,250.50" → 125050; null when it is not one
create or replace function fn_bank_halalas(p text) returns bigint
language plpgsql immutable set search_path = public as $$
declare s text := replace(coalesce(p, ''), ',', '');
begin
  if s !~ '^[0-9]{1,12}(\.[0-9]{1,2})?$' then return null; end if;
  return round(s::numeric * 100)::bigint;
end $$;
revoke all on function fn_bank_halalas(text) from public, anon, authenticated;

-- the relayed message: the app's header, its signature and the text (format v1, written by the phone app)
--   FIVEHOURS-RELAY 1
--   sender: <the SMS sender or the app that notified>
--   received: <ISO time on the phone>
--   channel: sms | notification
--   signature: <hex HMAC-SHA256(relay key, sender \n received \n channel \n text)>
--   ---
--   <the text, exactly>
create or replace function fn_bank_relay_parse(p_body text) returns jsonb
language plpgsql immutable set search_path = public as $$
declare body text := replace(coalesce(p_body, ''), E'\r\n', E'\n'); head text; txt text; i int; h jsonb := '{}'::jsonb; line text; k text; v text;
begin
  i := position(E'\n---\n' in body);
  if i = 0 or btrim(split_part(body, E'\n', 1)) <> 'FIVEHOURS-RELAY 1' then return null; end if;
  head := left(body, i - 1); txt := substr(body, i + 5);
  txt := regexp_replace(txt, E'\n+$', '');
  foreach line in array string_to_array(head, E'\n') loop
    k := lower(btrim(split_part(line, ':', 1))); v := btrim(substr(line, position(':' in line) + 1));
    if k in ('sender', 'received', 'channel', 'signature') and position(':' in line) > 0 then h := h || jsonb_build_object(k, v); end if;
  end loop;
  if not (h ? 'sender' and h ? 'received' and h ? 'channel' and h ? 'signature') then return null; end if;
  return h || jsonb_build_object('text', txt);
end $$;
revoke all on function fn_bank_relay_parse(text) from public, anon, authenticated;

-- what a message says: kind and direction (the owner's rules), amount, balance, reference, time, the account digits
create or replace function fn_bank_extract(p_org uuid, p_text text, p_fallback timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t text := fn_bank_normalize(p_text); lt text; r bank_parse_rules%rowtype; m text[]; amt bigint; bal bigint; ref text; at timestamptz;
        tok text; hint text; acc cash_accounts%rowtype; n int; yr int; mo int; dy int;
        -- the balance as banks write it: «الرصيد», «رصيدك», «الرصيد المتاح», «Balance», «Avail Bal» … then the number
        bal_re constant text := '(?:الرصيد|رصيد|balance|bal)\S*(?:\s+(?:المتاح|الحالي|available|avail))?\s*[:：]?\s*(?:SAR|ر\.?\s?س\.?)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)';
begin
  lt := lower(t);
  select * into r from bank_parse_rules where organization_id = p_org and is_active and position(lower(keyword) in lt) > 0 order by priority, keyword limit 1;
  if r.id is null then return jsonb_build_object('ok', false, 'reason', 'kind'); end if;
  -- the amount: the labelled one, else the first sum with its currency once the balance is taken out
  m := regexp_match(t, '(?:مبلغ|المبلغ|بمبلغ|قيمة|amount|amt)\s*[:：]?\s*(?:SAR|ر\.?\s?س\.?|ريال)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)', 'i');
  if m is null then
    m := regexp_match(regexp_replace(t, bal_re || '\s*(?:SAR|ر\.?\s?س\.?|ريال)?', '', 'gi'), '([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:SAR|ر\.?\s?س\.?|ريال)', 'i');
    if m is null then m := regexp_match(regexp_replace(t, bal_re, '', 'gi'), '(?:SAR|ر\.?\s?س\.?)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)', 'i'); end if;
  end if;
  amt := fn_bank_halalas(m[1]);
  if amt is null or amt <= 0 then return jsonb_build_object('ok', false, 'reason', 'amount', 'kind', r.kind); end if;
  bal := fn_bank_halalas((regexp_match(t, bal_re, 'i'))[1]);
  m := regexp_match(t, '(?:رقم المرجع|المرجع|مرجع|رقم العملية|رقم الحوالة|\mref(?:erence)?\.?(?:\s*no\.?)?)\s*[:：#]?\s*([A-Za-z0-9][A-Za-z0-9-]{3,})', 'i');
  ref := m[1];
  -- the time the message gives (Riyadh): year-month-day first, else day/month/year; not a part of a longer number; a
  -- date more than three days from when the phone received the message is not trusted (that time is used instead)
  m := regexp_match(t, '(?<![0-9])([0-9]{4})[/.-]([0-9]{1,2})[/.-]([0-9]{1,2})\s*[- ,T]?\s*([0-9]{1,2}):([0-9]{2})(?![0-9])');
  if m is not null then yr := m[1]::int; mo := m[2]::int; dy := m[3]::int;
  else
    m := regexp_match(t, '(?<![0-9])([0-9]{1,2})[/.-]([0-9]{1,2})[/.-]([0-9]{2}|[0-9]{4})\s*[- ,]?\s*([0-9]{1,2}):([0-9]{2})(?![0-9])');
    if m is not null then dy := m[1]::int; mo := m[2]::int; yr := m[3]::int; if yr < 100 then yr := yr + 2000; end if; end if;
  end if;
  if m is not null then
    begin
      at := make_timestamptz(yr, mo, dy, m[4]::int, m[5]::int, 0, 'Asia/Riyadh');
    exception when others then at := null;
    end;
    if at is not null and p_fallback is not null and abs(extract(epoch from at - p_fallback)) > 3 * 86400 then at := null; end if;
  end if;
  at := coalesce(at, p_fallback, now());
  -- the account: digits masked in the middle (605****192), only its end (**192), or all of it (10+ digits that are not a
  -- phone number), each standing alone; matched with the rule of each branch's bank account (starts with … ends with …);
  -- one account only, else left for the owner
  for tok in select (regexp_matches(t, '(?<![0-9A-Za-z])([0-9]{2,}[*xX•…]+[0-9]{2,}|[*xX•…]+[0-9]{3,}|[0-9]{10,})(?![0-9A-Za-z])', 'g'))[1] loop
    if tok ~ '^[0-9]+$' and (tok ~ '^05' or tok ~ '^9665' or tok ~ '^00966') then continue; end if;
    hint := coalesce(hint, tok);
    select count(*) into n from cash_accounts a
     where a.organization_id = p_org and a.kind = 'bank_account' and a.archived_at is null and a.account_prefix is not null and a.account_suffix is not null
       and fn_bank_account_fits(tok, a.account_prefix, a.account_suffix);
    if n = 1 then
      select a.* into acc from cash_accounts a
       where a.organization_id = p_org and a.kind = 'bank_account' and a.archived_at is null and a.account_prefix is not null and a.account_suffix is not null
         and fn_bank_account_fits(tok, a.account_prefix, a.account_suffix);
      hint := tok; exit;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'kind', r.kind, 'direction', r.direction, 'rule', r.keyword, 'amount_halalas', amt, 'balance_halalas', bal,
                            'reference', ref, 'occurred_at', at, 'account_hint', hint, 'cash_account_id', acc.id, 'branch_id', acc.branch_id);
end $$;
revoke all on function fn_bank_extract(uuid, text, timestamptz) from public, anon, authenticated;

-- does a token of the message fit an account that starts with p_prefix and ends with p_suffix?
--   full digits: starts and ends so; masked (head…tail): the shown head agrees with the prefix and the tail with the
--   suffix; only the tail (…tail): the tail agrees with the suffix (ambiguous when two accounts share an ending)
create or replace function fn_bank_account_fits(p_tok text, p_prefix text, p_suffix text) returns boolean
language plpgsql immutable set search_path = public as $$
declare head text; tail text; agree_end boolean;
begin
  if p_tok ~ '^[0-9]+$' then return p_tok like p_prefix || '%' and p_tok like '%' || p_suffix; end if;
  head := substring(p_tok from '^([0-9]*)'); tail := substring(p_tok from '([0-9]+)$');
  agree_end := tail is not null and (length(tail) >= length(p_suffix) and tail like '%' || p_suffix or length(tail) < length(p_suffix) and p_suffix like '%' || tail);
  if not agree_end then return false; end if;
  if head = '' then return length(tail) >= 3; end if;
  return left(head, least(length(head), length(p_prefix))) = left(p_prefix, least(length(head), length(p_prefix)));
end $$;
revoke all on function fn_bank_account_fits(text, text, text) from public, anon, authenticated;

-- the movement of a message (A7). The same movement told twice — the SMS and the notification, or a message relayed
-- again — is one movement: the same branch account, direction, kind and amount, and the same reference, or (when one of
-- the two has none) within two minutes. A movement whose account is not known is never merged (it could be another
-- branch's); two real movements of the same amount within two minutes without a reference would be merged — the second
-- message shows «مكررة لحركة سابقة» with its text, for the owner to see.
create or replace function fn_bank_make_movement(p_msg uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare msg bank_messages%rowtype; x jsonb; key text; mv uuid; acc uuid; amt bigint; at timestamptz; ref text;
begin
  select * into msg from bank_messages where id = p_msg for update;
  x := fn_bank_extract(msg.organization_id, msg.sms_text, coalesce(msg.sms_received_at, msg.mail_date, msg.received_at));
  if not (x->>'ok')::boolean then
    update bank_messages set status = 'unparsed', reject_reason = 'لم تُفهم: ' || case x->>'reason' when 'kind' then 'نوع الحركة' else 'المبلغ' end, processed_at = now() where id = msg.id;
    return jsonb_build_object('status', 'unparsed', 'reason', x->>'reason');
  end if;
  acc := (x->>'cash_account_id')::uuid; amt := (x->>'amount_halalas')::bigint; at := (x->>'occurred_at')::timestamptz; ref := upper(x->>'reference');
  if acc is not null then
    perform pg_advisory_xact_lock(hashtext('bank_mv:' || acc::text || ':' || amt::text));
    select id into mv from bank_movements v
     where v.cash_account_id = acc and v.direction = x->>'direction' and v.kind = x->>'kind' and v.amount_halalas = amt
       and (upper(v.reference) = ref or ((v.reference is null or ref is null) and abs(extract(epoch from v.occurred_at - at)) <= 120))
     order by abs(extract(epoch from v.occurred_at - at)) limit 1;
    if mv is not null then
      update bank_messages set status = 'duplicate_movement', movement_id = mv, reject_reason = null, processed_at = now() where id = msg.id;
      return jsonb_build_object('status', 'duplicate_movement', 'movement_id', mv);
    end if;
  end if;
  -- the key keeps the rule above true under any race: per reference when there is one, else per message
  key := case when acc is not null and ref is not null then md5(acc::text || '|' || (x->>'direction') || '|' || (x->>'kind') || '|' || amt || '|' || ref) else 'msg:' || msg.id::text end;
  insert into bank_movements(organization_id, branch_id, cash_account_id, message_id, kind, direction, amount_halalas, occurred_at, reference, balance_halalas, account_hint, dedupe_key)
  values (msg.organization_id, (x->>'branch_id')::uuid, acc, msg.id, x->>'kind', x->>'direction', amt, at, x->>'reference', (x->>'balance_halalas')::bigint, x->>'account_hint', key)
  on conflict (organization_id, dedupe_key) do nothing
  returning id into mv;
  if mv is null then
    select id into mv from bank_movements where organization_id = msg.organization_id and dedupe_key = key;
    update bank_messages set status = 'duplicate_movement', movement_id = mv, reject_reason = null, processed_at = now() where id = msg.id;
    return jsonb_build_object('status', 'duplicate_movement', 'movement_id', mv);
  end if;
  update bank_messages set status = 'parsed', movement_id = mv, reject_reason = null, processed_at = now() where id = msg.id;
  return jsonb_build_object('status', 'parsed', 'movement_id', mv);
end $$;
revoke all on function fn_bank_make_movement(uuid) from public, anon, authenticated;

-- is a kept message the app's (mailbox, format, signature, sender)? then its movement; else «rejected» with the reason
create or replace function fn_bank_process(p_msg uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s bank_mail_settings%rowtype; m bank_messages%rowtype; rel jsonb; why text; sig text;
begin
  select * into m from bank_messages where id = p_msg for update;
  select * into s from bank_mail_settings where organization_id = m.organization_id;
  rel := fn_bank_relay_parse(m.raw_body);
  if s.mailbox_address is null or s.relay_key_encrypted is null then why := 'بريد البنك غير مُعدّ';
  elsif coalesce(m.mail_from, '') <> lower(s.mailbox_address) then why := 'ليست من بريد التطبيق';
  elsif rel is null then why := 'ليست بصيغة تطبيق الجوال';
  else
    sig := encode(hmac(convert_to((rel->>'sender') || E'\n' || (rel->>'received') || E'\n' || (rel->>'channel') || E'\n' || (rel->>'text'), 'UTF8'),
                       convert_to(pgp_sym_decrypt(s.relay_key_encrypted, fn_secret('keybox_key')), 'UTF8'), 'sha256'), 'hex');
    if lower(rel->>'signature') <> sig then why := 'توقيع التطبيق غير صحيح';
    elsif not exists (select 1 from unnest(s.allowed_senders) a where lower(a) = lower(rel->>'sender')) then why := 'مرسل غير مسموح: ' || left(rel->>'sender', 40);
    elsif (rel->>'channel') not in ('sms', 'notification') then why := 'قناة غير معروفة';
    end if;
  end if;
  if why is not null then
    update bank_messages set status = 'rejected', reject_reason = why, processed_at = now() where id = m.id;
    return jsonb_build_object('status', 'rejected', 'reason', why);
  end if;
  begin
    update bank_messages set sms_received_at = (rel->>'received')::timestamptz where id = m.id;
  exception when others then null;
  end;
  return fn_bank_make_movement(m.id);
end $$;
revoke all on function fn_bank_process(uuid) from public, anon, authenticated;

-- one email from the mailbox (the edge function bank-mail, service role only). The raw text is kept first, whatever it
-- is, and stays kept even if reading it fails; the same relayed text again is the same message; only mail from the
-- app's mailbox, signed with the relay key, of an allowed bank sender, becomes a movement.
create or replace function fn_bank_ingest(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s bank_mail_settings%rowtype; v_org uuid; body text := left(coalesce(p->>'body', ''), 20000); rel jsonb; hash text; msg uuid;
        from_addr text; at timestamptz; r jsonb;
begin
  select * into s from bank_mail_settings order by updated_at desc limit 1;     -- one organisation per project
  v_org := coalesce(s.organization_id, (select id from organizations order by created_at limit 1));
  rel := fn_bank_relay_parse(body);
  hash := md5(coalesce(rel->>'sender', '') || E'\n' || coalesce(rel->>'received', '') || E'\n' || coalesce(rel->>'text', body));
  begin at := nullif(p->>'date', '')::timestamptz; exception when others then at := null; end;
  from_addr := lower(btrim(coalesce(substring(coalesce(p->>'from', '') from '<([^>]+)>'), p->>'from', '')));
  insert into bank_messages(organization_id, mail_message_id, mail_from, mail_date, subject, raw_body, content_hash, sms_sender, channel, sms_text)
  values (v_org, left(p->>'message_id', 300), left(from_addr, 300), at, left(p->>'subject', 300), body, hash,
          left(rel->>'sender', 100), left(rel->>'channel', 20), rel->>'text')
  on conflict (organization_id, content_hash) do nothing
  returning id into msg;
  if msg is null then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  begin
    r := fn_bank_process(msg);
  exception when others then
    -- the raw text stays; the message waits for the owner as not understood
    update bank_messages set status = 'unparsed', reject_reason = 'تعذّرت القراءة: ' || left(sqlerrm, 120), processed_at = now() where id = msg;
    r := jsonb_build_object('status', 'unparsed', 'reason', 'error');
  end;
  return jsonb_build_object('ok', true, 'message_id', msg) || r;
end $$;
revoke all on function fn_bank_ingest(jsonb) from public, anon, authenticated;
grant execute on function fn_bank_ingest(jsonb) to service_role;

-- an email the function could not hand over (too large, unreadable): kept as a placeholder so the reading moves on
create or replace function fn_bank_ingest_failed(p_uid bigint, p_error text) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid := coalesce((select organization_id from bank_mail_settings order by updated_at desc limit 1), (select id from organizations order by created_at limit 1));
begin
  insert into bank_messages(organization_id, raw_body, content_hash, status, reject_reason, processed_at)
  values (v_org, '[رسالة لم تُحفظ: رقمها في البريد ' || p_uid || ']', md5('failed:' || p_uid || ':' || clock_timestamp()::text), 'rejected',
          'تعذّر حفظها: ' || left(coalesce(p_error, ''), 150), now());
end $$;
revoke all on function fn_bank_ingest_failed(bigint, text) from public, anon, authenticated;
grant execute on function fn_bank_ingest_failed(bigint, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. The mailbox poll (the edge function): what it reads with, and where it stopped
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_bank_mail_poll_config() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s bank_mail_settings%rowtype;
begin
  select * into s from bank_mail_settings order by updated_at desc limit 1;
  if s.organization_id is null or not s.enabled or s.mailbox_address is null or s.imap_user is null or s.password_encrypted is null or s.relay_key_encrypted is null then
    return jsonb_build_object('configured', false);
  end if;
  return jsonb_build_object('configured', true, 'host', s.imap_host, 'port', s.imap_port, 'user', s.imap_user,
                            'password', pgp_sym_decrypt(s.password_encrypted, fn_secret('keybox_key')), 'last_uid', s.last_uid, 'uid_validity', s.uid_validity);
end $$;
revoke all on function fn_bank_mail_poll_config() from public, anon, authenticated;
grant execute on function fn_bank_mail_poll_config() to service_role;

create or replace function fn_bank_mail_poll_done(p_last_uid bigint, p_uid_validity bigint, p_error text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update bank_mail_settings set last_uid = greatest(case when uid_validity is distinct from p_uid_validity and p_uid_validity is not null then 0 else last_uid end, coalesce(p_last_uid, 0)),
                                uid_validity = coalesce(p_uid_validity, uid_validity), last_polled_at = now(), last_error = left(p_error, 300)
   where organization_id = (select organization_id from bank_mail_settings order by updated_at desc limit 1);
end $$;
revoke all on function fn_bank_mail_poll_done(bigint, bigint, text) from public, anon, authenticated;
grant execute on function fn_bank_mail_poll_done(bigint, bigint, text) to service_role;

-- the edge function asks whether the caller (a signed-in staff member) may start a reading now
create or replace function fn_bank_poll_allowed() returns boolean
language sql stable security definer set search_path = public as $$ select fn_can('bank.manage') $$;
revoke all on function fn_bank_poll_allowed() from public, anon;
grant execute on function fn_bank_poll_allowed() to authenticated;

-- the schedule (pg_cron + pg_net, set at rollout) calls the function with a key kept only in the Vault
create or replace function fn_bank_cron_ok(p_key text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  return p_key is not null and length(p_key) >= 32 and p_key = fn_secret('bank_mail_cron_key');
exception when others then
  return false;
end $$;
revoke all on function fn_bank_cron_ok(text) from public, anon, authenticated;
grant execute on function fn_bank_cron_ok(text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. The owner's screens: settings (no secret leaves), rules, messages, movements, reading a message again
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_admin_bank_mail_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s bank_mail_settings%rowtype;
begin
  perform fn_require_cap('bank.manage');
  select * into s from bank_mail_settings where organization_id = fn_user_org_id();
  return jsonb_build_object('mailbox_address', s.mailbox_address, 'imap_host', coalesce(s.imap_host, 'imap.gmail.com'), 'imap_port', coalesce(s.imap_port, 993),
    'imap_user', s.imap_user, 'has_password', s.password_encrypted is not null, 'has_relay_key', s.relay_key_encrypted is not null, 'relay_key_last4', s.relay_key_last4,
    'allowed_senders', to_jsonb(coalesce(s.allowed_senders, array['AlRajhiBank', 'Alrajhi', 'الراجحي'])), 'enabled', coalesce(s.enabled, false),
    'last_polled_at', s.last_polled_at, 'last_error', s.last_error, 'version', coalesce(s.version, 1),
    'state', case when s.organization_id is null or s.mailbox_address is null or s.imap_user is null or s.password_encrypted is null or s.relay_key_encrypted is null then 'not_configured'
                  when not s.enabled then 'off' when s.last_error is not null then 'error' else 'on' end,
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'branch', b.name_ar, 'name', a.name, 'prefix', a.account_prefix, 'suffix', a.account_suffix) order by b.name_ar)
                          from cash_accounts a join branches b on b.id = a.branch_id
                          where a.organization_id = fn_user_org_id() and a.kind = 'bank_account' and a.archived_at is null), '[]'::jsonb));
end $$;
revoke all on function fn_admin_bank_mail_get() from public, anon;
grant execute on function fn_admin_bank_mail_get() to authenticated;

-- save the settings; a new relay key is returned once (to put in the phone app), never shown again
create or replace function fn_admin_bank_mail_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s bank_mail_settings%rowtype; changed text[] := '{}'; v text; key text; senders text[];
begin
  perform fn_require_cap('bank.manage');
  insert into bank_mail_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  select * into s from bank_mail_settings where organization_id = fn_user_org_id() for update;
  perform fn_check_version_strict(s.version, (p->>'version')::int);
  if p ? 'mailbox_address' then
    v := nullif(lower(btrim(coalesce(p->>'mailbox_address', ''))), '');
    if v is not null and v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'VALIDATION: mailbox_address'; end if;
    if v is distinct from s.mailbox_address then s.mailbox_address := v; changed := array_append(changed, 'mailbox_address'); end if;
  end if;
  if p ? 'imap_host' then
    v := lower(btrim(coalesce(p->>'imap_host', '')));
    if v !~ '^[a-z0-9.-]{3,100}$' then raise exception 'VALIDATION: imap_host'; end if;
    if v <> s.imap_host then s.imap_host := v; changed := array_append(changed, 'imap_host'); end if;
  end if;
  if p ? 'imap_port' then
    if coalesce(p->>'imap_port', '') !~ '^[0-9]{1,5}$' or (p->>'imap_port')::int not between 1 and 65535 then raise exception 'VALIDATION: imap_port'; end if;
    if (p->>'imap_port')::int <> s.imap_port then s.imap_port := (p->>'imap_port')::int; changed := array_append(changed, 'imap_port'); end if;
  end if;
  if p ? 'imap_user' then
    v := nullif(btrim(coalesce(p->>'imap_user', '')), '');
    if v is not null and (char_length(v) > 200 or v ~ '\s') then raise exception 'VALIDATION: imap_user'; end if;
    if v is distinct from s.imap_user then s.imap_user := v; changed := array_append(changed, 'imap_user'); end if;
  end if;
  -- the stored password belongs to its server and login: changing either without a new password clears it, so it can
  -- never be sent to another server
  if changed && array['imap_host', 'imap_port', 'imap_user'] and nullif(coalesce(p->>'password', ''), '') is null and s.password_encrypted is not null then
    s.password_encrypted := null; changed := array_append(changed, 'password_cleared');
  end if;
  v := nullif(coalesce(p->>'password', ''), '');
  if v is not null then
    if char_length(v) > 200 then raise exception 'VALIDATION: password'; end if;
    s.password_encrypted := pgp_sym_encrypt(v, fn_secret('keybox_key')); changed := array_append(changed, 'password');
  elsif coalesce((p->>'clear_password')::boolean, false) and s.password_encrypted is not null then
    s.password_encrypted := null; changed := array_append(changed, 'password_cleared');
  end if;
  if p ? 'allowed_senders' then
    senders := array(select distinct btrim(x) from jsonb_array_elements_text(coalesce(p->'allowed_senders', '[]'::jsonb)) x where btrim(x) <> '');
    if cardinality(senders) = 0 or cardinality(senders) > 20 or exists (select 1 from unnest(senders) x where char_length(x) > 40) then raise exception 'VALIDATION: allowed_senders'; end if;
    if senders is distinct from s.allowed_senders then s.allowed_senders := senders; changed := array_append(changed, 'allowed_senders'); end if;
  end if;
  if coalesce((p->>'new_relay_key')::boolean, false) then
    key := encode(gen_random_bytes(24), 'hex');
    s.relay_key_encrypted := pgp_sym_encrypt(key, fn_secret('keybox_key')); s.relay_key_last4 := right(key, 4); changed := array_append(changed, 'relay_key');
  end if;
  if p ? 'enabled' then
    if jsonb_typeof(p->'enabled') <> 'boolean' then raise exception 'VALIDATION: enabled'; end if;
    if (p->>'enabled')::boolean and (s.mailbox_address is null or s.imap_user is null or s.password_encrypted is null or s.relay_key_encrypted is null) then
      raise exception 'VALIDATION: bank_mail_incomplete';
    end if;
    if (p->>'enabled')::boolean is distinct from s.enabled then s.enabled := (p->>'enabled')::boolean; changed := array_append(changed, 'enabled'); end if;
  end if;
  if cardinality(changed) = 0 and key is null then return jsonb_build_object('ok', true, 'unchanged', true, 'version', s.version); end if;
  if s.enabled and (s.mailbox_address is null or s.imap_user is null or s.password_encrypted is null or s.relay_key_encrypted is null) then s.enabled := false; changed := array_append(changed, 'disabled_incomplete'); end if;
  update bank_mail_settings set mailbox_address = s.mailbox_address, imap_host = s.imap_host, imap_port = s.imap_port, imap_user = s.imap_user,
         password_encrypted = s.password_encrypted, relay_key_encrypted = s.relay_key_encrypted, relay_key_last4 = s.relay_key_last4,
         allowed_senders = s.allowed_senders, enabled = s.enabled, last_error = case when changed && array['imap_host', 'imap_port', 'imap_user', 'password'] then null else last_error end,
         version = version + 1, updated_at = now()
   where organization_id = s.organization_id returning version into s.version;
  -- by field name only: no password and no key in the log
  perform fn_audit_change(null, 'bank_mail.settings_changed', 'bank_mail', null, null, jsonb_build_object('fields', to_jsonb(changed)));
  return jsonb_build_object('ok', true, 'version', s.version, 'relay_key', key);
end $$;
revoke all on function fn_admin_bank_mail_set(jsonb) from public, anon;
grant execute on function fn_admin_bank_mail_set(jsonb) to authenticated;

create or replace function fn_admin_upsert_bank_rule(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r bank_parse_rules%rowtype; before jsonb; kw text := btrim(coalesce(p->>'keyword', ''));
begin
  perform fn_require_cap('bank.manage');
  if char_length(kw) not between 2 and 60 then raise exception 'VALIDATION: keyword'; end if;
  if coalesce(p->>'kind', '') not in ('deposit', 'transfer_in', 'pos_settlement', 'other_in', 'transfer_out', 'withdrawal', 'fee', 'pos_fee', 'purchase', 'other_out') then raise exception 'VALIDATION: kind'; end if;
  if coalesce(p->>'priority', '') !~ '^[0-9]{1,4}$' then raise exception 'VALIDATION: priority'; end if;
  if (p->>'id') is null then
    if exists (select 1 from bank_parse_rules where organization_id = fn_user_org_id() and lower(keyword) = lower(kw)) then raise exception 'DUPLICATE_NAME'; end if;
    insert into bank_parse_rules(organization_id, keyword, kind, direction, priority)
    values (fn_user_org_id(), kw, p->>'kind', case when p->>'kind' in ('deposit', 'transfer_in', 'pos_settlement', 'other_in') then 'in' else 'out' end, (p->>'priority')::int)
    returning * into r;
    perform fn_audit_change(null, 'bank_rule.created', 'bank_rule', r.id, null, to_jsonb(r));
  else
    select * into r from bank_parse_rules where id = (p->>'id')::uuid and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_check_version_strict(r.version, (p->>'version')::int);
    if exists (select 1 from bank_parse_rules where organization_id = r.organization_id and lower(keyword) = lower(kw) and id <> r.id) then raise exception 'DUPLICATE_NAME'; end if;
    before := to_jsonb(r);
    update bank_parse_rules set keyword = kw, kind = p->>'kind', direction = case when p->>'kind' in ('deposit', 'transfer_in', 'pos_settlement', 'other_in') then 'in' else 'out' end,
           priority = (p->>'priority')::int, is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
     where id = r.id returning * into r;
    perform fn_audit_change(null, 'bank_rule.updated', 'bank_rule', r.id, before, to_jsonb(r));
  end if;
  return jsonb_build_object('ok', true, 'id', r.id, 'version', r.version);
end $$;
revoke all on function fn_admin_upsert_bank_rule(jsonb) from public, anon;
grant execute on function fn_admin_upsert_bank_rule(jsonb) to authenticated;

-- the messages as they arrived (the owner): raw text, what became of each, newest first
create or replace function fn_bank_messages(p_status text default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform fn_require_cap('bank.manage');
  if p_status is not null and p_status not in ('received', 'rejected', 'unparsed', 'parsed', 'duplicate_movement') then raise exception 'VALIDATION: status'; end if;
  return coalesce((select jsonb_agg(x order by x->>'received_at' desc) from (
    select jsonb_build_object('id', m.id, 'received_at', m.received_at, 'mail_from', m.mail_from, 'sms_sender', m.sms_sender, 'channel', m.channel,
                              'sms_received_at', m.sms_received_at, 'text', coalesce(m.sms_text, left(m.raw_body, 2000)), 'status', m.status,
                              'reason', m.reject_reason, 'movement_id', m.movement_id) as x
    from bank_messages m where m.organization_id = fn_user_org_id() and (p_status is null or m.status = p_status)
    order by m.received_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) q), '[]'::jsonb);
end $$;
revoke all on function fn_bank_messages(text, int) from public, anon;
grant execute on function fn_bank_messages(text, int) to authenticated;

-- the movements over a period: of a branch (its account) or, for the owner, all of them with the unassigned ones
create or replace function fn_bank_movements(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (fn_can('bank.view') or fn_can('bank.manage')) then raise exception 'FORBIDDEN: bank.view' using errcode = '42501'; end if;
  if p_branch is not null then perform fn_require_branch(p_branch); elsif not fn_can('bank.manage') then raise exception 'FORBIDDEN: bank.manage' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'branch_id', v.branch_id, 'branch', b.name_ar, 'account', a.name, 'kind', v.kind, 'direction', v.direction,
                                                       'amount_halalas', v.amount_halalas, 'occurred_at', v.occurred_at, 'reference', v.reference,
                                                       'balance_halalas', v.balance_halalas, 'account_hint', v.account_hint, 'status', v.status,
                                                       'text', m.sms_text, 'channel', m.channel) order by v.occurred_at desc, v.created_at desc)
                   from bank_movements v join bank_messages m on m.id = v.message_id
                   left join branches b on b.id = v.branch_id left join cash_accounts a on a.id = v.cash_account_id
                   where v.organization_id = fn_user_org_id() and fn_branch_date(v.branch_id, v.occurred_at) between p_from and p_to
                     and (case when p_branch is null then true else v.branch_id = p_branch end)), '[]'::jsonb);
end $$;
revoke all on function fn_bank_movements(uuid, date, date) from public, anon;
grant execute on function fn_bank_movements(uuid, date, date) to authenticated;

-- after the owner changes the words, the senders or the key: read a message not understood, or refused, again
create or replace function fn_bank_reparse(p_message uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m bank_messages%rowtype; r jsonb;
begin
  perform fn_require_cap('bank.manage');
  select * into m from bank_messages where id = p_message and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if m.status not in ('unparsed', 'rejected') then raise exception 'VALIDATION: message_status'; end if;
  r := fn_bank_process(m.id);
  perform fn_audit_change(null, 'bank_message.reparsed', 'bank_message', m.id, jsonb_build_object('status', m.status), r);
  return jsonb_build_object('ok', true) || r;
end $$;
revoke all on function fn_bank_reparse(uuid) from public, anon;
grant execute on function fn_bank_reparse(uuid) to authenticated;

-- a movement whose account the message did not tell apart (e.g. an ending two accounts share): the owner names the
-- branch's bank account, once, with a reason
create or replace function fn_bank_assign_account(p_movement uuid, p_account uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bank_movements%rowtype; a cash_accounts%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform fn_require_cap('bank.manage');
  select * into v from bank_movements where id = p_movement and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v.cash_account_id is not null then raise exception 'VALIDATION: movement_assigned'; end if;
  if v_reason is null or char_length(v_reason) > 300 then raise exception 'VALIDATION: reason'; end if;
  select * into a from cash_accounts where id = p_account and organization_id = v.organization_id and kind = 'bank_account' and archived_at is null;
  if not found then raise exception 'VALIDATION: account'; end if;
  update bank_movements set cash_account_id = a.id, branch_id = a.branch_id where id = v.id;
  perform fn_audit_change(a.branch_id, 'bank_movement.assigned', 'bank_movement', v.id, null, jsonb_build_object('account', a.name, 'amount_halalas', v.amount_halalas), v_reason);
  return jsonb_build_object('ok', true, 'branch_id', a.branch_id);
end $$;
revoke all on function fn_bank_assign_account(uuid, uuid, text) from public, anon;
grant execute on function fn_bank_assign_account(uuid, uuid, text) to authenticated;
