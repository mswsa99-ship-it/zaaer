-- =====================================================================
-- 0030 — rates (Phase 2): decisions 9, 15, 32, 33 and the rounding rule of 47.
--   1. Unit types gain a weekly price, a monthly price, a minimum nightly price and a price mode («موحد» or
--      «مختلف للمنصات»). Branches gain the supervisor's discount ceiling: 0 until the owner or a manager sets it.
--   2. rate_calendar: a price per unit type per night, and a platform price when the type is priced by channel.
--      A night without a price takes the type's base price. Past nights are read-only, no price goes under the
--      type's minimum, only the owner or a manager edits, and every edit is audited with what it replaced.
--   3. reservation_nights: the price of every night of a stay, fixed when the night is booked. The rent lines are
--      written from it; extending adds nights; shortening marks the removed nights and refunds exactly their
--      prices. Existing stays are given their nights from their rent lines.
--   4. A stay of 30+ nights takes the monthly price and 7+ nights the weekly price, spread evenly over its nights
--      with the remainder on the last night; otherwise each night takes the calendar (or base) price.
--   5. Discounts: the supervisor gives one with a reason, before arrival, within the branch's percentage and never
--      under the type's minimum nightly price; beyond that, or after arrival, it is the owner's or a manager's.
--      A report lists who gave which discount, how much and why (the supervisor gets its summary only).
--   6. Lowering a type's capacity lists the upcoming stays that would no longer fit.
-- Nights are never erased: a removed night keeps its row, marked removed, with who removed it and why.
-- =====================================================================
select set_config('app.source', 'migration', true);

-- ---------------------------------------------------------------- 1. price fields
alter table room_categories add column if not exists weekly_price_halalas bigint;
alter table room_categories add column if not exists monthly_price_halalas bigint;
alter table room_categories add column if not exists min_nightly_halalas bigint;
alter table room_categories add column if not exists price_mode text not null default 'unified';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'room_categories_price_fields_chk') then
    alter table room_categories add constraint room_categories_price_fields_chk check (
      (weekly_price_halalas is null or weekly_price_halalas > 0) and (monthly_price_halalas is null or monthly_price_halalas > 0)
      and (min_nightly_halalas is null or min_nightly_halalas > 0) and price_mode in ('unified', 'by_channel'));
  end if;
end $$;

alter table branches add column if not exists supervisor_max_discount_bp int not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'branches_supervisor_discount_chk') then
    alter table branches add constraint branches_supervisor_discount_chk check (supervisor_max_discount_bp between 0 and 10000);
  end if;
end $$;

-- how a stay was priced when it was made: daily (calendar or base), weekly, monthly, or a manual nightly price
alter table reservations add column if not exists price_basis text not null default 'daily';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_price_basis_chk') then
    alter table reservations add constraint reservations_price_basis_chk check (price_basis in ('daily', 'weekly', 'monthly', 'manual'));
  end if;
end $$;

-- ---------------------------------------------------------------- 2. the price calendar (decision 33)
create table if not exists rate_calendar (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  category_id uuid not null references room_categories(id),
  night date not null,
  price_halalas bigint check (price_halalas is null or price_halalas > 0),
  platform_price_halalas bigint check (platform_price_halalas is null or platform_price_halalas > 0),
  updated_by uuid references staff_profiles(id),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (category_id, night)
);
create index if not exists idx_rate_calendar_branch_night on rate_calendar(branch_id, night);
alter table rate_calendar enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'rate_calendar' and policyname = 'rates_read') then
    create policy "rates_read" on rate_calendar for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner', 'manager'));
  end if;
end $$;
revoke insert, update on rate_calendar from anon, authenticated;

-- ---------------------------------------------------------------- 3. the price of each night of a stay
create table if not exists reservation_nights (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  branch_id uuid not null references branches(id),
  reservation_id uuid not null,   -- its foreign key, with what a purge needs, is added by 0031 (pasted with 0022)
  night date not null,
  price_halalas bigint not null check (price_halalas >= 0),
  basis text not null check (basis in ('base', 'calendar', 'platform', 'weekly', 'monthly', 'manual', 'kept', 'legacy')),
  status text not null default 'active' check (status in ('active', 'removed')),
  removed_at timestamptz,
  removed_by uuid references staff_profiles(id),
  removed_reason text,
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now()
);
create unique index if not exists uq_reservation_nights_active on reservation_nights(reservation_id, night) where status = 'active';
create index if not exists idx_reservation_nights_reservation on reservation_nights(reservation_id);
alter table reservation_nights enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'reservation_nights' and policyname = 'nights_read') then
    create policy "nights_read" on reservation_nights for select to authenticated
      using (branch_id in (select fn_user_branch_ids()) and fn_has_role('owner', 'manager', 'supervisor', 'finance'));
  end if;
end $$;
revoke insert, update on reservation_nights from anon, authenticated;

-- a stay without nights (made before 0030, or written straight into the table) gets them from its rent lines:
-- each night takes the unit price of the rent line that covers it, else the stay's nightly rate
create or replace function fn_ensure_nights(p_reservation uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  select * into r from reservations where id = p_reservation;
  if not found or exists (select 1 from reservation_nights where reservation_id = r.id) then return; end if;
  insert into reservation_nights(organization_id, branch_id, reservation_id, night, price_halalas, basis, created_at)
  select r.organization_id, r.branch_id, r.id, g::date,
         coalesce((select c.unit_price_halalas from reservation_charges c
                   where c.reservation_id = r.id and c.kind = 'rent' and c.service_from <= g::date and g::date < c.service_to
                     and c.quantity = (c.service_to - c.service_from)
                   order by c.created_at desc limit 1), r.nightly_rate_halalas, 0),
         'legacy', r.created_at
  from generate_series(r.check_in, r.check_out - 1, interval '1 day') g;
end $$;
revoke all on function fn_ensure_nights(uuid) from public, anon, authenticated;

do $$ declare x record; begin
  for x in select id from reservations loop perform fn_ensure_nights(x.id); end loop;
end $$;

-- ---------------------------------------------------------------- 4. pricing a stay (decisions 15, 33, 47)
-- the price of each night: a manual price when given; 30+ nights → the monthly price and 7+ nights → the weekly
-- price (when the type has one and periods apply), spread evenly with the remainder on the last night; otherwise
-- the calendar's price for the night (its platform row for a platform booking of a type priced by channel), else
-- the type's base price
create or replace function fn_stay_prices(p_category uuid, p_check_in date, p_check_out date, p_platform boolean default false,
                                          p_override bigint default null, p_periods boolean default true)
returns table(night date, price_halalas bigint, basis text)
language plpgsql stable security definer set search_path = public as $$
declare c room_categories%rowtype; n int; v_period int; v_price bigint; v_basis text; total bigint; each_night bigint; i int := 0; d date;
begin
  select * into c from room_categories where id = p_category;
  if not found then raise exception 'BRANCH_MISMATCH: category'; end if;
  n := p_check_out - p_check_in;
  if n is null or n <= 0 then raise exception 'VALIDATION: dates'; end if;
  if p_override is not null then
    if p_override < 0 then raise exception 'VALIDATION: amount'; end if;
    return query select g::date, p_override, 'manual'::text from generate_series(p_check_in, p_check_out - 1, interval '1 day') g;
    return;
  end if;
  if p_periods and n >= 30 and c.monthly_price_halalas is not null then v_period := 30; v_price := c.monthly_price_halalas; v_basis := 'monthly';
  elsif p_periods and n >= 7 and c.weekly_price_halalas is not null then v_period := 7; v_price := c.weekly_price_halalas; v_basis := 'weekly';
  end if;
  if v_period is not null then
    total := round(v_price::numeric * n / v_period);
    each_night := total / n;
    for d in select g::date from generate_series(p_check_in, p_check_out - 1, interval '1 day') g loop
      i := i + 1;
      night := d; basis := v_basis;
      price_halalas := case when i = n then total - each_night * (n - 1) else each_night end;
      return next;
    end loop;
    return;
  end if;
  return query
    select g::date,
           coalesce(case when p_platform and c.price_mode = 'by_channel' then rc.platform_price_halalas end, rc.price_halalas, c.base_price_halalas),
           case when p_platform and c.price_mode = 'by_channel' and rc.platform_price_halalas is not null then 'platform'
                when rc.price_halalas is not null then 'calendar' else 'base' end
    from generate_series(p_check_in, p_check_out - 1, interval '1 day') g
    left join rate_calendar rc on rc.category_id = c.id and rc.night = g::date
    order by 1;
end $$;
revoke all on function fn_stay_prices(uuid, date, date, boolean, bigint, boolean) from public, anon, authenticated;

-- the same nights grouped into runs of one price: [{from, to, nights, price, basis}] (to is exclusive)
create or replace function fn_stay_runs(p_category uuid, p_check_in date, p_check_out date, p_platform boolean default false,
                                        p_override bigint default null, p_periods boolean default true)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare x record; runs jsonb := '[]'::jsonb; cur jsonb;
begin
  for x in select * from fn_stay_prices(p_category, p_check_in, p_check_out, p_platform, p_override, p_periods) s order by s.night loop
    if cur is not null and (cur->>'price')::bigint = x.price_halalas and cur->>'basis' = x.basis and (cur->>'to')::date = x.night then
      cur := cur || jsonb_build_object('to', x.night + 1, 'nights', (cur->>'nights')::int + 1);
    else
      if cur is not null then runs := runs || jsonb_build_array(cur); end if;
      cur := jsonb_build_object('from', x.night, 'to', x.night + 1, 'nights', 1, 'price', x.price_halalas, 'basis', x.basis);
    end if;
  end loop;
  if cur is not null then runs := runs || jsonb_build_array(cur); end if;
  return runs;
end $$;
revoke all on function fn_stay_runs(uuid, date, date, boolean, bigint, boolean) from public, anon, authenticated;

-- books the nights of the runs on a stay and writes one rent line per run (tax per line, decision 47)
create or replace function fn_book_nights(p_reservation uuid, p_runs jsonb, p_label text, p_reason text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; x jsonb; total bigint := 0; txt text;
begin
  select * into r from reservations where id = p_reservation;
  for x in select * from jsonb_array_elements(p_runs) loop
    insert into reservation_nights(organization_id, branch_id, reservation_id, night, price_halalas, basis, created_by)
    select r.organization_id, r.branch_id, r.id, g::date, (x->>'price')::bigint, x->>'basis', fn_staff_id()
    from generate_series((x->>'from')::date, (x->>'to')::date - 1, interval '1 day') g;
    txt := p_label || ' ' || (x->>'nights') || ' ليلة × ' || to_char((x->>'price')::bigint / 100.0, 'FM9999999990.00') || ' ر.س'
           || case x->>'basis' when 'weekly' then ' (السعر الأسبوعي)' when 'monthly' then ' (السعر الشهري)' when 'platform' then ' (سعر المنصات)' else '' end;
    perform fn_add_charge(r.id, 'rent', txt, (x->>'nights')::numeric, (x->>'price')::bigint, true, p_reason, null, (x->>'from')::date, (x->>'to')::date);
    total := total + (x->>'nights')::bigint * (x->>'price')::bigint;
  end loop;
  return total;
end $$;
revoke all on function fn_book_nights(uuid, jsonb, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 5. discounts (decision 9)
-- may the caller give this discount on this stay? (existing = the stay's discounts so far, rent = its rent)
create or replace function fn_check_discount(p_category uuid, p_branch uuid, p_nights int, p_rent bigint, p_existing bigint, p_new bigint, p_after_arrival boolean)
returns void language plpgsql stable security definer set search_path = public as $$
declare bp int; mn bigint;
begin
  if coalesce(p_new, 0) <= 0 then return; end if;
  if coalesce(p_existing, 0) + p_new > p_rent then raise exception 'VALIDATION: discount_exceeds_rent'; end if;
  if fn_has_role('owner', 'manager') then return; end if;
  if not fn_has_role('supervisor') then raise exception 'FORBIDDEN: discount'; end if;
  if p_after_arrival then raise exception 'FORBIDDEN: post-arrival discount'; end if;
  select supervisor_max_discount_bp into bp from branches where id = p_branch;
  if coalesce(p_existing, 0) + p_new > floor(p_rent::numeric * coalesce(bp, 0) / 10000) then raise exception 'VALIDATION: discount_percent'; end if;
  select min_nightly_halalas into mn from room_categories where id = p_category;
  if mn is not null and p_rent - coalesce(p_existing, 0) - p_new < mn * p_nights then raise exception 'VALIDATION: discount_minimum'; end if;
end $$;
revoke all on function fn_check_discount(uuid, uuid, int, bigint, bigint, bigint, boolean) from public, anon, authenticated;

-- the quote of a stay: its nights, rent, discount, tax and total exactly as the reservation would store them, and
-- how much discount the caller may give (decision 9: «نافذة الخصم تعرض المسموح»)
create or replace function fn_quote_stay(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date;
        c room_categories%rowtype; b branches%rowtype; src booking_sources%rowtype; platform boolean := false;
        ovr bigint := nullif(p->>'nightly_rate_halalas', '')::bigint; disc bigint := coalesce(nullif(p->>'discount_halalas', '')::bigint, 0);
        runs jsonb; x jsonb; n int; rent_gross bigint := 0; rent_net bigint := 0; tax bigint := 0; net bigint; t bigint; disc_net bigint := 0; disc_tax bigint := 0;
        computed bigint; min_total bigint; sup_max bigint; my_max bigint;
begin
  perform fn_require_branch(v_branch);
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if co - ci > 366 then raise exception 'VALIDATION: dates'; end if;
  select * into c from room_categories where id = v_cat and branch_id = v_branch;
  if not found then raise exception 'BRANCH_MISMATCH: category'; end if;
  select * into b from branches where id = v_branch;
  if nullif(p->>'source_id', '') is not null then
    select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id();
    platform := found and src.kind <> 'direct';
  end if;
  if disc < 0 then raise exception 'VALIDATION: amount'; end if;
  n := co - ci;
  runs := fn_stay_runs(v_cat, ci, co, platform, ovr, true);
  for x in select * from jsonb_array_elements(runs) loop
    rent_gross := rent_gross + (x->>'nights')::bigint * (x->>'price')::bigint;
    select * into net, t from fn_apply_tax(v_branch, (x->>'nights')::bigint * (x->>'price')::bigint, true);
    rent_net := rent_net + net; tax := tax + t;
  end loop;
  if disc > rent_gross then raise exception 'VALIDATION: discount_exceeds_rent'; end if;
  if disc > 0 then select * into disc_net, disc_tax from fn_apply_tax(v_branch, -disc, true); end if;
  computed := (select coalesce(sum(s.price_halalas), 0) from fn_stay_prices(v_cat, ci, co, platform, null, true) s);
  min_total := c.min_nightly_halalas * n;
  sup_max := greatest(0, least(floor(rent_gross::numeric * b.supervisor_max_discount_bp / 10000)::bigint, rent_gross - coalesce(min_total, 0)));
  my_max := case when fn_has_role('owner', 'manager') then rent_gross when fn_has_role('supervisor') then sup_max else 0 end;
  return jsonb_build_object('nights', n, 'runs', runs, 'channel', case when platform then 'platform' else 'system' end,
    'basis', case when ovr is not null then 'manual' when n >= 30 and c.monthly_price_halalas is not null then 'monthly'
                  when n >= 7 and c.weekly_price_halalas is not null then 'weekly' else 'daily' end,
    'nightly_rate', round(rent_gross::numeric / n)::bigint, 'rent_gross', rent_gross, 'computed_rent', computed,
    'rent', rent_net, 'discount', disc_net, 'tax', tax + disc_tax, 'total', rent_net + disc_net + tax + disc_tax,
    'tax_rate_bp', b.tax_rate_bp, 'prices_include_tax', b.prices_include_tax,
    'min_nightly', c.min_nightly_halalas, 'discount_max', my_max, 'supervisor_discount_max', sup_max,
    'supervisor_max_discount_bp', b.supervisor_max_discount_bp);
end $$;
grant execute on function fn_quote_stay(jsonb) to authenticated;

-- the old entry point keeps its signature (the assistant and older screens) and answers from the same quote
create or replace function fn_staff_quote(p_branch uuid, p_category uuid, p_check_in date, p_check_out date, p_nightly_override bigint default null, p_discount_halalas bigint default 0)
returns jsonb language sql stable security definer set search_path = public as $$
  select fn_quote_stay(jsonb_build_object('branch_id', p_branch, 'category_id', p_category, 'check_in', p_check_in, 'check_out', p_check_out,
                                          'nightly_rate_halalas', p_nightly_override, 'discount_halalas', coalesce(p_discount_halalas, 0)));
$$;
grant execute on function fn_staff_quote(uuid, uuid, date, date, bigint, bigint) to authenticated;

-- what the caller may still give as discount on an existing stay
create or replace function fn_discount_allowance(p_reservation uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reservations%rowtype; rent bigint; n int; disc bigint; bp int; mn bigint; mx bigint; after_arrival boolean;
begin
  perform fn_require_role('owner', 'manager', 'supervisor');
  select * into r from reservations where id = p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  select coalesce(sum(price_halalas), 0), count(*) into rent, n from reservation_nights where reservation_id = r.id and status = 'active';
  if n = 0 then rent := r.rent_amount_halalas; n := r.check_out - r.check_in; end if;
  disc := coalesce((select sum(round(abs(quantity * unit_price_halalas)))::bigint from reservation_charges where reservation_id = r.id and kind = 'discount'), 0);
  after_arrival := r.status in ('checked_in', 'checked_out');
  select supervisor_max_discount_bp into bp from branches where id = r.branch_id;
  select min_nightly_halalas into mn from room_categories where id = r.room_category_id;
  if fn_has_role('owner', 'manager') then mx := greatest(0, rent - disc);
  elsif after_arrival or r.status not in ('confirmed', 'pending_verification') then mx := 0;
  else mx := greatest(0, least(floor(rent::numeric * bp / 10000)::bigint - disc, rent - disc - coalesce(mn * n, 0)));
  end if;
  return jsonb_build_object('rent', rent, 'discounts', disc, 'nights', n, 'after_arrival', after_arrival, 'max', mx,
                            'percent_bp', bp, 'min_nightly', mn, 'unlimited', fn_has_role('owner', 'manager'));
end $$;
grant execute on function fn_discount_allowance(uuid) to authenticated;

-- the nights of a stay with their prices (removed ones too, with who removed them and why)
create or replace function fn_reservation_nights(p_reservation uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when fn_has_role('owner', 'manager', 'supervisor', 'finance')
               and exists (select 1 from reservations r where r.id = p_reservation and r.branch_id in (select fn_user_branch_ids()))
         then coalesce((select jsonb_agg(jsonb_build_object('night', n.night, 'price', n.price_halalas, 'basis', n.basis, 'status', n.status,
                                                            'removed_at', n.removed_at, 'removed_reason', n.removed_reason) order by n.night, n.created_at)
                        from reservation_nights n where n.reservation_id = p_reservation), '[]'::jsonb) end;
$$;
grant execute on function fn_reservation_nights(uuid) to authenticated;

-- ---------------------------------------------------------------- 6. creating a stay prices it night by night
create or replace function fn_staff_create_reservation_unit(p jsonb, p_group_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_cat uuid := (p->>'category_id')::uuid; v_room uuid := (p->>'room_id')::uuid;
        ci date := (p->>'check_in')::date; co date := (p->>'check_out')::date; src booking_sources%rowtype; q jsonb; r reservations%rowtype; b branches%rowtype;
        gp guest_profiles%rowtype; v_phone text := nullif(trim(p->>'guest_phone'),''); v_name text := trim(p->>'guest_name'); v_status reservation_status; ext text := nullif(trim(p->>'external_ref'),'');
        v_adults int := coalesce((p->>'adults')::int, 1); v_comp int := coalesce((p->>'companions')::int, 0); cap int;
        v_details jsonb := coalesce(p->'companions_details', '[]'::jsonb); d jsonb; v_arr time; v_dep time;
        v_disc bigint := coalesce(nullif(p->>'discount_halalas', '')::bigint, 0); v_ovr bigint := nullif(p->>'nightly_rate_halalas', '')::bigint;
begin
  perform fn_require_role('owner','manager','supervisor');
  perform fn_require_branch(v_branch);
  select * into b from branches where id = v_branch;
  if ci is null or co is null or co <= ci then raise exception 'VALIDATION: dates'; end if;
  if coalesce(v_name,'') = '' then raise exception 'VALIDATION: guest_name'; end if;
  if jsonb_typeof(v_details) <> 'array' then raise exception 'VALIDATION: companions_details'; end if;
  -- companions: the detailed list wins over a bare count (never fewer rows than people declared)
  if jsonb_array_length(v_details) > v_comp then v_comp := jsonb_array_length(v_details); end if;
  if v_adults < 1 or v_comp < 0 then raise exception 'VALIDATION: guests'; end if;
  for d in select * from jsonb_array_elements(v_details) loop
    if coalesce(trim(d->>'full_name'),'') = '' then raise exception 'VALIDATION: companion_name'; end if;
  end loop;
  begin
    v_arr := coalesce(nullif(p->>'arrival_time','')::time, b.check_in_time);
    v_dep := coalesce(nullif(p->>'departure_time','')::time, b.check_out_time);
  exception when others then raise exception 'VALIDATION: times'; end;
  select * into src from booking_sources where id = (p->>'source_id')::uuid and organization_id = fn_user_org_id() and is_active;
  if not found then raise exception 'VALIDATION: source'; end if;
  if src.external_reference_required and ext is null then raise exception 'VALIDATION: external_ref_required'; end if;
  select max_capacity into cap from room_categories where id = v_cat and branch_id = v_branch and archived_at is null;
  if cap is null then raise exception 'BRANCH_MISMATCH: category'; end if;
  if v_adults + v_comp > cap then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- the stay's nights from the calendar (or the weekly / monthly price), the platform row for a platform booking
  q := fn_quote_stay(jsonb_build_object('branch_id', v_branch, 'category_id', v_cat, 'check_in', ci, 'check_out', co, 'source_id', src.id,
                                        'nightly_rate_halalas', v_ovr, 'discount_halalas', v_disc));
  -- a manual nightly price under what the stay would cost is a discount by another name: the owner's or a manager's
  if v_ovr is not null and (q->>'rent_gross')::bigint < (q->>'computed_rent')::bigint and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: rate below the quoted price requires manager';
  end if;
  if v_disc > 0 and coalesce(trim(p->>'discount_reason'), '') = '' then raise exception 'VALIDATION: discount_reason'; end if;
  perform fn_check_discount(v_cat, v_branch, (q->>'nights')::int, (q->>'rent_gross')::bigint, 0, v_disc, false);
  v_status := case when coalesce((p->>'confirm')::boolean, true) then 'confirmed' else 'pending_verification' end;

  -- guest profile: reuse by phone within org, never merge by name only
  if v_phone is not null then select * into gp from guest_profiles where organization_id = fn_user_org_id() and phone = v_phone limit 1; end if;
  if gp.id is null then
    insert into guest_profiles(organization_id, full_name, phone, nationality) values (fn_user_org_id(), v_name, v_phone, p->>'nationality') returning * into gp;
  end if;

  insert into reservations(organization_id, branch_id, external_ref, source_id, status, booking_type, company_name, visit_purpose, check_in, check_out, adults, companions,
                           room_category_id, nightly_rate_halalas, price_basis, notes, created_by, identity_status, payment_status, expected_arrival_time, expected_departure_time, group_ref)
  values (fn_user_org_id(), v_branch, ext, src.id, v_status, coalesce(p->>'booking_type','individual'), p->>'company_name', p->>'visit_purpose', ci, co, v_adults, v_comp,
          v_cat, (q->>'nightly_rate')::bigint, q->>'basis', p->>'notes', fn_staff_id(), 'not_started', 'pending', v_arr, v_dep, p_group_ref) returning * into r;

  insert into reservation_guests(reservation_id, guest_profile_id, is_primary, full_name, phone, nationality) values (r.id, gp.id, true, v_name, v_phone, p->>'nationality');
  -- companions: identity stays 'not_started' until the document is matched at arrival (G-identity)
  for d in select * from jsonb_array_elements(v_details) loop
    insert into reservation_guests(reservation_id, is_primary, full_name, relationship, nationality, phone)
    values (r.id, false, trim(d->>'full_name'), nullif(trim(d->>'relationship'),''), nullif(trim(d->>'nationality'),''), nullif(trim(d->>'phone'),''));
  end loop;

  perform fn_book_nights(r.id, q->'runs', 'إيجار');
  if v_disc > 0 then
    perform fn_add_charge(r.id, 'discount', trim(p->>'discount_reason'), 1, v_disc, true, trim(p->>'discount_reason'));
  end if;
  if v_room is not null then
    if not fn_room_available(v_room, ci, co) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
    perform fn_allocate(r.id, v_room, ci, co, 'create');
  end if;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.created', 'reservation', r.id, null,
    jsonb_build_object('internal_ref', r.internal_ref, 'source', src.code, 'external_ref', ext, 'check_in', ci, 'check_out', co, 'room_id', v_room, 'quote', q,
                       'arrival_time', v_arr, 'departure_time', v_dep, 'companions', v_comp, 'group_ref', p_group_ref));
  return jsonb_build_object('ok', true, 'id', r.id, 'internal_ref', r.internal_ref, 'quote', q, 'group_ref', p_group_ref);
exception when unique_violation then
  raise exception 'DUPLICATE_EXTERNAL_REF';
end $$;
revoke all on function fn_staff_create_reservation_unit(jsonb, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 7. extending and shortening by the nights' own prices
create or replace function fn_staff_amend_stay(p_reservation uuid, p_new_check_out date, p_pricing_mode text, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; a reservation_allocations%rowtype; delta int; before jsonb; runs jsonb; platform boolean; last_price bigint; refund bigint;
begin
  perform fn_require_role('owner','manager','supervisor');
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_pricing_mode not in ('keep_rate','reprice') then raise exception 'VALIDATION: pricing_mode'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status not in ('confirmed','checked_in','pending_verification') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_new_check_out <= r.check_in then raise exception 'VALIDATION: dates'; end if;
  if r.status = 'checked_in' and p_new_check_out <= fn_branch_today(r.branch_id) and p_new_check_out < r.check_out then raise exception 'VALIDATION: checkout_in_past'; end if;
  delta := p_new_check_out - r.check_out;
  if delta = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  -- leaving a weekly or monthly stay early is settled by the owner or a manager (decision 15)
  if delta < 0 and r.price_basis in ('weekly', 'monthly') and not fn_has_role('owner','manager') then
    raise exception 'FORBIDDEN: shortening a weekly or monthly stay requires manager';
  end if;
  before := jsonb_build_object('check_out', r.check_out, 'total_halalas', r.total_halalas);
  perform fn_ensure_nights(r.id);

  -- allocation: extend the current active allocation (exclusion constraint guards the added period)
  select * into a from reservation_allocations where reservation_id = r.id and status = 'active' order by to_date desc limit 1 for update;
  if found then
    if a.to_date <> r.check_out then raise exception 'ALLOCATION_MISMATCH: active allocation does not end at check_out'; end if;
    if a.to_date = r.check_out then
      if p_new_check_out <= a.from_date then raise exception 'VALIDATION: dates'; end if;
      begin
        update reservation_allocations set to_date = p_new_check_out where id = a.id;
      exception when exclusion_violation then
        raise exception 'ALLOCATION_CONFLICT: room is allocated during the added period' using errcode = '23P01';
      end;
    end if;
  end if;

  if delta > 0 then
    -- keep_rate: the added nights at the stay's last night's price; reprice: the calendar's prices for those nights
    -- (an extension is never re-priced as a weekly or monthly stay — that price is fixed when the stay is made)
    if p_pricing_mode = 'keep_rate' then
      select price_halalas into last_price from reservation_nights where reservation_id = r.id and status = 'active' order by night desc limit 1;
      runs := jsonb_build_array(jsonb_build_object('from', r.check_out, 'to', p_new_check_out, 'nights', delta,
                                                   'price', coalesce(last_price, r.nightly_rate_halalas), 'basis', 'kept'));
    else
      platform := exists (select 1 from booking_sources s where s.id = r.source_id and s.kind <> 'direct');
      runs := fn_stay_runs(r.room_category_id, r.check_out, p_new_check_out, platform, null, false);
    end if;
    perform fn_book_nights(r.id, runs, 'تمديد', p_reason);
  else
    -- the refund is exactly the removed nights' prices; the nights keep their rows, marked removed
    select coalesce(sum(price_halalas), 0) into refund from reservation_nights
    where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
    update reservation_nights set status = 'removed', removed_at = now(), removed_by = fn_staff_id(), removed_reason = p_reason
    where reservation_id = r.id and status = 'active' and night >= p_new_check_out and night < r.check_out;
    perform fn_add_charge(r.id, 'adjustment', 'تقصير الإقامة ' || abs(delta) || ' ليلة', 1, -refund, true, p_reason, null, p_new_check_out, r.check_out);
  end if;
  update reservations set check_out = p_new_check_out,
         nightly_rate_halalas = coalesce((select round(avg(price_halalas))::bigint from reservation_nights where reservation_id = r.id and status = 'active'), nightly_rate_halalas),
         version = version + 1, updated_at = now()
  where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.departure_changed', 'reservation', r.id, before,
    jsonb_build_object('check_out', p_new_check_out, 'total_halalas', (select total_halalas from reservations where id = r.id), 'delta_nights', delta,
                       'pricing_mode', p_pricing_mode, 'nights', case when delta > 0 then runs else jsonb_build_object('refunded_halalas', refund) end), p_reason);
  return jsonb_build_object('ok', true, 'delta_nights', delta, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_amend_stay(uuid, date, text, text, int) to authenticated;

-- ---------------------------------------------------------------- 8. discounts on an existing stay (decision 9)
create or replace function fn_staff_adjust_price(p_reservation uuid, p_kind text, p_amount_halalas bigint, p_description text, p_reason text, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; before jsonb; rent bigint; n int; disc bigint;
begin
  if p_kind not in ('discount','adjustment','penalty','addon') then raise exception 'VALIDATION: kind'; end if;
  if p_kind = 'adjustment' then perform fn_require_role('owner','manager'); else perform fn_require_role('owner','manager','supervisor'); end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'VALIDATION: reason'; end if;
  if p_amount_halalas = 0 or (p_kind in ('discount','penalty','addon') and p_amount_halalas < 0) then raise exception 'VALIDATION: amount'; end if;
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if r.status in ('cancelled','rejected','closed','no_show') then raise exception 'RESERVATION_STATUS_INVALID'; end if;
  if p_kind = 'discount' then
    perform fn_ensure_nights(r.id);
    select coalesce(sum(price_halalas), 0), count(*) into rent, n from reservation_nights where reservation_id = r.id and status = 'active';
    disc := coalesce((select sum(round(abs(quantity * unit_price_halalas)))::bigint from reservation_charges where reservation_id = r.id and kind = 'discount'), 0);
    perform fn_check_discount(r.room_category_id, r.branch_id, n, rent, disc, p_amount_halalas, r.status in ('checked_in','checked_out'));
  end if;
  before := jsonb_build_object('total_halalas', r.total_halalas);
  perform fn_add_charge(r.id, p_kind, coalesce(nullif(trim(p_description),''), p_kind), 1, p_amount_halalas, true, p_reason);
  update reservations set version = version + 1 where id = r.id;
  perform fn_recompute_reservation_finance(r.id);
  perform fn_audit_change(r.branch_id, 'reservation.total_changed', 'reservation', r.id, before, jsonb_build_object('total_halalas', (select total_halalas from reservations where id = r.id), 'kind', p_kind, 'amount_halalas', p_amount_halalas), p_reason);
  return jsonb_build_object('ok', true, 'finance', fn_reservation_finance_internal(r.id));
end $$;
grant execute on function fn_staff_adjust_price(uuid, text, bigint, text, text, int) to authenticated;

-- the discounts given in a period: who, how much, why (owner, manager, finance); the supervisor gets the totals only
create or replace function fn_reports_discounts(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text; full_view boolean; res jsonb;
begin
  perform fn_require_role('owner', 'manager', 'supervisor', 'finance');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'VALIDATION: range'; end if;
  select timezone into tz from branches where id = p_branch;
  full_view := fn_has_role('owner', 'manager', 'finance');
  with d as (
    select ch.id, r.id as reservation_id, r.internal_ref, ch.description, ch.reason, round(abs(ch.quantity * ch.unit_price_halalas))::bigint as amount,
           ch.created_at, ch.created_by, sp.full_name as staff_name, sp.role::text as staff_role,
           (r.actual_check_in is not null and ch.created_at >= r.actual_check_in) as after_arrival
    from reservation_charges ch
    join reservations r on r.id = ch.reservation_id
    left join staff_profiles sp on sp.id = ch.created_by
    where ch.branch_id = p_branch and ch.kind = 'discount' and (ch.created_at at time zone tz)::date between p_from and p_to
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to),
    'total_halalas', coalesce(sum(amount), 0), 'count', count(*),
    'by_staff', coalesce((select jsonb_agg(jsonb_build_object('staff', s.staff_name, 'role', s.staff_role, 'count', s.n, 'total_halalas', s.total) order by s.total desc)
                          from (select staff_name, staff_role, count(*) as n, sum(amount) as total from d group by staff_name, staff_role) s), '[]'::jsonb),
    'rows', case when full_view then coalesce((select jsonb_agg(jsonb_build_object('id', d2.id, 'reservation_id', d2.reservation_id, 'internal_ref', d2.internal_ref,
              'amount_halalas', d2.amount, 'reason', coalesce(d2.reason, d2.description), 'staff', d2.staff_name, 'role', d2.staff_role,
              'created_at', d2.created_at, 'after_arrival', d2.after_arrival) order by d2.created_at desc) from d d2), '[]'::jsonb) end)
  into res from d;
  return res;
end $$;
grant execute on function fn_reports_discounts(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------- 9. the price calendar (decision 33)
-- types in rows, nights in columns: the price (and the platform price), whether it is explicit, and how many units of
-- the type are free that night out of how many it has (for display: confirmed and in-house stays count)
create or replace function fn_rate_calendar(p_branch uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date;
begin
  perform fn_require_role('owner', 'manager');
  perform fn_require_branch(p_branch);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then raise exception 'VALIDATION: range'; end if;
  today := fn_branch_today(p_branch);
  return jsonb_build_object('today', today, 'from', p_from, 'to', p_to,
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name_ar, 'base_price', c.base_price_halalas, 'weekly_price', c.weekly_price_halalas,
        'monthly_price', c.monthly_price_halalas, 'min_nightly', c.min_nightly_halalas, 'price_mode', c.price_mode, 'units', u.total,
        'days', (select jsonb_agg(jsonb_build_object('night', g::date, 'price', rc.price_halalas, 'platform_price', rc.platform_price_halalas,
                   'available', greatest(0, u.total - (select count(*) from reservations r
                                                       where r.room_category_id = c.id and r.status in ('confirmed', 'checked_in')
                                                         and g::date >= r.check_in and g::date < r.check_out))) order by g)
                 from generate_series(p_from, p_to, interval '1 day') g
                 left join rate_calendar rc on rc.category_id = c.id and rc.night = g::date)
      ) order by c.sort_order, c.name_ar)
      from room_categories c
      cross join lateral (select count(*)::int as total from rooms rm where rm.category_id = c.id and rm.archived_at is null and coalesce(rm.is_active, true)) u
      where c.branch_id = p_branch and c.archived_at is null), '[]'::jsonb));
end $$;
grant execute on function fn_rate_calendar(uuid, date, date) to authenticated;

-- sets prices: explicit cells [{category_id, night}], or a range × types × weekdays (0 = Sunday … 6 = Saturday).
-- price_halalas / platform_price_halalas set the rows given; clear = back to the base price (true: both rows,
-- 'price' or 'platform': that row only). Owner or manager only;
-- past nights refused; nothing under the type's minimum; one audit row with the cells and what they held before.
create or replace function fn_rate_calendar_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_branch uuid := (p->>'branch_id')::uuid; today date; cats uuid[]; wd int[]; d0 date := nullif(p->>'from', '')::date; d1 date := nullif(p->>'to', '')::date;
        v_cells jsonb := p->'cells'; v_clear text := case when p->>'clear' = 'true' then 'both' when p->>'clear' in ('price', 'platform') then p->>'clear' end;
        set_p boolean := nullif(p->>'price_halalas', '') is not null; set_pp boolean := nullif(p->>'platform_price_halalas', '') is not null;
        v_p bigint := nullif(p->>'price_halalas', '')::bigint; v_pp bigint := nullif(p->>'platform_price_halalas', '')::bigint;
        x record; old_p bigint; old_pp bigint; new_p bigint; new_pp bigint; n int := 0; seen int := 0; before jsonb := '[]'::jsonb;
begin
  perform fn_require_role('owner', 'manager');
  perform fn_require_branch(v_branch);
  today := fn_branch_today(v_branch);
  if v_clear is null and not set_p and not set_pp then raise exception 'VALIDATION: price'; end if;
  if (set_p and v_p <= 0) or (set_pp and v_pp <= 0) then raise exception 'VALIDATION: amount'; end if;
  if v_cells is not null and jsonb_typeof(v_cells) <> 'array' then raise exception 'VALIDATION: cells'; end if;
  if v_cells is null then
    if d0 is null or d1 is null or d1 < d0 or d1 - d0 > 731 then raise exception 'VALIDATION: range'; end if;
    select array_agg(value::uuid) into cats from jsonb_array_elements_text(coalesce(p->'category_ids', '[]'::jsonb));
    if cats is null then raise exception 'VALIDATION: categories'; end if;
    if p ? 'weekdays' and jsonb_typeof(p->'weekdays') = 'array' and jsonb_array_length(p->'weekdays') > 0 then
      select array_agg(value::int) into wd from jsonb_array_elements_text(p->'weekdays');
    end if;
  end if;
  for x in
    select c.id as category_id, c.min_nightly_halalas as min_p, c.price_mode, t.night
    from room_categories c
    join lateral (
      select (e->>'night')::date as night from jsonb_array_elements(coalesce(v_cells, '[]'::jsonb)) e
      where v_cells is not null and (e->>'category_id')::uuid = c.id
      union
      select g::date from generate_series(d0, d1, interval '1 day') g
      where v_cells is null and c.id = any(cats) and (wd is null or extract(dow from g)::int = any(wd))
    ) t on true
    where c.branch_id = v_branch and c.archived_at is null
    order by t.night, c.id
  loop
    seen := seen + 1;
    if seen > 5000 then raise exception 'VALIDATION: too_many_cells'; end if;
    if x.night < today then raise exception 'VALIDATION: past_night'; end if;
    if set_p and x.min_p is not null and v_p < x.min_p then raise exception 'VALIDATION: below_minimum'; end if;
    if set_pp and x.price_mode = 'by_channel' and x.min_p is not null and v_pp < x.min_p then raise exception 'VALIDATION: below_minimum'; end if;
    select price_halalas, platform_price_halalas into old_p, old_pp from rate_calendar where category_id = x.category_id and night = x.night;
    if not found then old_p := null; old_pp := null; end if;
    new_p := case when v_clear in ('both', 'price') then null when set_p then v_p else old_p end;
    new_pp := case when v_clear in ('both', 'platform') then null when set_pp and x.price_mode = 'by_channel' then v_pp else old_pp end;
    if new_p is distinct from old_p or new_pp is distinct from old_pp then
      insert into rate_calendar(organization_id, branch_id, category_id, night, price_halalas, platform_price_halalas, updated_by)
      values (fn_user_org_id(), v_branch, x.category_id, x.night, new_p, new_pp, fn_staff_id())
      on conflict (category_id, night) do update set price_halalas = excluded.price_halalas, platform_price_halalas = excluded.platform_price_halalas,
                                                      updated_by = excluded.updated_by, updated_at = now();
      n := n + 1;
      if n <= 400 then
        before := before || jsonb_build_array(jsonb_build_object('category_id', x.category_id, 'night', x.night, 'price', old_p, 'platform_price', old_pp));
      end if;
    end if;
  end loop;
  if seen = 0 then raise exception 'VALIDATION: cells'; end if;
  if n > 0 then
    perform fn_audit_change(v_branch, 'rates.updated', 'rate_calendar', v_branch,
      jsonb_build_object('cells', before, 'more', greatest(n - 400, 0)),
      jsonb_build_object('changed', n, 'price_halalas', case when v_clear in ('both', 'price') then null else v_p end,
                         'platform_price_halalas', case when v_clear in ('both', 'platform') then null else v_pp end, 'clear', v_clear, 'from', d0, 'to', d1, 'category_ids', to_jsonb(cats), 'weekdays', to_jsonb(wd), 'cells', v_cells is not null),
      nullif(trim(coalesce(p->>'reason', '')), ''));
  end if;
  return jsonb_build_object('ok', true, 'changed', n, 'matched', seen);
end $$;
grant execute on function fn_rate_calendar_set(jsonb) to authenticated;

-- ---------------------------------------------------------------- 10. unit types: price fields and capacity (decision 32)
create or replace function fn_category_capacity_impact(p_category uuid, p_max_capacity int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c room_categories%rowtype;
begin
  perform fn_require_role('owner', 'manager');
  select * into c from room_categories where id = p_category;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(c.branch_id);
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'internal_ref', r.internal_ref, 'check_in', r.check_in, 'check_out', r.check_out,
                                                       'guests', r.adults + r.companions, 'status', r.status) order by r.check_in)
                   from reservations r
                   where r.room_category_id = c.id and r.status in ('pending_verification', 'confirmed', 'checked_in')
                     and r.check_out > fn_branch_today(c.branch_id) and r.adults + r.companions > p_max_capacity), '[]'::jsonb);
end $$;
grant execute on function fn_category_capacity_impact(uuid, int) to authenticated;

create or replace function fn_admin_upsert_room_category(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c room_categories%rowtype; v_id uuid := (p->>'id')::uuid; v_branch uuid := (p->>'branch_id')::uuid; before jsonb; affected int := 0; low int;
begin
  perform fn_require_role('owner','manager');
  if coalesce(trim(p->>'name_ar'),'') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if (p ? 'base_price_halalas') and (p->>'base_price_halalas')::bigint < 0 then raise exception 'VALIDATION: amount'; end if;
  if (nullif(p->>'weekly_price_halalas', '')::bigint <= 0) or (nullif(p->>'monthly_price_halalas', '')::bigint <= 0)
     or (nullif(p->>'min_nightly_halalas', '')::bigint <= 0) then raise exception 'VALIDATION: amount'; end if;
  if (p ? 'price_mode') and p->>'price_mode' not in ('unified', 'by_channel') then raise exception 'VALIDATION: price_mode'; end if;
  if v_id is null then
    perform fn_require_branch(v_branch);
    insert into room_categories(organization_id, branch_id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, amenities, is_public, sort_order,
                                weekly_price_halalas, monthly_price_halalas, min_nightly_halalas, price_mode)
    values (fn_user_org_id(), v_branch, trim(p->>'name_ar'), p->>'name_en', p->>'description', coalesce((p->>'base_capacity')::int,2), coalesce((p->>'max_capacity')::int,4),
            coalesce((p->>'base_price_halalas')::bigint, 0), coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'amenities','[]'::jsonb)) x), '{}'),
            coalesce((p->>'is_public')::boolean, true), coalesce((p->>'sort_order')::int, 0),
            nullif(p->>'weekly_price_halalas', '')::bigint, nullif(p->>'monthly_price_halalas', '')::bigint, nullif(p->>'min_nightly_halalas', '')::bigint,
            coalesce(p->>'price_mode', 'unified')) returning * into c;
    perform fn_audit_change(c.branch_id, 'room_category.created', 'room_category', c.id, null, to_jsonb(c));
  else
    select * into c from room_categories where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(c.branch_id);
    perform fn_check_version_strict(c.version, (p->>'version')::int);
    before := to_jsonb(c);
    -- changing a price never reprices existing reservations (their nights and charges are snapshots)
    update room_categories set name_ar = trim(p->>'name_ar'), name_en = coalesce(p->>'name_en', name_en), description = coalesce(p->>'description', description),
      base_capacity = coalesce((p->>'base_capacity')::int, base_capacity), max_capacity = coalesce((p->>'max_capacity')::int, max_capacity),
      base_price_halalas = coalesce((p->>'base_price_halalas')::bigint, base_price_halalas),
      weekly_price_halalas = case when p ? 'weekly_price_halalas' then nullif(p->>'weekly_price_halalas', '')::bigint else weekly_price_halalas end,
      monthly_price_halalas = case when p ? 'monthly_price_halalas' then nullif(p->>'monthly_price_halalas', '')::bigint else monthly_price_halalas end,
      min_nightly_halalas = case when p ? 'min_nightly_halalas' then nullif(p->>'min_nightly_halalas', '')::bigint else min_nightly_halalas end,
      price_mode = coalesce(p->>'price_mode', price_mode),
      amenities = case when p ? 'amenities' then (select array_agg(x) from jsonb_array_elements_text(p->'amenities') x) else amenities end,
      is_public = coalesce((p->>'is_public')::boolean, is_public), is_active = coalesce((p->>'is_active')::boolean, is_active),
      sort_order = coalesce((p->>'sort_order')::int, sort_order), version = version + 1, updated_at = now()
    where id = c.id returning * into c;
    if c.max_capacity < c.base_capacity then raise exception 'VALIDATION: capacity'; end if;
    if c.max_capacity < (before->>'max_capacity')::int then
      affected := jsonb_array_length(fn_category_capacity_impact(c.id, c.max_capacity));
    end if;
  end if;
  -- no nightly price of the type under its minimum: the base price, the weekly and monthly prices per night, and the
  -- calendar's coming nights (decision 33: «ولا سعر تحت الأدنى»)
  if c.min_nightly_halalas is not null then
    if c.base_price_halalas < c.min_nightly_halalas
       or (c.weekly_price_halalas is not null and c.weekly_price_halalas::numeric / 7 < c.min_nightly_halalas)
       or (c.monthly_price_halalas is not null and c.monthly_price_halalas::numeric / 30 < c.min_nightly_halalas) then
      raise exception 'VALIDATION: below_minimum';
    end if;
    select count(*) into low from rate_calendar rc
    where rc.category_id = c.id and rc.night >= fn_branch_today(c.branch_id)
      and (rc.price_halalas < c.min_nightly_halalas or (c.price_mode = 'by_channel' and rc.platform_price_halalas < c.min_nightly_halalas));
    if low > 0 then raise exception 'VALIDATION: calendar_below_minimum'; end if;
  end if;
  if v_id is not null then
    perform fn_audit_change(c.branch_id, 'room_category.updated', 'room_category', c.id, before, to_jsonb(c) || jsonb_build_object('stays_over_capacity', affected));
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'version', c.version, 'stays_over_capacity', affected);
end $$;
grant execute on function fn_admin_upsert_room_category(jsonb) to authenticated;

-- ---------------------------------------------------------------- 11. branch settings: the supervisor's discount ceiling
create or replace function fn_admin_upsert_branch(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b branches%rowtype; v_id uuid := (p->>'id')::uuid; before jsonb; tax_changed boolean;
begin
  perform fn_require_role('owner', 'manager');
  if coalesce(trim(p->>'name_ar'), '') = '' then raise exception 'VALIDATION: name_ar'; end if;
  if p ? 'timezone' then
    begin perform now() at time zone (p->>'timezone'); exception when others then raise exception 'VALIDATION: timezone'; end;
  end if;
  if (p->>'tax_rate_bp') is not null and ((p->>'tax_rate_bp') !~ '^[0-9]{1,4}$' or (p->>'tax_rate_bp')::int > 10000) then raise exception 'VALIDATION: tax_rate'; end if;
  if (p->>'default_deposit_halalas') is not null and (p->>'default_deposit_halalas') !~ '^[0-9]{1,12}$' then raise exception 'VALIDATION: amount'; end if;
  if (p->>'supervisor_max_discount_bp') is not null and ((p->>'supervisor_max_discount_bp') !~ '^[0-9]{1,5}$' or (p->>'supervisor_max_discount_bp')::int > 10000) then
    raise exception 'VALIDATION: discount_limit';
  end if;
  if v_id is null then
    perform fn_require_role('owner');
    insert into branches(organization_id, name_ar, name_en, city, address, map_url, phone, email, check_in_time, check_out_time, timezone, tax_rate_bp, prices_include_tax,
                         default_deposit_halalas, tax_number, commercial_register, is_active, supervisor_max_discount_bp)
    values (fn_user_org_id(), p->>'name_ar', p->>'name_en', p->>'city', p->>'address', p->>'map_url', p->>'phone', p->>'email',
            coalesce((p->>'check_in_time')::time, '16:00'), coalesce((p->>'check_out_time')::time, '12:00'),
            coalesce(p->>'timezone', 'Asia/Riyadh'), coalesce((p->>'tax_rate_bp')::int, 0), coalesce((p->>'prices_include_tax')::boolean, false),
            coalesce((p->>'default_deposit_halalas')::bigint, 5000), nullif(trim(coalesce(p->>'tax_number', '')), ''), p->>'commercial_register', coalesce((p->>'is_active')::boolean, true),
            coalesce((p->>'supervisor_max_discount_bp')::int, 0))
    returning * into b;
    perform fn_room_cleaning_type(b.id);   -- (its cash box and bank account come from trg_branch_bootstrap_accounts)
    perform fn_audit_change(b.id, 'branch.created', 'branch', b.id, null, to_jsonb(b));
  else
    select * into b from branches where id = v_id and organization_id = fn_user_org_id() for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform fn_require_branch(b.id);
    perform fn_check_version(b.version, (p->>'version')::int);
    tax_changed := ((p->>'tax_rate_bp') is not null and (p->>'tax_rate_bp')::int is distinct from b.tax_rate_bp)
                or ((p->>'prices_include_tax') is not null and (p->>'prices_include_tax')::boolean is distinct from b.prices_include_tax)
                or ((p ? 'tax_number') and nullif(trim(coalesce(p->>'tax_number', '')), '') is distinct from b.tax_number);
    if tax_changed and not fn_has_role('owner') then raise exception 'FORBIDDEN: tax settings are the owner''s'; end if;
    before := to_jsonb(b);
    update branches set
      name_ar = p->>'name_ar', name_en = coalesce(p->>'name_en', name_en), city = coalesce(p->>'city', city), address = coalesce(p->>'address', address),
      map_url = coalesce(p->>'map_url', map_url), phone = coalesce(p->>'phone', phone), email = coalesce(p->>'email', email),
      check_in_time = coalesce((p->>'check_in_time')::time, check_in_time), check_out_time = coalesce((p->>'check_out_time')::time, check_out_time),
      timezone = coalesce(p->>'timezone', timezone), tax_rate_bp = coalesce((p->>'tax_rate_bp')::int, tax_rate_bp),
      prices_include_tax = coalesce((p->>'prices_include_tax')::boolean, prices_include_tax),
      default_deposit_halalas = coalesce((p->>'default_deposit_halalas')::bigint, default_deposit_halalas),
      supervisor_max_discount_bp = coalesce((p->>'supervisor_max_discount_bp')::int, supervisor_max_discount_bp),
      tax_number = case when p ? 'tax_number' then nullif(trim(coalesce(p->>'tax_number', '')), '') else tax_number end,
      commercial_register = coalesce(p->>'commercial_register', commercial_register),
      is_active = coalesce((p->>'is_active')::boolean, is_active), version = version + 1, updated_at = now()
    where id = b.id returning * into b;
    perform fn_audit_change(b.id, 'branch.updated', 'branch', b.id, before, to_jsonb(b));
    if tax_changed then
      perform fn_audit_change(b.id, 'branch.tax_changed', 'branch', b.id,
        jsonb_build_object('tax_rate_bp', before->'tax_rate_bp', 'prices_include_tax', before->'prices_include_tax', 'tax_number', before->'tax_number'),
        jsonb_build_object('tax_rate_bp', b.tax_rate_bp, 'prices_include_tax', b.prices_include_tax, 'tax_number', b.tax_number),
        'يسري على الحجوزات الجديدة فقط');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', b.id, 'version', b.version);
end $$;
grant execute on function fn_admin_upsert_branch(jsonb) to authenticated;

-- ---------------------------------------------------------------- 12. what blocks removing a definition (decision 48)
-- a branch with terminal settlements, platform payouts or calendar prices, and a unit type with calendar prices, are
-- archived rather than removed (the removal answers with these counts and offers the archive)
create or replace function fn_definition_dependencies(p_entity text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d jsonb := '{}'::jsonb; v_branch uuid;
begin
  perform fn_require_role('owner','manager');
  v_branch := case p_entity
    when 'branch' then p_id
    when 'block' then (select branch_id from blocks where id = p_id)
    when 'floor' then (select branch_id from floors where id = p_id)
    when 'room_category' then (select branch_id from room_categories where id = p_id)
    when 'room' then (select branch_id from rooms where id = p_id)
    when 'facility' then (select branch_id from facilities where id = p_id)
    when 'task_type' then (select branch_id from task_types where id = p_id)
    when 'service' then (select branch_id from service_definitions where id = p_id) end;
  if v_branch is null then raise exception 'NOT_FOUND'; end if;
  perform fn_require_branch(v_branch);
  case p_entity
    when 'branch' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where branch_id = p_id),
        'room_categories', (select count(*) from room_categories where branch_id = p_id),
        'reservations', (select count(*) from reservations where branch_id = p_id),
        'staff', (select count(*) from branch_memberships where branch_id = p_id),
        'blocks', (select count(*) from blocks where branch_id = p_id),
        'floors', (select count(*) from floors where branch_id = p_id),
        'facilities', (select count(*) from facilities where branch_id = p_id),
        'task_types', (select count(*) from task_types where branch_id = p_id and code is null),
        'services', (select count(*) from service_definitions where branch_id = p_id),
        'vouchers', (select count(*) from financial_vouchers where branch_id = p_id),
        'invoices', (select count(*) from invoices where branch_id = p_id),
        'keyboxes', (select count(*) from keyboxes where branch_id = p_id),
        'policies', (select count(*) from property_policies where branch_id = p_id),
        'conversations', (select count(*) from conversations where branch_id = p_id),
        'tasks', (select count(*) from housekeeping_tasks where branch_id = p_id),
        'pos_settlements', (select count(*) from pos_settlements where branch_id = p_id),
        'platform_payouts', (select count(*) from platform_payouts where branch_id = p_id),
        'rate_calendar', (select count(*) from rate_calendar where branch_id = p_id and (price_halalas is not null or platform_price_halalas is not null)));
    when 'block' then
      d := jsonb_build_object(
        'floors', (select count(*) from floors where block_id = p_id),
        'rooms', (select count(*) from rooms where block_id = p_id),
        'facilities', (select count(*) from facilities where block_id = p_id));
    when 'floor' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where floor_id = p_id),
        'facilities', (select count(*) from facilities where floor_id = p_id));
    when 'room_category' then
      d := jsonb_build_object(
        'rooms', (select count(*) from rooms where category_id = p_id),
        'reservations', (select count(*) from reservations where room_category_id = p_id),
        'inventory_periods', (select count(*) from inventory_periods where category_id = p_id),
        'release_rules', (select count(*) from release_rules where category_id = p_id),
        'released_slots', (select count(*) from released_slots where category_id = p_id),
        'rate_calendar', (select count(*) from rate_calendar where category_id = p_id and (price_halalas is not null or platform_price_halalas is not null)));
    when 'room' then
      d := jsonb_build_object(
        'reservations', (select count(*) from reservations where room_id = p_id),
        'allocations', (select count(*) from reservation_allocations where room_id = p_id),
        'tasks', (select count(*) from housekeeping_tasks where room_id = p_id),
        'keyboxes', (select count(*) from keyboxes where room_id = p_id),
        'maintenance_tickets', (select count(*) from maintenance_tickets where room_id = p_id),
        'code_rotation_events', (select count(*) from code_rotation_events where room_id = p_id));
    when 'facility' then
      d := jsonb_build_object('tasks', (select count(*) from housekeeping_tasks where facility_id = p_id));
    when 'task_type' then
      d := jsonb_build_object(
        'tasks', (select count(*) from housekeeping_tasks where task_type_id = p_id),
        'services', (select count(*) from service_definitions where task_type_id = p_id));
    when 'service' then
      d := jsonb_build_object('charges', (select count(*) from reservation_charges where service_definition_id = p_id));
    else raise exception 'VALIDATION: entity';
  end case;
  return d;
end $$;
revoke all on function fn_definition_dependencies(text, uuid) from public, anon;
grant execute on function fn_definition_dependencies(text, uuid) to authenticated;
