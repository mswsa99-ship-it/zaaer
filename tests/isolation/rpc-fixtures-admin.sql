-- tests/isolation/rpc-fixtures-admin.sql: explicit separate loader (NOT part of any rpc-fixtures* glob preload). Synthetic only, local disposable DB, no trigger/FK disabled, no outbound/channel table touched.
-- Per target (2 hotels x 2 branches) it seeds, as plain test seed INSERTs (constraint-checked by the table's own CHECKs):
--  * purpose 'guide': one NOT-approved, not-archived guide photo (purpose='checkin', kind photo, 8-byte PNG signature, room = the target's base victim room), for fn_admin_approve_media_item;
--  * purpose 'unanswered': one open unanswered_questions row on the target branch, for fn_admin_resolve_unanswered.
-- Rows are registered in iso.created under those purposes only; base victims (purpose 'victim') are untouched.
do $$
declare t record; rm uuid; mid uuid; qid uuid; k int := 0;
begin
  for t in select * from iso.target order by key loop
    k := k + 1;
    select c.id::uuid into rm from iso.created c where c.tbl = 'rooms' and c.purpose = 'victim' and c.org = t.org and c.branch is not distinct from t.branch_id order by c.id limit 1;
    if rm is null then select c.id::uuid into rm from iso.created c where c.tbl = 'rooms' and c.purpose = 'victim' and c.org = t.org order by c.id limit 1; end if;
    if rm is null then raise exception 'ADMIN FIXTURE: no base victim room for %', t.key; end if;
    insert into branch_media_items(organization_id, branch_id, kind, room_id, caption, mime, bytes, size_bytes, sha256, purpose)
      values (t.org, t.branch_id, 'photo', rm, 'iso-guide-' || k, 'image/png', decode('89504e470d0a1a0a', 'hex'), 8, md5('iso-guide-' || k), 'checkin') returning id into mid;
    insert into unanswered_questions(organization_id, branch_id, question, normalized)
      values (t.org, t.branch_id, 'iso unanswered ' || k, 'iso unanswered ' || k) returning id into qid;
    insert into iso.created(tbl, id, org, branch, purpose) values ('branch_media_items', mid::text, t.org, t.branch_id, 'guide'), ('unanswered_questions', qid::text, t.org, t.branch_id, 'unanswered');
  end loop;
end $$;
