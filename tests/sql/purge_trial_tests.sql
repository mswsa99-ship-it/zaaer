-- =====================================================================
-- The trial data (TD*; migrations 0072 and 0073): the example catalogue stays until the owner erases it, a trial
-- item the owner edits becomes theirs, and «مسح كل بيانات التجربة» (every branch, the whole period, every kind)
-- erases what the trial left — the stays and their money, the journal's entries of that money, the closings, the
-- expenses, the bank's movements and matching, the product orders, the journey's records, the alerts — while the
-- guests imported from Zaaer, the stays in the house or to come, the opening balances and the owner's own items
-- stay. Run last: it erases the test database's data.
-- =====================================================================
\set ON_ERROR_STOP off
create temp table test_results(name text, ok boolean, detail text);
grant all on test_results to public;
create temp table notes(k text primary key, v text);
grant all on notes to public;
create or replace function td_record(p_name text, p_ok boolean, p_detail text default null) returns void language sql security definer as $$
  insert into test_results values (p_name, p_ok, p_detail);
$$;
create or replace function td_note(p_k text) returns text language sql security definer as $$ select v from notes where k = p_k $$;
create or replace function td_login(p_uid uuid, p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email)::text, false);
end $$;

-- ---------------------------------------------------------------- TD01–TD02 the example catalogue
insert into organizations(id, name_ar) values ('00000000-0000-0000-0000-0000000000d1', 'منشأة التجربة') on conflict do nothing;
insert into branches(id, organization_id, name_ar) values ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d1', 'فرع التجربة') on conflict do nothing;
insert into notes values ('seed1', fn_seed_sample_products('00000000-0000-0000-0000-0000000000d1')::text);
insert into notes values ('seed2', fn_seed_sample_products('00000000-0000-0000-0000-0000000000d1')::text);
insert into notes values ('seed_org1', fn_seed_sample_products('00000000-0000-0000-0000-000000000001')::text);
select td_record('TD01 an organisation with no product gets the example catalogue once — 3 categories and 12 items, marked as trial data and offered in its branches; one that has products gets nothing',
  td_note('seed1') = '12' and td_note('seed2') = '0' and td_note('seed_org1') = '0'
  and (select count(*) from product_categories where organization_id = '00000000-0000-0000-0000-0000000000d1' and is_sample) = 3
  and (select count(*) from products where organization_id = '00000000-0000-0000-0000-0000000000d1' and is_sample) = 12
  and (select count(*) from product_branches where branch_id = '00000000-0000-0000-0000-0000000000d2' and available) = 12);
-- (the organisation of the checks gets its own example catalogue next to the owner's items)
update products set is_sample = false where organization_id = '00000000-0000-0000-0000-000000000001';
insert into product_categories(organization_id, name, sort_order, is_sample) values ('00000000-0000-0000-0000-000000000001', 'فئة تجريبية', 900, true);
insert into products(organization_id, category_id, name, price_halalas, is_sample)
select '00000000-0000-0000-0000-000000000001', id, 'منتج تجريبي ' || g, 100 * g, true from product_categories, generate_series(1, 3) g
 where organization_id = '00000000-0000-0000-0000-000000000001' and name = 'فئة تجريبية';
select td_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare x products%rowtype; s jsonb; begin
  select * into x from products where name = 'منتج تجريبي 1';
  perform fn_admin_set_product_branch(x.id, '00000000-0000-0000-0000-000000000010', true);
  insert into notes values ('after_switch', (select is_sample::text from products where id = x.id));
  perform fn_admin_upsert_product(jsonb_build_object('id', x.id, 'version', x.version, 'name', x.name, 'category_id', x.category_id, 'price_halalas', 150));
  s := fn_admin_products();
  perform td_record('TD02 a trial item offered in a branch stays trial data; once the owner edits it, it is theirs; the settings show which items are trial data',
    td_note('after_switch') = 'true' and not (select is_sample from products where id = x.id)
    and exists (select 1 from jsonb_array_elements(s->'products') p where p->>'name' = 'منتج تجريبي 2' and (p->>'is_sample')::boolean)
    and exists (select 1 from jsonb_array_elements(s->'products') p where p->>'name' = 'منتج تجريبي 1' and not (p->>'is_sample')::boolean),
    td_note('after_switch'));
exception when others then perform td_record('TD02 a trial item the owner edits becomes theirs', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- the trial: a stay that ended, with its money and orders, an expense, the bank, the journey
create temp table ids(k text primary key, v uuid);
grant all on ids to public;
create or replace function td_id(p_k text) returns uuid language sql security definer as $$ select v from ids where k = p_k $$;
create or replace function td_today(p uuid) returns date language sql security definer as $$ select fn_branch_today(p) $$;
create or replace function td_fin(p uuid) returns jsonb language sql security definer as $$ select fn_reservation_finance_internal(p) $$;
create or replace function td_acc(p_branch uuid, p_kind text) returns uuid language sql security definer as $$
  select id from cash_accounts where branch_id = p_branch and kind::text = p_kind order by created_at limit 1 $$;
create or replace function td_check_in(p uuid, p_room uuid) returns void language sql security definer as $$
  update reservations set status = 'checked_in', room_id = p_room, actual_check_in = now() where id = p $$;
create or replace function td_shift(p uuid, p_days int) returns void language plpgsql security definer as $$
begin
  update reservation_allocations set from_date = from_date + p_days, to_date = to_date + p_days where reservation_id = p;
  update reservation_nights set night = night + p_days where reservation_id = p;
  update reservation_charges set service_from = service_from + p_days, service_to = service_to + p_days where reservation_id = p;
  update reservations set check_in = check_in + p_days, check_out = check_out + p_days where id = p;
end $$;
select td_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare r jsonb; b uuid; cat uuid; room uuid; res uuid; pc uuid; pr uuid; o jsonb; ec uuid; begin
  r := fn_admin_upsert_branch('{"name_ar":"فرع بيانات التجربة","name_en":"Trial data branch"}'); b := (r->>'id')::uuid; insert into ids values ('b', b);
  r := fn_admin_upsert_room_category(jsonb_build_object('branch_id', b, 'name_ar', 'غرفة التجربة', 'base_price_halalas', 10000)); cat := (r->>'id')::uuid;
  r := fn_admin_upsert_room(jsonb_build_object('branch_id', b, 'category_id', cat, 'room_number', '991')); room := (r->>'id')::uuid; insert into ids values ('room', room);
  r := fn_staff_create_reservation(jsonb_build_object('branch_id', b, 'category_id', cat, 'check_in', td_today(b)::text, 'check_out', (td_today(b) + 1)::text,
         'guest_phone', '0559100001', 'guest_name', 'نزيل التجربة', 'room_id', room, 'source_id', '00000000-0000-0000-0000-000000000021'));
  res := (r->>'id')::uuid; insert into ids values ('res', res);
  r := fn_create_voucher(jsonb_build_object('reservation_id', res, 'kind', 'receipt', 'amount_halalas', (td_fin(res)->>'total')::bigint, 'method', 'cash', 'idempotency_key', 'td-rent'));
  insert into ids values ('voucher', (r->>'voucher_id')::uuid);
  perform td_check_in(res, room);
  r := fn_admin_upsert_product_category('{"name":"فئة بيانات التجربة"}'); pc := (r->>'id')::uuid;
  r := fn_admin_upsert_product(jsonb_build_object('category_id', pc, 'name', 'منتج بيانات التجربة', 'price_halalas', 300)); pr := (r->>'id')::uuid;
  perform fn_admin_set_product_branch(pr, b, true);
  o := fn_staff_create_product_order(res, jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 1)));
  perform fn_staff_pay_product_order(jsonb_build_object('order_id', o->>'id', 'method', 'cash', 'idempotency_key', 'td-order', 'expected_version', (o->>'version')::int));
  r := fn_staff_check_out(jsonb_build_object('reservation_id', res, 'early_departure', 'keep', 'reason', 'تجربة'));
  r := fn_admin_upsert_expense_category('{"name":"مصروف التجربة"}'); ec := (r->>'id')::uuid;
  r := fn_expense_create(jsonb_build_object('branch_id', b, 'account_id', td_acc(b, 'cash_box'), 'category_id', ec, 'amount_halalas', 2500, 'description', 'مصروف تجريبي',
         'payee', 'محل', 'idempotency_key', 'td-exp', 'attachments', jsonb_build_array(jsonb_build_object('data_base64', encode('\x89504e470d0a1a0a0000000d49484452'::bytea, 'base64'), 'file_name', 'إيصال.png'))));
exception when others then insert into test_results values ('TD00 the trial is set up', false, sqlerrm);
end $$;
reset role;
-- the stay ended three days ago; the bank's message and movement of its payment, matched; its journey's records; a draft closing
select td_shift(td_id('res'), -3);
do $$ declare msg uuid; mv uuid; mt uuid; b uuid := td_id('b'); begin
  insert into bank_messages(organization_id, raw_body, content_hash, status, received_at) values ('00000000-0000-0000-0000-000000000001', 'إيداع تجريبي', md5('td-bank'), 'parsed', now() - interval '3 days')
  returning id into msg;
  insert into bank_movements(organization_id, branch_id, cash_account_id, message_id, kind, direction, amount_halalas, occurred_at, dedupe_key, status)
  values ('00000000-0000-0000-0000-000000000001', b, td_acc(b, 'bank_account'), msg, 'deposit', 'in', 10000, now() - interval '3 days', 'td-bank-1', 'matched') returning id into mv;
  update bank_messages set movement_id = mv where id = msg;
  insert into bank_matches(organization_id, movement_id, kind, active) values ('00000000-0000-0000-0000-000000000001', mv, 'link', true) returning id into mt;
  insert into bank_match_items(organization_id, match_id, target_type, target_id, amount_halalas, active) values ('00000000-0000-0000-0000-000000000001', mt, 'voucher', td_id('voucher'), 10000, true);
  insert into guest_reviews(organization_id, branch_id, reservation_id, token_hash, submitted_at, overall, staff, cleanliness, comfort, facilities, value, location)
  values ('00000000-0000-0000-0000-000000000001', b, td_id('res'), md5('td-review') || md5('x'), now(), 8, 8, 8, 8, 8, 8, 8);
  insert into journey_messages(organization_id, branch_id, reservation_id, kind, status, reason) values ('00000000-0000-0000-0000-000000000001', b, td_id('res'), 'review_invite', 'skipped', 'no_phone');
  insert into stay_extension_requests(organization_id, branch_id, reservation_id, kind, amount_halalas, status, source) values ('00000000-0000-0000-0000-000000000001', b, td_id('res'), 'night', 10000, 'released', 'page');
  insert into alert_events(organization_id, branch_id, event, ref_key, reservation_id, title) values ('00000000-0000-0000-0000-000000000001', b, 'review_low', 'td:' || td_id('res'), td_id('res'), 'تنبيه تجريبي');
  insert into day_closings(organization_id, branch_id, business_date) values ('00000000-0000-0000-0000-000000000001', b, td_today(b) - 3);
exception when others then insert into test_results values ('TD00b the trial''s bank, journey and closing are set up', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------- TD03 what «مسح كل بيانات التجربة» will take
-- a guest imported from Zaaer, with no stay
insert into guest_profiles(organization_id, full_name, phone, notes, imported_at)
values ('00000000-0000-0000-0000-000000000001', 'ضيف من زائر', '0559000001', 'مستورد من زائر', now() - interval '20 days');
select td_login('a0000000-0000-0000-0000-000000000001', 'owner@test.local');
set role authenticated;
do $$ declare o jsonb; begin
  o := fn_admin_trial_overview();
  insert into notes values ('overview', o::text);
  perform td_record('TD03 the page counts what the trial left before the owner chooses: stays, vouchers, the journal''s entries, bank movements, product orders, trial items, and the imported guests that stay',
    (o->>'reservations')::int > 0 and (o->>'vouchers')::int > 0 and (o->>'journal_entries')::int > 0 and (o->>'sample_products')::int = 2
    and (o->>'guests_imported')::int >= 1 and o->>'first_day' is not null and (o->>'paste_applied')::boolean,
    o::text);
exception when others then perform td_record('TD03 the page counts what the trial left', false, sqlerrm);
end $$;
reset role;

-- ---------------------------------------------------------------- TD04 erased: everything of the trial, nothing of the hotel
create temp table kept as
select (select count(*) from reservations r where r.organization_id = '00000000-0000-0000-0000-000000000001'
          and not (r.status in ('checked_out', 'closed', 'cancelled', 'rejected', 'no_show')
                   or (r.status in ('draft', 'pending_verification', 'confirmed') and r.check_out < fn_branch_today(r.branch_id)))) as live_stays,
       (select count(*) from guest_profiles where organization_id = '00000000-0000-0000-0000-000000000001' and imported_at is not null) as imported,
       (select count(*) from journal_entries where organization_id = '00000000-0000-0000-0000-000000000001' and source_type = 'opening') as openings,
       (select count(*) from products where organization_id = '00000000-0000-0000-0000-000000000001' and not is_sample) as own_products,
       (select count(*) from rooms r join branches b on b.id = r.branch_id where b.organization_id = '00000000-0000-0000-0000-000000000001') as rooms;
grant select on kept to public;
do $$ declare c jsonb; v_from date; begin
  select least(min(check_in), min((created_at at time zone 'Asia/Riyadh')::date)) into v_from from reservations where organization_id = '00000000-0000-0000-0000-000000000001';
  c := fn_purge_run('00000000-0000-0000-0000-000000000001', null, least(v_from, current_date - 400), fn_branch_today('00000000-0000-0000-0000-000000000010'), fn_purge_categories());
  insert into notes values ('counts', c::text);
exception when others then insert into notes values ('counts', 'ERROR ' || sqlerrm);
end $$;
select td_record('TD04 «مسح كل بيانات التجربة» runs to its end over every branch, the whole period and every kind, and says what it took — the stays, the vouchers and their journal entries, the closings, the expenses, the bank''s messages, movements and matches, the product orders, the reviews, the alerts and the trial items',
  td_note('counts') not like 'ERROR%' and (td_note('counts')::jsonb->>'reservations')::int >= 1 and (td_note('counts')::jsonb->>'vouchers')::int >= 2
  and (td_note('counts')::jsonb->>'journal_entries')::int >= 3 and (td_note('counts')::jsonb->>'sample_products')::int = 2
  and (td_note('counts')::jsonb->>'day_closings')::int >= 1 and (td_note('counts')::jsonb->>'expense_vouchers')::int >= 1
  and (td_note('counts')::jsonb->>'bank_movements')::int >= 1 and (td_note('counts')::jsonb->>'bank_messages')::int >= 1 and (td_note('counts')::jsonb->>'bank_matches')::int >= 1
  and (td_note('counts')::jsonb->>'product_orders')::int >= 1 and (td_note('counts')::jsonb->>'guest_reviews')::int >= 1 and (td_note('counts')::jsonb->>'alerts')::int >= 0
  and not exists (select 1 from reservations where id = td_id('res')) and not exists (select 1 from alert_events where ref_key = 'td:' || td_id('res'))
  and not exists (select 1 from journey_messages where reservation_id = td_id('res')) and not exists (select 1 from stay_extension_requests where reservation_id = td_id('res')),
  td_note('counts'));
select td_record('TD05 nothing of the hotel goes: the stays in the house or to come, the guests imported from Zaaer, the opening balances, the owner''s own items, the units',
  (select live_stays from kept) = (select count(*) from reservations r where r.organization_id = '00000000-0000-0000-0000-000000000001'
          and not (r.status in ('checked_out', 'closed', 'cancelled', 'rejected', 'no_show')
                   or (r.status in ('draft', 'pending_verification', 'confirmed') and r.check_out < fn_branch_today(r.branch_id))))
  and (select imported from kept) = (select count(*) from guest_profiles where organization_id = '00000000-0000-0000-0000-000000000001' and imported_at is not null)
  and (select openings from kept) = (select count(*) from journal_entries where organization_id = '00000000-0000-0000-0000-000000000001' and source_type = 'opening')
  and (select own_products from kept) = (select count(*) from products where organization_id = '00000000-0000-0000-0000-000000000001' and not is_sample)
  and (select rooms from kept) = (select count(*) from rooms r join branches b on b.id = r.branch_id where b.organization_id = '00000000-0000-0000-0000-000000000001'),
  (select row_to_json(kept)::text from kept));
select td_record('TD06 nothing points to what went: no journal entry to a voucher, an expense, a closing, a bank movement or a payout that is gone; the books still balance; no order, journey record, review, extension or alert to a stay that is gone; no bank match to a target that is gone',
  not exists (select 1 from journal_entries e where e.organization_id = '00000000-0000-0000-0000-000000000001' and (
      (e.source_type = 'voucher' and not exists (select 1 from financial_vouchers v where v.id = e.source_id))
   or (e.source_type = 'expense' and not exists (select 1 from expense_vouchers v where v.id = e.source_id))
   or (e.source_type = 'day_closing' and not exists (select 1 from day_closings v where v.id = e.source_id))
   or (e.source_type = 'bank_movement' and not exists (select 1 from bank_movements v where v.id = e.source_id))
   or (e.source_type = 'payout' and not exists (select 1 from platform_payouts v where v.id = e.source_id))))
  and (select coalesce(sum(debit_halalas), 0) = coalesce(sum(credit_halalas), 0) from journal_lines l join journal_entries e on e.id = l.entry_id where e.organization_id = '00000000-0000-0000-0000-000000000001')
  and not exists (select 1 from product_orders o where not exists (select 1 from reservations r where r.id = o.reservation_id))
  and not exists (select 1 from journey_messages o where not exists (select 1 from reservations r where r.id = o.reservation_id))
  and not exists (select 1 from guest_reviews o where not exists (select 1 from reservations r where r.id = o.reservation_id))
  and not exists (select 1 from stay_extension_requests o where not exists (select 1 from reservations r where r.id = o.reservation_id))
  and not exists (select 1 from alert_events o where o.reservation_id is not null and not exists (select 1 from reservations r where r.id = o.reservation_id))
  and not exists (select 1 from bank_match_items i where i.active and i.target_type = 'voucher' and not exists (select 1 from financial_vouchers v where v.id = i.target_id))
  and not exists (select 1 from bank_movements m where m.status = 'matched' and not exists (select 1 from bank_matches mt where mt.movement_id = m.id and mt.active)));
select td_record('TD07 the trial''s bank messages, closings and expenses are gone with the period, and the trial items too',
  (select count(*) from bank_messages where organization_id = '00000000-0000-0000-0000-000000000001') = 0
  and (select count(*) from day_closings dc join branches b on b.id = dc.branch_id where b.organization_id = '00000000-0000-0000-0000-000000000001') = 0
  and (select count(*) from expense_vouchers where organization_id = '00000000-0000-0000-0000-000000000001') = 0
  and (select count(*) from products where organization_id = '00000000-0000-0000-0000-000000000001' and is_sample) = 0
  and (select count(*) from product_categories where organization_id = '00000000-0000-0000-0000-000000000001' and name = 'فئة تجريبية') = 1,
  (select count(*)::text from bank_messages where organization_id = '00000000-0000-0000-0000-000000000001'));
select td_record('TD08 the other organisation''s data is untouched (its example catalogue stays)',
  (select count(*) from products where organization_id = '00000000-0000-0000-0000-0000000000d1' and is_sample) = 12);

-- ---------------------------------------------------------------- results
\set ON_ERROR_STOP on
select case when ok then 'PASS' else 'FAIL' end as result, name, left(coalesce(detail, ''), 600) as detail from test_results order by name;
do $$
declare n int; f int;
begin
  select count(*), count(*) filter (where not ok) into n, f from test_results;
  if f > 0 then raise exception 'TRIAL DATA TESTS FAILED: % of %', f, n; end if;
  if n < 8 then raise exception 'TRIAL DATA TESTS INCOMPLETE: % of 8 checks ran', n; end if;
end $$;
