-- ============================================================================================================
-- إزالة فرع الرياض التجريبي المؤرشف — يشغّله المالك بنفسه في محرر SQL (Supabase ← SQL Editor ← New query)
-- طلب المالك (23 نوفمبر 2026): إزالة «فرع الرياض - طريق الملك فهد» المؤرشف منذ 30 أكتوبر ووحداته العشر.
--
-- يُزال مع الفرع كل ما يتبعه وحده (محتوى تجريبي من 22 أكتوبر): الوحدات العشر وصناديق مفاتيحها، ونوعا الوحدات
--   وتوفّرهما (28 يومًا) وقاعدتا الإتاحة وما أُتيح منها، والمبنى والطابقان والمرفقان، و3 أنواع مهام، وخدمة
--   «ساعات اضافية»، و7 سياسات و10 إجابات في قاعدة المعرفة، والصندوق والحساب البنكي التلقائيان، وإعدادات رحلة
--   الضيف وواتساب الخاصة به، و16 قيدًا عنه في سجل الإجراءات.
-- لا يمس فرعي بريدة وعنيزة ولا أي إعداد عام. يرفض العمل دون أي تغيير إن لم يكن الفرع مؤرشفًا موقوفًا، أو كان عليه
--   موظف أو حجز أو سند أو أي سجل غير المذكور، أو اختلفت الأعداد عمّا عُدّ يوم 23 نوفمبر.
-- معاملة واحدة: إن فشل أي فحص لا يتغير شيء. النسخة الاحتياطية قبله: فرع backup/2026-11-23-0650، والمفتاح في Drive المالك.
-- ============================================================================================================
do $rm$
declare
  b constant uuid := '00000000-0000-0000-0000-000000000010';
  -- what belongs to the branch alone, and how many rows each holds (counted on 23 Nov 2026)
  expected constant jsonb := '{"rooms": 10, "keyboxes": 10, "room_categories": 2, "inventory_periods": 28, "release_rules": 2,
    "released_slots": 5, "blocks": 1, "floors": 2, "facilities": 2, "task_types": 3, "service_definitions": 1,
    "property_policies": 7, "knowledge_entries": 10, "cash_accounts": 2, "branch_journey_settings": 1,
    "branch_whatsapp_channels": 1}';
  ids uuid[];
  outside_before jsonb;
  outside_after jsonb;
  t text; n bigint; bad text := '';
begin
  -- 1) the branch: this one, archived and stopped
  if not exists (select 1 from public.branches where id = b and archived_at is not null and not is_active
                   and name_ar = 'فرع الرياض - طريق الملك فهد') then
    raise exception 'REMOVE_REFUSED (nothing changed): the archived trial branch is not there';
  end if;

  -- 2) nothing else points at it: every table with a branch_id holds no row for it, except the ones above and the log
  for t in select c.relname from pg_attribute a join pg_class c on c.oid = a.attrelid
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and a.attname = 'branch_id' and not a.attisdropped loop
    execute format('select count(*) from public.%I where branch_id = $1', t) into n using b;
    if expected ? t then
      if n <> (expected ->> t)::bigint then bad := bad || t || ':' || n || '<>' || (expected ->> t) || ' '; end if;
    elsif t <> 'audit_events' and n <> 0 then
      bad := bad || t || '=' || n || ' ';
    end if;
  end loop;
  -- nor at its cash accounts, task types, service or knowledge answers from outside the branch
  if exists (select 1 from public.gl_accounts where cash_account_id in (select id from public.cash_accounts where branch_id = b)) then bad := bad || 'gl_accounts '; end if;
  if exists (select 1 from public.service_definitions where branch_id <> b and task_type_id in (select id from public.task_types where branch_id = b)) then bad := bad || 'services '; end if;
  if exists (select 1 from public.reservation_charges where service_definition_id in (select id from public.service_definitions where branch_id = b)) then bad := bad || 'charges '; end if;
  if exists (select 1 from public.unanswered_questions where knowledge_entry_id in (select id from public.knowledge_entries where branch_id = b)) then bad := bad || 'unanswered '; end if;
  if bad <> '' then raise exception 'REMOVE_REFUSED (nothing changed): %', bad; end if;

  -- every removed row's id, for the log
  select array_agg(id) into ids from (
    select b as id
    union all select id from public.rooms where branch_id = b
    union all select id from public.keyboxes where branch_id = b
    union all select id from public.room_categories where branch_id = b
    union all select id from public.blocks where branch_id = b
    union all select id from public.floors where branch_id = b
    union all select id from public.facilities where branch_id = b
    union all select id from public.task_types where branch_id = b
    union all select id from public.service_definitions where branch_id = b
    union all select id from public.property_policies where branch_id = b
    union all select id from public.knowledge_entries where branch_id = b
    union all select id from public.cash_accounts where branch_id = b) x;
  if cardinality(ids) <> 51 then raise exception 'REMOVE_REFUSED (nothing changed): % rows, not 51', cardinality(ids); end if;

  -- what lies outside the branch, to prove it unchanged afterwards
  select jsonb_object_agg(k, v) into outside_before from (
    select c.relname as k, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::bigint
           - case when c.relname = 'branches' then 1 when expected ? c.relname then (expected ->> c.relname)::bigint else 0 end as v
      from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname <> 'audit_events') z;

  -- 3) the removal, children before parents
  delete from public.audit_events where branch_id = b or entity_id = any(ids);
  delete from public.keyboxes where branch_id = b;
  delete from public.service_definitions where branch_id = b;
  delete from public.facilities where branch_id = b;
  delete from public.rooms where branch_id = b;
  delete from public.floors where branch_id = b;
  delete from public.blocks where branch_id = b;
  delete from public.inventory_periods where branch_id = b;
  delete from public.release_rules where branch_id = b;
  delete from public.released_slots where branch_id = b;
  delete from public.room_categories where branch_id = b;
  delete from public.task_types where branch_id = b;
  delete from public.property_policies where branch_id = b;
  delete from public.knowledge_entries where branch_id = b;
  delete from public.cash_accounts where branch_id = b;
  delete from public.branch_journey_settings where branch_id = b;
  delete from public.branch_whatsapp_channels where branch_id = b;
  delete from public.branches where id = b;

  -- 4) the checks: nothing of the branch is left anywhere, and everything outside it is as it was
  for t in select c.relname from pg_attribute a join pg_class c on c.oid = a.attrelid
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and a.attname = 'branch_id' and not a.attisdropped loop
    execute format('select count(*) from public.%I where branch_id = $1', t) into n using b;
    if n <> 0 then bad := bad || t || '=' || n || ' '; end if;
  end loop;
  if exists (select 1 from public.audit_events where entity_id = any(ids)) then bad := bad || 'audit_events '; end if;
  select jsonb_object_agg(c.relname, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::bigint)
    into outside_after from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname <> 'audit_events';
  if outside_after is distinct from outside_before then bad := bad || 'outside: ' || (outside_before - array(select key from jsonb_each(outside_before) e where outside_after -> e.key = e.value))::text || ' '; end if;
  if bad <> '' then raise exception 'REMOVE_CHECK_FAILED (nothing changed): %', bad; end if;
end $rm$;

-- النتيجة المتوقعة: فرعان، 24 وحدة منها 23 في الخدمة، 48 قيدًا في سجل الإجراءات، 6 سياسات، لا إجابات في قاعدة المعرفة
select (select count(*) from public.branches) as branches,
       (select count(*) from public.rooms) as rooms,
       (select count(*) from public.rooms where is_active) as rooms_in_service,
       (select count(*) from public.audit_events) as audit,
       (select count(*) from public.property_policies) as policies,
       (select count(*) from public.knowledge_entries) as knowledge;
