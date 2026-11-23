-- ============================================================================================================
-- مسح بيانات مرحلة البناء والتصحيح — يشغّله المالك بنفسه في محرر SQL (Supabase ← SQL Editor ← New query)
-- قرار المالك ق1 (23 نوفمبر 2026): «احذف كل البيانات المدخلة كبيانات حجوزات أو زوار أو مالية… احذف الأثر كاملًا»
--
-- يُمسح: الحجوزات والإقامات ولياليها وتخصيصاتها، والنزلاء كلهم (ومنهم المستوردون من زائر) وحظرهم وتقييماتهم،
--        والمال كله: السندات والتأمينات والمرتجعات والفواتير والمصروفات ومرفقاتها والقيود والإقفالات اليومية
--        وفترات القفل وحركات البنك ورسائله ومطابقاتها ومدفوعات المنصات وتسويات الشبكة، وطلبات المنتجات،
--        ومهام التنظيف والصيانة، وفحوص المغادرة، ومحادثات النزلاء وواتساب والمساعد، والتنبيهات والإشعارات،
--        وبنود «بحاجة لمراجعة»، وسجلات الأخطاء والمراقبات، وسجل الإجراءات الخاص بكل ذلك. وتعود الترقيمات إلى 1.
-- يبقى: المنشأة والفروع والبلوكات والطوابق والمرافق والوحدات وفئاتها وصناديق المفاتيح، والأسعار والسياسات،
--        والصناديق والحسابات البنكية وشجرة الحسابات وتصنيفات المصروفات، والموظفون وعضوياتهم وصلاحياتهم،
--        والإعدادات (الضريبة، رحلة الضيف، واتساب، الدفع، الذكاء الاصطناعي، بريد البنك وقواعده)، والمنتجات
--        وفئاتها، وأنواع المهام والخدمات، وقاعدة المعرفة وقواعد التنبيه، وسجل الإجراءات الخاص بالإعدادات.
--
-- معاملة واحدة: إن فشل أي فحص في آخرها لا يتغير شيء. لا يمس حسابات الدخول (auth) ولا الترحيلات.
-- النسخة الاحتياطية قبله: فرع backup/2026-11-23-0617 (100 جدول، 5,168 صفًا)، والمفتاح في Drive المالك.
-- ============================================================================================================
do $wipe$
declare
  wipe text[] := array[
    'access_delivery_events', 'access_release_requests', 'accounting_periods', 'ai_action_proposals',
    'ai_guardrail_events', 'ai_ops_conversations', 'ai_ops_messages', 'ai_tool_executions', 'ai_usage_daily',
    'alert_events', 'bank_match_items', 'bank_matches', 'bank_messages', 'bank_movements', 'checkout_inspections',
    'client_errors', 'code_rotation_events', 'conversation_messages', 'conversations', 'data_purge_requests',
    'day_closing_lines', 'day_closing_requests', 'day_closings', 'expense_attachments', 'expense_vouchers',
    'financial_vouchers', 'guest_bans', 'guest_lookup_attempts', 'guest_phone_challenges', 'guest_phone_sessions',
    'guest_profiles', 'guest_reviews', 'housekeeping_tasks', 'human_handoff_tickets', 'integration_events',
    'invoices', 'journal_entries', 'journal_lines', 'journey_messages', 'maintenance_tickets', 'monitor_runs',
    'notifications', 'payment_transactions', 'platform_payouts', 'pos_settlements', 'product_order_lines',
    'product_orders', 'registration_sessions', 'reservation_allocations', 'reservation_charges',
    'reservation_guests', 'reservation_nights', 'reservations', 'review_items', 'stay_acknowledgements',
    'stay_extension_requests', 'stay_payment_exceptions', 'unanswered_questions', 'whatsapp_inbound_messages',
    'whatsapp_outbox'];
  -- سجل الإجراءات: يُمسح ما يخص المُمسوح فقط، ويبقى ما يخص الإعدادات (الفروع، الوحدات، الموظفين…)
  audit_types text[] := array[
    'reservation', 'voucher', 'invoice', 'expense_voucher', 'day_closing', 'housekeeping_task', 'ai_action_proposal',
    'guest', 'guest_profile', 'guest_ban', 'guest_review', 'product_order', 'platform_payout', 'pos_settlement',
    'bank_movement', 'bank_match', 'bank_message', 'checkout_inspection', 'review_item', 'deposit', 'refund',
    'maintenance_ticket', 'conversation', 'journey', 'stay', 'payment', 'journal_entry', 'accounting_period'];
  keep_before jsonb := '{}';
  t text; n bigint; bad text := '';
begin
  -- 0) المشروع الصحيح وعلى حاله: 74 ترحيلًا، و100 جدول، وكل جداول المسح موجودة
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute 'select count(*) from supabase_migrations.schema_migrations' into n;
    if n <> 74 then raise exception 'WIPE_ABORTED: migration history is %, expected 74', n; end if;
  end if;
  select count(*) into n from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r';
  if n <> 100 then raise exception 'WIPE_ABORTED: % tables in public, expected 100', n; end if;
  foreach t in array wipe loop
    if to_regclass(format('public.%I', t)) is null then raise exception 'WIPE_ABORTED: table % is missing', t; end if;
  end loop;

  -- 1) عدد صفوف كل جدول باقٍ قبل المسح
  for t in select c.relname from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and not (c.relname = any(wipe)) loop
    execute format('select count(*) from public.%I', t) into n;
    keep_before := keep_before || jsonb_build_object(t, n);
  end loop;

  -- 2) المسح: أمر واحد لكل الجداول؛ يرفضه PostgreSQL إن أشار إليها جدول باقٍ، فلا يبقى صف معلّق
  execute 'truncate table ' || (select string_agg(format('public.%I', x), ', ') from unnest(wipe) x) || ' restart identity';

  -- 3) أثر المُمسوح في سجل الإجراءات
  delete from public.audit_events where entity_type = any(audit_types);

  -- 4) الترقيمات من 1 (السندات والتأمينات والفواتير والمصروفات…)
  update public.document_sequences set last_value = 0 where last_value <> 0;

  -- 5) الوحدات بلا إقامات: متاحة ونظيفة (الصيانة والإيقاف يبقيان كما هما)، والصناديق تنسى آخر حجز
  -- (after the run of 23 Nov 2026: split in two so a dirty unit out of service or in maintenance stays so; on that day's
  --  data the result is identical — every unit out of service was clean)
  update public.rooms set status = 'available', cleanliness = 'clean', version = version + 1, updated_at = now()
   where status in ('reserved', 'occupied', 'cleaning', 'ready');
  update public.rooms set cleanliness = 'clean', version = version + 1, updated_at = now()
   where cleanliness <> 'clean';
  update public.keyboxes set last_reservation_id = null where last_reservation_id is not null;
  -- عدّادات استعمال قاعدة المعرفة من محادثات النزلاء
  update public.knowledge_entries set used_count = 0, last_used_at = null where used_count <> 0 or last_used_at is not null;

  -- 6) الفحوص: جداول المسح فارغة، والجداول الباقية بعددها نفسه، ولا أثر باقٍ للمُمسوح في السجل
  foreach t in array wipe loop
    execute format('select count(*) from public.%I', t) into n;
    if n <> 0 then bad := bad || t || '=' || n || ' '; end if;
  end loop;
  for t in select key from jsonb_each(keep_before) loop
    execute format('select count(*) from public.%I', t) into n;
    if t <> 'audit_events' and n <> (keep_before ->> t)::bigint then bad := bad || t || ':' || (keep_before ->> t) || '->' || n || ' '; end if;
  end loop;
  if exists (select 1 from public.audit_events where entity_type = any(audit_types)) then bad := bad || 'audit_events '; end if;
  if exists (select 1 from public.rooms where status in ('reserved', 'occupied')) then bad := bad || 'rooms '; end if;
  if bad <> '' then raise exception 'WIPE_CHECK_FAILED (nothing changed): %', bad; end if;
end $wipe$;

-- النتيجة: كل الأعداد الأولى صفر، والأخيرة لما بقي
select (select count(*) from public.reservations) as reservations,
       (select count(*) from public.guest_profiles) as guests,
       (select count(*) from public.financial_vouchers) as vouchers,
       (select count(*) from public.journal_entries) as journal_entries,
       (select count(*) from public.expense_vouchers) as expenses,
       (select count(*) from public.day_closings) as day_closings,
       (select count(*) from public.conversations) as conversations,
       (select count(*) from public.audit_events) as audit_kept,
       (select count(*) from public.rooms) as rooms_kept,
       (select count(*) from public.staff_profiles) as staff_kept,
       (select count(*) from public.products) as products_kept;
