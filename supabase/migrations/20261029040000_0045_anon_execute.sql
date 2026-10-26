-- =====================================================================
-- 0045 — A visitor with no account calls only what the guest's own pages call.
--        Phase 7 hardening (G01, G02; the security advisor's «anon can execute SECURITY DEFINER function», 136 on the
--        hosted project). Every function here already refused a visitor inside (no staff session, no matrix cell), but
--        the door stood open: anything a guest page never calls now answers «permission denied» before it runs.
--        The guest's pages call thirteen: the phone lookup (phone + code, or phone + booking number), the phone's
--        bookings, the guest session and its data, the arrival request and the door code, «ملخص الإقامة» and its
--        acceptance, the branch as a guest page shows it (with its logo and image and its WhatsApp). The older lookup
--        by booking number + the phone's last four digits (fn_guest_lookup) is called by no page now and closes too.
--        The thirteen keep EXECUTE for anon; every other function in public loses it, with the PUBLIC grant anon
--        inherits. Signed-in staff (authenticated) and the Edge Functions (service_role) keep exactly what they had,
--        function by function (checked below). A function created later and not meant for guests revokes PUBLIC and
--        anon in its own migration; tests/sql/acceptance_tests.sql AX01 holds the guest list and fails on anything else.
--        Changes no data.
-- =====================================================================
do $$
declare
  f record;
  guest text[] := array['fn_guest_phone_verify', 'fn_guest_phone_verify_ref', 'fn_guest_phone_reservations',
                        'fn_guest_phone_open', 'fn_guest_session', 'fn_guest_submit', 'fn_guest_submit_checkin', 'fn_guest_access_code',
                        'fn_guest_stay_summary', 'fn_guest_acknowledge', 'fn_public_branch', 'fn_branch_media', 'fn_public_whatsapp'];
  auth_before oid[]; auth_after oid[]; n int := 0;
begin
  select coalesce(array_agg(p.oid order by p.oid), '{}') into auth_before from pg_proc p
   where p.pronamespace = 'public'::regnamespace and has_function_privilege('authenticated', p.oid, 'execute')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
              and has_function_privilege('anon', p.oid, 'execute') loop
    -- authenticated may hold EXECUTE through PUBLIC alone: give it its own grant before PUBLIC's goes
    if has_function_privilege('authenticated', f.sig, 'execute') then execute format('grant execute on function %s to authenticated', f.sig); end if;
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname = any(guest) then execute format('grant execute on function %s to anon', f.sig); else n := n + 1; end if;
  end loop;
  select coalesce(array_agg(p.oid order by p.oid), '{}') into auth_after from pg_proc p
   where p.pronamespace = 'public'::regnamespace and has_function_privilege('authenticated', p.oid, 'execute')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  if auth_after <> auth_before then raise exception '0045: signed-in staff would lose or gain a function (% → % functions)', cardinality(auth_before), cardinality(auth_after); end if;
  if (select count(distinct p.proname) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = any(guest)
        and has_function_privilege('anon', p.oid, 'execute')) <> cardinality(guest) then
    raise exception '0045: a guest function is missing or not reachable';
  end if;
  raise notice '0045: % functions closed to visitors with no account; % kept for the guest pages', n, cardinality(guest);
end $$;

-- functions created from now on are not granted to anon by name; PUBLIC's built-in grant still reaches it, so a new
-- migration revokes it as here — and AX01 fails the suite if a function outside the guest list reaches anon
alter default privileges in schema public revoke execute on functions from anon;
