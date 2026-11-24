-- =====================================================================
-- Plan 4.13 «مصفوفة الأدوار المالية» (closes T3): what the supervisor, finance and housekeeping can actually do on
-- the money entry points matches the approved matrix, live, role by role. Probe style: every function is called
-- with deliberately invalid data; the capability check runs first, so an allowed role fails on the data (VALIDATION/
-- NOT_FOUND) while a denied role fails on FORBIDDEN. The matrix names المشرف والمالية وخدمة الغرف; the owner always
-- may. Uncodified descriptive names (no prefix registration yet; reported to the integrator).
-- Runs on the shared database (organisation, branch 010, staff of the earlier files).
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create or replace function t_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;
create or replace function t_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function t_fails(p_sql text, p_like text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlerrm like p_like then 'ok' else sqlerrm end;
end $$;
-- the verdict of one probe: 'forbidden', or the error the data caused (the capability let the role through)
create or replace function t_probe(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return case when sqlstate = '42501' or sqlerrm like 'FORBIDDEN%' then 'forbidden' else sqlerrm end;
end $$;

set role authenticated;

-- the probes, one per matrix operation a money role touches
create temp table probes(name text, stmt text);
insert into probes values
  ('voucher.receipt',   'select fn_create_voucher(jsonb_build_object(''reservation_id'', ''00000000-0000-0000-0000-000000000099'', ''kind'', ''receipt'', ''amount_halalas'', 100, ''method'', ''cash''))'),
  ('voucher.refund',    'select fn_refund(jsonb_build_object(''reservation_id'', ''00000000-0000-0000-0000-000000000099'', ''kind'', ''refund'', ''amount_halalas'', 100, ''reason'', ''x'', ''idempotency_key'', ''probe-rf''))'),
  ('deposit.refund',    'select fn_refund(jsonb_build_object(''reservation_id'', ''00000000-0000-0000-0000-000000000099'', ''kind'', ''deposit_refund'', ''amount_halalas'', 100, ''reason'', ''x'', ''idempotency_key'', ''probe-dr''))'),
  ('deposit.apply',     'select fn_refund(jsonb_build_object(''reservation_id'', ''00000000-0000-0000-0000-000000000099'', ''kind'', ''deposit_apply'', ''amount_halalas'', 100, ''reason'', ''x'', ''idempotency_key'', ''probe-da''))'),
  ('voucher.cancel',    'select fn_cancel_voucher(''00000000-0000-0000-0000-000000000099'', ''سبب'')'),
  ('invoice.issue',     'select fn_staff_issue_invoice(jsonb_build_object(''reservation_id'', ''00000000-0000-0000-0000-000000000099''))'),
  ('invoice.edit',      'select fn_staff_edit_invoice(jsonb_build_object(''invoice_id'', ''00000000-0000-0000-0000-000000000099'', ''reason'', ''x''))'),
  ('invoice.cancel',    'select fn_cancel_invoice(''00000000-0000-0000-0000-000000000099'', ''سبب'')'),
  ('invoice.credit_note', 'select fn_issue_credit_note(''00000000-0000-0000-0000-000000000099'', ''سبب'')'),
  ('expense.create',    'select fn_expense_create(jsonb_build_object(''branch_id'', ''00000000-0000-0000-0000-000000000010''))'),
  ('expense.cancel',    'select fn_expense_cancel(''00000000-0000-0000-0000-000000000099'', ''سبب'')'),
  ('checkin (arrival)', 'select fn_staff_check_in(jsonb_build_object(''reservation_id'', ''00000000-0000-0000-0000-000000000099''))');

-- the approved matrix as the plan records it (المشرف يملك القبض والمصروف والوصول)
create temp table expected(role text, probe text, allowed boolean);
insert into expected values
  ('supervisor',   'voucher.receipt',    true),
  ('supervisor',   'voucher.refund',     false),
  ('supervisor',   'deposit.refund',     true),
  ('supervisor',   'deposit.apply',      true),
  ('supervisor',   'voucher.cancel',     false),
  ('supervisor',   'invoice.issue',      true),
  ('supervisor',   'invoice.edit',       true),
  ('supervisor',   'invoice.cancel',     false),
  ('supervisor',   'invoice.credit_note', false),
  ('supervisor',   'expense.create',     true),
  ('supervisor',   'expense.cancel',     false),
  ('supervisor',   'checkin (arrival)',  true),
  ('finance',      'voucher.receipt',    true),
  ('finance',      'voucher.refund',     true),
  ('finance',      'deposit.refund',     true),
  ('finance',      'deposit.apply',      true),
  ('finance',      'voucher.cancel',     false),
  ('finance',      'invoice.issue',      true),
  ('finance',      'invoice.edit',       true),
  ('finance',      'invoice.cancel',     false),
  ('finance',      'invoice.credit_note', false),
  ('finance',      'expense.create',     true),
  ('finance',      'expense.cancel',     false),
  ('finance',      'checkin (arrival)',  false),
  ('housekeeping', 'voucher.receipt',    false),
  ('housekeeping', 'voucher.refund',     false),
  ('housekeeping', 'deposit.refund',     false),
  ('housekeeping', 'deposit.apply',      false),
  ('housekeeping', 'voucher.cancel',     false),
  ('housekeeping', 'invoice.issue',      false),
  ('housekeeping', 'invoice.edit',       false),
  ('housekeeping', 'invoice.cancel',     false),
  ('housekeeping', 'invoice.credit_note', false),
  ('housekeeping', 'expense.create',     false),
  ('housekeeping', 'expense.cancel',     false),
  ('housekeeping', 'checkin (arrival)',  false),
  ('owner',        'voucher.receipt',    true),
  ('owner',        'voucher.refund',     true),
  ('owner',        'deposit.refund',     true),
  ('owner',        'deposit.apply',      true),
  ('owner',        'voucher.cancel',     true),
  ('owner',        'invoice.issue',      true),
  ('owner',        'invoice.edit',       true),
  ('owner',        'invoice.cancel',     true),
  ('owner',        'invoice.credit_note', true),
  ('owner',        'expense.create',     true),
  ('owner',        'expense.cancel',     true),
  ('owner',        'checkin (arrival)',  true);

create temp table probe_results(role text, probe text, verdict text);

select t_login('a0000000-0000-0000-0000-000000000002', 'sup@test.local');
insert into probe_results select 'supervisor', name, t_probe(stmt) from probes;
select t_login('a0000000-0000-0000-0000-000000000004', 'fin@test.local');
insert into probe_results select 'finance', name, t_probe(stmt) from probes;
select t_login('a0000000-0000-0000-0000-000000000003', 'hk@test.local');
insert into probe_results select 'housekeeping', name, t_probe(stmt) from probes;
select t_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
insert into probe_results select 'owner', name, t_probe(stmt) from probes;

do $$
declare rec record; bad int := 0; got boolean; begin
  for rec in select * from expected order by role, probe loop
    select verdict <> 'forbidden' into got from probe_results where role = rec.role and probe = rec.probe;
    if got is distinct from rec.allowed then
      bad := bad + 1;
      perform t_record('4.13 ' || rec.role || ' / ' || rec.probe, false,
        'expected ' || rec.allowed::text || ', got ' || coalesce((select verdict from probe_results where role = rec.role and probe = rec.probe), 'no row'));
    end if;
  end loop;
  perform t_record('4.13 مصفوفة الأدوار المالية تطابق المعتمدة (48 تحققًا: أربعة أدوار × اثنتي عشرة عملية)', bad = 0, bad || ' mismatches');
end $$;
reset role;

-- the detail, for the record
select * from probe_results order by role, probe;
select (case when ok then 'PASS' else 'FAIL' end) as result, name, detail from test_results order by ctid;
do $$ begin if exists (select 1 from test_results where not ok) then raise exception 'FINANCE ROLE MATRIX TESTS FAILED'; end if; end $$;
