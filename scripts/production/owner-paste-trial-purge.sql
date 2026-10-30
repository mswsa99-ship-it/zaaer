-- =====================================================================================================
-- للصق مرة واحدة في Supabase ← SQL Editor ← New query ← الصق هذا الملف كله ← Run
--
-- تفريغ بيانات التجربة قبل استيراد بيانات زائر (31 أكتوبر 2026). يحذف كل ما أُدخل للتجربة حتى 30 أكتوبر:
-- الحجوزات (ومنها الحجزان المقيمان)، والسندات والفواتير والمدفوعات وتسويات الشبكة، وملفات نزلاء التجربة،
-- والمحادثات ومساعد العمليات، والمهام والصيانة المنتهية، والإشعارات وسجلات التكامل، وسجل الإجراءات لتلك الفترة.
-- يستعمل دالة التفريغ نفسها التي تعمل بها صفحة «تفريغ البيانات».
--
-- لا يمس: الفرعين الجديدين بريدة وعنيزة ووحداتهما وأنواعهما، ولا الموظفين والمشرفَين، ولا المصادر والإعدادات
-- والأسعار والسياسات وقاعدة المعرفة. ثم يؤرشف «فرع الرياض» التجريبي (أرشفة، لا حذف).
--
-- كل شيء في معاملة واحدة: إن فشل أي جزء لا يتغير شيء. توجد نسخة احتياطية مشفّرة قبلها
-- (backup/2026-10-30-1853، ومفتاحها في Drive المالك). النتيجة المتوقعة في آخر سطر: «تم» وأعداد ما حُذف.
-- =====================================================================================================
begin;

do $trial$
declare v_owner staff_profiles%rowtype; v_trial uuid; v_counts jsonb;
begin
  select * into v_owner from staff_profiles where role = 'owner' and is_active order by created_at limit 1;
  select id into v_trial from branches where organization_id = v_owner.organization_id and name_ar = 'فرع الرياض - طريق الملك فهد';
  if v_trial is null then raise exception 'لم يُعثر على فرع التجربة؛ لم يتغير شيء'; end if;
  if exists (select 1 from reservations r join branches b on b.id = r.branch_id where b.name_ar in ('فرع بريدة', 'فرع عنيزة')) then
    raise exception 'في الفرعين الجديدين حجوزات؛ توقف التفريغ ولم يتغير شيء';
  end if;

  -- the trial's in-house stays leave first (the purge never touches a stay in house)
  update reservations set status = 'checked_out', actual_check_out = coalesce(actual_check_out, now()), updated_at = now()
  where branch_id = v_trial and status in ('checked_in', 'confirmed', 'pending_verification', 'draft');

  -- the purge itself, for the trial period, every kind of data
  v_counts := fn_purge_run(v_owner.organization_id, null, date '2026-10-01', date '2026-10-30',
                           array['conversations', 'reservations', 'finance', 'guests', 'operations', 'logs', 'audit']);
  perform fn_audit(v_owner.organization_id, null, v_owner.id, 'data_purge_executed', 'organization', v_owner.organization_id,
    jsonb_build_object('from', '2026-10-01', 'to', '2026-10-30', 'counts', v_counts, 'via', 'owner paste before the Zaaer import'));

  -- the trial branch leaves the lists (archived, never removed)
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner.auth_user_id, 'role', 'authenticated', 'email', v_owner.email)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner.auth_user_id::text, true);
  if (select archived_at from branches where id = v_trial) is null then
    perform fn_admin_archive_definition('branch', v_trial, 'فرع التجربة؛ الفرعان الفعليان بريدة وعنيزة من بيانات زائر (31 أكتوبر 2026)');
  end if;

  if exists (select 1 from reservations where branch_id = v_trial) then
    raise exception 'بقيت حجوزات تجربة بعد التفريغ؛ لم يتغير شيء';
  end if;
  perform set_config('app.trial_purge_counts', v_counts::text, false);
end $trial$;

commit;

select 'تم' as result,
       current_setting('app.trial_purge_counts', true) as deleted,
       (select count(*) from reservations) as reservations_left,
       (select count(*) from guest_profiles) as guest_profiles_left,
       (select string_agg(name_ar || case when archived_at is null then '' else ' (مؤرشف)' end, '، ' order by created_at) from branches) as branches;
