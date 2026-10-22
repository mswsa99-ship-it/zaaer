/*
# Demo Seed Data

Creates a demo organization "منازل الراحة", one branch with 10 rooms across
2 categories, booking sources, release rules, inventory, keyboxes, and several
reservation scenarios. No real identities or payment data.

Also creates a demo staff user record (auth user must be created from the app
sign-up; this seed only creates the staff_profile row placeholder keyed by email
so the app can link it after sign-up).
*/

-- Organization
insert into organizations (id, name_ar, name_en, license_number, license_status)
values ('00000000-0000-0000-0000-000000000001', 'منازل الراحة', 'Comfort Homes', 'HSP-DEMO-001', 'active')
on conflict (id) do nothing;

-- Branch
insert into branches (id, organization_id, name_ar, name_en, city, address, phone, email, check_in_time, check_out_time, is_active)
values ('00000000-0000-0000-0000-000000000010',
        '00000000-0000-0000-0000-000000000001',
        'فرع الرياض - طريق الملك فهد', 'Riyadh - King Fahd Rd',
        'الرياض', 'طريق الملك فهد، الرياض', '+966500000000', 'demo@manazelarraha.sa',
        '16:00', '12:00', true)
on conflict (id) do nothing;

-- Booking sources
insert into booking_sources (id, organization_id, name, booking_url, is_active) values
  ('00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', 'Booking.com', 'https://www.booking.com/hotel/sa/manazel.html', true),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000001', 'مباشر (استقبال)', null, true)
on conflict (id) do nothing;

-- Room categories
insert into room_categories (id, branch_id, organization_id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, amenities, is_public, is_active, sort_order) values
  ('00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001',
   'استوديو مريح', 'Cozy Studio', 'استوديو بمساحة 35م مع مطبخ مجهز وحمام خاص', 2, 3, 25000, array['واي فاي','مكياج','تكييف','مطبخ'], true, true, 1),
  ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001',
   'شقة بغرفة نوم', 'One Bedroom Apartment', 'شقة بغرفة نوم وصالة ومطبخ وحمامين', 3, 5, 40000, array['واي فاي','مكياج','تكييف','مطبخ','غسالة','صالة'], true, true, 2)
on conflict (id) do nothing;

-- Rooms: 7 studios, 3 one-bedroom apartments
insert into rooms (id, branch_id, organization_id, category_id, room_number, floor, status) values
  ('00000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000030', '101', 1, 'available'),
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000030', '102', 1, 'available'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000030', '103', 1, 'available'),
  ('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000030', '104', 1, 'available'),
  ('00000000-0000-0000-0000-000000000104', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000030', '201', 2, 'available'),
  ('00000000-0000-0000-0000-000000000105', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000030', '202', 2, 'available'),
  ('00000000-0000-0000-0000-000000000106', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000030', '203', 2, 'maintenance'),
  ('00000000-0000-0000-0000-000000000107', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000031', '301', 3, 'available'),
  ('00000000-0000-0000-0000-000000000108', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000031', '302', 3, 'available'),
  ('00000000-0000-0000-0000-000000000109', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000031', '303', 3, 'available')
on conflict (id) do nothing;

-- Keyboxes for each room (code stored encrypted; demo code 1234 for room 101 only as a known test)
insert into keyboxes (room_id, branch_id, code_encrypted, code_version, code_status, last_changed_at, field_tested, requires_rotation)
select r.id, r.branch_id, pgp_sym_encrypt('1234', 'demo-keybox-key-v1'), 1, 'active', now(), true, true
from rooms r where r.room_number = '101'
on conflict do nothing;

insert into keyboxes (room_id, branch_id, code_encrypted, code_version, code_status, last_changed_at, field_tested, requires_rotation)
select r.id, r.branch_id, pgp_sym_encrypt('0000', 'demo-keybox-key-v1'), 1, 'active', now(), true, true
from rooms r where r.room_number in ('102','103','104','201','202','301','302','303')
on conflict do nothing;

-- Keybox for maintenance room 203 — needs change
insert into keyboxes (room_id, branch_id, code_encrypted, code_version, code_status, last_changed_at, field_tested, requires_rotation)
select r.id, r.branch_id, pgp_sym_encrypt('0000', 'demo-keybox-key-v1'), 1, 'needs_change', now(), false, true
from rooms r where r.room_number = '203'
on conflict do nothing;

-- Release rules: studio enabled with initial 1, increment 1
insert into release_rules (branch_id, category_id, enabled, initial_public_release, release_increment, release_trigger) values
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000030', true, 1, 1, 'access_delivered'),
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000031', false, 3, 1, 'manual')
on conflict (branch_id, category_id) do nothing;

-- Inventory for next 14 days: 7 studios total (block 1 for maintenance), 3 apartments
do $$
declare
  d date := current_date;
begin
  for i in 0..13 loop
    insert into inventory_periods (branch_id, category_id, date, total_units, publicly_visible_units, blocked_units)
    values ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000030', d + i, 6, 1, 1)
    on conflict (branch_id, category_id, date) do nothing;
    insert into inventory_periods (branch_id, category_id, date, total_units, publicly_visible_units, blocked_units)
    values ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000031', d + i, 3, 3, 0)
    on conflict (branch_id, category_id, date) do nothing;
  end loop;
end $$;

-- Released slots: studio starts at 1
insert into released_slots (branch_id, category_id, date, released_count)
select '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000030', current_date + i, 1
from generate_series(0, 13) i
on conflict (branch_id, category_id, date) do nothing;

-- ============ RESERVATION SCENARIOS ============
-- Scenario 1: Confirmed booking, identity verified, payment paid, room ready, access approved (ready for key delivery)
-- Use room 102, studio, checking in today
insert into reservations (id, organization_id, branch_id, external_ref, source_id, status, booking_type,
  check_in, check_out, adults, companions, room_category_id, room_id,
  rent_amount_halalas, taxes_halalas, total_halalas, paid_halalas,
  payment_status, identity_status, government_registration, access_status, created_at)
values ('00000000-0000-0000-0000-000000000200',
  '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010',
  'BK-DEMO-1001', '00000000-0000-0000-0000-000000000020', 'confirmed', 'individual',
  current_date, current_date + 2, 2, 1,
  '00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000101',
  50000, 7500, 57500, 57500,
  'paid', 'verified', true, 'approved', now())
on conflict (id) do nothing;

-- Update room 102 to reserved
update rooms set status = 'reserved' where id = '00000000-0000-0000-0000-000000000101';

-- Primary guest for scenario 1
insert into guest_profiles (id, full_name, phone, nationality) values
  ('00000000-0000-0000-0000-000000000300', 'أحمد محمد العتيبي', '+966500000111', 'سعودي')
on conflict (id) do nothing;

insert into reservation_guests (id, reservation_id, guest_profile_id, is_primary, full_name, identity_type,
  identity_number_encrypted, identity_number_last4, nationality, birth_date, phone, phone_verified,
  relationship, verification_status, data_submitted)
values ('00000000-0000-0000-0000-000000000400',
  '00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000300', true,
  'أحمد محمد العتيبي', 'national_id',
  pgp_sym_encrypt('1098765432', 'demo-id-key-v1'), '5432', 'سعودي', '1990-05-15',
  '+966500000111', true, 'self', 'verified', true)
on conflict (id) do nothing;

-- Companion for scenario 1
insert into reservation_guests (id, reservation_id, is_primary, full_name, identity_type,
  identity_number_encrypted, identity_number_last4, nationality, birth_date, phone,
  relationship, verification_status, data_submitted)
values ('00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000200', false, 'سارة أحمد العتيبي', 'national_id',
  pgp_sym_encrypt('1098765433', 'demo-id-key-v1'), '5433', 'سعودي', '2018-03-20', null,
  'ابنة', 'verified', true)
on conflict (id) do nothing;

-- Payment for scenario 1
insert into payment_transactions (id, reservation_id, method, amount_halalas, status, provider, provider_ref, verified_at)
values ('00000000-0000-0000-0000-000000000500',
  '00000000-0000-0000-0000-000000000200', 'booking_platform', 57500, 'paid', 'Booking.com', 'BK-PAY-1001', now())
on conflict (id) do nothing;

-- Access release request for scenario 1
insert into access_release_requests (id, reservation_id, status, approved_at)
values ('00000000-0000-0000-0000-000000000600',
  '00000000-0000-0000-0000-000000000200', 'approved', now())
on conflict (id) do nothing;

-- ============ Scenario 2: Pending payment, identity not verified ============
insert into reservations (id, organization_id, branch_id, external_ref, source_id, status, booking_type,
  check_in, check_out, adults, companions, room_category_id,
  rent_amount_halalas, taxes_halalas, total_halalas, paid_halalas,
  payment_status, identity_status, government_registration, access_status, created_at)
values ('00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010',
  'BK-DEMO-1002', '00000000-0000-0000-0000-000000000020', 'confirmed', 'individual',
  current_date, current_date + 1, 1, 0,
  '00000000-0000-0000-0000-000000000030',
  25000, 3750, 28750, 0,
  'pending', 'data_submitted', false, 'locked', now())
on conflict (id) do nothing;

insert into guest_profiles (id, full_name, phone, nationality) values
  ('00000000-0000-0000-0000-000000000301', 'خالد عبدالله القحطاني', '+966500000222', 'سعودي')
on conflict (id) do nothing;

insert into reservation_guests (id, reservation_id, guest_profile_id, is_primary, full_name, identity_type,
  identity_number_encrypted, identity_number_last4, nationality, birth_date, phone, phone_verified,
  relationship, verification_status, data_submitted)
values ('00000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000301', true,
  'خالد عبدالله القحطاني', 'national_id',
  pgp_sym_encrypt('1023456789', 'demo-id-key-v1'), '6789', 'سعودي', '1985-11-10',
  '+966500000222', true, 'self', 'data_submitted', true)
on conflict (id) do nothing;

-- ============ Scenario 3: Data not submitted yet ============
insert into reservations (id, organization_id, branch_id, external_ref, source_id, status, booking_type,
  check_in, check_out, adults, companions, room_category_id,
  rent_amount_halalas, taxes_halalas, total_halalas, paid_halalas,
  payment_status, identity_status, government_registration, access_status, created_at)
values ('00000000-0000-0000-0000-000000000202',
  '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010',
  'BK-DEMO-1003', '00000000-0000-0000-0000-000000000021', 'confirmed', 'individual',
  current_date + 1, current_date + 3, 2, 0,
  '00000000-0000-0000-0000-000000000030',
  50000, 7500, 57500, 57500,
  'paid', 'not_started', false, 'locked', now())
on conflict (id) do nothing;

insert into guest_profiles (id, full_name, phone, nationality) values
  ('00000000-0000-0000-0000-000000000302', 'فهد ناصر الدوسري', '+966500000333', 'سعودي')
on conflict (id) do nothing;

insert into reservation_guests (id, reservation_id, guest_profile_id, is_primary, full_name,
  phone, phone_verified, relationship, verification_status, data_submitted)
values ('00000000-0000-0000-0000-000000000403',
  '00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000302', true,
  'فهد ناصر الدوسري', '+966500000333', true, 'self', 'not_started', false)
on conflict (id) do nothing;

-- ============ Scenario 4: Checked-in / occupied (room 104) ============
insert into reservations (id, organization_id, branch_id, external_ref, source_id, status, booking_type,
  check_in, check_out, adults, companions, room_category_id, room_id,
  rent_amount_halalas, taxes_halalas, total_halalas, paid_halalas,
  payment_status, identity_status, government_registration, access_status, keybox_delivered,
  actual_check_in, created_at)
values ('00000000-0000-0000-0000-000000000203',
  '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000010',
  'BK-DEMO-1004', '00000000-0000-0000-0000-000000000020', 'checked_in', 'individual',
  current_date - 1, current_date + 1, 1, 0,
  '00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000103',
  25000, 3750, 28750, 28750,
  'paid', 'verified', true, 'delivered', true, now() - interval '1 day', now())
on conflict (id) do nothing;

update rooms set status = 'occupied' where id = '00000000-0000-0000-0000-000000000103';

insert into guest_profiles (id, full_name, phone, nationality) values
  ('00000000-0000-0000-0000-000000000303', 'ماجد سعيد الحربي', '+966500000444', 'سعودي')
on conflict (id) do nothing;

insert into reservation_guests (id, reservation_id, guest_profile_id, is_primary, full_name, identity_type,
  identity_number_encrypted, identity_number_last4, nationality, birth_date, phone, phone_verified,
  relationship, verification_status, data_submitted)
values ('00000000-0000-0000-0000-000000000404',
  '00000000-0000-0000-0000-000000000203', '00000000-0000-0000-0000-000000000303', true,
  'ماجد سعيد الحربي', 'national_id',
  pgp_sym_encrypt('1055566778', 'demo-id-key-v1'), '6778', 'سعودي', '1988-01-25',
  '+966500000444', true, 'self', 'verified', true)
on conflict (id) do nothing;
