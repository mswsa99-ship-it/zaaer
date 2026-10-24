-- =====================================================================
-- Synthetic history for the migration check (decision 41, X10). Applied on the schema as it is in production
-- (supabase/production-applied.txt), before the pending migrations run. Everything is invented: no real guest,
-- unit or price. It covers the records a migration must never lose or change: reservations in several states,
-- vouchers of every kind and method (one cancelled), refunds, an invoice, a discount line, a completed
-- cleaning task, an archived service, and a stay that already ended.
-- =====================================================================
\set ON_ERROR_STOP on
insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
 ('20000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','مالك السجل','hist-owner@test.local','owner'),
 ('20000000-0000-0000-0000-000000000002','b0000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','مشرف السجل','hist-sup@test.local','supervisor')
on conflict (id) do nothing;
insert into branch_memberships(staff_id, branch_id) values ('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000010') on conflict do nothing;
create table if not exists _hist_ids(k text primary key, v uuid);

select set_config('request.jwt.claim.sub', 'b0000000-0000-0000-0000-000000000001', false);
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","email":"hist-owner@test.local"}', false);
grant all on _hist_ids to authenticated;
set role authenticated;
do $$
declare r jsonb; v jsonb; svc jsonb; t jsonb; rid uuid; room uuid; tt uuid;
  b constant uuid := '00000000-0000-0000-0000-000000000010';
  cat constant uuid := '00000000-0000-0000-0000-000000000030';
  src constant uuid := '00000000-0000-0000-0000-000000000021';
begin
  -- a future stay with a discount line
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (current_date + 30)::text,
         'check_out', (current_date + 33)::text, 'guest_name', 'ضيف سجل أول', 'source_id', src));
  rid := (r->>'id')::uuid; insert into _hist_ids values ('r1', rid);
  perform fn_staff_adjust_price(rid, 'discount', 1000, 'خصم سجل', 'اختبار', (select version from reservations where id = rid));

  -- money of every kind and method, one voucher cancelled, an invoice
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (current_date + 5)::text,
         'check_out', (current_date + 7)::text, 'guest_name', 'ضيف سجل ثان', 'source_id', src));
  rid := (r->>'id')::uuid; insert into _hist_ids values ('r2', rid);
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 30000, 'method', 'cash', 'idempotency_key', 'hist-r2-rcp'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'deposit', 'amount_halalas', 5000, 'method', 'mada', 'reference', 'POS-1', 'idempotency_key', 'hist-r2-dep'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 1500, 'method', 'bank_transfer', 'reference', 'TR-1', 'idempotency_key', 'hist-r2-rcp2'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 1200, 'method', 'ota_deferred', 'reference', 'OTA-1', 'idempotency_key', 'hist-r2-rcp4'));
  perform fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 900, 'method', 'pos', 'reference', 'POS-2', 'idempotency_key', 'hist-r2-rcp5'));
  v := fn_create_voucher(jsonb_build_object('reservation_id', rid, 'kind', 'receipt', 'amount_halalas', 700, 'method', 'card', 'reference', 'CARD-1', 'idempotency_key', 'hist-r2-rcp3'));
  perform fn_cancel_voucher((v->>'voucher_id')::uuid, 'خطأ إدخال');
  perform fn_refund(jsonb_build_object('reservation_id', rid, 'kind', 'refund', 'amount_halalas', 1000, 'method', 'cash', 'reason', 'رد جزئي', 'idempotency_key', 'hist-r2-ref'));
  perform fn_refund(jsonb_build_object('reservation_id', rid, 'kind', 'deposit_refund', 'amount_halalas', 2000, 'method', 'cash', 'reason', 'رد تأمين جزئي', 'idempotency_key', 'hist-r2-depref'));
  perform fn_create_invoice(rid, null, null);

  -- a cancelled stay
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (current_date + 10)::text,
         'check_out', (current_date + 12)::text, 'guest_name', 'ضيف سجل ثالث', 'source_id', src));
  rid := (r->>'id')::uuid; insert into _hist_ids values ('r3', rid);
  perform fn_staff_cancel_reservation(rid, 'إلغاء الضيف');

  -- a stay that will be written as already ended (below, as history)
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', (current_date + 50)::text,
         'check_out', (current_date + 52)::text, 'guest_name', 'ضيف سجل رابع', 'source_id', src));
  insert into _hist_ids values ('r4', (r->>'id')::uuid);

  -- a completed cleaning task, an archived service
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', 'HIST-1'));
  room := (r->>'id')::uuid;
  select id into tt from task_types where branch_id = b and code = 'room_cleaning';
  t := fn_hk_create_task(jsonb_build_object('room_id', room, 'task_type_id', tt));
  perform fn_hk_complete_task((t->>'id')::uuid, 'تم', (select version from housekeeping_tasks where id = (t->>'id')::uuid));
  svc := fn_admin_upsert_service(jsonb_build_object('branch_id', b, 'name_ar', 'غسيل سجل', 'price_halalas', 2500));
  perform fn_admin_archive_definition('service', (svc->>'id')::uuid, 'لم تعد مقدمة');
end $$;
reset role;

-- The ended stay is history: written directly, as a migration would find it.
update reservations set status = 'checked_out', check_in = current_date - 5, check_out = current_date - 2,
       actual_check_in = now() - interval '5 days', actual_check_out = now() - interval '2 days'
 where id = (select v from _hist_ids where k = 'r4');
