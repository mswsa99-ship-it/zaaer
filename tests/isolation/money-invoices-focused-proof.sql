-- Class B money-products lane (invoices): fn_staff_issue_invoice(p jsonb), fn_create_invoice(uuid,date,date), fn_staff_edit_invoice(p jsonb).
-- Disposable database only, one transaction, everything rolls back. Synthetic identifiers, no credentials, no network.
-- Before EACH call: no enabled keyed web_bridge channel, zero whatsapp_outbox rows. After EACH call: still zero outbox rows,
-- no conversation_messages inserted. The fixture seeds 9 synthetic pending outbox rows; this proof deletes them inside its
-- own rolled-back transaction (no worker runs here) so the baseline is zero, and records that it did so.
\set ON_ERROR_STOP on
begin;
set local app.identity_key='money-products-local-synthetic-key';
\ir money-products-prep.sql
do $$
declare t record; own uuid; foreign_own uuid; rids uuid[]; rid_i uuid; rid_c uuid; b jsonb; a jsonb; rb jsonb; ra jsonb; r jsonb; err text; orgs text[]; act record; changes text[];
        inv invoices%rowtype; invb invoices%rowtype; au record; sid uuid; n int; can boolean; iid uuid; sig text; cap text; call text; before_cnt int; tot bigint;
begin
 orgs := array(select id::text from organizations);
 select count(*) into n from iso.target; perform pg_temp.mpchk('targets/4', n=4, n::text);
 for t in select * from iso.target order by key loop
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  select auth_user into foreign_own from iso.actor where role='owner' and hotel<>t.hotel order by key limit 1;
  select staff.id into sid from staff_profiles staff where staff.auth_user_id=own;
  select f.res_conf, f.res_in into rid_i, rid_c from mp_fx f where f.key=t.key;
  select i.id into iid from invoices i join reservations x on x.id=i.reservation_id join iso.created c on c.id=i.id::text and c.tbl='invoices' and c.purpose='victim' and c.branch=t.branch_id limit 1;
  perform pg_temp.mpchk(t.key||'/fixtures: one confirmed and one checked-in synthetic stay with open charges, and the base fixture issued invoice', rid_i is not null and rid_c is not null and iid is not null, rid_i::text||'/'||rid_c::text||'/'||coalesce(iid::text,'-'));
  ---------------------------------------------------------------- negatives for all three signatures, no state change
  foreach sig in array array['issue','create','edit'] loop
   cap := case when sig='edit' then 'invoice.edit' else 'invoice.issue' end;
   -- validation / state failures
   perform pg_temp.mpguard(t.key||'/'||sig||'/validation');
   perform iso.set_claims(own); b:=iso.snap(); err:=null; set local role authenticated;
   begin
    if sig='issue' then perform fn_staff_issue_invoice(jsonb_build_object('reservation_id', rid_i, 'from', '2030-01-02', 'to', '2030-01-01'));
    elsif sig='create' then perform fn_create_invoice(rid_c, '2030-01-02', '2030-01-01');
    else perform fn_staff_edit_invoice(jsonb_build_object('invoice_id', iid, 'reason', '  ')); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||sig||'/validation (inverted period / blank reason), not a denial', err like 'VALIDATION%' and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||sig||'/validation');
   -- foreign-hotel owner
   perform pg_temp.mpguard(t.key||'/'||sig||'/foreign owner');
   perform iso.set_claims(foreign_own); b:=iso.snap(); err:=null; set local role authenticated;
   begin
    if sig='issue' then perform fn_staff_issue_invoice(jsonb_build_object('reservation_id', rid_i));
    elsif sig='create' then perform fn_create_invoice(rid_c);
    else perform fn_staff_edit_invoice(jsonb_build_object('invoice_id', iid, 'reason', 'x', 'bill_to', jsonb_build_object('name','Foreign attempt'))); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||sig||'/foreign owner refused, whole-public no-write', (err like 'RESERVATION_NOT_FOUND%' or err like 'NOT_FOUND%' or err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||sig||'/foreign owner');
   -- anon
   perform pg_temp.mpguard(t.key||'/'||sig||'/anon');
   perform iso.set_claims(null); b:=iso.snap(); err:=null; set local role anon;
   begin
    if sig='issue' then perform fn_staff_issue_invoice(jsonb_build_object('reservation_id', rid_i));
    elsif sig='create' then perform fn_create_invoice(rid_c);
    else perform fn_staff_edit_invoice(jsonb_build_object('invoice_id', iid, 'reason', 'x')); end if;
   exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||sig||'/anon refused', err like 'permission denied%' and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||sig||'/anon');
   -- same-hotel actors: wrong branch or role without the capability
   for act in select * from iso.actor x where x.hotel=t.hotel and x.role<>'owner' and x.role<>'guest' order by x.key loop
    perform iso.set_claims(act.auth_user); set local role authenticated; can := fn_can(cap); reset role;
    continue when act.branch is not distinct from replace(t.key, t.hotel||'|', '') and can;
    perform pg_temp.mpguard(t.key||'/'||sig||'/'||act.key);
    b:=iso.snap(); err:=null; set local role authenticated;
    begin
     if sig='issue' then perform fn_staff_issue_invoice(jsonb_build_object('reservation_id', rid_i));
     elsif sig='create' then perform fn_create_invoice(rid_c);
     else perform fn_staff_edit_invoice(jsonb_build_object('invoice_id', iid, 'reason', 'x', 'bill_to', jsonb_build_object('name','Wrong actor'))); end if;
    exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
    perform pg_temp.mpchk(t.key||'/'||sig||'/'||act.key||' refused (cap='||can||')', (err like 'FORBIDDEN%' or err like 'PAGE_%' or err like 'permission denied%') and a=b, err);
    perform pg_temp.mpafter(t.key||'/'||sig||'/'||act.key);
   end loop;
  end loop;
  ---------------------------------------------------------------- positives
  foreach sig in array array['issue','create'] loop
   perform pg_temp.mpguard(t.key||'/'||sig||'/owner control');
   perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated;
   if sig='issue' then r := fn_staff_issue_invoice(jsonb_build_object('reservation_id', rid_i, 'bill_to', jsonb_build_object('name','Synthetic Guest')));
   else r := fn_create_invoice(rid_c); end if;
   reset role; ra:=iso.row_snaps(orgs);
   perform pg_temp.mpafter(t.key||'/'||sig||'/owner control');
   select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
   perform pg_temp.mpchk(t.key||'/'||sig||'/exact touched rows: one invoice, one audit, number sequence, stay charges marked invoiced, nothing else',
     cardinality(array(select distinct unnest(changes)))=4 and changes @> array['audit_events|ins','invoices|ins','reservation_charges|upd'] and (changes @> array['document_sequences|ins'] or changes @> array['document_sequences|upd'])
     and (select count(*) from unnest(changes) c where c='invoices|ins')=1 and (select count(*) from unnest(changes) c where c='audit_events|ins')=1, changes::text);
   perform pg_temp.mpchk(t.key||'/'||sig||'/no table outside own org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
   select * into inv from invoices where id=(r->>'id')::uuid;
   perform pg_temp.mpchk(t.key||'/'||sig||'/literal invoice', (r->>'ok')::boolean and inv.organization_id=t.org and inv.branch_id=t.branch_id and inv.reservation_id=case when sig='issue' then rid_i else rid_c end
        and inv.status='issued' and inv.scope='remaining' and inv.origin='manual' and inv.issued_by=sid and inv.total_halalas=inv.subtotal_halalas+inv.tax_halalas and inv.total_halalas>0 and inv.total_halalas=(r->>'total_halalas')::bigint, to_jsonb(inv)::text);
   select * into au from audit_events e where e.entity_id=inv.id and e.action='invoice.issued';
   perform pg_temp.mpchk(t.key||'/'||sig||'/audit identity', au.organization_id=t.org and au.branch_id=t.branch_id and au.actor_id=sid and (au.details->'after'->>'total_halalas')::bigint=inv.total_halalas, au.details::text);
   -- a second call: nothing left to invoice, refused as state, no write
   perform pg_temp.mpguard(t.key||'/'||sig||'/second call');
   b:=iso.snap(); err:=null; set local role authenticated;
   begin if sig='issue' then perform fn_staff_issue_invoice(jsonb_build_object('reservation_id', rid_i)); else perform fn_create_invoice(rid_c); end if; exception when others then err:=sqlerrm; end; reset role; a:=iso.snap();
   perform pg_temp.mpchk(t.key||'/'||sig||'/nothing left to invoice (state, not denial)', err like 'NOTHING_TO_INVOICE%' and a=b, err);
   perform pg_temp.mpafter(t.key||'/'||sig||'/second call');
  end loop;
  -- edit: change the bill-to name of the fixture invoice
  perform pg_temp.mpguard(t.key||'/edit/owner control');
  select * into invb from invoices where id=iid;
  perform iso.set_claims(own); rb:=iso.row_snaps(orgs); set local role authenticated;
  begin r := fn_staff_edit_invoice(jsonb_build_object('invoice_id', iid, 'reason', 'edit-synthetic-'||t.key, 'bill_to', jsonb_build_object('name','Edited Synthetic Name'))); exception when others then err:=sqlerrm; r := jsonb_build_object('err', err); end;
  reset role; ra:=iso.row_snaps(orgs);
  perform pg_temp.mpafter(t.key||'/edit/owner control');
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.mpchk(t.key||'/edit/result ok, changed', coalesce((r->>'ok')::boolean,false) and (r->>'unchanged')::boolean is false and (r->>'version')::int=invb.version+1, r::text);
  perform pg_temp.mpchk(t.key||'/edit/exact touched rows: invoice update, one audit, one review item, charge markers, nothing else',
     changes @> array['audit_events|ins','invoices|upd','review_items|ins'] and cardinality(array(select distinct unnest(changes)))=4 and 'reservation_charges|upd' = any(changes)
     and (select count(*) from unnest(changes) c where c in ('invoices|upd','audit_events|ins','review_items|ins'))=3, changes::text);
  perform pg_temp.mpchk(t.key||'/edit/no table outside own org changed', not exists(select 1 from iso.row_changes(rb, ra) x where x.org<>t.org::text));
  select * into inv from invoices where id=iid;
  perform pg_temp.mpchk(t.key||'/edit/literal row: bill-to name, version, history kept, lines recomputed from the stay (fixture invoice had a 1-halala snapshot with no lines)', inv.bill_to->>'name'='Edited Synthetic Name' and inv.version=invb.version+1 and jsonb_array_length(inv.versions)=jsonb_array_length(invb.versions)+1 and inv.updated_by=sid
     and jsonb_array_length(inv.snapshot->'lines')=(select count(*) from reservation_charges where reservation_id=inv.reservation_id) and inv.total_halalas=(select sum(total_halalas) from reservation_charges where reservation_id=inv.reservation_id), to_jsonb(inv)::text);
  select * into au from audit_events e where e.entity_id=iid and e.action='invoice.edited';
  perform pg_temp.mpchk(t.key||'/edit/audit identity and reason', au.organization_id=t.org and au.branch_id=t.branch_id and au.actor_id=sid and au.details::text like '%edit-synthetic-'||t.key||'%', au.details::text);
  -- the same edit again: invariants only (totals, bill-to), never a new invoice; observed behaviour is recorded in the detail
  perform pg_temp.mpguard(t.key||'/edit/repeat');
  invb := inv; rb:=iso.row_snaps(orgs); set local role authenticated; r := fn_staff_edit_invoice(jsonb_build_object('invoice_id', iid, 'reason', 'again', 'bill_to', jsonb_build_object('name','Edited Synthetic Name'))); reset role; ra:=iso.row_snaps(orgs);
  select * into inv from invoices where id=iid;
  select array_agg(x.tbl||'|'||x.kind order by x.tbl, x.kind) into changes from iso.row_changes(rb, ra) x;
  perform pg_temp.mpchk(t.key||'/edit/repeat keeps totals and bill-to, no new invoice row; OBSERVED unchanged='||(r->>'unchanged')||' version '||invb.version||'->'||inv.version||' touched '||coalesce(changes::text,'none'),
     inv.total_halalas=invb.total_halalas and inv.bill_to=invb.bill_to and not exists(select 1 from iso.row_changes(rb, ra) x where x.tbl='invoices' and x.kind='ins') and (inv.version=invb.version or inv.version=invb.version+1), r::text);
  perform pg_temp.mpafter(t.key||'/edit/repeat');
 end loop;
end $$;
select name, ok::text as ok, coalesce(detail,'') as detail from mp_assert order by ok, name;
do $$ begin if exists(select 1 from mp_assert where not ok) then raise exception 'FAIL count %', (select count(*) from mp_assert where not ok); end if;
 raise notice 'assertions=%', (select count(*) from mp_assert); end $$;
rollback;
