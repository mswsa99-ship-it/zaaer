-- LOCAL CANDIDATE v2, UNADOPTED. Payment provider settings: separate owner-granted sensitive permission payment.settings (user item 2; authority is the user's original message, not this comment).
-- v2 changes vs the supplied file: the catalog is regenerated from the v7 LIVE function text plus ONE row (the supplied file carried a stray older fn_audit_list body and a syntax error, both dropped).
create or replace function fn_permission_catalog()
 RETURNS TABLE(code text, label text, area text, sort integer, default_roles role_code[], full_roles role_code[], limit_note text, locked boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
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
    ('payment.settings', 'إعدادات مزوّد الدفع الإلكتروني (للحسابات الفردية فقط، بمنحة صريحة من المالك)', 'الموظفون والأمان', 502, '{owner}', null, null, false),
    ('admin.permissions', 'تعديل مصفوفة الصلاحيات', 'الموظفون والأمان', 505, '{owner}', null, null, true),
    ('review.list', 'قائمة «بحاجة لمراجعة وتدقيق» والتأشير عليها', 'التقارير والسجل', 510, '{owner}', null, null, false),
    ('reports.finance', 'التقارير المالية وتقرير الخصومات', 'التقارير والسجل', 520, '{owner,manager,supervisor,finance}', '{owner,manager,finance}', 'ملخص الخصومات فقط', false),
    ('accounts.view', 'دليل الحسابات والقيود وميزان المراجعة وقائمة الدخل والميزانية', 'التقارير والسجل', 524, '{owner,manager,finance}', null, null, false),
    ('accounts.close_month', 'قفل الشهر المحاسبي وفتحه', 'التقارير والسجل', 526, '{owner}', null, null, false),
    ('bank.view', 'الرسائل البنكية والحركات المستخرجة منها', 'التقارير والسجل', 527, '{owner,manager,finance}', null, null, false),
    ('bank.manage', 'بريد البنك وقواعد قراءة الرسائل وإعادة قراءتها', 'التقارير والسجل', 528, '{owner}', null, null, false),
    ('reports.identities_usage', 'تقرير الهويات المعتمدة من المكتب وتقرير الاستعمال', 'التقارير والسجل', 530, '{owner}', null, null, false),
    ('audit.log', 'سجل الإجراءات', 'التقارير والسجل', 540, '{owner,manager,supervisor}', '{owner,manager}', 'بلا تفاصيل التغييرات', false),
    ('history.details', 'تفاصيل قبل وبعد التعديل في سجل الإجراءات وتاريخ الحجز (للحسابات الفردية فقط، بمنحة صريحة)', 'التقارير والسجل', 545, '{owner}', null, null, false);
$function$;
grant execute on function fn_permission_catalog() to authenticated;

insert into permission_page_map(code, page, action, sensitive, any_write)
  values ('payment.settings', '/admin/payment-providers', 'edit', true, false)
  on conflict (code) do nothing;

create or replace function fn_admin_payment_settings(p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s branch_payment_settings%rowtype;
begin
  -- provenance only: user item 2 (original reply, see report). A SEPARATE owner-granted sensitive permission 'payment.settings' for individual non-owner accounts; legacy and owner keep cap 'security'
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual' then
    if not fn_can('payment.settings') then raise exception 'FORBIDDEN: payment settings' using errcode = '42501'; end if;
  else
    perform fn_require_cap('security');
  end if;
  perform fn_require_branch(p_branch);
  select * into s from branch_payment_settings where branch_id = p_branch;
  return jsonb_build_object('branch_id', p_branch, 'provider', s.provider, 'provider_label', s.provider_label, 'merchant_id', s.merchant_id,
    'publishable_key', s.publishable_key, 'has_secret', s.secret_key_encrypted is not null, 'secret_last4', s.secret_last4,
    'pos_terminal_id', s.pos_terminal_id, 'online_enabled', coalesce(s.online_enabled, false), 'updated_at', s.updated_at,
    'updated_by', (select full_name from staff_profiles where id = s.updated_by),
    'complete', s.provider is not null and s.merchant_id is not null and s.publishable_key is not null and s.secret_key_encrypted is not null);
end $$;
revoke all on function fn_admin_payment_settings(uuid) from public, anon;
grant execute on function fn_admin_payment_settings(uuid) to authenticated;

create or replace function fn_admin_save_payment_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s branch_payment_settings%rowtype; v_branch uuid := (p->>'branch_id')::uuid; v text; changed text[] := '{}'; was boolean;
begin
  -- provenance only: user item 2 (original reply, see report). A SEPARATE owner-granted sensitive permission 'payment.settings' for individual non-owner accounts; legacy and owner keep cap 'security'
  if fn_staff_id() is not null and fn_current_role() <> 'owner' and fn_user_access_mode() = 'individual' then
    if not fn_can('payment.settings') then raise exception 'FORBIDDEN: payment settings' using errcode = '42501'; end if;
  else
    perform fn_require_cap('security');
  end if;
  perform fn_require_branch(v_branch);
  select * into s from branch_payment_settings where branch_id = v_branch for update;
  was := found;
  if not was then s.branch_id := v_branch; s.organization_id := (select organization_id from branches where id = v_branch); s.online_enabled := false; end if;
  if p ? 'provider' then
    v := nullif(trim(coalesce(p->>'provider', '')), '');
    if v is not null and v not in ('moyasar', 'tap', 'hyperpay', 'paytabs', 'other') then raise exception 'VALIDATION: provider'; end if;
    if v is distinct from s.provider then s.provider := v; changed := array_append(changed, 'provider'); end if;
  end if;
  if p ? 'provider_label' then
    v := nullif(trim(coalesce(p->>'provider_label', '')), '');
    if v is not null and char_length(v) > 60 then raise exception 'VALIDATION: provider_label'; end if;
    s.provider_label := v;
  end if;
  if s.provider is distinct from 'other' then s.provider_label := null; end if;
  if p ? 'merchant_id' then
    v := nullif(trim(coalesce(p->>'merchant_id', '')), '');
    if v is not null and (char_length(v) > 80 or v !~ '^[A-Za-z0-9._:-]+$') then raise exception 'VALIDATION: merchant_id'; end if;
    if v is distinct from s.merchant_id then s.merchant_id := v; changed := array_append(changed, 'merchant_id'); end if;
  end if;
  if p ? 'publishable_key' then
    v := nullif(trim(coalesce(p->>'publishable_key', '')), '');
    if v is not null and (char_length(v) > 200 or v ~ '\s') then raise exception 'VALIDATION: publishable_key'; end if;
    if v is distinct from s.publishable_key then s.publishable_key := v; changed := array_append(changed, 'publishable_key'); end if;
  end if;
  -- the secret key is kept encrypted and never returned; an empty value leaves it, «clear_secret» removes it
  if nullif(trim(coalesce(p->>'secret_key', '')), '') is not null then
    v := trim(p->>'secret_key');
    if char_length(v) < 8 or char_length(v) > 300 or v ~ '\s' then raise exception 'VALIDATION: secret_key'; end if;
    s.secret_key_encrypted := pgp_sym_encrypt(v, fn_secret('keybox_key')); s.secret_last4 := right(v, 4); changed := array_append(changed, 'secret_key');
  elsif coalesce((p->>'clear_secret')::boolean, false) and s.secret_key_encrypted is not null then
    s.secret_key_encrypted := null; s.secret_last4 := null; changed := array_append(changed, 'secret_key');
  end if;
  if p ? 'pos_terminal_id' then
    v := nullif(fn_latin_digits(trim(coalesce(p->>'pos_terminal_id', ''))), '');
    if v is not null and (char_length(v) > 40 or v !~ '^[A-Za-z0-9-]+$') then raise exception 'VALIDATION: pos_terminal_id'; end if;
    if v is distinct from s.pos_terminal_id then s.pos_terminal_id := v; changed := array_append(changed, 'pos_terminal_id'); end if;
  end if;
  if p ? 'online_enabled' then
    if (p->>'online_enabled')::boolean and (s.provider is null or s.merchant_id is null or s.publishable_key is null or s.secret_key_encrypted is null) then
      raise exception 'VALIDATION: payment_incomplete';
    end if;
    if (p->>'online_enabled')::boolean is distinct from s.online_enabled then s.online_enabled := (p->>'online_enabled')::boolean; changed := array_append(changed, 'online_enabled'); end if;
  end if;
  if s.online_enabled and (s.provider is null or s.merchant_id is null or s.publishable_key is null or s.secret_key_encrypted is null) then s.online_enabled := false; end if;
  insert into branch_payment_settings(branch_id, organization_id, provider, provider_label, merchant_id, publishable_key, secret_key_encrypted, secret_last4,
                                      pos_terminal_id, online_enabled, updated_at, updated_by)
  values (s.branch_id, s.organization_id, s.provider, s.provider_label, s.merchant_id, s.publishable_key, s.secret_key_encrypted, s.secret_last4,
          s.pos_terminal_id, s.online_enabled, now(), fn_staff_id())
  on conflict (branch_id) do update set provider = excluded.provider, provider_label = excluded.provider_label, merchant_id = excluded.merchant_id,
    publishable_key = excluded.publishable_key, secret_key_encrypted = excluded.secret_key_encrypted, secret_last4 = excluded.secret_last4,
    pos_terminal_id = excluded.pos_terminal_id, online_enabled = excluded.online_enabled, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  if cardinality(changed) > 0 then
    perform fn_audit_change(v_branch, 'payment_settings.updated', 'branch', v_branch, null,
      jsonb_build_object('changed', to_jsonb(changed), 'provider', s.provider, 'secret_last4', s.secret_last4, 'online_enabled', s.online_enabled), null);
  end if;
  return jsonb_build_object('ok', true, 'changed', to_jsonb(changed));
end $$;
revoke all on function fn_admin_save_payment_settings(jsonb) from public, anon;
grant execute on function fn_admin_save_payment_settings(jsonb) to authenticated;
