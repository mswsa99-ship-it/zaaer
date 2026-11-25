-- 0144: narrow grants only, nothing is widened and no data is touched.
--  1. The staff assistant is read-only: its three proposal functions are no longer callable by signed-in staff.
--     (The assistant no longer offers any write tool; this closes the direct RPC path that a signed-in person could
--     still call with their own session.)
--  2. Guest phone, birth date and document tail, and the reservation's government reference, company name and
--     platform-collects flag, are no longer selectable straight from the tables. The app reads them through
--     fn_reservation_detail, which masks them by role.
-- Security-definer functions are unaffected (they run as the owner). payment_status is NOT changed here: the cards
-- and dashboard still read it directly and need a role-aware source first (tracked, next cycle).
-- Rollback: supabase/rollback/0144_rollback.sql.

revoke execute on function public.fn_ai_ops_propose(uuid, text, jsonb, text) from authenticated, anon, public;
revoke execute on function public.fn_ai_ops_execute_proposal(uuid) from authenticated, anon, public;
revoke execute on function public.fn_ai_ops_reject_proposal(uuid, text) from authenticated, anon, public;

revoke select (phone, birth_date, identity_number_last4) on public.reservation_guests from authenticated;
revoke select (gov_registration_ref, company_name, platform_collects) on public.reservations from authenticated;
