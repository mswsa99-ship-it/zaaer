-- 0061 — Phase 5 of the 31 October review, adopted by recommendation (the owner: «اعتمد الباقي بالتوصية»):
--   COPY-11  the server's own texts count nights in Arabic: «ليلة واحدة», «ليلتان», «4 ليالٍ», «11 ليلة».
--   COPY-12  one money format on the server too: «1,600.00 ر.س» (grouped), as on every screen.
--   MONEY-08 a price change without a description is named in Arabic («خصم», «تسوية», «غرامة»), never its code.
--   SEC-07   once the main guest's phone is recorded, the guest's link cannot change it (the reception can): a leaked
--            link no longer turns into lasting access through «حجوزاتي» on another phone.
--   SEC-08   the phone + booking-number lookup counts its attempts one at a time per phone, so parallel tries cannot
--            pass the limit of 5 together.
--   PERM-09  nightly prices are quoted only to a role that books, prices, extends or moves a stay; the reports' filter
--            lists (boxes, accounts, staff) only to a role that sees money.
-- The functions that write those texts keep everything else as it is: each is re-created from its current
-- definition with only the counted phrase changed, and the block stops if the phrase is not found exactly once.

create or replace function fn_ar_nights(n integer) returns text language sql immutable set search_path = public as $$
  select case when n = 1 then 'ليلة واحدة' when n = 2 then 'ليلتان'
              when abs(n) % 100 between 3 and 10 then n || ' ليالٍ' else n || ' ليلة' end
$$;
revoke all on function fn_ar_nights(integer) from public, anon;
grant execute on function fn_ar_nights(integer) to authenticated, service_role;

create or replace function fn_sar_text(p bigint) returns text language sql immutable set search_path = public as $$
  select to_char(coalesce(p, 0) / 100.0, 'FM999,999,999,990.00') || ' ر.س';
$$;

do $$
declare
  fixes constant text[][] := array[
    array['fn_book_nights', $a$p_label || ' ' || (x->>'nights') || ' ليلة × ' || to_char((x->>'price')::bigint / 100.0, 'FM9999999990.00') || ' ر.س'$a$,
                            $b$p_label || ' ' || fn_ar_nights((x->>'nights')::int) || ' × ' || fn_sar_text((x->>'price')::bigint)$b$],
    array['fn_shorten_for_departure', $a$'مغادرة مبكرة: ' || abs(delta) || ' ليلة لم تُستخدم'$a$,
                                      $b$'مغادرة مبكرة: ' || fn_ar_nights(abs(delta)) || ' لم تُستخدم'$b$],
    array['fn_staff_amend_stay', $a$'تقصير الإقامة ' || abs(delta) || ' ليلة'$a$,
                                 $b$'تقصير الإقامة ' || fn_ar_nights(abs(delta))$b$],
    array['fn_staff_check_out', $a$'مغادرة قبل موعدها: ' || v_unused || ' ليلة مدفوعة أو محجوزة لم تُستخدم.$a$,
                                $b$'مغادرة قبل موعدها: ليالٍ مدفوعة أو محجوزة لم تُستخدم (' || v_unused || ').$b$],
    array['fn_staff_adjust_price', $a$coalesce(nullif(trim(p_description),''), p_kind)$a$,
                                   $b$coalesce(nullif(trim(p_description),''), case p_kind when 'discount' then 'خصم' when 'adjustment' then 'تسوية' when 'penalty' then 'غرامة' when 'addon' then 'إضافة' else p_kind end)$b$],
    array['fn_guest_submit', $a$phone = coalesce(v_phone, phone),$a$,
                             $b$phone = case when g.is_primary and g.phone is not null then g.phone else coalesce(v_phone, phone) end,$b$],
    array['fn_guest_phone_verify_ref', $a$  if (select count(*) from guest_lookup_attempts where external_ref = 'PHONE:' || v_phone$a$,
                                       $b$  perform pg_advisory_xact_lock(hashtext('lookup:' || v_phone));
  if (select count(*) from guest_lookup_attempts where external_ref = 'PHONE:' || v_phone$b$],
    array['fn_report_filter_options', $a$select case when p_branch in (select fn_user_branch_ids()) then$a$,
                                      $b$select case when p_branch in (select fn_user_branch_ids()) and fn_sees_money() then$b$]
  ];
  i int; fn oid; def text; n int;
begin
  for i in 1 .. array_length(fixes, 1) loop
    select p.oid into fn from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = fixes[i][1];
    if fn is null then raise exception '0061: % is missing', fixes[i][1]; end if;
    def := pg_get_functiondef(fn);
    n := (length(def) - length(replace(def, fixes[i][2], ''))) / length(fixes[i][2]);
    if n <> 1 then raise exception '0061: the counted phrase of % was found % times, not once', fixes[i][1], n; end if;
    execute replace(def, fixes[i][2], fixes[i][3]);
  end loop;
end $$;

-- PERM-09: the quote of a stay (nightly prices) for the roles that book, price, extend or move a stay only
create or replace function fn_staff_quote(p_branch uuid, p_category uuid, p_check_in date, p_check_out date, p_nightly_override bigint default null, p_discount_halalas bigint default 0)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when fn_can('res.create') or fn_can('rates') or fn_can('stay.extend') or fn_can('room.assign') then
    fn_quote_stay(jsonb_build_object('branch_id', p_branch, 'category_id', p_category, 'check_in', p_check_in, 'check_out', p_check_out,
                                     'nightly_rate_halalas', p_nightly_override, 'discount_halalas', coalesce(p_discount_halalas, 0)))
  end;
$$;

-- SEC-09: a visitor without an account reads only the branch columns the guest pages show (the internal settings —
-- discount limits, deposits, archive reasons, e-mail — are not theirs to read)
revoke select on branches from anon;
grant select (id, name_ar, name_en, check_in_time, check_out_time, tax_rate_bp, prices_include_tax, map_url, booking_platform_url,
              default_language, is_active, created_at) on branches to anon;
