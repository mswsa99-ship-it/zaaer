/*
# 0006 — Property policies (public knowledge base for the AI receptionist)

The AI may only state policy facts returned by get_public_property_policies,
which reads this table. Management edits it from /admin/policies.
*/
create table if not exists property_policies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  topic text not null check (topic in ('checkin','cancellation','wifi','parking','location','children','contact','stay','privacy','other')),
  title text not null,
  content_ar text not null,
  content_en text,
  is_public boolean not null default true,
  sort_order int default 0,
  updated_by uuid,
  updated_at timestamptz default now(),
  created_at timestamptz default now()
);
create index if not exists idx_policies_branch on property_policies(branch_id, is_public);

alter table property_policies enable row level security;
create policy "anon_read_public_policies" on property_policies for select to anon using (is_public);
create policy "staff_read_policies" on property_policies for select to authenticated using (branch_id in (select fn_user_branch_ids()));
create policy "mgr_write_policies" on property_policies for all to authenticated
  using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'))
  with check (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner','manager'));

insert into property_policies (organization_id, branch_id, topic, title, content_ar, sort_order) values
 ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','checkin','مواعيد الوصول والمغادرة','الوصول من الساعة 4:00 عصرًا، والمغادرة حتى 12:00 ظهرًا. الوصول المبكر أو المغادرة المتأخرة بحسب التوفر وبموافقة المشرف.',1),
 ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','stay','شروط الإقامة','يلزم تسجيل بيانات جميع النزلاء والمرافقين ومطابقة الهوية مع الوثيقة الأصلية عند الوصول قبل تسليم رمز الدخول. يُمنع التدخين داخل الوحدات.',2),
 ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','cancellation','سياسة الإلغاء','تخضع سياسة الإلغاء لشروط منصة الحجز التي تم الحجز من خلالها. للحجز المباشر: إلغاء مجاني حتى 48 ساعة قبل الوصول.',3),
 ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','wifi','الإنترنت','إنترنت لاسلكي مجاني في جميع الوحدات. تُرسل بيانات الشبكة مع رمز الدخول بعد الاعتماد.',4),
 ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','parking','المواقف','مواقف مجانية أمام المبنى لنزلاء المنشأة.',5),
 ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','children','الأطفال والمرافقون','يُحتسب الأطفال ضمن السعة القصوى للوحدة ويجب تسجيل بياناتهم كمرافقين.',6),
 ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010','contact','التواصل','للمساعدة العاجلة تواصل مع الاستقبال على الرقم الموضح في صفحة الفرع، أو اطلب تحويل المحادثة إلى مشرف.',7)
on conflict do nothing;
