-- =====================================================================
-- External review fixes (migration 0009) — RF01–RF16
-- A03 payment idempotency · A04 invoice periods · A06 strict versions · A09 two organizations
-- money column gate · A05 ledger-based report reconciliation
-- Runs after security/core tests on the same DB (reuses their fixtures: org 1 + org 2).
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
create or replace function t_ver(p_table text, p_id uuid) returns int language plpgsql security definer as $$ declare v int; begin execute format('select version from %I where id = $1', p_table) into v using p_id; return v; end $$;
create or replace function t_vouchers(p_res uuid, p_kind text) returns int language sql security definer as $$ select count(*)::int from financial_vouchers where reservation_id = p_res and kind = p_kind and status = 'approved' $$;
create or replace function t_paid(p_res uuid) returns bigint language sql security definer as $$ select paid_halalas from reservations where id = p_res $$;
create or replace function t_memberships(p_staff uuid) returns int language sql security definer as $$ select count(*)::int from branch_memberships where staff_id = p_staff $$;
create or replace function t_charge(p_id uuid) returns reservation_charges language sql security definer as $$ select * from reservation_charges where id = p_id $$;

create temp table rf(k text primary key, v uuid);
grant all on rf to public;

select t_login('a0000000-0000-0000-0000-000000000001','owner@test.local');
set role authenticated;

-- fixture: a 3-night stay without a room
do $$ declare r jsonb; begin
  r := fn_staff_create_reservation('{"branch_id":"00000000-0000-0000-0000-000000000010","category_id":"00000000-0000-0000-0000-000000000030","check_in":"2032-01-10","check_out":"2032-01-13","guest_name":"مراجعة","guest_phone":"0500002222","source_id":"00000000-0000-0000-0000-000000000021"}'::jsonb);
  insert into rf values ('res', (r->>'id')::uuid);
end $$;

-- ---------- A03 ----------
do $$ declare res uuid := (select v from rf where k='res'); a jsonb; b jsonb; begin
  a := fn_staff_confirm_payment(res, 'pos', 10000, 'MADA-1', 'rf-key-1');
  b := fn_staff_confirm_payment(res, 'pos', 10000, 'MADA-1', 'rf-key-1');
  perform t_record('RF01 A03 replay with same key+content → duplicate built from the stored voucher; one voucher only',
    (b->>'duplicate')::boolean and (b->>'amount_halalas')::bigint = 10000 and t_vouchers(res, 'receipt') = 1, b::text);
  begin
    perform fn_staff_confirm_payment(res, 'pos', 99999, 'MADA-1', 'rf-key-1');
    perform t_record('RF02 A03 same key with a different amount → IDEMPOTENCY_CONFLICT', false, 'accepted');
  exception when others then perform t_record('RF02 A03 same key with a different amount → IDEMPOTENCY_CONFLICT', sqlerrm like 'IDEMPOTENCY_CONFLICT%', sqlerrm); end;
  begin
    perform fn_staff_confirm_payment(res, 'bank_transfer', 10000, 'MADA-1', 'rf-key-1');
    perform t_record('RF03 A03 same key with a different method → IDEMPOTENCY_CONFLICT', false, 'accepted');
  exception when others then perform t_record('RF03 A03 same key with a different method → IDEMPOTENCY_CONFLICT', sqlerrm like 'IDEMPOTENCY_CONFLICT%', sqlerrm); end;
  begin
    perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', 5000, 'method', 'cash', 'idempotency_key', 'rf-key-1'));
    perform t_record('RF04 A03 the voucher path cannot reuse a key taken by the payment path with other content', false, 'accepted');
  exception when others then perform t_record('RF04 A03 the voucher path cannot reuse a key taken by the payment path with other content', sqlerrm like 'IDEMPOTENCY_CONFLICT%', sqlerrm); end;
  perform t_record('RF04b A03 after all replays: exactly one receipt, paid = 100 SAR', t_vouchers(res, 'receipt') = 1 and t_paid(res) = 10000, 'paid=' || t_paid(res));
end $$;

-- ---------- A06 ----------
do $$ declare res uuid := (select v from rf where k='res'); begin
  begin
    perform fn_staff_amend_stay(res, '2032-01-14', 'keep_rate', 'تمديد');
    perform t_record('RF05 A06 amend_stay without expected version → VERSION_REQUIRED', false);
  exception when others then perform t_record('RF05 A06 amend_stay without expected version → VERSION_REQUIRED', sqlerrm like 'VERSION_REQUIRED%', sqlerrm); end;
  begin
    perform fn_staff_amend_stay(res, '2032-01-14', 'keep_rate', 'تمديد', t_ver('reservations', res) - 1);
    perform t_record('RF06 A06 amend_stay with a stale version → VERSION_CONFLICT', false);
  exception when others then perform t_record('RF06 A06 amend_stay with a stale version → VERSION_CONFLICT', sqlerrm like 'VERSION_CONFLICT%', sqlerrm); end;
  begin
    perform fn_staff_adjust_price(res, 'penalty', 1000, 'غرامة', 'سبب');
    perform t_record('RF07 A06 adjust_price without expected version → VERSION_REQUIRED', false);
  exception when others then perform t_record('RF07 A06 adjust_price without expected version → VERSION_REQUIRED', sqlerrm like 'VERSION_REQUIRED%', sqlerrm); end;
  begin
    perform fn_admin_upsert_room_category(jsonb_build_object('id', '00000000-0000-0000-0000-000000000030', 'name_ar', 'تعديل بلا نسخة'));
    perform t_record('RF08 A06 definition update without version → VERSION_REQUIRED', false);
  exception when others then perform t_record('RF08 A06 definition update without version → VERSION_REQUIRED', sqlerrm like 'VERSION_REQUIRED%', sqlerrm); end;
end $$;

-- ---------- A04 ----------
do $$ declare res uuid := (select v from rf where k='res'); r jsonb; inv jsonb; inv2 jsonb; begin
  -- extend by 2 nights: the new rent line carries exactly the extension period
  r := fn_staff_amend_stay(res, '2032-01-15', 'keep_rate', 'تمديد ليلتين', t_ver('reservations', res));
  perform t_record('RF09 A04 an extension rent line covers only the added nights',
    exists (select 1 from reservation_charges c where c.reservation_id = res and c.kind = 'rent' and c.service_from = '2032-01-13' and c.service_to = '2032-01-15'), r::text);
  -- invoice the original stay only
  inv := fn_create_invoice(res, '2032-01-10', '2032-01-13');
  perform t_record('RF10 A04 a period invoice includes only charges inside the period; snapshot keeps charge ids',
    (inv->>'period_from') = '2032-01-10' and (inv->>'period_to') = '2032-01-13'
    and not exists (select 1 from reservation_charges c where c.reservation_id = res and c.service_from >= '2032-01-13' and c.invoice_id is not null)
    and jsonb_array_length((select snapshot->'charge_ids' from invoices where id = (inv->>'id')::uuid)) = (inv->>'charge_count')::int, inv::text);
  inv2 := fn_create_invoice(res);
  perform t_record('RF11 A04 an invoice without a period takes the rest and derives its period from the charges',
    (inv2->>'period_from') = '2032-01-13' and (inv2->>'period_to') = '2032-01-15'
    and not exists (select 1 from reservation_charges c where c.reservation_id = res and c.invoice_id is null), inv2::text);
  begin
    perform fn_create_invoice(res);
    perform t_record('RF11b A04 nothing left → NOTHING_TO_INVOICE (no empty invoice)', false);
  exception when others then perform t_record('RF11b A04 nothing left → NOTHING_TO_INVOICE (no empty invoice)', sqlerrm like 'NOTHING_TO_INVOICE%', sqlerrm); end;
end $$;

-- ---------- A05 reconciliation ----------
do $$ declare res uuid := (select v from rf where k='res'); rep jsonb; led jsonb; begin
  perform fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'deposit', 'amount_halalas', 30000, 'method', 'cash', 'idempotency_key', 'rf-dep'));
  perform fn_refund(jsonb_build_object('reservation_id', res, 'kind', 'refund', 'amount_halalas', 2500, 'method', 'cash', 'reason', 'تعويض', 'idempotency_key', 'rf-ref'));
  rep := fn_reports_finance('00000000-0000-0000-0000-000000000010', fn_branch_today('00000000-0000-0000-0000-000000000010') - 1, fn_branch_today('00000000-0000-0000-0000-000000000010'));
  led := rep->'ledger';
  perform t_record('RF12 A05 report ledger reconciles: net = receipts − refunds + deposit_apply, read straight from vouchers',
    (led->>'net_collected')::bigint = (led->>'receipts')::bigint - (led->>'refunds')::bigint + (led->>'deposits_applied')::bigint
    and (led->>'receipts')::bigint = (select coalesce(sum(amount_halalas),0) from financial_vouchers v where v.branch_id = '00000000-0000-0000-0000-000000000010' and v.kind = 'receipt' and v.status = 'approved' and v.occurred_at::date between current_date - 2 and current_date + 1),
    led::text);
  perform t_record('RF13 A05 deposits are reported separately and never counted as revenue',
    (led->>'deposits_received')::bigint >= 30000 and (led->>'net_collected')::bigint < (led->>'receipts')::bigint + (led->>'deposits_received')::bigint and rep ? 'definitions', left(rep::text, 200));
end $$;
reset role;

-- report gates: housekeeping refused; another org's branch refused
select t_login('a0000000-0000-0000-0000-000000000003','hk@test.local');
set role authenticated;
do $$ begin
  begin perform fn_reports_finance('00000000-0000-0000-0000-000000000010'); perform t_record('RF14 A05 housekeeping cannot read the finance report', false);
  exception when others then perform t_record('RF14 A05 housekeeping cannot read the finance report', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;

-- ---------- money column gate ----------
do $$ declare n int; begin
  begin
    select count(total_halalas) into n from reservations;
    perform t_record('RF15 gate: housekeeping cannot select money columns from reservations', false, 'read ' || n);
  exception when insufficient_privilege then perform t_record('RF15 gate: housekeeping cannot select money columns from reservations', true); end;
  select count(status) into n from reservations;
  perform t_record('RF15b gate: non-money columns stay readable (status)', n >= 0);
end $$;
reset role;
-- every column of public.reservations is readable by staff except the money ones: a column a migration adds is granted
-- in every environment (0035 — a lookup by table name alone made 0033 skip its grant on the hosted project)
do $$ declare unreadable text; begin
  select string_agg(a.attname, ', ' order by a.attname) into unreadable
  from pg_attribute a
  where a.attrelid = 'public.reservations'::regclass and a.attnum > 0 and not a.attisdropped
    and not has_column_privilege('authenticated', 'public.reservations', a.attname, 'SELECT')
    and a.attname not in ('addons_halalas', 'balance_due_halalas', 'deposit_balance_halalas', 'discount_halalas', 'nightly_rate_halalas',
                          'paid_halalas', 'price_basis', 'prices_include_tax', 'refunded_halalas', 'rent_amount_halalas', 'tax_rate_bp',
                          'taxes_halalas', 'total_halalas');
  perform t_record('RF15c gate: every non-money reservations column is readable by staff (0011, 0033, 0035)', unreadable is null, unreadable);
  select string_agg(a.attname, ', ' order by a.attname) into unreadable
  from pg_attribute a
  where a.attrelid = 'public.reservations'::regclass and a.attname in ('total_halalas', 'paid_halalas', 'balance_due_halalas', 'deposit_balance_halalas')
    and has_column_privilege('authenticated', 'public.reservations', a.attname, 'SELECT');
  perform t_record('RF15d gate: the money columns stay unreadable through the table', unreadable is null, unreadable);
end $$;

-- ---------- A09: two organizations ----------
select t_login('a0000000-0000-0000-0000-000000000005','owner2@test.local');
set role authenticated;
do $$ declare n int; begin
  begin
    insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000011');
    perform t_record('RF16 A09 owner of org 2 cannot add org 1 staff to a branch', false, 'inserted');
  exception when others then perform t_record('RF16 A09 owner of org 2 cannot add org 1 staff to a branch', true, sqlerrm); end;
  begin
    insert into branch_memberships(staff_id, branch_id) values ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000010');
    perform t_record('RF16b A09 owner of org 2 cannot attach itself to an org 1 branch', false, 'inserted');
  exception when others then perform t_record('RF16b A09 owner of org 2 cannot attach itself to an org 1 branch', true, sqlerrm); end;
  delete from branch_memberships where staff_id = '10000000-0000-0000-0000-000000000002';
  get diagnostics n = row_count;
  perform t_record('RF16c A09 owner of org 2 cannot delete org 1 memberships', n = 0, 'deleted ' || n);
  select count(*) into n from reservations where organization_id = '00000000-0000-0000-0000-000000000001';
  perform t_record('RF16d org 2 sees no org 1 reservations', n = 0, 'saw ' || n);
  select count(*) into n from financial_vouchers where organization_id = '00000000-0000-0000-0000-000000000001';
  perform t_record('RF16e org 2 sees no org 1 vouchers', n = 0, 'saw ' || n);
  begin perform fn_reports_finance('00000000-0000-0000-0000-000000000010'); perform t_record('RF16f org 2 cannot run reports on an org 1 branch', false);
  exception when others then perform t_record('RF16f org 2 cannot run reports on an org 1 branch', sqlerrm like 'FORBIDDEN%', sqlerrm); end;
end $$;
reset role;
select t_record('RF16g org 1 memberships intact after the cross-org attempts', t_memberships('10000000-0000-0000-0000-000000000002') >= 1);

reset role;
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail,''),110) as detail from test_results order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where ok is not true) as failed from test_results;
\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from test_results where ok is not true) then raise exception 'REVIEW TESTS FAILED'; end if;
end $$;
