-- restores exactly the grants 0144 removed (authenticated only)
grant execute on function public.fn_ai_ops_propose(uuid, text, jsonb, text) to authenticated;
grant execute on function public.fn_ai_ops_execute_proposal(uuid) to authenticated;
grant execute on function public.fn_ai_ops_reject_proposal(uuid, text) to authenticated;
grant select (phone, birth_date, identity_number_last4) on public.reservation_guests to authenticated;
grant select (gov_registration_ref, company_name, platform_collects) on public.reservations to authenticated;
