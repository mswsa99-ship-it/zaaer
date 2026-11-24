-- =====================================================================
-- 0085 (proposed number; the integrator renumbers) — plan 4.12 «إعدادات الضبط لكل فندق» (decision ق2).
--
--  The acceptance: one page with the approval table and the thresholds, per role; a hotel's threshold never touches
--  another hotel; every threshold change is recorded in the security log («أمني»). This migration is the server half:
--  one settings row per hotel (keyed by organization_id, seeded for existing hotels and for every new hotel through
--  fn_hotel_settings_seed), a read for the hotel's staff, and an owner-only setter that validates, writes the row and
--  files the change under a «security.*» action — the audit trigger files those in the security category only the
--  owner reads. Enforcement of each threshold (4.2, 4.3, 4.6, 4.7, 4.8) reads these values in its own item's work.
-- =====================================================================

create table if not exists finance_control_settings (
  organization_id uuid primary key references organizations(id) on delete cascade,
  -- مصروف فوق حد الدور: the expense amount above which the role needs prior approval (plan 4.3 enforces it)
  expense_limit_supervisor_halalas bigint not null default 5000000,
  expense_limit_finance_halalas bigint not null default 5000000,
  -- خصم فوق العتبة (plan 4.8) and استرداد فوق العتبة: prior approval above these
  discount_threshold_halalas bigint not null default 5000000,
  refund_threshold_halalas bigint not null default 10000000,
  -- فرق في إقفال اليوم: an immediate alert to the owner above this difference (plan 4.4/4.6)
  closing_diff_alert_halalas bigint not null default 100000,
  updated_at timestamptz not null default now(),
  updated_by uuid references staff_profiles(id),
  constraint fcs_expense_limit_supervisor_pos check (expense_limit_supervisor_halalas > 0),
  constraint fcs_expense_limit_finance_pos check (expense_limit_finance_halalas > 0),
  constraint fcs_discount_threshold_pos check (discount_threshold_halalas > 0),
  constraint fcs_refund_threshold_pos check (refund_threshold_halalas > 0),
  constraint fcs_closing_diff_alert_pos check (closing_diff_alert_halalas > 0)
);
alter table finance_control_settings enable row level security;
revoke all on finance_control_settings from anon, authenticated;
grant select on finance_control_settings to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'finance_control_settings' and policyname = 'staff_reads_own_hotel_controls') then
    create policy "staff_reads_own_hotel_controls" on finance_control_settings for select to authenticated
      using ((organization_id = (select fn_user_org_id())) and (organization_id = fn_user_org_id()));
  end if;
end $$;

-- 0078's pointer guard: the editor named on the row is of the row's hotel
create trigger zz_hotel_pointers after insert or update of updated_by, organization_id on public.finance_control_settings
  for each row execute function fn_hotel_pointers('updated_by', 'staff_profiles');

-- the hotel's own row (never another hotel's): the function answers for the caller's hotel only
create or replace function fn_finance_controls_get() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s finance_control_settings%rowtype;
begin
  if fn_user_org_id() is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into finance_control_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  select * into s from finance_control_settings where organization_id = fn_user_org_id();
  return jsonb_build_object('organization_id', s.organization_id,
    'expense_limit_supervisor_halalas', s.expense_limit_supervisor_halalas,
    'expense_limit_finance_halalas', s.expense_limit_finance_halalas,
    'discount_threshold_halalas', s.discount_threshold_halalas,
    'refund_threshold_halalas', s.refund_threshold_halalas,
    'closing_diff_alert_halalas', s.closing_diff_alert_halalas,
    'updated_at', s.updated_at);
end $$;
revoke all on function fn_finance_controls_get() from public, anon;
grant execute on function fn_finance_controls_get() to authenticated;

-- the owner sets the thresholds of their own hotel; every change lands in the security log with before and after
create or replace function fn_finance_controls_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s finance_control_settings%rowtype; before_row finance_control_settings%rowtype; k text; v bigint;
        keys text[] := array['expense_limit_supervisor_halalas', 'expense_limit_finance_halalas', 'discount_threshold_halalas',
                             'refund_threshold_halalas', 'closing_diff_alert_halalas'];
begin
  perform fn_require_role('owner');
  perform fn_user_org_id();
  insert into finance_control_settings(organization_id) values (fn_user_org_id()) on conflict do nothing;
  select * into before_row from finance_control_settings where organization_id = fn_user_org_id() for update;
  s := before_row;
  for k in select e.key from jsonb_each(p) e loop
    if not (k = any(keys)) then raise exception 'VALIDATION: unknown_key'; end if;
    if coalesce(p->>k, '') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: %', k; end if;
    v := (p->>k)::bigint;
    if v <= 0 then raise exception 'VALIDATION: %', k; end if;
    if k = 'expense_limit_supervisor_halalas' then s.expense_limit_supervisor_halalas := v;
    elsif k = 'expense_limit_finance_halalas' then s.expense_limit_finance_halalas := v;
    elsif k = 'discount_threshold_halalas' then s.discount_threshold_halalas := v;
    elsif k = 'refund_threshold_halalas' then s.refund_threshold_halalas := v;
    else s.closing_diff_alert_halalas := v; end if;
  end loop;
  update finance_control_settings set
    expense_limit_supervisor_halalas = s.expense_limit_supervisor_halalas,
    expense_limit_finance_halalas = s.expense_limit_finance_halalas,
    discount_threshold_halalas = s.discount_threshold_halalas,
    refund_threshold_halalas = s.refund_threshold_halalas,
    closing_diff_alert_halalas = s.closing_diff_alert_halalas,
    updated_at = now(), updated_by = fn_staff_id()
  where organization_id = fn_user_org_id();
  perform fn_audit_change(null, 'security.control_thresholds_updated', 'finance_control_settings', fn_user_org_id(),
    jsonb_build_object('expense_limit_supervisor_halalas', before_row.expense_limit_supervisor_halalas,
                       'expense_limit_finance_halalas', before_row.expense_limit_finance_halalas,
                       'discount_threshold_halalas', before_row.discount_threshold_halalas,
                       'refund_threshold_halalas', before_row.refund_threshold_halalas,
                       'closing_diff_alert_halalas', before_row.closing_diff_alert_halalas),
    jsonb_build_object('expense_limit_supervisor_halalas', s.expense_limit_supervisor_halalas,
                       'expense_limit_finance_halalas', s.expense_limit_finance_halalas,
                       'discount_threshold_halalas', s.discount_threshold_halalas,
                       'refund_threshold_halalas', s.refund_threshold_halalas,
                       'closing_diff_alert_halalas', s.closing_diff_alert_halalas));
  return fn_finance_controls_get();
end $$;
revoke all on function fn_finance_controls_set(jsonb) from public, anon;
grant execute on function fn_finance_controls_set(jsonb) to authenticated;

-- defaults for every hotel that already exists, and for every hotel created from now on (0079's seed gains a line)
insert into finance_control_settings(organization_id) select id from organizations on conflict do nothing;

create or replace function public.fn_hotel_settings_seed(p_org uuid) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  if not exists(select 1 from organizations where id=p_org) then raise exception 'HOTEL_NOT_FOUND'; end if;
  perform pg_advisory_xact_lock(hashtext('hotel_settings_seed:' || p_org::text));
  insert into ai_settings(organization_id) values(p_org) on conflict do nothing;
  insert into system_settings(organization_id) values(p_org) on conflict do nothing;
  insert into finance_control_settings(organization_id) values(p_org) on conflict do nothing;
  perform fn_alert_rules_seed(p_org);
  perform fn_gl_seed(p_org);
  insert into bank_parse_rules(organization_id,keyword,kind,direction,priority)
  select p_org,r.k,r.kind,r.dir,r.p from (values ('استرداد', 'other_in', 'in', 5), ('رسوم نقاط البيع', 'pos_fee', 'out', 10), ('عمولة نقاط البيع', 'pos_fee', 'out', 11), ('POS fee', 'pos_fee', 'out', 12),
                   ('تسوية نقاط البيع', 'pos_settlement', 'in', 20), ('مبيعات نقاط البيع', 'pos_settlement', 'in', 21), ('تسوية مدى', 'pos_settlement', 'in', 22), ('POS settlement', 'pos_settlement', 'in', 23),
                   ('حوالة واردة', 'transfer_in', 'in', 30), ('تحويل وارد', 'transfer_in', 'in', 31), ('Incoming transfer', 'transfer_in', 'in', 32), ('واردة', 'transfer_in', 'in', 35),
                   ('حوالة صادرة', 'transfer_out', 'out', 40), ('تحويل صادر', 'transfer_out', 'out', 41), ('Outgoing transfer', 'transfer_out', 'out', 42), ('صادرة', 'transfer_out', 'out', 45),
                   ('إيداع', 'deposit', 'in', 50), ('ايداع', 'deposit', 'in', 51), ('Deposit', 'deposit', 'in', 52),
                   ('سحب', 'withdrawal', 'out', 60), ('Withdrawal', 'withdrawal', 'out', 61),
                   ('رسوم', 'fee', 'out', 70), ('Fees', 'fee', 'out', 71),
                   ('شراء', 'purchase', 'out', 80), ('Purchase', 'purchase', 'out', 81)) r(k, kind, dir, p)
  where not exists(select 1 from bank_parse_rules x where x.organization_id=p_org)
  on conflict do nothing;
end $$;
revoke all on function public.fn_hotel_settings_seed(uuid) from public,anon,authenticated;
