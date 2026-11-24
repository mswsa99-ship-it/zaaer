-- =====================================================================
-- Load fixture (item 2.10): one synthetic hotel (organization) with its
-- branches and one year of bookings. Run once per hotel:
--   psql -d $DB -v hotel=1 -v year_start=2025-11-24 -f tests/load/10-fixture-hotel.sql
-- Everything is invented: no real guest, hotel, phone or price. Names are
-- «فندق اختبار N»; phones are 0550000xxx sequences that belong to no one.
--
-- Volume assumptions (stated, not hidden — the plan fixes 50 hotels x 30
-- branches x one year of bookings but not the booking rate):
--   * 20 units per branch (10 in each of 2 categories)
--   * ~75% average annual occupancy (gap days average 1 per stay)
--   * average stay ~2.5 nights (uniform 1..4)
--   => ~104 stays per room-year, ~2,080 bookings per branch-year,
--      ~3.1M bookings over the full 50 x 30 fixture.
-- The year is a rolling 365 days ending 60 days in the future so the
-- arrival/occupancy screens have realistic data «today».
--
-- Bulk-load notes: session_replication_role=replica skips the row-level
-- business triggers (tax snapshot, voucher GL mirror, deposit gate, ...).
-- Every value those triggers would derive (tax snapshot, paid/balance/
-- deposit columns, room status, content hashes) is written explicitly
-- with the same shape the writers produce, so the measured read paths
-- see production-shaped rows. Exclusion/unique/column CHECK constraints
-- stay enforced (index/check enforced, not trigger enforced): the room
-- sequences are non-overlapping by construction and every natural key is
-- unique by construction.
-- =====================================================================
\set ON_ERROR_STOP on
set session_replication_role = replica;
set work_mem = '64MB';

-- psql variables are not expanded inside a dollar-quoted DO body: pass them
-- through custom settings instead.
select set_config('load.hotel', :'hotel', false);
select set_config('load.year_start', :'year_start', false);

do $$
declare
  h int := current_setting('load.hotel')::int;
  ys date := current_setting('load.year_start')::date;  -- first possible check-in day
  nd int := 365;                       -- days of check-in dates
  units int := 20;                     -- rooms per branch
  nbranch int := 30;                   -- branches per hotel
  org uuid := md5('org:'||h)::uuid;
  b int;
  br uuid;
  owner_id uuid := md5('staff:'||h||':owner')::uuid;
  manager_id uuid := md5('staff:'||h||':manager')::uuid;
  sup_id uuid := md5('staff:'||h||':supervisor')::uuid;
  src_int uuid := md5('src:'||h||':direct')::uuid;
  src_phone uuid := md5('src:'||h||':phone')::uuid;
  src_booking uuid := md5('src:'||h||':booking')::uuid;
  src_airbnb uuid := md5('src:'||h||':airbnb')::uuid;
  ecat uuid := md5('ecat:'||h)::uuid;
  cash uuid; bank uuid; cat1 uuid; cat2 uuid; blk uuid; fl1 uuid; fl2 uuid; tt uuid;
begin
  -- ---- hotel (organization), its staff, its booking sources ----
  insert into organizations(id, name_ar, name_en, license_number) values
    (org, 'فندق اختبار '||h, 'Load Hotel '||h, 'L'||lpad(h::text,6,'0'));

  insert into auth.users(id, email, email_confirmed_at, created_at) values
    (md5('auth:'||h||':owner')::uuid,  'load-owner-'||h||'@test.invalid', now(), now()),
    (md5('auth:'||h||':manager')::uuid,'load-mgr-'||h||'@test.invalid',   now(), now()),
    (md5('auth:'||h||':sup')::uuid,    'load-sup-'||h||'@test.invalid',   now(), now());

  insert into staff_profiles(id, auth_user_id, organization_id, full_name, email, role) values
    (owner_id,   md5('auth:'||h||':owner')::uuid,   org, 'مالك اختبار '||h,  'load-owner-'||h||'@test.invalid', 'owner'),
    (manager_id, md5('auth:'||h||':manager')::uuid, org, 'مدير اختبار '||h,  'load-mgr-'||h||'@test.invalid',   'manager'),
    (sup_id,     md5('auth:'||h||':sup')::uuid,     org, 'مشرف اختبار '||h,  'load-sup-'||h||'@test.invalid',   'supervisor');

  insert into booking_sources(id, organization_id, name, code, kind, commission_bp) values
    (src_int,     org, 'مباشر',        'DIRECT',  'internal', 0),
    (src_phone,   org, 'هاتف',         'PHONE',   'internal', 0),
    (src_booking, org, 'Booking.com',  'BDC',     'external', 1500),
    (src_airbnb,  org, 'Airbnb',       'ABB',     'external', 1700);

  insert into expense_categories(id, organization_id, name, sort_order, is_active, version) values
    (ecat, org, 'مصروفات تشغيل', 1, true, 1);

  -- ---- branches with their structure and one year of bookings each ----
  for b in 1..nbranch loop
    br := md5('branch:'||h||':'||b)::uuid;
    cash := md5('acc:'||h||':'||b||':cash')::uuid;
    bank := md5('acc:'||h||':'||b||':bank')::uuid;
    cat1 := md5('cat:'||h||':'||b||':1')::uuid;
    cat2 := md5('cat:'||h||':'||b||':2')::uuid;
    blk  := md5('blk:'||h||':'||b)::uuid;
    fl1  := md5('fl:'||h||':'||b||':1')::uuid;
    fl2  := md5('fl:'||h||':'||b||':2')::uuid;
    tt   := md5('tt:'||h||':'||b)::uuid;

    insert into branches(id, organization_id, name_ar, name_en, city, timezone, tax_rate_bp, prices_include_tax, default_deposit_halalas,
                         tax_rent_enabled, tax_rent_rate_bp)
    values (br, org, 'فرع اختبار '||h||'-'||b, 'Branch '||h||'-'||b, 'مدينة اختبار', 'Asia/Riyadh', 1500, false, 5000, true, 1500);

    insert into branch_memberships(staff_id, branch_id, organization_id) values (manager_id, br, org), (sup_id, br, org);

    insert into blocks(id, organization_id, branch_id, name, sort_order) values (blk, org, br, 'A', 1);
    insert into floors(id, organization_id, branch_id, block_id, name, sort_order) values
      (fl1, org, br, blk, '1', 1), (fl2, org, br, blk, '2', 2);

    insert into room_categories(id, organization_id, branch_id, name_ar, name_en, base_capacity, max_capacity, base_price_halalas, sort_order)
    values (cat1, org, br, 'غرفة خاصة', 'Private room', 2, 3, 7500, 1),
           (cat2, org, br, 'جناح',       'Suite',        2, 5, 15000, 2);

    -- 20 rooms: 10 per category, 10 per floor. Status/cleanliness reflect «today»:
    -- occupied when an active stay covers today (set in the second pass below).
    insert into rooms(id, organization_id, branch_id, category_id, room_number, floor, block_id, floor_id, status, cleanliness, is_active)
    select md5('room:'||h||':'||b||':'||r)::uuid, org, br,
           case when r <= 10 then cat1 else cat2 end,
           lpad(r::text, 3, '0'),
           case when r <= 10 then 1 else 2 end,
           blk, case when r <= 10 then fl1 else fl2 end,
           case when r = 20 then 'maintenance'::room_status else 'ready'::room_status end,
           case when r % 7 = 0 then 'dirty' else 'clean' end,
           true
    from generate_series(1, units) r;

    insert into cash_accounts(id, organization_id, branch_id, kind, name, is_default, opening_balance_halalas, opening_on) values
      (cash, org, br, 'cash_box', 'صندوق الفرع', true, 0, ys),
      (bank, org, br, 'bank_account', 'حساب بنك الفرع', false, 0, ys);

    insert into task_types(id, organization_id, branch_id, code, name, is_active, version)
    values (tt, org, br, 'CLEAN', 'تنظيف', true, 1);

    -- ================= year of bookings =================
    -- Non-overlapping stays per room: stay k of a room starts after every
    -- earlier stay plus its gap. Lengths/gaps are hashed, so the fixture is
    -- reproducible. ~71-75% occupancy, average stay ~2.5 nights.
    create temporary table _stays on commit drop as
    with slots as (
      select r as room_no, k,
             1 + (abs(hashtext('len:'||h||':'||b||':'||r||':'||k)) % 4) as nights,
             (abs(hashtext('gap:'||h||':'||b||':'||r||':'||k)) % 3)      as gap_days
      from generate_series(1, units) r, generate_series(1, 140) k
    ), seq as (
      select room_no, k, nights,
             sum(nights + gap_days) over (partition by room_no order by k) - (nights + gap_days) as start_off
      from slots
    )
    select room_no, k, nights,
           ys + start_off::int as check_in,
           ys + start_off::int + nights as check_out,
           md5('res:'||h||':'||b||':'||room_no||':'||k)::uuid as res_id,
           md5('room:'||h||':'||b||':'||room_no)::uuid as room_id
    from seq
    where ys + start_off::int < ys + nd;
    create index on _stays(res_id);

    -- reservations
    insert into reservations(
      id, organization_id, branch_id, internal_ref, external_ref, source_id, status, booking_type, company_name,
      check_in, check_out, adults, companions, room_category_id, room_id,
      rent_amount_halalas, discount_halalas, addons_halalas, taxes_halalas, total_halalas,
      paid_halalas, payment_status, identity_status, access_status,
      actual_check_in, actual_check_out, created_at, created_by, updated_at, version,
      rate_type, nightly_rate_halalas, cancelled_at, cancel_reason, no_show_at,
      deposit_balance_halalas, refunded_halalas, balance_due_halalas,
      group_ref, tax_rate_bp, prices_include_tax, price_basis,
      platform_booked_on, platform_collects, free_stay,
      tax_services_rate_bp, tax_products_rate_bp)
    select
      s.res_id, org, br,
      'R'||h||'-'||b||'-'||s.room_no||'-'||s.k,
      case when (abs(hashtext('src:'||s.res_id::text)) % 10) >= 6
           then 'EXT-'||h||'-'||b||'-'||s.room_no||'-'||s.k end,
      case (abs(hashtext('src:'||s.res_id::text)) % 10)
        when 0 then src_phone when 1 then src_phone when 2 then src_int when 3 then src_int
        when 4 then src_int when 5 then src_int when 6 then src_booking when 7 then src_booking
        when 8 then src_airbnb else src_booking end,
      case
        when s.check_in > current_date then
          case when abs(hashtext('st:'||s.res_id::text)) % 10 = 0 then 'pending_verification'::reservation_status else 'confirmed'::reservation_status end
        when s.check_out > current_date then
          case when abs(hashtext('st:'||s.res_id::text)) % 10 = 0 then 'confirmed'::reservation_status else 'checked_in'::reservation_status end
        else
          case abs(hashtext('st:'||s.res_id::text)) % 20
            when 0 then 'cancelled'::reservation_status when 1 then 'no_show'::reservation_status
            when 2 then 'checked_out'::reservation_status when 3 then 'checked_out'::reservation_status
            when 4 then 'checked_out'::reservation_status else 'closed'::reservation_status end
      end,
      case when abs(hashtext('bt:'||s.res_id::text)) % 10 = 0 then 'company' else 'individual' end,
      case when abs(hashtext('bt:'||s.res_id::text)) % 10 = 0 then 'شركة اختبار '||(abs(hashtext('co:'||s.res_id::text)) % 50) end,
      s.check_in, s.check_out,
      1 + (abs(hashtext('ad:'||s.res_id::text)) % 2), (abs(hashtext('cm:'||s.res_id::text)) % 3),
      case when s.room_no <= 10 then cat1 else cat2 end,
      s.room_id,
      v.rent, v.discount, 0, v.tax, v.total,
      v.paid,
      case
        when s.check_in > current_date then case when v.paid > 0 then 'partially_paid'::payment_status else 'pending'::payment_status end
        when s.check_out > current_date then 'partially_paid'::payment_status
        else case abs(hashtext('st:'||s.res_id::text)) % 20
               when 0 then 'refunded'::payment_status when 1 then 'paid'::payment_status else 'paid'::payment_status end
      end,
      case when s.check_in > current_date then 'data_submitted'::guest_verification_status else 'verified'::guest_verification_status end,
      case
        when s.check_in > current_date then 'approved'::access_status
        when s.check_out > current_date then 'key_handed'::access_status
        else 'locked'::access_status end,
      case when s.check_in <= current_date and s.check_in > current_date - 400
                and not (s.check_out <= current_date and abs(hashtext('st:'||s.res_id::text)) % 20 in (0,1))
           then s.check_in::timestamp + time '16:05' end,
      case when s.check_out <= current_date and abs(hashtext('st:'||s.res_id::text)) % 20 not in (0,1)
           then s.check_out::timestamp + time '11:30' end,
      (s.check_in - (abs(hashtext('cr:'||s.res_id::text)) % 30))::timestamp + interval '12 hours' + (abs(hashtext('crt:'||s.res_id::text)) % 43200) * interval '1 second',
      case when abs(hashtext('cb:'||s.res_id::text)) % 2 = 0 then manager_id else sup_id end,
      now(), 1,
      'daily', v.nightly,
      case when s.check_out <= current_date and abs(hashtext('st:'||s.res_id::text)) % 20 = 0
           then (s.check_in - 1)::timestamp + time '18:00' end,
      case when s.check_out <= current_date and abs(hashtext('st:'||s.res_id::text)) % 20 = 0 then 'إلغاء الضيف' end,
      case when s.check_out <= current_date and abs(hashtext('st:'||s.res_id::text)) % 20 = 1
           then s.check_in::timestamp + time '20:00' end,
      case when s.check_out > current_date - 30 and s.check_in <= current_date and abs(hashtext('dep:'||s.res_id::text)) % 10 < 4 then 5000 else 0 end,
      case when s.check_out <= current_date and abs(hashtext('st:'||s.res_id::text)) % 20 = 0 then v.paid else 0 end,
      case when s.check_out <= current_date then 0 else v.total - v.paid end,
      case when abs(hashtext('gr:'||s.res_id::text)) % 25 = 0 then 'G'||h||'-'||b||'-'||s.room_no end,
      1500, false, 'daily',
      case when (abs(hashtext('src:'||s.res_id::text)) % 10) >= 6 then (s.check_in - (abs(hashtext('pb:'||s.res_id::text)) % 20)) end,
      case when (abs(hashtext('src:'||s.res_id::text)) % 10) >= 6 then (abs(hashtext('pc:'||s.res_id::text)) % 10) < 6 end,
      false,
      0, 0
    from _stays s
    cross join lateral (
      select (case when s.room_no <= 10 then 7500 else 15000 end) as nightly,
             (case when s.room_no <= 10 then 7500 else 15000 end) * s.nights as rent,
             case when abs(hashtext('di:'||s.res_id::text)) % 5 = 0
                  then ((case when s.room_no <= 10 then 7500 else 15000 end) * s.nights * 10) / 100 else 0 end as discount
    ) d
    cross join lateral (
      select d.rent, d.discount, d.nightly,
             ((d.rent - d.discount) * 1500) / 10000 as tax,
             d.rent - d.discount + ((d.rent - d.discount) * 1500) / 10000 as total,
             case
               when s.check_out <= current_date then d.rent - d.discount + ((d.rent - d.discount) * 1500) / 10000
               when s.check_in <= current_date then ((d.rent - d.discount) / s.nights) + (((d.rent - d.discount) / s.nights) * 1500) / 10000
               else case when abs(hashtext('pw:'||s.res_id::text)) % 10 < 7
                         then ((d.rent - d.discount) / s.nights) + (((d.rent - d.discount) / s.nights) * 1500) / 10000 else 0 end
             end as paid
    ) v;

    -- primary guest per booking (synthetic names/phones; no real identity data)
    insert into reservation_guests(id, reservation_id, guest_profile_id, is_primary, full_name, identity_type,
                                   identity_number_last4, nationality, phone, phone_verified, verification_status,
                                   data_submitted, created_at, identity_fingerprint, entry_path, organization_id, branch_id)
    select md5('rg:'||r.id)::uuid, r.id,
           case when abs(hashtext('gp:'||r.id::text)) % 5 = 0 then md5('gp:'||r.id)::uuid end,
           true, 'ضيف اختبار '||h||'-'||b||'-'||substr(r.id::text, 1, 8),
           'national_id', lpad((abs(hashtext('i4:'||r.id::text)) % 10000)::text, 4, '0'), 'SA',
           '055'||lpad((abs(hashtext('ph:'||r.id::text)) % 10000000)::text, 7, '0'), true,
           case when r.check_in > current_date then 'data_submitted'::guest_verification_status else 'verified'::guest_verification_status end,
           true, r.created_at, md5('ifp:'||r.id::text), 'office', org, br
    from reservations r where r.branch_id = br;

    -- CRM profiles for the repeat-guest sample (20%)
    insert into guest_profiles(id, full_name, phone, nationality, created_at, organization_id, identity_fingerprint, identity_type, identity_last4, rating)
    select md5('gp:'||r.id)::uuid, 'ضيف اختبار '||h||'-'||b||'-'||substr(r.id::text, 1, 8),
           '055'||lpad((abs(hashtext('ph:'||r.id::text)) % 10000000)::text, 7, '0'), 'SA', r.created_at, org,
           md5('ifp:'||r.id::text), 'national_id', lpad((abs(hashtext('i4:'||r.id::text)) % 10000)::text, 4, '0'),
           case when abs(hashtext('rt:'||r.id::text)) % 3 = 0 then 1 + (abs(hashtext('rt2:'||r.id::text)) % 5) end
    from reservations r where r.branch_id = br and abs(hashtext('gp:'||r.id::text)) % 5 = 0;

    -- allocations: active for open/future stays (non-overlapping per room by
    -- construction, satisfying alloc_no_overlap), closed for finished ones
    insert into reservation_allocations(id, reservation_id, room_id, branch_id, organization_id, from_date, to_date, status, created_by, created_at, closed_at)
    select md5('al:'||r.id)::uuid, r.id, r.room_id, br, org, r.check_in, r.check_out,
           case when r.status in ('confirmed','checked_in','pending_verification') then 'active' else 'closed' end,
           r.created_by, r.created_at,
           case when r.status not in ('confirmed','checked_in','pending_verification') then r.check_out::timestamp + time '12:00' end
    from reservations r where r.branch_id = br;

    -- vouchers: the money the stay actually moved (receipt per paid amount,
    -- deposit for ~40% of in-house/recent, refund for the cancelled)
    insert into financial_vouchers(id, organization_id, branch_id, reservation_id, number, kind, amount_halalas, method,
                                   status, reference, idempotency_key, content_hash, occurred_at, created_by, created_at, account_id)
    select md5('v:'||r.id||':rcp')::uuid, org, br, r.id,
           'V'||h||'-'||b||'-'||substr(r.id::text, 1, 12),
           'receipt', r.paid_halalas,
           case (abs(hashtext('vm:'||r.id::text)) % 10)
             when 0 then 'mada'::payment_method when 1 then 'mada'::payment_method
             when 2 then 'pos'::payment_method when 3 then 'pos'::payment_method
             when 4 then 'bank_transfer'::payment_method
             when 5 then 'ota_deferred'::payment_method when 6 then 'ota_deferred'::payment_method
             else 'cash'::payment_method end,
           'approved',
           case when (abs(hashtext('vm:'||r.id::text)) % 10) in (2,3) then 'POS-'||substr(r.id::text,1,6)
                when (abs(hashtext('vm:'||r.id::text)) % 10) = 4 then 'TR-'||substr(r.id::text,1,6) end,
           'load-'||h||'-'||b||'-'||substr(r.id::text,1,12)||'-rcp',
           md5('vc:'||r.id::text),
           greatest(r.created_at, r.check_in::timestamp + time '15:00' - interval '6 hours'),
           r.created_by, r.created_at,
           case when (abs(hashtext('vm:'||r.id::text)) % 10) in (5,6) then null else cash end
    from reservations r
    where r.branch_id = br and r.paid_halalas > 0;

    insert into financial_vouchers(id, organization_id, branch_id, reservation_id, number, kind, amount_halalas, method,
                                   status, reference, idempotency_key, content_hash, occurred_at, created_by, created_at, account_id)
    select md5('v:'||r.id||':dep')::uuid, org, br, r.id,
           'VD'||h||'-'||b||'-'||substr(r.id::text, 1, 12),
           'deposit', 5000, 'cash'::payment_method, 'approved', null,
           'load-'||h||'-'||b||'-'||substr(r.id::text,1,12)||'-dep',
           md5('vd:'||r.id::text),
           r.check_in::timestamp + time '16:10', r.created_by, r.created_at, cash
    from reservations r
    where r.branch_id = br and r.deposit_balance_halalas > 0;

    insert into financial_vouchers(id, organization_id, branch_id, reservation_id, number, kind, amount_halalas, method,
                                   status, reference, reason, idempotency_key, content_hash, occurred_at, created_by, created_at, account_id)
    select md5('v:'||r.id||':ref')::uuid, org, br, r.id,
           'VR'||h||'-'||b||'-'||substr(r.id::text, 1, 12),
           'refund', r.refunded_halalas, 'cash'::payment_method, 'approved', null, 'رد إلغاء',
           'load-'||h||'-'||b||'-'||substr(r.id::text,1,12)||'-ref',
           md5('vr:'||r.id::text),
           coalesce(r.cancelled_at, r.created_at) + interval '1 hour', r.created_by, r.created_at, cash
    from reservations r
    where r.branch_id = br and r.refunded_halalas > 0;

    -- charges: the rent line, its tax line, an add-on for ~15%
    insert into reservation_charges(id, organization_id, branch_id, reservation_id, kind, description, quantity,
                                    unit_price_halalas, total_halalas, taxable, service_from, service_to, created_by, created_at)
    select md5('c:'||r.id||':rent')::uuid, org, br, r.id, 'rent', 'أجرة '||r.check_in||' → '||r.check_out,
           r.check_out - r.check_in, r.nightly_rate_halalas, r.rent_amount_halalas, true,
           r.check_in, r.check_out, r.created_by, r.created_at
    from reservations r where r.branch_id = br and r.rent_amount_halalas > 0;

    insert into reservation_charges(id, organization_id, branch_id, reservation_id, kind, description, quantity,
                                    unit_price_halalas, total_halalas, taxable, service_from, service_to, created_by, created_at)
    select md5('c:'||r.id||':tax')::uuid, org, br, r.id, 'tax', 'ضريبة القيمة المضافة 15%',
           1, r.taxes_halalas, r.taxes_halalas, false,
           r.check_in, r.check_out, r.created_by, r.created_at
    from reservations r where r.branch_id = br and r.taxes_halalas > 0;

    insert into reservation_charges(id, organization_id, branch_id, reservation_id, kind, description, quantity,
                                    unit_price_halalas, total_halalas, taxable, service_from, service_to, created_by, created_at)
    select md5('c:'||r.id||':addon')::uuid, org, br, r.id, 'addon', 'خدمة إضافية',
           1, 3000, 3000, true,
           r.check_in, r.check_out, r.created_by, r.created_at
    from reservations r where r.branch_id = br and abs(hashtext('adn:'||r.id::text)) % 20 < 3;

    -- housekeeping: a realistic open backlog plus today's completions
    insert into housekeeping_tasks(id, organization_id, branch_id, room_id, task_type_id, task_type_name_snapshot,
                                   priority, status, assignee_id, scheduled_start, completed_at, completed_by, created_by, created_at)
    select md5('hk:'||h||':'||b||':'||r)::uuid, org, br, md5('room:'||h||':'||b||':'||r)::uuid, tt, 'تنظيف',
           'medium',
           case when r % 6 = 0 then 'completed'
                when r % 6 = 1 then 'in_progress'
                else 'pending' end,
           null,
           current_timestamp - (r % 8) * interval '1 hour',
           case when r % 6 = 0 then current_timestamp - (r % 5) * interval '1 hour' end,
           case when r % 6 = 0 then sup_id end,
           sup_id, current_timestamp - interval '1 day'
    from generate_series(1, units) r;

    -- a modest expense trail so the account ledger is not receipts-only
    insert into expense_vouchers(id, organization_id, branch_id, number, account_id, category_id, amount_halalas,
                                 occurred_at, payee, description, status, idempotency_key, created_by, created_at)
    select md5('ev:'||h||':'||b||':'||e)::uuid, org, br,
           'E'||h||'-'||b||'-'||e, cash, ecat,
           5000 + (abs(hashtext('ev:'||h||':'||b||':'||e)) % 45000),
           ys + (abs(hashtext('evd:'||h||':'||b||':'||e)) % nd),
           'مورد اختبار', 'مصروف تشغيل '||e, 'approved',
           'load-ev-'||h||'-'||b||'-'||e, manager_id, ys + (abs(hashtext('evd:'||h||':'||b||':'||e)) % nd)
    from generate_series(1, 20) e;

    drop table _stays;
  end loop;

  -- second pass: room status mirrors today's in-house/reserved stays
  update rooms rm set status = 'occupied'
  where rm.organization_id = org and rm.id in (
    select a.room_id from reservation_allocations a join reservations r on r.id = a.reservation_id
    where a.branch_id in (select id from branches where organization_id = org)
      and a.status = 'active' and r.status = 'checked_in'
      and a.from_date <= current_date and a.to_date > current_date);
  update rooms rm set status = 'reserved'
  where rm.organization_id = org and rm.status = 'ready' and rm.id in (
    select a.room_id from reservation_allocations a join reservations r on r.id = a.reservation_id
    where a.branch_id in (select id from branches where organization_id = org)
      and a.status = 'active' and r.status in ('confirmed','pending_verification') and a.from_date = current_date);
end $$;

reset session_replication_role;
