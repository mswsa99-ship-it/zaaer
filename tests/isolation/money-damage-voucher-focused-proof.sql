-- Class B money-products lane (damage and voucher correction): fn_staff_add_damage(jsonb), fn_staff_correct_voucher(jsonb).
-- Disposable database only, one transaction, everything rolls back. Synthetic identifiers, no credentials, no network.
-- Self-contained through money-products-prep.sql (base fixtures only). Before and after EACH call: no enabled keyed
-- web_bridge, zero whatsapp_outbox rows, no conversation_messages inserted (hard RAISE).
\set ON_ERROR_STOP on
begin;
set local app.identity_key='money-damage-voucher-local-synthetic-key';
\ir money-products-prep.sql
do $$
declare t record; own uuid; foreign_own uuid; rid uuid; vid uuid; b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; orgs text[]; act record; changes text[]; sig text; cap text; p jsonb;
        au record; sid uuid; n int; can boolean; ch reservation_charges%rowtype; v0 financial_vouchers%rowtype; nv financial_vouchers%rowtype; k int := 0; ver int; amt bigint;
begin
 orgs := array(select id::text from organizations);
 select count(*) into n from iso.target; perform pg_temp.mpchk('targets/4', n=4, n::text);
 for t in select * from iso.target order by key loop
  k := k + 1; amt := 700 + k * 11;
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select auth_user into foreign_own from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1;
  select staff.id into sid from staff_profiles staff where staff.auth_user_id=own;
  select f.res_in into rid from mp_fx f where f.key=t.key;
  select x.id into vid from financial_vouchers x where x.reservation_id=rid and x.idempotency_key like 'mpprep-%' and x.status='approved';
  perform pg_temp.mpchk(t.key||'/fixtures: synthetic checked-in stay with one approved cash receipt', rid is not null and vid is not null, rid::text||'/'||coalesce(vid::text,'-'));
  foreach sig in array array['damage','correct'] loop
   cap := case when sig='damage' then 'damage.charge' else 'voucher.correct' end;
   perform pg_temp.mpguard(t.key||'/'||sig||'/validation');
   perform iso.set_claims(own); b:=iso.snap(); err:=null; set local role authenticated;
   begin
    if sig='damage' then perform fn_staff_add_damage(jsonb_build_object('reservation_id', rid, 'amount_halalas', amt, 'reason', '  ', 'idempotency_key', 'mpd-'||t.key));
    else perform fn_staff_correct_voucher(jsonb_build_object('voucher_id', vid, 'reason', 'x', 'idempotency_key', '  ')); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||sig||'/validation (blank reason / blank key), not a denial', err like 'VALIDATION%' and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||sig||'/validation');
   if sig='correct' then
    perform pg_temp.mpguard(t.key||'/correct/nothing changed');
    b:=iso.snap(); err:=null; set local role authenticated;
    begin perform fn_staff_correct_voucher(jsonb_build_object('voucher_id', vid, 'reason', 'x', 'idempotency_key', 'mpc-nc-'||t.key)); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
    perform pg_temp.mpchk(t.key||'/correct/identical content refused as validation, no write', err like 'VALIDATION: nothing_changed%' and a=b, err);
    perform pg_temp.mpafter(t.key||'/correct/nothing changed');
   end if;
   perform pg_temp.mpguard(t.key||'/'||sig||'/foreign owner');
   perform iso.set_claims(foreign_own); b:=iso.snap(); err:=null; set local role authenticated;
   begin
    if sig='damage' then perform fn_staff_add_damage(jsonb_build_object('reservation_id', rid, 'amount_halalas', amt, 'reason', 'foreign', 'idempotency_key', 'mpd-f-'||t.key));
    else perform fn_staff_correct_voucher(jsonb_build_object('voucher_id', vid, 'reason', 'foreign', 'idempotency_key', 'mpc-f-'||t.key, 'amount_halalas', amt)); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||sig||'/foreign owner refused, whole-public no-write', (err like 'RESERVATION_NOT_FOUND%' or err like 'NOT_FOUND%' or err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||sig||'/foreign owner');
   perform pg_temp.mpguard(t.key||'/'||sig||'/anon');
   perform iso.set_claims(null); b:=iso.snap(); err:=null; set local role anon;
   begin
    if sig='damage' then perform fn_staff_add_damage(jsonb_build_object('reservation_id', rid, 'amount_halalas', amt, 'reason', 'anon', 'idempotency_key', 'mpd-a-'||t.key));
    else perform fn_staff_correct_voucher(jsonb_build_object('voucher_id', vid, 'reason', 'anon', 'idempotency_key', 'mpc-a-'||t.key, 'amount_halalas', amt)); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||sig||'/anon refused', err like 'permission denied%' and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||sig||'/anon');
   for act in select * from iso.actor x where x.hotel=t.hotel and x.role<>'owner' and x.role<>'guest' order by x.key loop
    perform iso.set_claims(act.auth_user); set local role authenticated; can := fn_can(cap); reset role;
    continue when act.branch is not distinct from replace(t.key, t.hotel||'|', '') and can;
    perform pg_temp.mpguard(t.key||'/'||sig||'/'||act.key);
    b:=iso.snap(); err:=null; set local role authenticated;
    begin
     if sig='damage' then perform fn_staff_add_damage(jsonb_build_object('reservation_id', rid, 'amount_halalas', amt, 'reason', 'wrong actor', 'idempotency_key', 'mpd-w-'||t.key));
     else perform fn_staff_correct_voucher(jsonb_build_object('voucher_id', vid, 'reason', 'wrong actor', 'idempotency_key', 'mpc-w-'||t.key, 'amount_halalas', amt)); end if;
    exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
    perform pg_temp.mpchk(t.key||'/'||sig||'/'||act.key||' refused (cap='||can||')', (err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
    perform pg_temp.mpafter(t.key||'/'||sig||'/'||act.key);
   end loop;
  end loop;
  p := jsonb_build_object('reservation_id', rid, 'amount_halalas', amt, 'reason', 'mp-damage-'||t.key, 'description', 'synthetic broken lamp', 'idempotency_key', 'mpd-'||t.key, 'apply_deposit', false);
  perform pg_temp.mpguard(t.key||'/damage/owner control');
  select version into ver from reservations where id=rid;
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_staff_add_damage(p); reset role; ra:=iso.row_snaps(orgs);
  perform pg_temp.mpafter(t.key||'/damage/owner control');
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.mpchk(t.key||'/damage/exact touched rows: one charge, one reservation update (version), one audit, nothing else', changes = array['audit_events|ins','reservation_charges|ins','reservations|upd'], changes::text);
  perform pg_temp.mpchk(t.key||'/damage/no table outside own org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
  select * into ch from reservation_charges where id=(r->>'charge_id')::uuid;
  perform pg_temp.mpchk(t.key||'/damage/literal charge', (r->>'ok')::boolean and (r->>'duplicate')::boolean is false and ch.reservation_id=rid and ch.purpose='damage' and ch.idempotency_key='mpd-'||t.key and ch.total_halalas=amt and ch.organization_id=t.org, to_jsonb(ch)::text);
  perform pg_temp.mpchk(t.key||'/damage/reservation version bumped', (select version from reservations where id=rid)=ver+1);
  select * into au from audit_events e where e.entity_id=rid and e.action='reservation.damage_charged' order by e.created_at desc limit 1;
  perform pg_temp.mpchk(t.key||'/damage/audit identity', au.organization_id=t.org and au.branch_id=t.branch_id and au.actor_id=sid and (au.details->'after'->>'amount_halalas')::bigint=amt, au.details::text);
  perform pg_temp.mpguard(t.key||'/damage/replay');
  b:=iso.snap(); set local role authenticated; r := fn_staff_add_damage(p); reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/damage/same key replays as duplicate and writes nothing', (r->>'duplicate')::boolean and a=b, r::text);
  perform pg_temp.mpafter(t.key||'/damage/replay');
  select * into v0 from financial_vouchers where id=vid;
  p := jsonb_build_object('voucher_id', vid, 'reason', 'mp-correct-'||t.key, 'idempotency_key', 'mpc-'||t.key, 'amount_halalas', v0.amount_halalas + 5);
  perform pg_temp.mpguard(t.key||'/correct/owner control');
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated;
  begin r := fn_staff_correct_voucher(p); exception when others then err:=sqlerrm; r := jsonb_build_object('err', err); end;
  reset role; ra:=iso.row_snaps(orgs);
  perform pg_temp.mpafter(t.key||'/correct/owner control');
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.mpchk(t.key||'/correct/result ok, unsettled, not duplicate', coalesce((r->>'ok')::boolean,false) and (r->>'settled')::boolean is false and (r->>'duplicate')::boolean is false, r::text);
  perform pg_temp.mpchk(t.key||'/correct/exact touched rows: replacement voucher + original cancelled, 2 journal entries (cancel + replacement), audit x2 (voucher + posting), review item, reservation, sequences',
     changes = array['audit_events|ins','audit_events|ins','document_sequences|upd','document_sequences|upd','financial_vouchers|ins','financial_vouchers|upd','journal_entries|ins','journal_entries|ins','journal_lines|ins','journal_lines|ins','journal_lines|ins','journal_lines|ins','reservations|upd','review_items|ins'], changes::text);
  perform pg_temp.mpchk(t.key||'/correct/no table outside own org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
  select * into nv from financial_vouchers where id=(r->>'voucher_id')::uuid;
  select * into v0 from financial_vouchers where id=vid;
  perform pg_temp.mpchk(t.key||'/correct/literal: original cancelled with reason, replacement approved with amount+5 and link', v0.status='cancelled' and v0.cancelled_by=sid and v0.cancel_reason like '%mp-correct-'||t.key
     and nv.status='approved' and nv.original_voucher_id=vid and nv.amount_halalas=v0.amount_halalas+5 and nv.method=v0.method and nv.reservation_id=rid and nv.organization_id=t.org and nv.branch_id=t.branch_id and nv.idempotency_key='mpc-'||t.key, to_jsonb(nv)::text);
  select * into au from audit_events e where e.entity_id=nv.id and e.action='voucher.corrected';
  perform pg_temp.mpchk(t.key||'/correct/audit identity', au.organization_id=t.org and au.branch_id=t.branch_id and au.actor_id=sid and (au.details->'after'->>'amount_halalas')::bigint=nv.amount_halalas and (au.details->'before'->>'amount_halalas')::bigint=v0.amount_halalas, au.details::text);
  perform pg_temp.mpguard(t.key||'/correct/replay');
  b:=iso.snap(); set local role authenticated; r := fn_staff_correct_voucher(p); reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/correct/same key replays as duplicate and writes nothing', (r->>'duplicate')::boolean and a=b, r::text);
  perform pg_temp.mpafter(t.key||'/correct/replay');
  perform pg_temp.mpguard(t.key||'/correct/already corrected');
  b:=iso.snap(); err:=null; set local role authenticated;
  begin perform fn_staff_correct_voucher(jsonb_build_object('voucher_id', vid, 'reason', 'again', 'idempotency_key', 'mpc-2-'||t.key, 'amount_halalas', v0.amount_halalas+9)); exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
  perform pg_temp.mpchk(t.key||'/correct/a cancelled voucher cannot be corrected again (state, not denial)', err like 'VOUCHER_STATUS_INVALID%' and a=b, err);
  perform pg_temp.mpafter(t.key||'/correct/already corrected');
 end loop;
end $$;
select name, ok::text as ok, coalesce(detail,'') as detail from mp_assert order by ok, name;
do $$ begin if exists(select 1 from mp_assert where not ok) then raise exception 'FAIL count %', (select count(*) from mp_assert where not ok); end if;
 raise notice 'assertions=%', (select count(*) from mp_assert); end $$;
rollback;
