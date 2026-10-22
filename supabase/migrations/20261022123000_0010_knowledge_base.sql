/*
# 0010 — Knowledge base for the reception assistant

The assistant answers guest questions ONLY from records the property controls:
  1. branch settings (check-in/out times, address, phone)      — branches
  2. the fixed policy topics (cancellation, wifi, parking, …)  — property_policies
  3. free-form Q&A entries managed by staff                    — knowledge_entries   (this migration)
Anything it could not answer is logged (unanswered_questions) so staff can turn it into an
answer with one click; the next guest gets the answer. Entries are archived, never deleted,
while they have usage/history; every change is audited with actor/time/reason.

Public exposure goes through fn_public_knowledge() only: anonymous clients never read the
table, and non-public (staff-only) entries never leave the server.
*/

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists knowledge_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete cascade,         -- null = every branch of the organization
  category text not null default 'general'
    check (category in ('general','stay','services','location','payment','policies','facilities','other')),
  question text not null,                                             -- canonical question as a guest would ask it
  keywords text[] not null default '{}',                              -- normalized triggers / synonyms
  answer text not null,                                               -- Arabic answer sent to the guest verbatim
  answer_en text,
  is_public boolean not null default true,                            -- false = staff-only (ops copilot), never sent to guests
  is_active boolean not null default true,
  priority int not null default 0,                                    -- tie-breaker between overlapping entries
  used_count int not null default 0,
  last_used_at timestamptz,
  version int not null default 1,
  archived_at timestamptz,
  archived_by uuid,
  archive_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint knowledge_question_len check (char_length(trim(question)) between 3 and 300),
  constraint knowledge_answer_len check (char_length(trim(answer)) between 2 and 2000)
);
create index if not exists idx_knowledge_org_branch on knowledge_entries(organization_id, branch_id) where archived_at is null;
create index if not exists idx_knowledge_keywords on knowledge_entries using gin (keywords);

create table if not exists unanswered_questions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid references branches(id) on delete cascade,
  question text not null,
  normalized text not null,
  asked_count int not null default 1,
  first_asked_at timestamptz not null default now(),
  last_asked_at timestamptz not null default now(),
  status text not null default 'open' check (status in ('open','answered','ignored')),
  knowledge_entry_id uuid references knowledge_entries(id) on delete set null,
  last_conversation_id uuid,
  resolved_by uuid,
  resolved_at timestamptz,
  resolve_note text
);
create unique index if not exists uq_unanswered_branch_norm on unanswered_questions(coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid), normalized);
create index if not exists idx_unanswered_open on unanswered_questions(organization_id, status, last_asked_at desc);

-- ---------------------------------------------------------------------------
-- 2. Arabic normalization (same rules as the TypeScript normalizeArabic())
-- ---------------------------------------------------------------------------
create or replace function fn_normalize_ar(p text) returns text
language sql immutable as $$
  -- digits → ASCII, diacritics/tatweel removed, [إأآٱ]→ا, [ىئ]→ي, ؤ→و, ة→ه, whitespace collapsed, lower-cased
  select trim(regexp_replace(
           regexp_replace(
             translate(lower(coalesce(p,'')), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹أإآٱةىئؤ', '01234567890123456789ااااهييو'),
             '[\u064B-\u0652\u0670\u0640]', '', 'g'),
           '\s+', ' ', 'g'));
$$;

-- ---------------------------------------------------------------------------
-- 3. Row-level security: staff of the organization read; writes only via RPC
-- ---------------------------------------------------------------------------
alter table knowledge_entries enable row level security;
alter table unanswered_questions enable row level security;

drop policy if exists "staff_read_knowledge" on knowledge_entries;
create policy "staff_read_knowledge" on knowledge_entries for select to authenticated
  using (organization_id = fn_user_org_id() and (branch_id is null or branch_id in (select fn_user_branch_ids())));

drop policy if exists "staff_read_unanswered" on unanswered_questions;
create policy "staff_read_unanswered" on unanswered_questions for select to authenticated
  using (organization_id = fn_user_org_id() and (branch_id is null or branch_id in (select fn_user_branch_ids())));
-- no insert/update/delete policies: all writes go through the SECURITY DEFINER functions below
revoke insert, update, delete on knowledge_entries from authenticated, anon;
revoke insert, update, delete on unanswered_questions from authenticated, anon;
revoke select on knowledge_entries from anon;
revoke select on unanswered_questions from anon;

-- ---------------------------------------------------------------------------
-- 4. Public read: only active, public, non-archived entries of the branch (or org-wide)
-- ---------------------------------------------------------------------------
create or replace function fn_public_knowledge(p_branch uuid)
returns table (id uuid, category text, question text, keywords text[], answer text, priority int)
language sql stable security definer set search_path = public as $$
  select k.id, k.category, k.question, k.keywords, k.answer, k.priority
  from knowledge_entries k
  join branches b on b.id = p_branch and b.organization_id = k.organization_id
  where k.is_public and k.is_active and k.archived_at is null
    and (k.branch_id is null or k.branch_id = p_branch)
  order by k.priority desc, k.used_count desc, k.created_at;
$$;
grant execute on function fn_public_knowledge(uuid) to anon, authenticated, service_role;

-- staff view (includes staff-only entries) — same shape plus flags, for the ops copilot
create or replace function fn_staff_knowledge(p_branch uuid)
returns table (id uuid, category text, question text, keywords text[], answer text, priority int, is_public boolean)
language sql stable security definer set search_path = public as $$
  select k.id, k.category, k.question, k.keywords, k.answer, k.priority, k.is_public
  from knowledge_entries k
  where k.organization_id = fn_user_org_id() and p_branch in (select fn_user_branch_ids())
    and k.is_active and k.archived_at is null and (k.branch_id is null or k.branch_id = p_branch)
  order by k.priority desc, k.used_count desc, k.created_at;
$$;
revoke all on function fn_staff_knowledge(uuid) from public, anon;
grant execute on function fn_staff_knowledge(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Management: upsert / archive / restore (owner, manager, supervisor)
-- ---------------------------------------------------------------------------
create or replace function fn_admin_upsert_knowledge(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k knowledge_entries%rowtype; v_org uuid; v_branch uuid; v_kw text[]; v_before jsonb; v_q text; v_a text;
begin
  perform fn_require_role('owner','manager','supervisor');
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
end $$;
revoke all on function fn_admin_upsert_knowledge(jsonb) from public, anon;
grant execute on function fn_admin_upsert_knowledge(jsonb) to authenticated;

create or replace function fn_admin_archive_knowledge(p_id uuid, p_reason text, p_archive boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k knowledge_entries%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
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
end $$;
revoke all on function fn_admin_archive_knowledge(uuid, text, boolean) from public, anon;
grant execute on function fn_admin_archive_knowledge(uuid, text, boolean) to authenticated;

create or replace function fn_admin_resolve_unanswered(p_id uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u unanswered_questions%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  if p_status not in ('open','ignored') then raise exception 'VALIDATION: status'; end if;
  select * into u from unanswered_questions where id = p_id and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if u.branch_id is not null then perform fn_require_branch(u.branch_id); end if;
  update unanswered_questions set status = p_status, resolved_by = case when p_status = 'open' then null else fn_staff_id() end,
    resolved_at = case when p_status = 'open' then null else now() end, resolve_note = p_note where id = u.id;
  perform fn_audit(u.organization_id, u.branch_id, fn_staff_id(), 'unanswered.' || p_status, 'unanswered_question', u.id, jsonb_build_object('before', u.status, 'after', p_status, 'reason', p_note));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_admin_resolve_unanswered(uuid, text, text) from public, anon;
grant execute on function fn_admin_resolve_unanswered(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Assistant hooks (service role only — called by the edge function)
-- ---------------------------------------------------------------------------
create or replace function fn_record_unanswered(p_branch uuid, p_question text, p_conversation uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_norm text; v_id uuid;
begin
  select organization_id into v_org from branches where id = p_branch;
  if v_org is null then return jsonb_build_object('ok', false, 'error', 'BRANCH_NOT_FOUND'); end if;
  v_norm := left(fn_normalize_ar(regexp_replace(p_question, '\d{4,}', '#', 'g')), 200);   -- digits masked: no phone/ID numbers in the log
  if char_length(v_norm) < 3 then return jsonb_build_object('ok', false, 'error', 'TOO_SHORT'); end if;
  insert into unanswered_questions(organization_id, branch_id, question, normalized, last_conversation_id)
  values (v_org, p_branch, left(regexp_replace(p_question, '\d{4,}', '#', 'g'), 300), v_norm, p_conversation)
  on conflict (coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid), normalized)
  do update set asked_count = unanswered_questions.asked_count + 1, last_asked_at = now(), last_conversation_id = excluded.last_conversation_id,
                status = case when unanswered_questions.status = 'answered' then 'answered' else 'open' end
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function fn_record_unanswered(uuid, text, uuid) from public, anon, authenticated;
grant execute on function fn_record_unanswered(uuid, text, uuid) to service_role;

create or replace function fn_knowledge_usage_bump(p_entry uuid) returns void
language sql security definer set search_path = public as $$
  update knowledge_entries set used_count = used_count + 1, last_used_at = now() where id = p_entry;
$$;
revoke all on function fn_knowledge_usage_bump(uuid) from public, anon, authenticated;
grant execute on function fn_knowledge_usage_bump(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 7. Demo seed (only for the demo organization created by 0004; synthetic content, no personal data)
-- ---------------------------------------------------------------------------
insert into knowledge_entries (organization_id, branch_id, category, question, keywords, answer, priority)
select '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010', c, q, k, a, p
from (values
  ('facilities', 'هل يوجد مسبح؟', array['مسبح','سباحه','pool'], 'نعم، يوجد مسبح خارجي مشترك يعمل يوميًا من 8 صباحًا حتى 10 مساءً، والدخول مجاني لنزلاء المنشأة. يُمنع نزول الأطفال دون مرافق.', 5),
  ('services', 'هل تقدمون الإفطار؟', array['افطار','فطور','breakfast','وجبه'], 'لا يُقدَّم إفطار داخل المنشأة، لكن كل وحدة مزودة بمطبخ صغير، وتتوفر مطاعم ومخابز على بُعد دقائق سيرًا.', 4),
  ('facilities', 'هل يوجد مصلى؟', array['مصلى','صلاه','مسجد'], 'يوجد مصلى للرجال في الدور الأرضي بجوار الاستقبال، وأقرب مسجد على بُعد 200 متر.', 3),
  ('services', 'هل توجد خدمة غسيل ملابس؟', array['غسيل','ملابس','مغسله','laundry','غساله'], 'تتوفر غسالة ملابس في وحدات الغرفتين، وخدمة مغسلة خارجية بطلب من الاستقبال (رسوم بحسب القطعة، تُضاف على الحجز).', 3),
  ('stay', 'هل يُسمح بالحيوانات الأليفة؟', array['حيوان','حيوانات','قطه','كلب','pet','pets'], 'نعتذر، لا يُسمح باصطحاب الحيوانات الأليفة داخل الوحدات حفاظًا على راحة بقية النزلاء.', 2),
  ('stay', 'هل يمكن إضافة سرير إضافي؟', array['سرير اضافي','سرير','مهد','طفل رضيع','extra bed'], 'يتوفر سرير إضافي قابل للطي ومهد للأطفال بطلب مسبق، بحسب سعة الوحدة؛ يُضاف الطلب على الحجز ويؤكده الاستقبال.', 2),
  ('payment', 'ما طرق الدفع المتاحة؟', array['دفع','بطاقه','مدى','تحويل','كاش','نقد','visa','mada','apple pay'], 'يُقبل الدفع بمدى وبطاقات الائتمان والتحويل البنكي والنقد عند الاستقبال. لا يُطلب منك إرسال بيانات بطاقتك عبر المحادثة أبدًا.', 2),
  ('services', 'هل يوجد تنظيف يومي للوحدة؟', array['تنظيف يومي','تنظيف','نظافه','تغيير المناشف','مناشف','housekeeping'], 'تنظيف الوحدة يتم قبل كل وصول، ويتوفر تنظيف دوري كل 3 أيام للإقامات الطويلة، وتُستبدل المناشف عند الطلب عبر الاستقبال.', 2),
  ('location', 'ما أقرب الأماكن للتسوق والمطاعم؟', array['تسوق','مول','مطاعم','مطعم','سوبرماركت','بقاله','قريب'], 'يبعد مركز التسوق الرئيسي 5 دقائق بالسيارة، وتوجد بقالة ومطاعم عائلية على بُعد دقائق سيرًا من المبنى.', 1),
  ('stay', 'هل يوجد مواقف ذوي الإعاقة أو وحدات مهيأة؟', array['اعاقه','ذوي','كرسي متحرك','مصعد','مهياه','accessible'], 'المبنى مزود بمصعد، وتتوفر وحدة مهيأة في الدور الأرضي بطلب مسبق، مع موقف قريب من المدخل.', 1)
) as v(c, q, k, a, p)
where exists (select 1 from branches where id = '00000000-0000-0000-0000-000000000010')
  and not exists (select 1 from knowledge_entries where organization_id = '00000000-0000-0000-0000-000000000001');
