-- 0156: the company national address check accepted an address with no postal_code or no building_number (a missing key made the
-- regex test NULL, and the NOT of a NULL chain does not raise). The form (src/lib/buyerTax.ts) already requires both; the database now agrees.
-- Only the two NULL-safe coalesce() calls change; everything else in the function is as in 0142.
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
   and coalesce(p_address->>'building_number','') ~ '^[0-9]{4}$'
   and coalesce(p_address->>'postal_code','') ~ '^[0-9]{5}$') then raise exception 'VALIDATION: company_address'; end if;
  update reservations set company_vat_number = p_vat, company_address = p_address, version = version + 1 where id = r.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fn_staff_set_company_tax(uuid, text, jsonb, int) from public;
grant execute on function fn_staff_set_company_tax(uuid, text, jsonb, int) to authenticated;
