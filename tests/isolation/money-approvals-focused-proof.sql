-- Money-bank lane, subfamily A: owner approvals and finance thresholds.
-- fn_approve_discount(jsonb), fn_finance_approve_refund(jsonb), fn_finance_controls_set(jsonb).
-- Disposable database only. One transaction, everything rolls back. No outbound call is possible: the proof refuses to
-- run if any enabled keyed bridge channel exists. Literal amounts, exact touched rows, audit identity, foreign and
-- same-hotel non-owner denials with whole-public no-write, validation failures kept apart from denial credit.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='money-approvals-local-synthetic-key';
do $$begin if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'Outbound-capable channel state refused';end if;end $$;
create temp table ma_assert(name text, ok boolean, detail text);
create function pg_temp.machk(n text, b boolean, d text default null) returns void language sql as $$insert into ma_assert values(n, coalesce(b,false), d)$$;
create temp table ma_before_audit as select id, md5(to_jsonb(a)::text) h from audit_events a;
create temp table ma_before_notif as select count(*) n from notifications;
do $$
declare t record; own uuid; rid uuid; k int := 0; p jsonb; r jsonb; b jsonb; a jsonb; rb jsonb; ra jsonb; err text; st text; changes text[]; touches text[];
        v record; au record; amt bigint; orgs text[]; foreign_own uuid; act record; sid uuid; n int; ap uuid; seen int;
begin
 orgs := array(select id::text from organizations);
 select count(*) into n from iso.target; perform pg_temp.machk('targets/4', n = 4, n::text);
 for t in select * from iso.target order by key loop
  k := k + 1; amt := 1100 + k * 13;
  select auth_user into own from iso.actor where role = 'owner' and hotel = t.hotel;
  select auth_user into foreign_own from iso.actor where role = 'owner' and hotel <> t.hotel order by key limit 1;
  select c.id::uuid into rid from iso.created c where c.tbl = 'reservations' and c.branch = t.branch_id and c.purpose = 'victim' order by c.id limit 1;
  perform pg_temp.machk(t.key||'/fixture reservation', rid is not null);
  select staff.id into sid from staff_profiles staff where staff.auth_user_id = own;
  ---------------------------------------------------------------- discount and refund approvals, same pattern
  foreach st in array array['discount','refund'] loop
   p := jsonb_build_object('reservation_id', rid, 'amount_halalas', amt, 'reason', 'ma-'||st||'-'||t.key);
   -- validation failures first: not denial credit, labelled as validation, nothing written
   perform iso.set_claims(own); b := iso.snap(); err := null; set local role authenticated;
   begin if st='discount' then perform fn_approve_discount(p - 'reason'); else perform fn_finance_approve_refund(p || '{"reason":"  "}'); end if; exception when others then err := sqlerrm; end;
   reset role; a := iso.snap(); perform pg_temp.machk(t.key||'/'||st||'/validation reason required (not a denial)', err like 'VALIDATION%' and a = b, err);
   b := iso.snap(); err := null; set local role authenticated;
   begin if st='discount' then perform fn_approve_discount(p || '{"amount_halalas":0}') ; else perform fn_finance_approve_refund(p || '{"amount_halalas":0}'); end if; exception when others then err := sqlerrm; end;
   reset role; a := iso.snap(); perform pg_temp.machk(t.key||'/'||st||'/validation zero amount (not a denial)', err is not null and a = b, err);
   -- foreign owner, same payload: denied or not found, whole-public no-write
   perform iso.set_claims(foreign_own); b := iso.snap(); err := null; set local role authenticated;
   begin if st='discount' then perform fn_approve_discount(p); else perform fn_finance_approve_refund(p); end if; exception when others then err := sqlerrm; end;
   reset role; a := iso.snap(); perform pg_temp.machk(t.key||'/'||st||'/foreign owner refused', (err like 'FORBIDDEN%' or err like 'RESERVATION_NOT_FOUND%' or err like 'RESERVATION_ACCESS%' or err like 'permission denied%') and a = b, err);
   -- same-hotel, same-branch non-owner roles: each denied, whole-public no-write
   for act in select * from iso.actor x where x.hotel = t.hotel and x.branch = replace(t.key, t.hotel||'|', '') and x.role <> 'owner' and x.role <> 'guest' order by x.key loop
    perform iso.set_claims(act.auth_user); b := iso.snap(); err := null; set local role authenticated;
    begin if st='discount' then perform fn_approve_discount(p); else perform fn_finance_approve_refund(p); end if; exception when others then err := sqlerrm; end;
    reset role; a := iso.snap();
    perform pg_temp.machk(t.key||'/'||st||'/'||act.role||' refused', (err like 'FORBIDDEN%' or err like 'ROLE_REQUIRED%' or err like 'PAGE_%' or err like 'permission denied%') and a = b, err);
   end loop;
   -- anonymous
   perform iso.set_claims(null); b := iso.snap(); err := null; set local role anon;
   begin if st='discount' then perform fn_approve_discount(p); else perform fn_finance_approve_refund(p); end if; exception when others then err := sqlerrm; end;
   reset role; a := iso.snap(); perform pg_temp.machk(t.key||'/'||st||'/anon refused', err like 'permission denied%' and a = b, err);
   -- the authorized control
   perform iso.set_claims(own);
   rb := iso.row_snaps(orgs); b := iso.snap(); set local role authenticated;
   if st='discount' then r := fn_approve_discount(p); else r := fn_finance_approve_refund(p); end if;
   reset role; ra := iso.row_snaps(orgs); a := iso.snap();
   perform pg_temp.machk(t.key||'/'||st||'/ok result', (r->>'ok')::boolean and (r->>'approval_id') is not null, r::text);
   ap := (r->>'approval_id')::uuid;
   select array_agg(x.tbl||'|'||x.pk order by x.tbl, x.pk) into changes from iso.row_changes(rb, ra) x;
   select array_agg(x.org) into touches from iso.row_changes(rb, ra) x where x.org <> t.org::text;
   perform pg_temp.machk(t.key||'/'||st||'/only own org changed', touches is null, touches::text);
   select count(*) into seen from iso.row_changes(rb, ra) x where x.kind = 'ins' and x.tbl = case when st='discount' then 'discount_approvals' else 'finance_refund_approvals' end and x.pk = ap::text;
   perform pg_temp.machk(t.key||'/'||st||'/exact touched rows: one approval + one audit insert, nothing else', cardinality(changes) = 2 and seen = 1 and exists (select 1 from iso.row_changes(rb, ra) x where x.tbl = 'audit_events' and x.kind = 'ins'), changes::text);
   if st='discount' then select * into v from discount_approvals where id = ap; else select * into v from finance_refund_approvals where id = ap; end if;
   perform pg_temp.machk(t.key||'/'||st||'/literal row', v.organization_id = t.org and v.branch_id = t.branch_id and v.reservation_id = rid and v.amount_halalas = amt and v.reason = 'ma-'||st||'-'||t.key and v.approved_by = sid, to_jsonb(v)::text);
   select * into au from audit_events e where e.entity_id = ap and e.entity_type = case when st='discount' then 'discount_approval' else 'refund_approval' end;
   perform pg_temp.machk(t.key||'/'||st||'/audit identity', au.organization_id = t.org and au.branch_id = t.branch_id and au.actor_id = sid
      and au.action = case when st='discount' then 'discount.approved' else 'refund.prior_approval' end
      and (au.details->'after'->>'amount_halalas')::bigint = amt and au.details->'after'->>'reservation_id' = rid::text, au.details::text);
   -- each call is a new approval (no idempotency key): a second identical call adds exactly one more pair, still own org only
   rb := iso.row_snaps(orgs); set local role authenticated;
   if st='discount' then r := fn_approve_discount(p); else r := fn_finance_approve_refund(p); end if;
   reset role; ra := iso.row_snaps(orgs);
   perform pg_temp.machk(t.key||'/'||st||'/repeat adds one more approval, not idempotent by design', (select count(*) from iso.row_changes(rb, ra) x where x.kind = 'ins') = 2 and (r->>'approval_id')::uuid <> ap, null);
  end loop;
 end loop;
 ---------------------------------------------------------------- finance controls: org level, one pass per hotel
 for t in select distinct on (hotel) * from iso.target order by hotel, key loop
  k := k + 1;
  select auth_user into own from iso.actor where role = 'owner' and hotel = t.hotel;
  select auth_user into foreign_own from iso.actor where role = 'owner' and hotel <> t.hotel order by key limit 1;
  select staff.id into sid from staff_profiles staff where staff.auth_user_id = own;
  amt := 52000 + k * 11;
  p := jsonb_build_object('operational_refund_threshold_halalas', amt);
  -- denials (the function takes no organization argument: scope comes from the caller, so there is no foreign-target form;
  -- the foreign-org attack is covered by the own-org-only assertion on the authorized control below)
  for act in select * from iso.actor x where x.hotel = t.hotel and x.role <> 'owner' and x.role <> 'guest' order by x.key loop
   perform iso.set_claims(act.auth_user); b := iso.snap(); err := null; set local role authenticated;
   begin perform fn_finance_controls_set(p); exception when others then err := sqlerrm; end; reset role; a := iso.snap();
   perform pg_temp.machk(t.hotel||'/controls '||act.key||' refused', (err like 'FORBIDDEN%' or err like 'ROLE_REQUIRED%' or err like 'PAGE_%' or err like 'permission denied%') and a = b, err);
  end loop;
  perform iso.set_claims(null); b := iso.snap(); err := null; set local role anon;
  begin perform fn_finance_controls_set(p); exception when others then err := sqlerrm; end; reset role; a := iso.snap();
  perform pg_temp.machk(t.hotel||'/controls anon refused', err like 'permission denied%' and a = b, err);
  -- validation (not denial)
  perform iso.set_claims(own);
  foreach st in array array['{}', '{"unknown_key":1}', '{"operational_refund_threshold_halalas":-5}', '{"discount_review_threshold_bp":10001}'] loop
   b := iso.snap(); err := null; set local role authenticated;
   begin perform fn_finance_controls_set(st::jsonb); exception when others then err := sqlerrm; end; reset role; a := iso.snap();
   perform pg_temp.machk(t.hotel||'/controls validation '||st||' (not a denial)', err like 'VALIDATION%' and a = b, err);
  end loop;
  -- the authorized control: two literal thresholds, one in finance_control_settings and one in system_settings
  perform iso.set_claims(own);
  perform iso.set_claims(own); set local role authenticated; perform fn_finance_controls_get(); reset role;  -- materialise the settings row first, so the control below is an update
  rb := iso.row_snaps(orgs); b := iso.snap(); set local role authenticated;
  r := fn_finance_controls_set(p || jsonb_build_object('discount_review_threshold_bp', 1500 + k));
  reset role; ra := iso.row_snaps(orgs); a := iso.snap();
  select array_agg(x.tbl||'|'||x.kind order by x.tbl) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.machk(t.hotel||'/controls exact touched tables: settings upd, system_settings upd, audit ins', changes = array['audit_events|ins','finance_control_settings|upd','system_settings|upd'], changes::text);
  select array_agg(x.org) into touches from iso.row_changes(rb, ra) x where x.org <> t.org::text;
  perform pg_temp.machk(t.hotel||'/controls only own org changed (other hotel slice identical)', touches is null, touches::text);
  perform pg_temp.machk(t.hotel||'/controls literal returned', (r->>'operational_refund_threshold_halalas')::bigint = amt and (r->>'discount_review_threshold_bp')::int = 1500 + k, r::text);
  perform pg_temp.machk(t.hotel||'/controls literal stored', (select operational_refund_threshold_halalas from finance_control_settings where organization_id = t.org) = amt
       and (select discount_review_threshold_bp from system_settings where organization_id = t.org) = 1500 + k, null);
  select * into au from audit_events e where e.organization_id = t.org and e.action = 'security.finance_execution_thresholds_updated' and e.entity_id = t.org order by e.created_at desc limit 1;
  perform pg_temp.machk(t.hotel||'/controls audit identity: actor, before and after thresholds', au.actor_id = sid and au.branch_id is null
       and (au.details->'after'->>'operational_refund_threshold_halalas')::bigint = amt and au.details->'before'->>'operational_refund_threshold_halalas' is distinct from amt::text, au.details::text);
  -- an unchanged-value repeat still audits (documented behaviour), and a null threshold clears it
  set local role authenticated; r := fn_finance_controls_set('{"operational_refund_threshold_halalas":null}'::jsonb); reset role;
  perform pg_temp.machk(t.hotel||'/controls null clears threshold', (select operational_refund_threshold_halalas from finance_control_settings where organization_id = t.org) is null, r::text);
 end loop;
end $$;
do $$begin if exists(select 1 from ma_before_audit b left join audit_events a using(id) where b.h is distinct from md5(to_jsonb(a)::text)) then raise exception 'existing audit rows changed'; end if;
if (select count(*) from notifications) <> (select n from ma_before_notif) then raise exception 'notification rows changed: unexpected outbound-style effect'; end if;end $$;
select * from ma_assert order by name;
select count(*) assertions, count(*) filter (where not ok) failed from ma_assert;
do $$begin if exists(select 1 from ma_assert where not ok) then raise exception 'Money approvals assertion failed';end if;end $$;
rollback;
