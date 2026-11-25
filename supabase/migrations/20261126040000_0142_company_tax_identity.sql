-- 0142 (LOCAL DRAFT, NOT APPLIED, NOT REVIEWED): company VAT number and national address on a reservation.
-- Format checks mirror src/lib/buyerTax.ts. Needs a bounded safety review before it touches any real project.
alter table reservations
  add column if not exists company_vat_number text,
  add column if not exists company_address jsonb;

alter table reservations drop constraint if exists reservations_company_vat_chk;
alter table reservations add constraint reservations_company_vat_chk
  check (company_vat_number is null or company_vat_number ~ '^3[0-9]{13}3$');

create or replace function fn_staff_set_company_tax(p_reservation uuid, p_vat text, p_address jsonb, p_expected_version int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype;
begin
  perform fn_require_role('owner','manager','supervisor');
  select * into r from reservations where id = p_reservation for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  perform fn_require_branch(r.branch_id);
  perform fn_check_version_strict(r.version, p_expected_version);
  if p_vat is not null and p_vat !~ '^3[0-9]{13}3$' then raise exception 'VALIDATION: vat_number'; end if;
  if p_address is not null and not (
       coalesce(p_address->>'street','') <> ''
   and coalesce(p_address->>'city','') <> ''
   and coalesce(p_address->>'district','') <> ''
   and (p_address->>'building_number') ~ '^[0-9]{4}$'
   and (p_address->>'postal_code') ~ '^[0-9]{5}$') then raise exception 'VALIDATION: company_address'; end if;
  update reservations set company_vat_number = p_vat, company_address = p_address, version = version + 1 where id = r.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_staff_set_company_tax(uuid, text, jsonb, int) from public;
grant execute on function fn_staff_set_company_tax(uuid, text, jsonb, int) to authenticated;
