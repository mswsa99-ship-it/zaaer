-- Transactional synthetic fixtures. Run after core fixtures, before purge tests.
\set ON_ERROR_STOP on
begin;
create temp table fcs_results(name text,ok boolean);
grant all on fcs_results to public;
create temp table fcs_ids(k text,v uuid);
grant all on fcs_ids to public;
create or replace function fcs_compute(b uuid,d date) returns jsonb language sql security definer as $$select fn_day_closing_compute(b,d)$$;
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
set local role authenticated;
do $$ declare b uuid; c uuid; a uuid; e jsonb; p jsonb; other_before jsonb; begin
 other_before:=fn_finance_controls_get();
 insert into fcs_results values('default effective limits preserve current behavior',
 (other_before->'effective_expense_limits'->>'supervisor')::bigint=500000
 and (other_before->'effective_expense_limits'->>'finance')::bigint=2000000);
 e:=fn_admin_upsert_branch('{"name_ar":"فرع اختبار إعدادات المال","name_en":"Finance settings test"}'); b:=(e->>'id')::uuid;
 insert into fcs_ids values('branch',b);
 e:=fn_admin_upsert_expense_category('{"name":"فئة اختبار إعدادات المال"}'); c:=(e->>'id')::uuid;
 select id into a from cash_accounts where branch_id=b and kind='cash_box' and archived_at is null;
 perform fn_admin_set_account_opening(a,1000000,fn_branch_today(b),'اختبار محلي');
 insert into fcs_ids values('account',a),('category',c);
 perform fn_finance_controls_set('{"expense_role_limits":{"supervisor":1500,"finance":2500,"housekeeping":3500},"anomaly_expense_threshold_halalas":1000,"discount_review_threshold_bp":2000}');
 insert into fcs_results values('setter returns actual operational fields',
 (fn_finance_controls_get()->'effective_expense_limits'->>'supervisor')::bigint=1500
 and (fn_finance_controls_get()->>'discount_review_threshold_bp')::int=2000);
end $$;
reset role;
insert into branch_memberships(staff_id,branch_id) select s,v from fcs_ids cross join unnest(array['10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000004']::uuid[]) s where k='branch';
insert into fcs_results select 'other hotel is unchanged', expense_role_limits='{}'::jsonb from finance_control_settings where organization_id='00000000-0000-0000-0000-000000000002';
insert into fcs_results select 'security audit records operational before and after',exists(select 1 from audit_events where action='security.finance_execution_thresholds_updated' and category='security' and organization_id='00000000-0000-0000-0000-000000000001' and details->'after'->'expense_role_limits'->>'supervisor'='1500');
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000002',true);
set local role authenticated;
do $$ declare p jsonb; e jsonb; rejected boolean:=false; begin
 begin perform fn_finance_controls_set('{"expense_role_limits":{"supervisor":999999}}'); exception when insufficient_privilege then rejected:=true; end;
 insert into fcs_results values('supervisor cannot change threshold',rejected);
 p:=jsonb_build_object('branch_id',(select v from fcs_ids where k='branch'),'account_id',(select v from fcs_ids where k='account'),'category_id',(select v from fcs_ids where k='category'), 'description','اختبار تطبيق العتبة','attachments',jsonb_build_array(jsonb_build_object('data_base64','JVBERi0xLjQK')));
 e:=fn_expense_create(p||'{"amount_halalas":1500}');
 insert into fcs_results values('at threshold approved',e->>'status'='approved');
 e:=fn_expense_create(p||'{"amount_halalas":1501}');
 insert into fcs_ids values('pending',(e->>'id')::uuid);
 insert into fcs_results values('above changed threshold pending',e->>'status'='pending');
 rejected:=false;
 begin perform fn_expense_approve((e->>'id')::uuid); exception when insufficient_privilege then rejected:=true; end;
 insert into fcs_results values('supervisor cannot approve pending',rejected);
 insert into fcs_results select 'RLS only own hotel',count(*)=1 from finance_control_settings;
end $$;
reset role;
insert into fcs_results select 'pending expense not in account movements',not exists(select 1 from fn_account_movements((select v from fcs_ids where k='account')) where ref_id=(select v from fcs_ids where k='pending'));
insert into fcs_results select 'anomaly follows saved threshold',exists(select 1 from review_items where kind='expense_over_threshold' and entity_id in(select id from expense_vouchers where branch_id=(select v from fcs_ids where k='branch')));
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
set local role authenticated;
select fn_finance_controls_set('{"expense_role_limits":{"supervisor":2000}}');
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000002',true);
do $$ declare e jsonb; begin
 e:=fn_expense_create(jsonb_build_object('branch_id',(select v from fcs_ids where k='branch'),'account_id',(select v from fcs_ids where k='account'),'category_id',(select v from fcs_ids where k='category'),'amount_halalas',1501,'description','بعد تغيير العتبة','attachments',jsonb_build_array(jsonb_build_object('data_base64','JVBERi0xLjQK'))));
 insert into fcs_results values('next operation uses new limit',e->>'status'='approved');
end $$;
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
select fn_expense_approve((select v from fcs_ids where k='pending'));
do $$ declare n int; bad boolean:=false; begin
 begin perform fn_finance_controls_set('{"expense_role_limits":{"manager":1}}'); exception when others then bad:=sqlerrm like 'VALIDATION%'; end;
 insert into fcs_results values('unsupported role refused',bad);
 bad:=false;
 begin perform fn_finance_controls_set('{"organization_id":"00000000-0000-0000-0000-000000000002"}'); exception when others then bad:=sqlerrm like 'VALIDATION%'; end;
 insert into fcs_results values('hotel selector injection refused',bad);
end $$;
do $$ declare before_row jsonb; bad boolean:=false; begin
 before_row:=fn_finance_controls_get();
 begin perform fn_finance_controls_set('{"expense_role_limits":{"supervisor":1234},"discount_review_threshold_bp":10001}');
 exception when others then bad:=sqlerrm like 'VALIDATION%'; end;
 insert into fcs_results values('invalid mixed update rolls back every field',bad and fn_finance_controls_get()=before_row);
end $$;
-- Finance role uses its own configured threshold, not the supervisor limit.
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000004',true);
do $$ declare e jsonb; p jsonb; begin
 p:=jsonb_build_object('branch_id',(select v from fcs_ids where k='branch'),'account_id',(select v from fcs_ids where k='account'),'category_id',(select v from fcs_ids where k='category'),'description','اختبار حد المالية','attachments',jsonb_build_array(jsonb_build_object('data_base64','JVBERi0xLjQK')));
 e:=fn_expense_create(p||'{"amount_halalas":2500}');
 insert into fcs_results values('finance at own threshold approved',e->>'status'='approved');
 e:=fn_expense_create(p||'{"amount_halalas":2501}');
 insert into fcs_results values('finance above own threshold pending',e->>'status'='pending');
end $$;
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000005',true);
do $$ declare d jsonb; begin
 d:=fn_finance_controls_get();
 insert into fcs_results values('second hotel sees inherited operational limits',
 (d->'effective_expense_limits'->>'supervisor')::bigint=500000
 and d->>'operational_refund_threshold_halalas' is null);
end $$;
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
-- Opt-in refund enforcement: change setting, refuse operation, approve, execute once.
do $$ declare cat uuid; r uuid; e jsonb; payload jsonb; refused boolean:=false; n int; b uuid:=(select v from fcs_ids where k='branch'); begin
 perform fn_finance_controls_set('{"operational_refund_threshold_halalas":1000,"operational_closing_diff_alert_halalas":100}');
 e:=fn_admin_upsert_room_category(jsonb_build_object('branch_id',b,'name_ar','غرفة اختبار اعتماد الاسترداد','base_price_halalas',10000)); cat:=(e->>'id')::uuid;
 perform fn_admin_upsert_room(jsonb_build_object('branch_id',b,'category_id',cat,'room_number','FCS-01'));
 e:=fn_staff_create_reservation(jsonb_build_object('branch_id',b,'category_id',cat,'check_in',fn_branch_today(b)+200,'check_out',fn_branch_today(b)+202,'guest_phone','0557654321','guest_name','ضيف اعتماد الاسترداد','source_id','00000000-0000-0000-0000-000000000021')); r:=(e->>'id')::uuid;
 perform fn_create_voucher(jsonb_build_object('reservation_id',r,'kind','receipt','amount_halalas',10000,'method','cash','received_confirmed',true,'idempotency_key','fcs-receipt'));
 e:=fn_refund(jsonb_build_object('reservation_id',r,'kind','refund','amount_halalas',1000,'method','cash','reason','عند العتبة','idempotency_key','fcs-at-threshold'));
 insert into fcs_results values('refund at threshold needs no prior approval',coalesce((e->>'ok')::boolean,false));
 payload:=jsonb_build_object('reservation_id',r,'kind','refund','amount_halalas',1001,'method','cash','reason','اختبار العتبة','idempotency_key','fcs-refund');
 begin perform fn_refund(payload); exception when others then refused:=sqlerrm like 'REFUND_APPROVAL_REQUIRED%'; end;
 insert into fcs_results values('refund above saved threshold refused without approval',refused);
 perform fn_finance_approve_refund(jsonb_build_object('reservation_id',r,'amount_halalas',1001,'reason','اعتماد تجريبي'));
 e:=fn_refund(payload);
 insert into fcs_results values('approved refund executes',coalesce((e->>'ok')::boolean,false));
 select count(*) into n from finance_refund_approvals where reservation_id=r and used_at is not null;
 insert into fcs_results values('refund consumes approval once',n=1);
 refused:=false;
 -- The discount gate reads the setting saved through the unified API, not a parallel unused value.
 begin perform fn_staff_adjust_price(r,'discount',5000,'خصم اختبار','طلب تجريبي', (select version from reservations where id=r));
 exception when others then refused:=sqlerrm like 'DISCOUNT_APPROVAL_REQUIRED%'; end;
 insert into fcs_results values('discount gate uses unified saved threshold',refused);

 refused:=false;
 begin perform fn_refund(payload||'{"idempotency_key":"fcs-refund-again"}'); exception when others then refused:=sqlerrm like 'REFUND_APPROVAL_REQUIRED%'; end;
 insert into fcs_results values('consumed refund approval cannot be reused',refused);
end $$;
-- Closing alert follows the configured threshold. Counts remain blind until review.
do $$ declare b uuid:=(select v from fcs_ids where k='branch'); live jsonb; lines jsonb; e jsonb; rv jsonb; c uuid; begin
 live:=fcs_compute(b,fn_branch_today(b));
 select jsonb_agg(jsonb_build_object('key',x->>'key','entered_halalas',(x->>'system_halalas')::bigint+case when x->>'key'='cash' then 101 else 0 end,'reason','فرق اختبار')) into lines from jsonb_array_elements(live->'boxes') x;
 e:=fn_day_closing_save(jsonb_build_object('branch_id',b,'business_date',fn_branch_today(b),'lines',lines)); c:=(e->>'id')::uuid;
 rv:=fn_day_closing_review(c);
 perform fn_day_closing_submit(c,(rv->>'version')::int,rv->>'hash');
 insert into fcs_results select 'closing difference above saved threshold alerts',exists(select 1 from review_items where kind='closing_difference_over_threshold' and entity_id=c);
end $$;
do $$ declare b uuid:=(select v from fcs_ids where k='branch'); live jsonb; lines jsonb; e jsonb; rv jsonb; c uuid; begin
 live:=fcs_compute(b,fn_branch_today(b)-1);
 select jsonb_agg(jsonb_build_object('key',x->>'key','entered_halalas',(x->>'system_halalas')::bigint+case when x->>'key'='cash' then 100 else 0 end,'reason','فرق عند العتبة')) into lines from jsonb_array_elements(live->'boxes') x;
 e:=fn_day_closing_save(jsonb_build_object('branch_id',b,'business_date',fn_branch_today(b)-1,'lines',lines)); c:=(e->>'id')::uuid;
 rv:=fn_day_closing_review(c);
 perform fn_day_closing_submit(c,(rv->>'version')::int,rv->>'hash');
 insert into fcs_results select 'closing difference at threshold does not alert',not exists(select 1 from review_items where kind='closing_difference_over_threshold' and entity_id=c);
end $$;
reset role;
select case when ok then 'PASS' else 'FAIL' end as result,name from fcs_results;
do $$ begin if exists(select 1 from fcs_results where ok is not true) or (select count(*) from fcs_results)<>26 then raise exception 'FINANCE EXECUTION SETTINGS FAILED'; end if; end $$;
rollback;
