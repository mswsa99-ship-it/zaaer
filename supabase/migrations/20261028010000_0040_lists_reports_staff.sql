-- =====================================================================
-- 0040 — Phase 6: the lists, the calendar, the log, the exports, the reports' filters, task times, free manual
--        cleanliness, the staff editor, forced sign-out and the capability usage report.
--
--  Decision 14 (10.1–10.4): the reservations list takes every filter the reference has (dates of arrival,
--        departure and creation, individual or company, the company, unit type and number, rent type, source,
--        a discount, status, payment and identity states), returns the columns a column picker needs, and a person's
--        saved views live on the server (staff_saved_views: own rows only). The units board gets «تقويم الحجوزات»
--        (fn_reservation_calendar: units × days). The log is read through fn_audit_list — readable Arabic names
--        (fn_audit_action_label, one dictionary with src/lib/auditLabels.ts), filters, pages and the same rows for
--        the export. The ledger is read through fn_voucher_list — filters, pages, and totals over the whole set, so
--        no export stops at a silent limit.
--  Decision 36: every report takes the filters its data has (staff, payment method, box or account, source, unit
--        type) beside the period and the branch; the same function serves the screen and the export.
--  Decision 43 (G25, X09): every export source is a function with the same filters as its screen and an exact total.
--  Decision 28: the task's planned start and end (columns from 0007b) stay the server's; no reminder, no automatic end.
--  Decision 12 is already in 0033 (free manual cleanliness, the owner's deviation from G18); nothing changes here.
--  Decision 34: «تسجيل خروج إجباري» — the owner or the manager ends every session of a staff member on every device,
--        with a reason; the account stays active. Deactivation ends the sessions too. Enforced in the database: every
--        token carries its session id, and fn_staff_id() answers nothing for a session that was ended (auth.sessions
--        timeboxed with not_after, its refresh tokens revoked), so the next request from any device is refused.
--  Decision 35: «تعديل موظف» for the owner only: name, phone, role and branches, with a reason, before and after in
--        the log; no one changes their own role or branches; the last owner is never demoted; the email is the login
--        identity and is not edited. Branch memberships are retired (removed_at), never erased, so history keeps.
--  Decision 55 (11.2, D04): «استعمال القدرات» for the owner from the audit log itself: last successful use, uses per
--        week, who used it (a person, the assistant, automation), the core-administration mark, and an honest
--        «غير محسوم» where the log cannot tell (a capability that is not audited, or a window the log does not cover).
--
--  Written without the words the SQL tool refuses: constraints and columns are added only when missing, policies are
--        changed with ALTER POLICY, superseded report signatures are retired by the owner's paste (0041).
-- =====================================================================

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The audit dictionary (decision 14, 10.3) — the same words as src/lib/auditLabels.ts
--    One family is missing here on purpose: the codes the hard removal of an unused definition writes (0015's
--    function) are spelled with a word this file keeps clear of; the owner's paste (0041)
--    re-creates both functions and the catalogue below with the complete dictionary. Until then those few codes read
--    humanised from their parts. tests/unit/audit_labels.test.ts holds the three copies together.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_audit_entity_label(p_entity text) returns text
language sql immutable set search_path = public as $$
  select case when p_entity is null then '—' else coalesce(
    case p_entity
      when 'reservation' then 'حجز'
      when 'reservation_guest' then 'ضيف'
      when 'guest_profile' then 'ملف ضيف'
      when 'financial_voucher' then 'سند'
      when 'voucher' then 'سند'
      when 'invoice' then 'فاتورة'
      when 'room' then 'وحدة'
      when 'room_category' then 'نوع وحدة'
      when 'facility' then 'مرفق'
      when 'housekeeping_task' then 'مهمة'
      when 'task_type' then 'نوع مهمة'
      when 'service_definition' then 'خدمة'
      when 'branch' then 'فرع'
      when 'block' then 'بلوك'
      when 'floor' then 'طابق'
      when 'staff_profile' then 'موظف'
      when 'cash_account' then 'صندوق أو حساب'
      when 'booking_source' then 'مصدر حجز'
      when 'service' then 'خدمة'
      when 'keybox' then 'صندوق مفتاح'
      when 'knowledge_entry' then 'إجابة'
      when 'unanswered_question' then 'سؤال بلا إجابة'
      when 'ai_settings' then 'إعدادات الذكاء الاصطناعي'
      when 'ai_proposal' then 'اقتراح المساعد'
      when 'ai_action_proposal' then 'اقتراح المساعد'
      when 'conversation' then 'محادثة'
      when 'review_items' then 'بند مراجعة'
      when 'pos_settlement' then 'تسوية شبكة'
      when 'platform_payout' then 'إيداع منصة'
      when 'review_item' then 'بند مراجعة'
      when 'maintenance_ticket' then 'بلاغ صيانة'
      when 'whatsapp_channel' then 'واتساب الفرع'
      when 'organization' then 'المنشأة'
      when 'data_purge' then 'تفريغ بيانات'
      when 'rate_calendar' then 'تقويم الأسعار'
      when 'inventory_period' then 'فترة توفر'
      when 'release_rule' then 'قاعدة توفر'
      when 'released_slot' then 'توفر'
      else null
    end, replace(p_entity, '_', ' ')) end;
$$;

create or replace function fn_audit_action_label(p_action text) returns text
language sql immutable set search_path = public as $$
  select coalesce(
    case p_action
      when 'reservation.created' then 'إنشاء حجز'
      when 'reservation.cancelled' then 'إلغاء حجز'
      when 'reservation.cancel_undone' then 'التراجع عن إلغاء حجز'
      when 'reservation.checked_in' then 'تسجيل وصول'
      when 'reservation.check_in_undone' then 'التراجع عن تسجيل الوصول'
      when 'reservation.checked_out' then 'تسجيل مغادرة'
      when 'reservation.closed' then 'إغلاق إقامة'
      when 'reservation.unclosed' then 'إعادة فتح إقامة مغلقة'
      when 'reservation.stay_reopened' then 'إعادة فتح إقامة بعد المغادرة'
      when 'reservation.no_show' then 'تسجيل عدم حضور'
      when 'reservation.departure_changed' then 'تغيير موعد المغادرة'
      when 'reservation.room_switched' then 'تبديل الوحدة'
      when 'reservation.service_added' then 'إضافة خدمة إلى الحجز'
      when 'reservation.total_changed' then 'تعديل إجمالي الحجز'
      when 'reservation.payment_exception' then 'مهلة سداد استثنائية'
      when 'reservation.inspected' then 'فحص المغادرة'
      when 'reservation.damage_charged' then 'رسم ضرر'
      when 'reservation.hold_set' then 'وضع حظر على الحجز'
      when 'reservation.hold_lifted' then 'رفع الحظر عن الحجز'
      when 'reservation.shomoos_registered' then 'تسجيل شموس'
      when 'reservation.shomoos_accepted' then 'تأكيد قبول شموس'
      when 'reservation.platform_checked' then 'مطابقة الحجز مع المنصة'
      when 'reservation.platform_unchecked' then 'إلغاء مطابقة الحجز مع المنصة'
      when 'reservation.summary_signed' then 'إقرار ملخص الإقامة ورقيًا'
      when 'assign_room' then 'تخصيص وحدة للحجز'
      when 'approve_checkin' then 'اعتماد الدخول'
      when 'checkout' then 'تسجيل مغادرة'
      when 'manual_release_slot' then 'فتح توفر يدويًا'
      when 'guest.entered_from_document' then 'إدخال بيانات ضيف من الوثيقة'
      when 'guest.corrected' then 'تصحيح بيانات ضيف'
      when 'guest.banned' then 'حظر ضيف'
      when 'guest.unbanned' then 'رفع حظر ضيف'
      when 'guest.rated' then 'تقييم ضيف'
      when 'guest_data_submitted' then 'إدخال الضيف بياناته بنفسه'
      when 'guest_verified_lookup' then 'تحقق الضيف من حجزه'
      when 'guest_checkin_request' then 'طلب وصول من الضيف'
      when 'guest_viewed_code' then 'عرض الضيف رمز الدخول'
      when 'guest_summary_accepted' then 'قبول الضيف ملخص الإقامة'
      when 'confirm_gov_registration' then 'تأكيد التسجيل الحكومي'
      when 'approve_identity' then 'اعتماد هوية ضيف'
      when 'reject_identity' then 'رفض هوية ضيف'
      when 'confirm_payment' then 'تأكيد دفعة'
      when 'voucher.receipt_created' then 'إنشاء سند قبض'
      when 'voucher.deposit_created' then 'إنشاء سند تأمين'
      when 'voucher.refund_created' then 'إنشاء سند رد'
      when 'voucher.deposit_refund_created' then 'إنشاء سند رد تأمين'
      when 'voucher.deposit_apply_created' then 'استخدام التأمين لتغطية رسوم'
      when 'voucher.cancelled' then 'إلغاء سند'
      when 'voucher.corrected' then 'تصحيح سند'
      when 'invoice.issued' then 'إصدار فاتورة'
      when 'invoice.edited' then 'تعديل فاتورة'
      when 'invoice.cancelled' then 'إلغاء فاتورة'
      when 'pos.settled' then 'تسوية الشبكة'
      when 'platform.payout_confirmed' then 'تأكيد إيداع منصة'
      when 'platform.payout_cancelled' then 'إلغاء إيداع منصة'
      when 'cash_account.created' then 'إنشاء صندوق أو حساب'
      when 'cash_account.updated' then 'تعديل صندوق أو حساب'
      when 'cash_account.archived' then 'أرشفة صندوق أو حساب'
      when 'cash_account.restored' then 'استعادة صندوق أو حساب'
      when 'rates.updated' then 'تعديل الأسعار'
      when 'review.marked' then 'مراجعة بند من قائمة المراجعة'
      when 'deliver_access_code' then 'تسليم رمز الدخول'
      when 'delivery_failed' then 'تعذّر تسليم رمز الدخول'
      when 'rotate_keybox_code' then 'تغيير رمز صندوق المفتاح'
      when 'keybox_field_tested' then 'تجربة رمز صندوق المفتاح'
      when 'keybox.code_viewed' then 'عرض رمز صندوق المفتاح'
      when 'task.created' then 'إنشاء مهمة'
      when 'task.started' then 'بدء مهمة'
      when 'task.completed' then 'إتمام مهمة'
      when 'task.cancelled' then 'إلغاء مهمة'
      when 'task.assigned' then 'إسناد مهمة'
      when 'cleaning_completed' then 'إتمام تنظيف'
      when 'room.cleanliness_changed' then 'تغيير حالة النظافة يدويًا'
      when 'maintenance_opened' then 'فتح بلاغ صيانة'
      when 'maintenance_resolved' then 'إغلاق بلاغ صيانة'
      when 'branch.created' then 'إنشاء فرع'
      when 'branch.updated' then 'تعديل فرع'
      when 'branch.money_defaults' then 'تعديل إعدادات المال للفرع'
      when 'branch.tax_changed' then 'تغيير ضريبة الفرع'
      when 'branch.logo_changed' then 'تغيير شعار الفرع'
      when 'branch.image_changed' then 'تغيير صورة الفرع'
      when 'branch.archived' then 'أرشفة فرع'
      when 'branch.restored' then 'استعادة فرع'
      when 'block.created' then 'إنشاء بلوك'
      when 'block.updated' then 'تعديل بلوك'
      when 'block.archived' then 'أرشفة بلوك'
      when 'block.restored' then 'استعادة بلوك'
      when 'floor.created' then 'إنشاء طابق'
      when 'floor.updated' then 'تعديل طابق'
      when 'floor.archived' then 'أرشفة طابق'
      when 'floor.restored' then 'استعادة طابق'
      when 'room.created' then 'إنشاء وحدة'
      when 'room.updated' then 'تعديل وحدة'
      when 'room.archived' then 'أرشفة وحدة'
      when 'room.restored' then 'استعادة وحدة'
      when 'room_category.created' then 'إنشاء نوع وحدة'
      when 'room_category.updated' then 'تعديل نوع وحدة'
      when 'room_category.archived' then 'أرشفة نوع وحدة'
      when 'room_category.restored' then 'استعادة نوع وحدة'
      when 'facility.created' then 'إنشاء مرفق'
      when 'facility.updated' then 'تعديل مرفق'
      when 'facility.archived' then 'أرشفة مرفق'
      when 'facility.restored' then 'استعادة مرفق'
      when 'task_type.created' then 'إنشاء نوع مهمة'
      when 'task_type.updated' then 'تعديل نوع مهمة'
      when 'task_type.archived' then 'أرشفة نوع مهمة'
      when 'task_type.restored' then 'استعادة نوع مهمة'
      when 'service.created' then 'إنشاء خدمة'
      when 'service.updated' then 'تعديل خدمة'
      when 'service.archived' then 'أرشفة خدمة'
      when 'service.restored' then 'استعادة خدمة'
      when 'source.enabled' then 'تفعيل مصدر حجز'
      when 'source.disabled' then 'تعطيل مصدر حجز'
      when 'staff_invited' then 'دعوة موظف'
      when 'staff.activated' then 'تفعيل موظف'
      when 'staff.deactivated' then 'إيقاف موظف'
      when 'staff.role_changed' then 'تغيير دور موظف'
      when 'staff.updated' then 'تعديل بيانات موظف'
      when 'staff.signed_out' then 'تسجيل خروج إجباري'
      when 'demo_owner_bootstrap' then 'إنشاء مالك نسخة العرض'
      when 'data_purge_executed' then 'تنفيذ تفريغ بيانات'
      when 'ai_proposal.executed' then 'تنفيذ اقتراح مساعد العمليات'
      when 'ai_settings_updated' then 'تعديل إعدادات الذكاء الاصطناعي'
      when 'knowledge.created' then 'إضافة إجابة إلى قاعدة المعرفة'
      when 'knowledge.updated' then 'تعديل إجابة في قاعدة المعرفة'
      when 'knowledge.archived' then 'أرشفة إجابة من قاعدة المعرفة'
      when 'knowledge.restored' then 'استعادة إجابة في قاعدة المعرفة'
      when 'unanswered.ignored' then 'تجاهل سؤال بلا إجابة'
      when 'unanswered.open' then 'إعادة فتح سؤال بلا إجابة'
      when 'conversation_taken' then 'استلام المحادثة من المساعد'
      when 'conversation_returned_to_assistant' then 'إعادة المحادثة إلى المساعد'
      when 'whatsapp_channel_updated' then 'تعديل إعداد واتساب الفرع'
      else null
    end,
    case when position('.' in p_action) > 1 then
      coalesce(case split_part(p_action, '.', 2)
        when 'created' then 'إنشاء' when 'updated' then 'تعديل' when 'archived' then 'أرشفة' when 'restored' then 'استعادة'
        when 'enabled' then 'تفعيل' when 'disabled' then 'تعطيل' when 'cancelled' then 'إلغاء' when 'completed' then 'إتمام'
        when 'started' then 'بدء' when 'assigned' then 'إسناد' when 'issued' then 'إصدار' when 'edited' then 'تعديل'
        when 'corrected' then 'تصحيح' when 'confirmed' then 'تأكيد' when 'approved' then 'اعتماد' when 'rejected' then 'رفض'
        when 'viewed' then 'عرض' when 'changed' then 'تغيير' when 'executed' then 'تنفيذ' when 'marked' then 'تعليم' when 'settled' then 'تسوية'
        else null end, replace(split_part(p_action, '.', 2), '_', ' '))
      || ' — ' || fn_audit_entity_label(split_part(p_action, '.', 1))
    end,
    replace(p_action, '_', ' '));
$$;


-- ---------------------------------------------------------------------------------------------------------------
-- 2. Sessions (decision 34): a token's session must still be open
-- ---------------------------------------------------------------------------------------------------------------
-- Every access token Supabase issues carries session_id = auth.sessions.id. A session the owner ended has
-- not_after in the past (and no row at all once Supabase cleans up); a token without the claim (tests, service
-- keys) has nothing to check. Read in the three identity helpers below, so RLS and every RPC refuse an ended
-- session on its next request, on any device, whatever the token's own expiry.
create or replace function fn_session_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then true
    when coalesce(auth.jwt()->>'session_id', '') !~ '^[0-9a-fA-F-]{36}$' then true
    else exists (select 1 from auth.sessions s where s.id = (auth.jwt()->>'session_id')::uuid and (s.not_after is null or s.not_after > now()))
  end;
$$;
revoke all on function fn_session_ok() from public, anon, authenticated;

create or replace function fn_staff_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from staff_profiles where auth_user_id = auth.uid() and is_active and fn_session_ok() limit 1;
$$;
create or replace function fn_current_role() returns role_code
language sql stable security definer set search_path = public as $$
  select role from staff_profiles where auth_user_id = auth.uid() and is_active and fn_session_ok() limit 1;
$$;
create or replace function fn_user_org_id() returns uuid
language sql stable security definer set search_path = public as $$
  select organization_id from staff_profiles where auth_user_id = auth.uid() and is_active and fn_session_ok() limit 1;
$$;

-- Ends every session of an auth user: the timebox closes now and the refresh tokens are revoked, so Supabase refuses
-- to refresh and fn_session_ok() refuses the tokens still in hand. Internal (not callable from the API).
create or replace function fn_end_sessions(p_user uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if p_user is null then return 0; end if;
  update auth.sessions set not_after = now(), updated_at = now() where user_id = p_user and (not_after is null or not_after > now());
  get diagnostics n = row_count;
  update auth.refresh_tokens set revoked = true, updated_at = now() where user_id = p_user::text and coalesce(revoked, false) = false;
  return n;
end $$;
revoke all on function fn_end_sessions(uuid) from public, anon, authenticated;

alter table staff_profiles add column if not exists sessions_ended_at timestamptz;
alter table staff_profiles add column if not exists updated_at timestamptz;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Branch memberships are retired, never erased (decision 35)
-- ---------------------------------------------------------------------------------------------------------------
alter table branch_memberships add column if not exists removed_at timestamptz;
alter table branch_memberships add column if not exists removed_by uuid;

/** the one question every reader asks: is this staff member on this branch now? (the owner is on every branch) */
create or replace function fn_is_member(p_staff uuid, p_branch uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff_profiles s where s.id = p_staff and s.is_active and s.role = 'owner'
                   and s.organization_id = (select organization_id from branches where id = p_branch))
      or exists (select 1 from branch_memberships m join staff_profiles s on s.id = m.staff_id
                   where m.staff_id = p_staff and m.branch_id = p_branch and m.removed_at is null and s.is_active);
$$;
revoke all on function fn_is_member(uuid, uuid) from public, anon;
grant execute on function fn_is_member(uuid, uuid) to authenticated;

create or replace function fn_user_branch_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select b.id from branches b
  where b.organization_id = fn_user_org_id()
    and (fn_has_role('owner') or exists (
      select 1 from branch_memberships m where m.branch_id = b.id and m.staff_id = fn_staff_id() and m.removed_at is null));
$$;

-- the invite re-opens a retired membership instead of failing on the unique pair
create or replace function fn_staff_invite(p_email text, p_full_name text, p_role role_code, p_branch_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp staff_profiles%rowtype; b uuid;
begin
  perform fn_require_role('owner');
  if p_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  if coalesce(trim(p_email), '') = '' or coalesce(trim(p_full_name), '') = '' then raise exception 'VALIDATION: email_and_name'; end if;
  insert into staff_profiles(organization_id, full_name, email, role, is_active) values (fn_user_org_id(), trim(p_full_name), lower(trim(p_email)), p_role, true) returning * into sp;
  foreach b in array coalesce(p_branch_ids, '{}') loop
    perform fn_require_branch(b);
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  perform fn_audit(sp.organization_id, null, fn_staff_id(), 'staff_invited', 'staff_profile', sp.id,
                   jsonb_build_object('role', p_role, 'branch_ids', to_jsonb(coalesce(p_branch_ids, '{}'))));
  return jsonb_build_object('ok', true, 'staff_id', sp.id);
end $$;

-- the assignee checks and the assistant's staff list ask fn_is_member
create or replace function fn_hk_create_task(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype; v_room uuid := (p->>'room_id')::uuid; v_fac uuid := (p->>'facility_id')::uuid; v_branch uuid; tt task_types%rowtype; v_assignee uuid := (p->>'assignee_id')::uuid;
        v_start timestamptz := coalesce((p->>'scheduled_start')::timestamptz, now()); v_end timestamptz := (p->>'scheduled_end')::timestamptz;
begin
  perform fn_require_role('owner','manager','supervisor','housekeeping');
  if (v_room is null) = (v_fac is null) then raise exception 'VALIDATION: one_target'; end if;    -- H01
  if v_room is not null then select branch_id into v_branch from rooms where id = v_room and archived_at is null; end if;
  if v_fac  is not null then select branch_id into v_branch from facilities where id = v_fac and archived_at is null; end if;
  if v_branch is null then raise exception 'NOT_FOUND: target'; end if;
  perform fn_require_branch(v_branch);
  select * into tt from task_types where id = (p->>'task_type_id')::uuid and branch_id = v_branch and archived_at is null;
  if not found then raise exception 'BRANCH_MISMATCH: task_type'; end if;
  if (p->>'reservation_id') is not null and not exists (select 1 from reservations where id = (p->>'reservation_id')::uuid and branch_id = v_branch) then
    raise exception 'BRANCH_MISMATCH: reservation';
  end if;
  if v_assignee is not null and not fn_is_member(v_assignee, v_branch) then raise exception 'ASSIGNEE_NOT_IN_BRANCH'; end if;   -- H02
  if v_end is not null and v_end < v_start then raise exception 'VALIDATION: schedule'; end if;                                  -- decision 28
  insert into housekeeping_tasks(organization_id, branch_id, room_id, facility_id, task_type_id, task_type_name_snapshot, reservation_id, priority, assignee_id, scheduled_start, scheduled_end, description, created_by)
  values (fn_user_org_id(), v_branch, v_room, v_fac, tt.id, tt.name, (p->>'reservation_id')::uuid, coalesce(p->>'priority','medium'), v_assignee,
          v_start, v_end, p->>'description', fn_staff_id()) returning * into t;
  if v_room is not null and tt.code = 'room_cleaning' then update rooms set cleanliness = 'dirty' where id = v_room and cleanliness = 'clean'; perform fn_recompute_room_ready(v_room); end if;
  perform fn_audit_change(v_branch, 'task.created', 'housekeeping_task', t.id, null, to_jsonb(t));
  return jsonb_build_object('ok', true, 'id', t.id);
end $$;

create or replace function fn_hk_assign_task(p_task uuid, p_assignee uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t housekeeping_tasks%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into t from housekeeping_tasks where id = p_task for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  perform fn_require_branch(t.branch_id);
  if p_assignee is not null and not fn_is_member(p_assignee, t.branch_id) then raise exception 'ASSIGNEE_NOT_IN_BRANCH'; end if;
  update housekeeping_tasks set assignee_id = p_assignee, version = version + 1, updated_at = now() where id = t.id;
  perform fn_audit_change(t.branch_id, 'task.assigned', 'housekeeping_task', t.id, jsonb_build_object('assignee_id', t.assignee_id), jsonb_build_object('assignee_id', p_assignee));
  return jsonb_build_object('ok', true);
end $$;

-- the operations assistant's executions carry source = 'ops_assistant' on every row they write (decision 55: the usage
-- report tells a person from the assistant); the proposal stays the staff member's own (fn_staff_id) as before
create or replace function fn_ai_ops_execute_proposal(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p ai_action_proposals%rowtype; res jsonb; a jsonb; key text;
begin
  select * into p from ai_action_proposals where id = p_id for update;
  if not found or p.staff_id <> fn_staff_id() then raise exception 'FORBIDDEN: not your proposal' using errcode = '42501'; end if;
  if p.status <> 'proposed' then raise exception 'PROPOSAL_STATUS_INVALID'; end if;
  if p.expires_at < now() then
    update ai_action_proposals set status = 'expired', decided_at = now(), decided_by = fn_staff_id() where id = p.id;
    return jsonb_build_object('ok', false, 'error', 'PROPOSAL_EXPIRED');
  end if;
  perform fn_require_branch(p.branch_id);
  a := p.args;
  key := 'ai:' || p.id::text;   -- idempotent money ops keyed by the proposal itself
  perform set_config('app.source', 'ops_assistant', true);
  begin
    case p.action
      when 'create_task'        then res := fn_hk_create_task(a || jsonb_build_object('description', coalesce(a->>'description','') || ' (اقتراح المساعد)'));
      when 'complete_task'      then res := fn_hk_complete_task((a->>'task_id')::uuid, a->>'note', (a->>'expected_version')::int);
      when 'assign_task'        then res := fn_hk_assign_task((a->>'task_id')::uuid, (a->>'assignee_id')::uuid);
      when 'set_cleanliness'    then res := fn_hk_set_cleanliness((a->>'room_id')::uuid, a->>'state', coalesce(a->>'reason','اقتراح المساعد'));
      when 'amend_stay'         then res := fn_staff_amend_stay((a->>'reservation_id')::uuid, (a->>'new_check_out')::date, coalesce(a->>'pricing_mode','keep_rate'), coalesce(a->>'reason', p.summary), (a->>'expected_version')::int);
      when 'switch_room'        then res := fn_staff_switch_room((a->>'reservation_id')::uuid, (a->>'room_id')::uuid, (a->>'effective')::date, coalesce(a->>'reason', p.summary), (a->>'expected_version')::int);
      when 'cancel_reservation' then res := fn_staff_cancel_reservation((a->>'reservation_id')::uuid, coalesce(a->>'reason', p.summary), 'staff', null);
      when 'no_show'            then res := fn_staff_no_show((a->>'reservation_id')::uuid, coalesce(a->>'reason', p.summary));
      when 'create_receipt'     then res := fn_create_voucher(jsonb_build_object('reservation_id', a->>'reservation_id', 'kind', 'receipt', 'amount_halalas', (a->>'amount_halalas')::bigint, 'method', a->>'method', 'reference', a->>'reference', 'note', 'اقتراح المساعد', 'idempotency_key', key));
      when 'create_deposit'     then res := fn_create_voucher(jsonb_build_object('reservation_id', a->>'reservation_id', 'kind', 'deposit', 'amount_halalas', (a->>'amount_halalas')::bigint, 'method', a->>'method', 'reference', a->>'reference', 'note', 'اقتراح المساعد', 'idempotency_key', key));
      when 'add_service'        then res := fn_staff_add_service((a->>'reservation_id')::uuid, (a->>'service_id')::uuid, coalesce((a->>'quantity')::numeric, 1), null);
      when 'create_invoice'     then res := fn_create_invoice((a->>'reservation_id')::uuid, null, null);
      else raise exception 'VALIDATION: action';
    end case;
  exception when others then
    -- record the failure on the proposal in an autonomous way: the outer transaction rolled back the business effect
    perform set_config('app.source', '', true);
    update ai_action_proposals set status = 'failed', error = left(sqlerrm, 300), decided_at = now(), decided_by = fn_staff_id() where id = p.id;
    return jsonb_build_object('ok', false, 'error', left(sqlerrm, 300));
  end;
  update ai_action_proposals set status = 'executed', result = res, decided_at = now(), decided_by = fn_staff_id() where id = p.id;
  perform fn_audit_change(p.branch_id, 'ai_proposal.executed', 'ai_action_proposal', p.id, null, jsonb_build_object('action', p.action, 'summary', p.summary, 'result', res));
  perform set_config('app.source', '', true);
  return jsonb_build_object('ok', true, 'result', res);
end $$;

-- the staff a branch has, for screens and the assistant (retired memberships excluded)
create or replace function fn_branch_staff(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p_branch in (select fn_user_branch_ids()) then
    coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'full_name', s.full_name, 'role', s.role) order by s.full_name)
              from staff_profiles s where s.is_active and fn_is_member(s.id, p_branch)), '[]'::jsonb)
  else '[]'::jsonb end;
$$;
grant execute on function fn_branch_staff(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Staff: the list, the editor, activation and forced sign-out (decisions 34, 35)
-- ---------------------------------------------------------------------------------------------------------------
-- the staff trigger (0026) records the reason the function passes
create or replace function fn_audit_staff_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if nullif(current_setting('app.staff_edit', true), '') = '1' then return new; end if;   -- the editor writes one row itself
  if old.role is distinct from new.role or old.is_active is distinct from new.is_active or old.full_name is distinct from new.full_name then
    insert into audit_events(organization_id, branch_id, actor_id, action, entity_type, entity_id, details)
    values (new.organization_id, null, fn_staff_id(),
            case when old.is_active is distinct from new.is_active then case when new.is_active then 'staff.activated' else 'staff.deactivated' end
                 when old.role is distinct from new.role then 'staff.role_changed'
                 else 'staff.updated' end,
            'staff_profile', new.id,
            jsonb_strip_nulls(jsonb_build_object(
              'before', jsonb_build_object('role', old.role, 'is_active', old.is_active),
              'after',  jsonb_build_object('role', new.role, 'is_active', new.is_active),
              'name_changed', case when old.full_name is distinct from new.full_name then true end,
              'reason', nullif(current_setting('app.staff_reason', true), ''))));
  end if;
  return new;
end $$;

create or replace function fn_admin_staff_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when fn_has_role('owner', 'manager') then coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'full_name', s.full_name, 'email', s.email, 'phone', case when fn_has_role('owner') then s.phone end,
      'role', s.role, 'is_active', s.is_active, 'linked', s.auth_user_id is not null, 'created_at', s.created_at,
      'sessions_ended_at', s.sessions_ended_at, 'updated_at', s.updated_at,
      'branch_ids', coalesce((select jsonb_agg(m.branch_id order by m.created_at) from branch_memberships m where m.staff_id = s.id and m.removed_at is null), '[]'::jsonb),
      'is_me', s.id = fn_staff_id()) order by s.is_active desc, s.full_name)
    from staff_profiles s where s.organization_id = fn_user_org_id()), '[]'::jsonb)
  else '[]'::jsonb end;
$$;
grant execute on function fn_admin_staff_list() to authenticated;

-- «تعديل موظف» (decision 35): the owner, with a reason; name, phone, role, branches. Never the email, never oneself's
-- role or branches, never the last owner's role. One audit row with before and after (the phone masked).
create or replace function fn_admin_update_staff(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp staff_profiles%rowtype; me uuid := fn_staff_id(); v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
        v_name text; v_phone text; v_role role_code; v_branches uuid[]; before_b uuid[]; after_b uuid[]; b uuid; changed text[] := '{}';
        before_j jsonb; after_j jsonb; owners int;
begin
  perform fn_require_role('owner');
  if v_reason is null then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = (p->>'staff_id')::uuid and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if p ? 'email' and lower(trim(p->>'email')) is distinct from sp.email then raise exception 'EMAIL_NOT_EDITABLE'; end if;

  v_name := case when p ? 'full_name' then nullif(trim(p->>'full_name'), '') else sp.full_name end;
  if v_name is null then raise exception 'VALIDATION: full_name'; end if;
  v_phone := case when p ? 'phone' then nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9+]', '', 'g'), '') else sp.phone end;
  v_role := case when p ? 'role' then (p->>'role')::role_code else sp.role end;
  if v_role = 'guest' then raise exception 'INVALID_ROLE'; end if;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into before_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  v_branches := case when p ? 'branch_ids' then coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(p->'branch_ids') x), '{}') else before_b end;

  if sp.id = me and (v_role is distinct from sp.role or not (v_branches <@ before_b and before_b <@ v_branches)) then
    raise exception 'SELF_ROLE_OR_BRANCHES';                                            -- no one changes their own role or branches
  end if;
  if sp.role = 'owner' and v_role <> 'owner' then
    select count(*) into owners from staff_profiles where organization_id = sp.organization_id and role = 'owner' and is_active and id <> sp.id;
    if owners = 0 then raise exception 'LAST_OWNER: cannot remove or demote the last active owner'; end if;
  end if;
  foreach b in array v_branches loop perform fn_require_branch(b); end loop;

  if v_name is distinct from sp.full_name then changed := array_append(changed, 'full_name'); end if;
  if v_phone is distinct from sp.phone then changed := array_append(changed, 'phone'); end if;
  if v_role is distinct from sp.role then changed := array_append(changed, 'role'); end if;
  if not (v_branches <@ before_b and before_b <@ v_branches) then changed := array_append(changed, 'branches'); end if;
  if coalesce(array_length(changed, 1), 0) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;

  perform set_config('app.staff_edit', '1', true);
  update staff_profiles set full_name = v_name, phone = v_phone, role = v_role, updated_at = now() where id = sp.id;
  -- memberships: retire what is gone, re-open or add what is new (effective from the person's next operation)
  update branch_memberships set removed_at = now(), removed_by = me where staff_id = sp.id and removed_at is null and not (branch_id = any(v_branches));
  foreach b in array v_branches loop
    insert into branch_memberships(staff_id, branch_id) values (sp.id, b)
      on conflict (staff_id, branch_id) do update set removed_at = null, removed_by = null;
  end loop;
  select coalesce(array_agg(m.branch_id order by m.created_at), '{}') into after_b from branch_memberships m where m.staff_id = sp.id and m.removed_at is null;
  perform set_config('app.staff_edit', '', true);

  before_j := jsonb_build_object('full_name', sp.full_name, 'phone', case when sp.phone is null then null else '••••' || right(sp.phone, 4) end, 'role', sp.role, 'branch_ids', to_jsonb(before_b));
  after_j  := jsonb_build_object('full_name', v_name, 'phone', case when v_phone is null then null else '••••' || right(v_phone, 4) end, 'role', v_role, 'branch_ids', to_jsonb(after_b));
  perform fn_audit(sp.organization_id, null, me, case when 'role' = any(changed) then 'staff.role_changed' else 'staff.updated' end, 'staff_profile', sp.id,
                   jsonb_build_object('changed', to_jsonb(changed), 'before', before_j, 'after', after_j, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'changed', to_jsonb(changed));
end $$;
grant execute on function fn_admin_update_staff(jsonb) to authenticated;

-- activation (owner): a reason, never oneself, the last owner stays; deactivation ends every session (decision 34)
create or replace function fn_admin_set_staff_active(p_staff uuid, p_active boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp staff_profiles%rowtype; n int := 0;
begin
  perform fn_require_role('owner');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into sp from staff_profiles where id = p_staff and organization_id = fn_user_org_id() for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if sp.id = fn_staff_id() then raise exception 'SELF_NOT_ALLOWED'; end if;
  if sp.is_active = coalesce(p_active, sp.is_active) then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  perform set_config('app.staff_reason', trim(p_reason), true);
  update staff_profiles set is_active = p_active, updated_at = now(), sessions_ended_at = case when p_active then sessions_ended_at else now() end where id = sp.id;
  perform set_config('app.staff_reason', '', true);
  if not p_active then n := fn_end_sessions(sp.auth_user_id); end if;
  return jsonb_build_object('ok', true, 'is_active', p_active, 'sessions_ended', n);
end $$;
grant execute on function fn_admin_set_staff_active(uuid, boolean, text) to authenticated;

-- «تسجيل خروج إجباري» (decision 34): owner or manager, with a reason; the manager never signs out an owner or another
-- manager; never oneself (sign out normally). Every session on every device ends now; the account stays active.
create or replace function fn_admin_force_logout(p_staff uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me staff_profiles%rowtype; sp staff_profiles%rowtype; n int;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p_reason), '') = '' then raise exception 'VALIDATION: reason'; end if;
  select * into me from staff_profiles where id = fn_staff_id();
  select * into sp from staff_profiles where id = p_staff and organization_id = me.organization_id for update;
  if not found then raise exception 'NOT_FOUND: staff'; end if;
  if sp.id = me.id then raise exception 'SELF_NOT_ALLOWED'; end if;
  if me.role = 'manager' and sp.role in ('owner', 'manager') then raise exception 'FORBIDDEN: a manager signs out neither an owner nor a manager' using errcode = '42501'; end if;
  n := fn_end_sessions(sp.auth_user_id);
  update staff_profiles set sessions_ended_at = now() where id = sp.id;
  perform fn_audit(sp.organization_id, null, me.id, 'staff.signed_out', 'staff_profile', sp.id,
                   jsonb_build_object('reason', trim(p_reason), 'sessions_ended', n, 'role', sp.role, 'linked', sp.auth_user_id is not null));
  return jsonb_build_object('ok', true, 'sessions_ended', n);
end $$;
grant execute on function fn_admin_force_logout(uuid, text) to authenticated;

-- the table is no longer written directly: name, phone, role, activation and memberships go through the functions above
alter policy "owner_update_profiles" on staff_profiles using (false) with check (false);

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Saved views (decision 14): a person's own filters and columns for a list, on the server, own rows only
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists staff_saved_views (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  staff_id uuid not null references staff_profiles(id),
  screen text not null,
  name text not null,
  filters jsonb not null default '{}'::jsonb,
  columns jsonb,
  is_default boolean not null default false,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint saved_view_screen_valid check (screen in ('reservations', 'vouchers', 'audit')),
  constraint saved_view_name_len check (length(trim(name)) between 1 and 60)
);
create index if not exists idx_saved_views_staff on staff_saved_views(staff_id, screen) where archived_at is null;
alter table staff_saved_views enable row level security;
revoke all on staff_saved_views from anon, authenticated;
grant select on staff_saved_views to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'staff_saved_views' and policyname = 'own_saved_views_select') then
    create policy "own_saved_views_select" on staff_saved_views for select to authenticated using (staff_id = fn_staff_id());
  end if;
end $$;

create or replace function fn_saved_views_list(p_screen text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'filters', filters, 'columns', columns, 'is_default', is_default, 'updated_at', updated_at) order by is_default desc, name)
                   from staff_saved_views where staff_id = fn_staff_id() and screen = p_screen and archived_at is null), '[]'::jsonb);
$$;
grant execute on function fn_saved_views_list(text) to authenticated;

-- save (new or by id): at most 20 live views per screen; one default per screen
create or replace function fn_saved_view_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := fn_staff_id(); v staff_saved_views%rowtype; v_name text := nullif(trim(coalesce(p->>'name', '')), ''); v_screen text := p->>'screen'; n int;
begin
  if me is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if v_name is null or length(v_name) > 60 then raise exception 'VALIDATION: name'; end if;
  if v_screen not in ('reservations', 'vouchers', 'audit') then raise exception 'VALIDATION: screen'; end if;
  if (p->>'id') is not null then
    select * into v from staff_saved_views where id = (p->>'id')::uuid and staff_id = me and archived_at is null for update;
    if not found then raise exception 'NOT_FOUND: view'; end if;
    update staff_saved_views set name = v_name, filters = coalesce(p->'filters', filters), columns = coalesce(p->'columns', columns),
           is_default = coalesce((p->>'is_default')::boolean, is_default), updated_at = now() where id = v.id returning * into v;
  else
    select count(*) into n from staff_saved_views where staff_id = me and screen = v_screen and archived_at is null;
    if n >= 20 then raise exception 'LIMIT: saved_views'; end if;
    insert into staff_saved_views(organization_id, staff_id, screen, name, filters, columns, is_default)
    values (fn_user_org_id(), me, v_screen, v_name, coalesce(p->'filters', '{}'::jsonb), p->'columns', coalesce((p->>'is_default')::boolean, false)) returning * into v;
  end if;
  if v.is_default then update staff_saved_views set is_default = false where staff_id = me and screen = v.screen and id <> v.id and is_default; end if;
  return jsonb_build_object('ok', true, 'id', v.id);
end $$;
grant execute on function fn_saved_view_save(jsonb) to authenticated;

create or replace function fn_saved_view_remove(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update staff_saved_views set archived_at = now(), is_default = false, updated_at = now() where id = p_id and staff_id = fn_staff_id() and archived_at is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'NOT_FOUND: view'; end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function fn_saved_view_remove(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. The reservations list (decision 14, 10.1): the reference's filters, the columns a picker needs, an exact total
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_reservation_list(p_branch uuid, p_filters jsonb default '{}'::jsonb, p_limit int default 50, p_offset int default 0)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with f as (select coalesce(p_filters, '{}'::jsonb) j, coalesce((select timezone from branches where id = p_branch), 'Asia/Riyadh') tz),
  base as (
    select r.*, (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1) as guest_name,
           (select room_number from rooms where id = r.room_id) as room_number, (select name from booking_sources where id = r.source_id) as source_name,
           (select name_ar from room_categories where id = r.room_category_id) as category_name,
           (select full_name from staff_profiles where id = r.created_by) as created_by_name,
           fn_has_role('owner','manager','supervisor','finance') as money
    from reservations r, f
    where r.branch_id = p_branch and r.branch_id in (select fn_user_branch_ids())
      and (coalesce(f.j->>'status','') = '' or r.status::text = any(string_to_array(f.j->>'status', ',')))
      and (coalesce(f.j->>'open_only','false') <> 'true' or r.status in ('pending_verification','confirmed','checked_in'))
      and (f.j->>'check_in_from' is null or r.check_in >= (f.j->>'check_in_from')::date)
      and (f.j->>'check_in_to' is null or r.check_in <= (f.j->>'check_in_to')::date)
      and (f.j->>'check_out_from' is null or r.check_out >= (f.j->>'check_out_from')::date)
      and (f.j->>'check_out_to' is null or r.check_out <= (f.j->>'check_out_to')::date)
      and (f.j->>'created_from' is null or (r.created_at at time zone f.tz)::date >= (f.j->>'created_from')::date)
      and (f.j->>'created_to' is null or (r.created_at at time zone f.tz)::date <= (f.j->>'created_to')::date)
      and (f.j->>'stay_on' is null or (r.check_in <= (f.j->>'stay_on')::date and r.check_out > (f.j->>'stay_on')::date))
      and (f.j->>'source_id' is null or r.source_id = (f.j->>'source_id')::uuid)
      and (f.j->>'category_id' is null or r.room_category_id = (f.j->>'category_id')::uuid)
      and (f.j->>'room_id' is null or r.room_id = (f.j->>'room_id')::uuid)
      and (coalesce(f.j->>'room_number','') = '' or exists (select 1 from rooms rm where rm.id = r.room_id and rm.room_number = f.j->>'room_number'))
      and (coalesce(f.j->>'booking_type','') = '' or r.booking_type = f.j->>'booking_type')
      and (coalesce(f.j->>'company','') = '' or coalesce(r.company_name,'') ilike '%' || (f.j->>'company') || '%')
      and (coalesce(f.j->>'price_basis','') = '' or r.price_basis = f.j->>'price_basis')
      and (coalesce(f.j->>'payment_status','') = '' or r.payment_status::text = f.j->>'payment_status')
      and (coalesce(f.j->>'identity_status','') = '' or r.identity_status::text = f.j->>'identity_status')
      and (coalesce(f.j->>'access_status','') = '' or r.access_status::text = f.j->>'access_status')
      and (coalesce(f.j->>'group_ref','') = '' or r.group_ref = f.j->>'group_ref')
      and (coalesce(f.j->>'has_discount','false') <> 'true' or r.discount_halalas > 0)
      and (coalesce(f.j->>'platform_collects','') = '' or r.platform_collects = (f.j->>'platform_collects')::boolean)
      and (coalesce(f.j->>'has_balance','false') <> 'true' or (fn_has_role('owner','manager','supervisor','finance') and r.balance_due_halalas > 0))
      and (coalesce(f.j->>'q','') = '' or r.internal_ref ilike '%' || (f.j->>'q') || '%' or coalesce(r.external_ref,'') ilike '%' || (f.j->>'q') || '%'
           or coalesce(r.cancel_reference,'') ilike '%' || (f.j->>'q') || '%' or coalesce(r.company_name,'') ilike '%' || (f.j->>'q') || '%'
           or exists (select 1 from reservation_guests g where g.reservation_id = r.id and (g.full_name ilike '%' || (f.j->>'q') || '%' or g.phone like '%' || (f.j->>'q') || '%')))
  ),
  ordered as (
    select b.*, row_number() over (order by
      case when (select j->>'sort' from f) = 'check_in_asc' then b.check_in end asc,
      case when (select j->>'sort' from f) = 'check_out' then b.check_out end desc,
      case when (select j->>'sort' from f) = 'created' then b.created_at end desc,
      case when (select j->>'sort' from f) = 'ref' then b.internal_ref end asc,
      b.check_in desc, b.created_at desc) as rn
    from base b)
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'status', status, 'check_in', check_in, 'check_out', check_out,
               'nights', check_out - check_in, 'guest_name', guest_name, 'room_number', room_number, 'source_name', source_name, 'category_name', category_name,
               'booking_type', booking_type, 'company_name', company_name, 'price_basis', price_basis, 'adults', adults, 'companions', companions,
               'platform_booked_on', platform_booked_on, 'platform_collects', platform_collects, 'created_by_name', created_by_name,
               'actual_check_in', actual_check_in, 'actual_check_out', actual_check_out, 'cancelled_at', cancelled_at, 'cancel_reference', cancel_reference,
               'total_halalas', case when money then total_halalas end, 'paid_halalas', case when money then paid_halalas end,
               'discount_halalas', case when money then discount_halalas end, 'nightly_rate_halalas', case when money then nightly_rate_halalas end,
               'balance_due_halalas', case when money then balance_due_halalas end, 'deposit_balance_halalas', case when money then deposit_balance_halalas end,
               'payment_status', payment_status, 'identity_status', identity_status, 'access_status', access_status, 'created_at', created_at,
               'group_ref', group_ref, 'hold', coalesce(security_hold, false),
               'ban', case when fn_has_role('owner','manager','supervisor','finance') then jsonb_array_length(fn_reservation_ban_matches(id)) > 0 end,
               'rating', case when fn_has_role('owner','manager','supervisor') then (select gp.rating from reservation_guests g join guest_profiles gp on gp.id = g.guest_profile_id
                                                                                     where g.reservation_id = b.id and g.is_primary limit 1) end) order by rn), '[]'::jsonb)
             from (select * from ordered where rn > coalesce(p_offset, 0) and rn <= coalesce(p_offset, 0) + least(greatest(coalesce(p_limit, 50), 1), 1000)) b));
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- 7. «تقويم الحجوزات» (decision 14, 10.2): the units of a branch against the days of a window
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_reservation_calendar(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare money boolean;
begin
  if p_branch is null or p_branch not in (select fn_user_branch_ids()) then raise exception 'FORBIDDEN: branch not permitted' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then raise exception 'VALIDATION: range'; end if;
  money := fn_has_role('owner','manager','supervisor','finance');
  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', fn_branch_today(p_branch),
    'units', coalesce((select jsonb_agg(jsonb_build_object('room_id', r.id, 'room_number', r.room_number, 'category_id', r.category_id,
                        'category', (select name_ar from room_categories where id = r.category_id), 'floor_id', r.floor_id,
                        'floor', (select name from floors where id = r.floor_id), 'block', (select name from blocks where id = r.block_id),
                        'status', r.status, 'cleanliness', r.cleanliness, 'is_active', r.is_active)
                        order by (select sort_order from floors where id = r.floor_id) nulls last, r.room_number)
                       from rooms r where r.branch_id = p_branch and r.archived_at is null), '[]'::jsonb),
    'segments', coalesce((select jsonb_agg(jsonb_build_object('room_id', a.room_id, 'reservation_id', r.id, 'internal_ref', r.internal_ref, 'status', r.status,
                           'from_date', greatest(a.from_date, p_from), 'to_date', least(a.to_date, p_to + 1), 'starts_before', a.from_date < p_from, 'ends_after', a.to_date > p_to + 1,
                           'guest', (select full_name from reservation_guests g where g.reservation_id = r.id and g.is_primary limit 1),
                           'source', (select name from booking_sources where id = r.source_id), 'group_ref', r.group_ref,
                           'payment_status', case when money then r.payment_status end, 'balance_due_halalas', case when money then r.balance_due_halalas end)
                           order by a.room_id, a.from_date)
                          from reservation_allocations a join reservations r on r.id = a.reservation_id
                          where a.branch_id = p_branch and a.status in ('active', 'closed') and r.status not in ('cancelled', 'rejected', 'no_show')
                            and a.from_date <= p_to and a.to_date > p_from), '[]'::jsonb));
end $$;
grant execute on function fn_reservation_calendar(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 8. The log (decision 14, 10.3): readable names, filters, pages; the same rows for the export (X09)
-- ---------------------------------------------------------------------------------------------------------------
-- a short reference for the entity of an event (a booking's number, a unit's number, a staff member's name…)
create or replace function fn_audit_entity_ref(p_entity text, p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case p_entity
    when 'reservation' then (select internal_ref from reservations where id = p_id)
    when 'room' then (select room_number from rooms where id = p_id)
    when 'staff_profile' then (select full_name from staff_profiles where id = p_id)
    when 'financial_voucher' then (select number from financial_vouchers where id = p_id)
    when 'voucher' then (select number from financial_vouchers where id = p_id)
    when 'invoice' then (select number from invoices where id = p_id)
    when 'housekeeping_task' then (select task_type_name_snapshot || coalesce(' · ' || (select room_number from rooms where id = h.room_id), '') from housekeeping_tasks h where h.id = p_id)
    when 'branch' then (select name_ar from branches where id = p_id)
    when 'room_category' then (select name_ar from room_categories where id = p_id)
    when 'facility' then (select name from facilities where id = p_id)
    when 'task_type' then (select name from task_types where id = p_id)
    when 'service_definition' then (select name_ar from service_definitions where id = p_id)
    when 'cash_account' then (select name from cash_accounts where id = p_id)
    when 'booking_source' then (select name from booking_sources where id = p_id)
    when 'block' then (select name from blocks where id = p_id)
    when 'floor' then (select name from floors where id = p_id)
    when 'knowledge_entry' then (select left(question, 60) from knowledge_entries where id = p_id)
    when 'reservation_guest' then (select internal_ref from reservations where id = (select reservation_id from reservation_guests where id = p_id))
    else null end;
$$;
revoke all on function fn_audit_entity_ref(text, uuid) from public, anon, authenticated;

create or replace function fn_audit_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q jsonb := coalesce(p, '{}'::jsonb); org uuid := fn_user_org_id(); tz text; lim int; off int; is_owner boolean; is_mgmt boolean;
        v_from date; v_to date; v_branch uuid; v_actor uuid; v_action text; v_prefix boolean; v_entity text; v_entity_id uuid; v_corr text; v_cat text; v_result text; v_q text; v_source text;
        total bigint; rows jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  is_owner := fn_has_role('owner'); is_mgmt := fn_has_role('owner', 'manager');
  v_branch := (q->>'branch_id')::uuid;
  if v_branch is not null then perform fn_require_branch(v_branch); end if;
  tz := coalesce((select timezone from branches where id = v_branch), (select timezone from branches where organization_id = org order by created_at limit 1), 'Asia/Riyadh');
  v_from := (q->>'from')::date; v_to := (q->>'to')::date;
  if v_from is not null and v_to is not null and v_to < v_from then raise exception 'VALIDATION: period'; end if;
  v_actor := (q->>'actor_id')::uuid; v_action := nullif(q->>'action', ''); v_prefix := coalesce((q->>'action_prefix')::boolean, false);
  v_entity := nullif(q->>'entity_type', ''); v_entity_id := (q->>'entity_id')::uuid; v_corr := nullif(q->>'correlation_id', '');
  v_cat := nullif(q->>'category', ''); v_result := nullif(q->>'result', ''); v_q := nullif(trim(coalesce(q->>'q', '')), ''); v_source := nullif(q->>'source', '');
  lim := least(greatest(coalesce((q->>'limit')::int, 50), 1), 500); off := greatest(coalesce((q->>'offset')::int, 0), 0);

  with x as (
    select e.* from audit_events e
    where e.organization_id = org
      and (e.category <> 'security' or is_owner)
      and (is_owner or e.branch_id is null or e.branch_id in (select fn_user_branch_ids()))
      and (v_branch is null or e.branch_id = v_branch)
      and (v_from is null or (e.created_at at time zone tz)::date >= v_from)
      and (v_to is null or (e.created_at at time zone tz)::date <= v_to)
      and (v_actor is null or e.actor_id = v_actor)
      and (v_action is null or (v_prefix and e.action like v_action || '%') or (not v_prefix and e.action = v_action))
      and (v_entity is null or e.entity_type = v_entity)
      and (v_entity_id is null or e.entity_id = v_entity_id)
      and (v_corr is null or e.correlation_id = v_corr)
      and (v_cat is null or e.category = v_cat)
      and (v_result is null or e.result = v_result)
      and (v_source is null or e.source = v_source)
      and (v_q is null or e.action ilike '%' || v_q || '%' or coalesce(e.entity_type, '') ilike '%' || v_q || '%' or coalesce(e.correlation_id, '') = v_q
           or fn_audit_action_label(e.action) ilike '%' || v_q || '%' or coalesce(e.entity_id::text, '') = v_q)
  )
  select count(*), coalesce((select jsonb_agg(jsonb_build_object(
           'id', y.id, 'created_at', y.created_at, 'action', y.action, 'action_label', fn_audit_action_label(y.action),
           'entity_type', y.entity_type, 'entity_label', fn_audit_entity_label(y.entity_type), 'entity_id', y.entity_id, 'entity_ref', fn_audit_entity_ref(y.entity_type, y.entity_id),
           'actor_id', y.actor_id, 'actor_name', case when y.actor_id is not null then (select full_name from staff_profiles where id = y.actor_id)
                                                      when y.actor_type = 'guest' then 'ضيف' when y.actor_type = 'user' then 'مستخدم' else 'النظام' end,
           'actor_type', y.actor_type, 'source', y.source, 'result', y.result, 'category', y.category, 'correlation_id', y.correlation_id,
           'branch_id', y.branch_id, 'branch_name', (select name_ar from branches where id = y.branch_id),
           'reason', y.details->>'reason', 'details', case when is_mgmt then y.details end) order by y.created_at desc, y.id desc)
         from (select * from x order by created_at desc, id desc limit lim offset off) y), '[]'::jsonb)
    into total, rows from x;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', lim, 'offset', off, 'tz', tz);
end $$;
grant execute on function fn_audit_list(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 9. The ledger (decision 14, 10.4): filters, pages, and totals over the whole filtered set — no silent limit
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_voucher_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q jsonb := coalesce(p, '{}'::jsonb); v_branch uuid := (q->>'branch_id')::uuid; tz text; v_from date; v_to date; v_kind text; v_method text; v_account text; v_acc uuid; v_acc_none boolean; v_status text;
        v_staff uuid; v_res uuid; v_q text; lim int; off int; total bigint; rows jsonb; totals jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  if v_branch is null then raise exception 'VALIDATION: branch_id'; end if;
  perform fn_require_branch(v_branch);
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = v_branch;
  v_from := (q->>'from')::date; v_to := (q->>'to')::date;
  if v_from is not null and v_to is not null and v_to < v_from then raise exception 'VALIDATION: period'; end if;
  v_kind := nullif(q->>'kind', ''); v_method := nullif(q->>'method', ''); v_account := nullif(q->>'account_id', ''); v_status := coalesce(nullif(q->>'status', ''), 'approved');
  v_acc_none := v_account = 'none'; v_acc := case when v_account is not null and v_account <> 'none' then v_account::uuid end;   -- 'none': the vouchers of no box or account
  v_staff := (q->>'staff_id')::uuid; v_res := (q->>'reservation_id')::uuid; v_q := nullif(trim(coalesce(q->>'q', '')), '');
  if v_status not in ('approved', 'cancelled', 'all') then raise exception 'VALIDATION: status'; end if;
  lim := least(greatest(coalesce((q->>'limit')::int, 100), 1), 1000); off := greatest(coalesce((q->>'offset')::int, 0), 0);
  with x as (
    select v.* from financial_vouchers v
    where v.branch_id = v_branch
      and (v_from is null or (v.occurred_at at time zone tz)::date >= v_from)
      and (v_to is null or (v.occurred_at at time zone tz)::date <= v_to)
      and (v_kind is null or v.kind = v_kind)
      and (v_method is null or v.method::text = v_method)
      and (v_account is null or (v_acc_none and v.account_id is null) or v.account_id = v_acc)
      and (v_status = 'all' or v.status = v_status)
      and (v_staff is null or v.created_by = v_staff)
      and (v_res is null or v.reservation_id = v_res)
      and (v_q is null or v.number ilike '%' || v_q || '%' or coalesce(v.reference, '') ilike '%' || v_q || '%'
           or exists (select 1 from reservations r where r.id = v.reservation_id and r.internal_ref ilike '%' || v_q || '%'))
  )
  select count(*),
         coalesce((select jsonb_agg(jsonb_build_object('id', y.id, 'number', y.number, 'kind', y.kind, 'amount_halalas', y.amount_halalas, 'method', y.method, 'status', y.status,
                    'reference', y.reference, 'reason', y.reason, 'note', y.note, 'occurred_at', y.occurred_at, 'cancel_reason', y.cancel_reason, 'cancelled_at', y.cancelled_at,
                    'created_by', y.created_by, 'creator_name', (select full_name from staff_profiles where id = y.created_by),
                    'account_id', y.account_id, 'account_name', (select name from cash_accounts where id = y.account_id), 'payout_id', y.payout_id,
                    'original_voucher_id', y.original_voucher_id, 'original_number', (select number from financial_vouchers o where o.id = y.original_voucher_id),
                    'reservation', case when y.reservation_id is not null then jsonb_build_object('id', y.reservation_id, 'internal_ref', (select internal_ref from reservations where id = y.reservation_id)) end)
                    order by y.occurred_at desc, y.number desc)
                   from (select * from x order by occurred_at desc, number desc limit lim offset off) y), '[]'::jsonb),
         jsonb_build_object(
           'receipts', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'receipt'), 0),
           'refunds', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'refund'), 0),
           'deposits', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'deposit'), 0),
           'deposit_refunds', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'deposit_refund'), 0),
           'deposit_applied', coalesce(sum(amount_halalas) filter (where status = 'approved' and kind = 'deposit_apply'), 0),
           'approved', count(*) filter (where status = 'approved'), 'cancelled', count(*) filter (where status = 'cancelled'),
           'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', m, 'amount_halalas', a) order by a desc) from (select method::text m, sum(amount_halalas) a from x where status = 'approved' and kind = 'receipt' group by method) z), '[]'::jsonb),
           'by_account', coalesce((select jsonb_agg(jsonb_build_object('account_id', acc, 'account_name', (select name from cash_accounts where id = acc), 'in_halalas', i, 'out_halalas', o) order by i desc)
                                   from (select account_id acc, coalesce(sum(amount_halalas) filter (where kind in ('receipt', 'deposit')), 0) i, coalesce(sum(amount_halalas) filter (where kind in ('refund', 'deposit_refund')), 0) o
                                         from x where status = 'approved' and account_id is not null group by account_id) z), '[]'::jsonb))
    into total, rows, totals from x;
  return jsonb_build_object('total', total, 'rows', rows, 'totals', totals, 'limit', lim, 'offset', off, 'tz', tz);
end $$;
grant execute on function fn_voucher_list(jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 10. Reports with filters (decision 36): staff, payment method, box or account, source, unit type
--     New signatures beside the old ones; the old ones are retired by the owner's paste (0041). Clients name every
--     argument, so PostgREST resolves the call.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function fn_reports_finance(p_branch uuid, p_from date, p_to date, p_filters jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from date; v_to date; tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_method text; v_account text; v_acc uuid; v_acc_none boolean; v_source uuid; v_cat uuid;
        l record; c record; rs record; open_dep bigint; total_charged bigint; net bigint; v_filtered boolean;
begin
  perform fn_require_role('owner','manager','finance');
  perform fn_require_branch(p_branch);
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_from := coalesce(p_from, fn_branch_today(p_branch) - 29);
  v_to   := coalesce(p_to, fn_branch_today(p_branch));
  if v_to < v_from then raise exception 'VALIDATION: period'; end if;
  v_staff := (f->>'staff_id')::uuid; v_method := nullif(f->>'method', ''); v_account := nullif(f->>'account_id', ''); v_source := (f->>'source_id')::uuid; v_cat := (f->>'category_id')::uuid;
  v_filtered := v_staff is not null or v_method is not null or v_account is not null or v_source is not null or v_cat is not null;
  v_acc_none := v_account = 'none'; v_acc := case when v_account is not null and v_account <> 'none' then v_account::uuid end;

  -- the vouchers of the period that pass the filters (a source or unit-type filter follows the voucher's booking)
  with fv as (
    select v.* from financial_vouchers v
    where v.branch_id = p_branch and v.status = 'approved' and (v.occurred_at at time zone tz)::date between v_from and v_to
      and (v_staff is null or v.created_by = v_staff)
      and (v_method is null or v.method::text = v_method)
      and (v_account is null or (v_acc_none and v.account_id is null) or v.account_id = v_acc)
      and (v_source is null or exists (select 1 from reservations r where r.id = v.reservation_id and r.source_id = v_source))
      and (v_cat is null or exists (select 1 from reservations r where r.id = v.reservation_id and r.room_category_id = v_cat)))
  select coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0)::bigint        as receipts,
         coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint         as refunds,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit'), 0)::bigint        as deposits_received,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_refund'), 0)::bigint as deposits_refunded,
         coalesce(sum(amount_halalas) filter (where kind = 'deposit_apply'), 0)::bigint  as deposits_applied,
         coalesce((select jsonb_agg(jsonb_build_object('method', method, 'amount_halalas', amount) order by amount desc, method)
                   from (select method::text as method, sum(amount_halalas)::bigint as amount from fv where kind = 'receipt' group by method) m), '[]'::jsonb) as by_method,
         coalesce((select jsonb_agg(jsonb_build_object('day', day, 'receipts', receipts, 'refunds', refunds) order by day)
                   from (select (occurred_at at time zone tz)::date as day,
                                coalesce(sum(amount_halalas) filter (where kind in ('receipt','deposit_apply')), 0)::bigint as receipts,
                                coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint as refunds
                         from fv group by 1) d), '[]'::jsonb) as by_day,
         coalesce((select jsonb_agg(jsonb_build_object('staff_id', sid, 'staff', coalesce((select full_name from staff_profiles where id = sid), '—'), 'receipts', rc, 'refunds', rf, 'count', n) order by rc desc)
                   from (select created_by sid, coalesce(sum(amount_halalas) filter (where kind = 'receipt'), 0)::bigint rc, coalesce(sum(amount_halalas) filter (where kind = 'refund'), 0)::bigint rf, count(*) n
                         from fv where kind in ('receipt', 'refund') group by created_by) s), '[]'::jsonb) as by_staff,
         coalesce((select jsonb_agg(jsonb_build_object('account_id', acc, 'account', coalesce((select name from cash_accounts where id = acc), '—'), 'in_halalas', i, 'out_halalas', o) order by i desc)
                   from (select account_id acc, coalesce(sum(amount_halalas) filter (where kind in ('receipt','deposit')), 0)::bigint i, coalesce(sum(amount_halalas) filter (where kind in ('refund','deposit_refund')), 0)::bigint o
                         from fv where account_id is not null group by account_id) a), '[]'::jsonb) as by_account
    into l from fv;
  net := l.receipts - l.refunds + l.deposits_applied;

  select coalesce(sum(total_halalas) filter (where kind = 'rent'), 0)::bigint as rent,
         coalesce(sum(total_halalas) filter (where kind in ('addon','penalty','adjustment')), 0)::bigint as addons,
         coalesce(sum(total_halalas) filter (where kind = 'discount'), 0)::bigint as discounts,
         coalesce(sum(total_halalas) filter (where kind = 'tax'), 0)::bigint as tax
    into c
    from reservation_charges ch
    where ch.branch_id = p_branch and ch.reservation_id in (
      select r.id from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from and r.status not in ('cancelled','rejected','no_show')
        and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat));
  total_charged := c.rent + c.addons + c.discounts + c.tax;

  select count(*)::bigint as cnt,
         coalesce(sum(greatest(check_out - check_in, 0)) filter (where status not in ('cancelled','rejected','no_show')), 0)::bigint as nights,
         count(*) filter (where status = 'cancelled') as cancelled,
         count(*) filter (where status = 'no_show') as no_show
    into rs
    from reservations r where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from
      and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat);

  select coalesce(sum(greatest(deposit_balance_halalas, 0)), 0)::bigint into open_dep from reservations where branch_id = p_branch;

  return jsonb_build_object(
    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'method', v_method, 'account_id', v_account, 'source_id', v_source, 'category_id', v_cat)),
    'filtered', v_filtered,
    'ledger', jsonb_build_object('receipts', l.receipts, 'refunds', l.refunds, 'net_collected', net,
                                 'deposits_received', l.deposits_received, 'deposits_refunded', l.deposits_refunded, 'deposits_applied', l.deposits_applied,
                                 'deposit_balance_open', open_dep),
    'charges', jsonb_build_object('total_charged', total_charged, 'rent', c.rent, 'addons', c.addons, 'discounts', c.discounts, 'tax', c.tax),
    'collection_rate_pct', case when total_charged > 0 and v_staff is null and v_method is null and v_account is null then round(net::numeric * 100 / total_charged, 1) end,
    'by_method', l.by_method, 'by_day', l.by_day, 'by_staff', l.by_staff, 'by_account', l.by_account,
    'reservations', jsonb_build_object('count', rs.cnt, 'nights', rs.nights, 'cancelled', rs.cancelled, 'no_show', rs.no_show,
      'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'count', cnt, 'total_halalas', total) order by cnt desc, source), '[]'::jsonb)
                    from (select coalesce(bs.name, '—') as source, count(*)::bigint as cnt, coalesce(sum(r.total_halalas), 0)::bigint as total
                          from reservations r left join booking_sources bs on bs.id = r.source_id
                          where r.branch_id = p_branch and r.check_in <= v_to and r.check_out > v_from
                            and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat)
                          group by coalesce(bs.name, '—')) s)),
    'definitions', jsonb_build_object(
      'revenue', 'صافي التحصيل = سندات قبض الإقامة − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند. التأمين المقبوض ليس إيرادًا.',
      'collection_rate', 'نسبة التحصيل = صافي التحصيل ÷ إجمالي الرسوم (إيجار + إضافات − خصومات + ضريبة) للإقامات المتقاطعة مع الفترة؛ لا تُحسب مع مرشح الموظف أو الطريقة أو الحساب.')
  );
end $$;
grant execute on function fn_reports_finance(uuid, date, date, jsonb) to authenticated;

create or replace function fn_reports_discounts(p_branch uuid, p_from date, p_to date, p_filters jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text; full_view boolean; res jsonb; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_source uuid; v_cat uuid; v_after boolean;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  select timezone into tz from branches where id = p_branch;
  full_view := fn_has_role('owner', 'manager', 'finance');
  v_staff := (f->>'staff_id')::uuid; v_source := (f->>'source_id')::uuid; v_cat := (f->>'category_id')::uuid; v_after := (f->>'after_arrival')::boolean;
  with d as (
    select ch.id, r.id as reservation_id, r.internal_ref, ch.description, ch.reason, round(abs(ch.quantity * ch.unit_price_halalas))::bigint as amount,
           ch.created_at, ch.created_by, sp.full_name as staff_name, sp.role::text as staff_role,
           (r.actual_check_in is not null and ch.created_at >= r.actual_check_in) as after_arrival
    from reservation_charges ch
    join reservations r on r.id = ch.reservation_id
    left join staff_profiles sp on sp.id = ch.created_by
    where ch.branch_id = p_branch and ch.kind = 'discount' and (ch.created_at at time zone tz)::date between p_from and p_to
      and (v_staff is null or ch.created_by = v_staff) and (v_source is null or r.source_id = v_source) and (v_cat is null or r.room_category_id = v_cat)
      and (v_after is null or (r.actual_check_in is not null and ch.created_at >= r.actual_check_in) = v_after)
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to),
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'source_id', v_source, 'category_id', v_cat, 'after_arrival', v_after)),
    'total_halalas', coalesce(sum(amount), 0), 'count', count(*),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', s.staff_name, 'role', s.staff_role, 'count', s.n, 'total_halalas', s.total) order by s.total desc)
                          from (select staff_name, staff_role, count(*) as n, sum(amount) as total from d group by staff_name, staff_role) s), '[]'::jsonb),
    'rows', case when full_view then coalesce((select jsonb_agg(jsonb_build_object('id', d2.id, 'reservation_id', d2.reservation_id, 'internal_ref', d2.internal_ref,
              'amount_halalas', d2.amount, 'reason', coalesce(d2.reason, d2.description), 'staff', d2.staff_name, 'role', d2.staff_role,
              'created_at', d2.created_at, 'after_arrival', d2.after_arrival) order by d2.created_at desc) from d d2), '[]'::jsonb) end)
  into res from d;
  return res;
end $$;
grant execute on function fn_reports_discounts(uuid, date, date, jsonb) to authenticated;

create or replace function fn_reports_late_entries(p_branch uuid, p_from date, p_to date, p_min_days int, p_filters jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid; v_source uuid;
begin
  perform fn_require_role('owner', 'manager');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_staff := (f->>'staff_id')::uuid; v_source := (f->>'source_id')::uuid;
  return (with x as (
    select r.id, r.internal_ref, r.external_ref, s.name as source_name, r.platform_booked_on, (r.created_at at time zone tz)::date as entered_on,
           r.created_at, r.check_in, r.status, (select full_name from staff_profiles where id = r.created_by) as created_by
    from reservations r join booking_sources s on s.id = r.source_id and s.kind = 'external'
    where r.branch_id = p_branch and r.platform_booked_on is not null and (r.created_at at time zone tz)::date between p_from and p_to
      and (v_staff is null or r.created_by = v_staff) and (v_source is null or r.source_id = v_source)
  ), late as (select *, entered_on - platform_booked_on as lag_days from x where entered_on - platform_booked_on >= greatest(coalesce(p_min_days, 1), 0))
  select jsonb_build_object(
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'source_id', v_source)),
    'platform_bookings', (select count(*) from x), 'late', (select count(*) from late),
    'after_arrival', (select count(*) from late where entered_on > check_in),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', coalesce(created_by, '—'), 'count', c, 'max_lag', m) order by c desc)
                          from (select created_by, count(*) c, max(lag_days) m from late group by created_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'internal_ref', internal_ref, 'external_ref', external_ref, 'source_name', source_name,
                                                         'booked_on', platform_booked_on, 'entered_on', entered_on, 'entered_at', created_at, 'lag_days', lag_days,
                                                         'check_in', check_in, 'after_arrival', entered_on > check_in, 'status', status, 'created_by', created_by)
                                      order by lag_days desc, created_at) from late), '[]'::jsonb)));
end $$;
revoke all on function fn_reports_late_entries(uuid, date, date, int, jsonb) from public, anon;
grant execute on function fn_reports_late_entries(uuid, date, date, int, jsonb) to authenticated;

create or replace function fn_reports_identities(p_branch uuid, p_from date, p_to date, p_path text, p_filters jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tz text; f jsonb := coalesce(p_filters, '{}'::jsonb); v_staff uuid;
begin
  perform fn_require_role('owner');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: period'; end if;
  if coalesce(p_path, 'office') not in ('office', 'guest', 'all') then raise exception 'VALIDATION: path'; end if;
  select coalesce(timezone, 'Asia/Riyadh') into tz from branches where id = p_branch;
  v_staff := (f->>'staff_id')::uuid;
  return (with x as (
    select g.id, r.id as reservation_id, r.internal_ref, g.full_name, g.is_primary, g.identity_type, g.identity_number_last4, g.entry_path,
           g.entered_at, g.verified_at, (select full_name from staff_profiles where id = g.entered_by) as entered_by,
           (select full_name from staff_profiles where id = g.verified_by) as verified_by
    from reservation_guests g join reservations r on r.id = g.reservation_id
    where r.branch_id = p_branch and g.verification_status = 'verified' and g.verified_at is not null
      and (g.verified_at at time zone tz)::date between p_from and p_to
      and (coalesce(p_path, 'office') = 'all' or g.entry_path = coalesce(p_path, 'office'))
      and (v_staff is null or g.verified_by = v_staff)
  )
  select jsonb_build_object(
    'filters', jsonb_strip_nulls(jsonb_build_object('staff_id', v_staff, 'path', coalesce(p_path, 'office'))),
    'count', (select count(*) from x),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', coalesce(verified_by, '—'), 'office', o, 'guest', gu) order by o + gu desc)
                          from (select verified_by, count(*) filter (where entry_path = 'office') o, count(*) filter (where entry_path is distinct from 'office') gu
                                  from x group by verified_by) z), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('guest_id', id, 'reservation_id', reservation_id, 'internal_ref', internal_ref, 'full_name', full_name,
                                                         'is_primary', is_primary, 'identity_type', identity_type, 'identity_last4', identity_number_last4,
                                                         'entry_path', entry_path, 'entered_by', entered_by, 'entered_at', entered_at,
                                                         'verified_by', verified_by, 'verified_at', verified_at) order by verified_at desc) from x), '[]'::jsonb)));
end $$;
revoke all on function fn_reports_identities(uuid, date, date, text, jsonb) from public, anon;
grant execute on function fn_reports_identities(uuid, date, date, text, jsonb) to authenticated;

-- the filter options a report screen offers: the branch's staff, boxes and accounts, sources, unit types
create or replace function fn_report_filter_options(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p_branch in (select fn_user_branch_ids()) then jsonb_build_object(
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.full_name, 'role', s.role, 'is_active', s.is_active) order by s.is_active desc, s.full_name)
                       from staff_profiles s where s.organization_id = fn_user_org_id()
                         and (s.role = 'owner' or exists (select 1 from branch_memberships m where m.staff_id = s.id and m.branch_id = p_branch)
                              or exists (select 1 from financial_vouchers v where v.branch_id = p_branch and v.created_by = s.id)
                              or exists (select 1 from reservations r where r.branch_id = p_branch and r.created_by = s.id))), '[]'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'is_active', a.is_active) order by a.kind, a.name)
                          from cash_accounts a where a.branch_id = p_branch), '[]'::jsonb),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'is_active', b.is_active) order by b.name)
                         from booking_sources b where b.organization_id = fn_user_org_id() and b.archived_at is null), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name_ar) order by c.sort_order, c.name_ar)
                            from room_categories c where c.branch_id = p_branch and c.archived_at is null), '[]'::jsonb),
    'floors', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'block', (select name from blocks where id = f.block_id)) order by f.sort_order, f.name)
                        from floors f where f.branch_id = p_branch and f.archived_at is null), '[]'::jsonb))
  else '{}'::jsonb end;
$$;
grant execute on function fn_report_filter_options(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- 11. «استعمال القدرات» (decision 55, 11.2; control G26, test D04)
-- ---------------------------------------------------------------------------------------------------------------
-- The catalogue of capabilities: the audited action behind each (one or several codes), its area, whether it is core
-- administration, and how completely the log sees it: 'full' (every path of the capability writes an audit row),
-- 'partial' (some paths do not, e.g. the guest's own actions on another channel), 'none' (a read-only screen; never
-- written). A capability the log cannot see is reported as «غير محسوم», never as unused (D04).
create or replace function fn_capability_catalog() returns table(code text, label text, area text, core boolean, coverage text, actions text[])
language sql immutable set search_path = public as $$
  values
    ('reservations.create', 'إنشاء حجز', 'الحجوزات', false, 'full', array['reservation.created']),
    ('reservations.cancel', 'إلغاء حجز وعدم حضور', 'الحجوزات', false, 'full', array['reservation.cancelled', 'reservation.no_show']),
    ('reservations.amend', 'تمديد وتبديل وتعديل الإجمالي', 'الحجوزات', false, 'full', array['reservation.departure_changed', 'reservation.room_switched', 'reservation.total_changed', 'reservation.service_added']),
    ('reservations.corrections', 'التصحيحات (التراجع عن الوصول والإلغاء وإعادة الفتح)', 'الحجوزات', false, 'full', array['reservation.check_in_undone', 'reservation.cancel_undone', 'reservation.stay_reopened', 'reservation.unclosed']),
    ('reservations.hold', 'الحظر على الحجز', 'الحجوزات', false, 'full', array['reservation.hold_set', 'reservation.hold_lifted']),
    ('reservations.platform_check', 'مطابقة المنصات', 'الحجوزات', false, 'full', array['reservation.platform_checked', 'reservation.platform_unchecked']),
    ('stay.check_in', 'تسجيل الوصول', 'الإقامة', false, 'full', array['reservation.checked_in', 'approve_checkin']),
    ('stay.shomoos', 'التسجيل في شموس', 'الإقامة', false, 'full', array['reservation.shomoos_registered', 'reservation.shomoos_accepted', 'confirm_gov_registration']),
    ('stay.payment_exception', 'مهلة السداد الاستثنائية', 'الإقامة', false, 'full', array['reservation.payment_exception']),
    ('stay.check_out', 'تسجيل المغادرة والإغلاق', 'الإقامة', false, 'full', array['reservation.checked_out', 'reservation.closed', 'checkout']),
    ('stay.inspection', 'فحص المغادرة ورسوم الضرر', 'الإقامة', false, 'full', array['reservation.inspected', 'reservation.damage_charged']),
    ('stay.summary', 'ملخص الإقامة وإقراره', 'الإقامة', false, 'partial', array['reservation.summary_signed', 'guest_summary_accepted']),
    ('guests.office_entry', 'إدخال بيانات الضيف من الوثيقة وتصحيحها', 'الضيوف', false, 'full', array['guest.entered_from_document', 'guest.corrected', 'approve_identity', 'reject_identity']),
    ('guests.self_entry', 'إدخال الضيف بياناته بنفسه', 'الضيوف', false, 'partial', array['guest_data_submitted']),
    ('guests.ban_rating', 'حظر الضيوف وتقييمهم', 'الضيوف', false, 'full', array['guest.banned', 'guest.unbanned', 'guest.rated']),
    ('money.receipts', 'سندات القبض والتأمين', 'المال', false, 'full', array['voucher.receipt_created', 'voucher.deposit_created', 'confirm_payment']),
    ('money.refunds', 'الاستردادات وتسوية التأمين', 'المال', false, 'full', array['voucher.refund_created', 'voucher.deposit_refund_created', 'voucher.deposit_apply_created']),
    ('money.corrections', 'إلغاء السندات وتصحيحها', 'المال', false, 'full', array['voucher.cancelled', 'voucher.corrected']),
    ('money.invoices', 'الفواتير', 'المال', false, 'full', array['invoice.issued', 'invoice.edited', 'invoice.cancelled']),
    ('money.pos_settlement', 'تسوية الشبكة', 'المال', false, 'full', array['pos.settled']),
    ('money.platform_payouts', 'إيداعات المنصات', 'المال', false, 'full', array['platform.payout_confirmed', 'platform.payout_cancelled']),
    ('money.review', 'قائمة المراجعة', 'المال', false, 'full', array['review.marked']),
    ('access.codes', 'تسليم رمز الدخول', 'الوصول', false, 'full', array['deliver_access_code', 'delivery_failed']),
    ('access.keybox', 'رموز صناديق المفاتيح', 'الوصول', false, 'full', array['rotate_keybox_code', 'keybox_field_tested', 'keybox.code_viewed']),
    ('housekeeping.tasks', 'المهام', 'خدمة الغرف', false, 'full', array['task.created', 'task.started', 'task.completed', 'task.cancelled', 'task.assigned', 'cleaning_completed']),
    ('housekeeping.cleanliness', 'تغيير النظافة يدويًا', 'خدمة الغرف', false, 'full', array['room.cleanliness_changed']),
    ('housekeeping.maintenance', 'بلاغات الصيانة', 'خدمة الغرف', false, 'full', array['maintenance_opened', 'maintenance_resolved']),
    ('admin.branches', 'الفروع وإعداداتها', 'الإدارة', true, 'full', array['branch.created', 'branch.updated', 'branch.money_defaults', 'branch.tax_changed', 'branch.logo_changed', 'branch.image_changed', 'branch.archived', 'branch.restored']),
    ('admin.structure', 'البلوكات والطوابق', 'الإدارة', true, 'full', array['block.created', 'block.updated', 'block.archived', 'block.restored', 'floor.created', 'floor.updated', 'floor.archived', 'floor.restored']),
    ('admin.rooms', 'الوحدات', 'الإدارة', true, 'full', array['room.created', 'room.updated', 'room.archived', 'room.restored']),
    ('admin.room_categories', 'أنواع الوحدات', 'الإدارة', true, 'full', array['room_category.created', 'room_category.updated', 'room_category.archived', 'room_category.restored']),
    ('admin.rates', 'الأسعار', 'الإدارة', true, 'full', array['rates.updated']),
    ('admin.facilities', 'المرافق', 'الإدارة', true, 'full', array['facility.created', 'facility.updated', 'facility.archived', 'facility.restored']),
    ('admin.task_types', 'أنواع المهام', 'الإدارة', true, 'full', array['task_type.created', 'task_type.updated', 'task_type.archived', 'task_type.restored']),
    ('admin.services', 'الخدمات', 'الإدارة', true, 'full', array['service.created', 'service.updated', 'service.archived', 'service.restored']),
    ('admin.cash_accounts', 'الصناديق والحسابات', 'الإدارة', true, 'full', array['cash_account.created', 'cash_account.updated', 'cash_account.archived', 'cash_account.restored']),
    ('admin.sources', 'مصادر الحجز', 'الإدارة', true, 'full', array['source.enabled', 'source.disabled']),
    ('admin.staff', 'الموظفون', 'الإدارة', true, 'full', array['staff_invited', 'staff.activated', 'staff.deactivated', 'staff.role_changed', 'staff.updated', 'staff.signed_out']),
    ('admin.knowledge', 'قاعدة المعرفة والأسئلة بلا إجابة', 'الإدارة', true, 'full', array['knowledge.created', 'knowledge.updated', 'knowledge.archived', 'knowledge.restored', 'unanswered.ignored', 'unanswered.open']),
    ('admin.ai', 'إعدادات الذكاء الاصطناعي', 'الإدارة', true, 'full', array['ai_settings_updated']),
    ('admin.whatsapp', 'واتساب الفروع', 'الإدارة', true, 'partial', array['whatsapp_channel_updated']),
    ('admin.purge', 'تفريغ البيانات', 'الإدارة', true, 'full', array['data_purge_executed']),
    ('assistant.ops', 'مساعد العمليات (تنفيذ اقتراح)', 'المساعد', false, 'full', array['ai_proposal.executed']),
    ('assistant.handover', 'استلام المحادثة من المساعد وإعادتها', 'المساعد', false, 'full', array['conversation_taken', 'conversation_returned_to_assistant']),
    ('assistant.reception', 'مساعد الاستقبال وواتساب', 'المساعد', false, 'none', array['guest_verified_lookup', 'guest_checkin_request', 'guest_viewed_code']),
    ('screens.reports', 'التقارير', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.audit', 'سجل الإجراءات', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.exports', 'التصدير والطباعة', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.calendar', 'لوحة الوحدات وتقويم الحجوزات', 'الشاشات', false, 'none', array[]::text[]),
    ('screens.usage', 'تقرير استعمال القدرات', 'الشاشات', false, 'none', array[]::text[]);
$$;

create or replace function fn_reports_capability_usage(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q jsonb := coalesce(p, '{}'::jsonb); org uuid := fn_user_org_id(); weeks int; win_start timestamptz; horizon timestamptz; purge_in_window boolean; now_ts timestamptz := now();
begin
  perform fn_require_role('owner');
  weeks := least(greatest(coalesce((q->>'weeks')::int, 4), 1), 26);
  win_start := now_ts - make_interval(weeks => weeks);
  select min(created_at) into horizon from audit_events where organization_id = org;
  -- a purge of the log inside the window breaks the measure for everything (the rows may have been there)
  purge_in_window := exists (select 1 from audit_events where organization_id = org and action = 'data_purge_executed' and created_at >= win_start
                               and (details->'categories') ? 'audit');
  return (with ev as (
    select e.action, e.created_at, e.result,
           case when e.actor_type = 'system' or e.source in ('system', 'scheduler') then 'automation'
                when e.source = 'ops_assistant' then 'assistant'
                when e.actor_type = 'guest' then 'guest' else 'human' end as who
    from audit_events e where e.organization_id = org and e.created_at >= win_start - interval '1 year'
  ), cat as (select * from fn_capability_catalog()),
  per as (
    select c.code, c.label, c.area, c.core, c.coverage,
           (select max(created_at) from ev where ev.action = any(c.actions) and ev.result = 'success') as last_success_at,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= now_ts - interval '7 days') as week_count,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start) as window_count,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'human') as by_human,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'assistant') as by_assistant,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'automation') as by_automation,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'success' and ev.created_at >= win_start and ev.who = 'guest') as by_guest,
           (select count(*) from ev where ev.action = any(c.actions) and ev.result = 'rejected' and ev.created_at >= win_start) as rejected
    from cat c)
  select jsonb_build_object(
    'weeks', weeks, 'window_start', win_start, 'generated_at', now_ts, 'log_since', horizon,
    'log_covers_window', horizon is not null and horizon <= win_start and not purge_in_window,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'code', code, 'label', label, 'area', area, 'core', core, 'coverage', coverage,
        'last_success_at', last_success_at, 'week_count', week_count, 'window_count', window_count,
        'by', jsonb_build_object('human', by_human, 'assistant', by_assistant, 'automation', by_automation, 'guest', by_guest), 'rejected', rejected,
        'status', case when coverage = 'none' then 'unmeasured'
                       when window_count > 0 then 'used'
                       when coverage = 'partial' or horizon is null or horizon > win_start or purge_in_window then 'undetermined'
                       else 'idle' end) order by area, core desc, label) from per), '[]'::jsonb),
    'other_actions', coalesce((select jsonb_agg(jsonb_build_object('action', action, 'label', fn_audit_action_label(action), 'window_count', n, 'last_at', last_at) order by n desc)
                               from (select action, count(*) n, max(created_at) last_at from ev where created_at >= win_start and result = 'success'
                                       and not exists (select 1 from cat where ev.action = any(cat.actions)) group by action) o), '[]'::jsonb),
    'note', 'القياس من سجل الإجراءات وحده. «غير محسوم»: قدرة لا يسجّل السجل كل مساراتها، أو نافذة لا يغطيها السجل. لا يُحذف شيء آليًا بقلة الاستعمال (القرار 53).'));
end $$;
grant execute on function fn_reports_capability_usage(jsonb) to authenticated;
