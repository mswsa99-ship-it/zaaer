-- money-remaining bank4 proof: fn_bank_convert, fn_bank_match, fn_bank_reparse, fn_bank_unmatch.
-- Local disposable PG16, base fixtures.sql only. One outer transaction, rolled back; every measured call also runs inside its own rolled-back
-- sub-block (setup, call, measure, raise MK_ROLLBACK) so each call starts from the same synthetic state. No bank poll, mail, network, Auth or protected call.
-- Setup rows are plain INSERTs (synthetic message / movement / expense target / link match). Hard RAISE before any call if an enabled keyed bridge exists
-- or the whatsapp_outbox baseline moves. Validation-state failures are labelled and are not denial credit.
-- Run: psql -X -d iso_* -v ON_ERROR_STOP=1 -v strict=1 -f tests/isolation/read-data-bank4-proof.sql
\set ON_ERROR_STOP on
begin;
do $$ begin if exists (select 1 from branch_whatsapp_channels where enabled and mode = 'web_bridge' and bridge_key_hash is not null) then raise exception 'ENABLED KEYED BRIDGE PRESENT: refused'; end if; end $$;
create temp table res(spec text, actor text, ctx text, target text, expect text, got text, ok boolean, detail text);
grant all on res to public;
create temp table cfg as select (select count(*) from whatsapp_outbox) outbox_n;
grant all on cfg to public;
create temp table mk as select t.branch_id, t.org, t.hotel, right(t.branch,1) br, (case when t.hotel='hotel-a' then 'A' else 'B' end)||right(t.branch,1) code from iso.target t;
grant all on mk to public;
create temp table orgs as select org::text o from (select distinct org from mk union select '00000000-0000-0000-0000-000000000001'::uuid) x;
grant all on orgs to public;
update cash_accounts a set name = 'MK-ACC-' || m.code from mk m where m.branch_id = a.branch_id and a.kind = 'bank_account';

create or replace function pg_temp.fx(p_branch uuid, p_what text, p_amount bigint default 5500) returns jsonb language plpgsql as $f$
declare m record; acct uuid; msg uuid := gen_random_uuid(); mv uuid := gen_random_uuid(); ex uuid := gen_random_uuid(); mt uuid := gen_random_uuid(); cat uuid; dir text; k text; st text := 'pending'; mst text := 'unparsed';
begin
  select * into m from mk where branch_id = p_branch;
  select id into acct from cash_accounts where branch_id = p_branch and kind = 'bank_account' and archived_at is null order by id limit 1;
  select id into cat from expense_categories where organization_id = m.org and is_active order by id limit 1;
  dir := case when p_what in ('convert_in') then 'in' else 'out' end;
  k := case p_what when 'convert_in' then 'deposit' else 'purchase' end;
  if p_what = 'reparse' then mst := 'rejected'; end if;
  insert into bank_messages(id, organization_id, raw_body, content_hash, mail_from, status, reject_reason, received_at)
    values (msg, m.org, 'MK-RAW-' || m.code, 'MK-HASH-' || msg::text, 'MK-NOT-APP-' || m.code || '@x.invalid', mst, case when mst = 'rejected' then 'MK-OLD-' || m.code end, now());
  if p_what <> 'reparse' then
    insert into bank_movements(id, organization_id, branch_id, cash_account_id, message_id, kind, direction, amount_halalas, occurred_at, reference, dedupe_key, status)
      values (mv, m.org, p_branch, acct, msg, k, dir, p_amount, now() - interval '1 day', 'MK-REF-' || m.code, 'MK-DD-' || mv::text, 'pending');
  end if;
  if p_what in ('match', 'match_diff', 'unmatch') then
    insert into expense_vouchers(id, organization_id, branch_id, number, account_id, category_id, amount_halalas, description, occurred_at)
      values (ex, m.org, p_branch, 'MK-EXP-' || m.code || '-' || left(ex::text, 6), acct, cat, case p_what when 'match_diff' then 5900 else p_amount end, 'MK-TGT-' || m.code, now() - interval '1 day');
  end if;
  if p_what = 'unmatch' then
    insert into bank_matches(id, organization_id, movement_id, kind, reason) values (mt, m.org, mv, 'link', 'MK-LINK-' || m.code);
    insert into bank_match_items(organization_id, match_id, target_type, target_id, amount_halalas) values (m.org, mt, 'expense', ex, p_amount);
    update bank_movements set status = 'matched' where id = mv;
  end if;
  return jsonb_build_object('movement', mv, 'message', msg, 'expense', ex, 'match', mt, 'cat', cat, 'acct', acct, 'org', m.org, 'code', m.code);
end $f$;
grant execute on function pg_temp.fx(uuid, text, bigint) to public;

do $$
declare a record; t record; w text; fxj jsonb; msg text; r jsonb; before jsonb; after jsonb; chg text; foreign_chg int; own_org text; sid uuid; v_org uuid; exp_c text; got text; ok boolean; det text;
        sig text; call_sql text; tgt_ctx text; sa text; amt bigint; ob0 int; ob1 int; n_ins int; settings bank_mail_settings%rowtype; exp_reason text; jid uuid; je_sum bigint; jl_d bigint; jl_c bigint;
        mvst text; cnt int; vstate text; rs_spec text; rs_ok boolean; rs_det text; rs_set boolean;
begin
 select outbox_n into ob0 from cfg;
 for a in select * from iso.actor order by hotel nulls first, role, branch loop
  select organization_id, id into v_org, sid from staff_profiles where auth_user_id = a.auth_user;
  for t in select * from mk order by code loop
   for w in select unnest(array['convert_out','convert_in','match','match_diff','unmatch','reparse']) loop
    if w = 'reparse' and t.br <> '1' then continue; end if;   -- reparse is message scoped: one message per hotel is enough
    if exists (select 1 from branch_whatsapp_channels where enabled and mode = 'web_bridge' and bridge_key_hash is not null) then raise exception 'ENABLED KEYED BRIDGE PRESENT: refused'; end if;
    rs_set := false; msg := null; r := null; chg := null; foreign_chg := 0; vstate := null; det := null; ok := true;
    exp_c := case when a.auth_user is null then 'FORBIDDEN' when a.role <> 'owner' then 'FORBIDDEN' when v_org is distinct from t.org then 'NOT_FOUND' else 'allow' end;
    begin
      fxj := pg_temp.fx(t.branch_id, w, 5500);
      select count(*) into ob1 from whatsapp_outbox; if ob1 <> ob0 then raise exception 'OUTBOX BASELINE MOVED before call'; end if;
      before := iso.row_snaps((select array_agg(o) from orgs));
      perform iso.set_claims(a.auth_user); set local role authenticated;
      begin
        r := case w
          when 'convert_out' then fn_bank_convert((fxj->>'movement')::uuid, jsonb_build_object('category_id', fxj->>'cat', 'description', 'MK-DESC-' || t.code))
          when 'convert_in' then fn_bank_convert((fxj->>'movement')::uuid, jsonb_build_object('description', 'MK-DESC-' || t.code))
          when 'match' then fn_bank_match((fxj->>'movement')::uuid, jsonb_build_array(jsonb_build_object('type', 'expense', 'id', fxj->>'expense')), null)
          when 'match_diff' then fn_bank_match((fxj->>'movement')::uuid, jsonb_build_array(jsonb_build_object('type', 'expense', 'id', fxj->>'expense')), 'MK-RSN-' || t.code)
          when 'unmatch' then fn_bank_unmatch((fxj->>'movement')::uuid, 'MK-UNM-' || t.code)
          when 'reparse' then fn_bank_reparse((fxj->>'message')::uuid) end;
      exception when others then msg := sqlerrm; end;
      reset role;
      after := iso.row_snaps((select array_agg(o) from orgs));
      select count(*) into ob1 from whatsapp_outbox;
      select string_agg(tbl || ':' || kind || ':' || n, ',' order by tbl, kind) into chg from (select tbl, kind, count(*) n from iso.row_changes(before, after) where org = t.org::text group by 1, 2) q;
      select count(*) into foreign_chg from iso.row_changes(before, after) where org <> t.org::text;
      got := case when msg is null then 'allow' when msg like 'FORBIDDEN%' then 'FORBIDDEN' when msg like 'NOT_FOUND%' then 'NOT_FOUND' else 'error' end;
      ok := got = exp_c; det := coalesce(msg, '');
      if ob1 <> ob0 then ok := false; det := det || ' OUTBOX CHANGED'; end if;
      if got <> 'allow' then
        if chg is not null or foreign_chg > 0 then ok := false; det := det || ' WRITE ON DENIAL ' || coalesce(chg, '') || '/' || foreign_chg; end if;
      else
        if foreign_chg > 0 then ok := false; det := det || ' FOREIGN WRITE ' || foreign_chg; end if;
        -- ===== exact content per signature
        if w = 'convert_out' then
          if r->>'as' <> 'expense' or not exists (select 1 from bank_movements where id = (fxj->>'movement')::uuid and status = 'converted')
             or not exists (select 1 from expense_vouchers x where x.id = (r->>'expense_id')::uuid and x.organization_id = t.org and x.branch_id = t.branch_id and x.account_id = (fxj->>'acct')::uuid
                              and x.category_id = (fxj->>'cat')::uuid and x.amount_halalas = 5500 and x.description = 'MK-DESC-' || t.code and x.created_by = sid and x.number = r->>'expense_number')
             or not exists (select 1 from bank_matches b where b.id = (r->>'match_id')::uuid and b.kind = 'convert' and b.reason = 'MK-DESC-' || t.code and b.created_by = sid and b.active and b.organization_id = t.org)
             or not exists (select 1 from bank_match_items i where i.match_id = (r->>'match_id')::uuid and i.target_type = 'expense' and i.target_id = (r->>'expense_id')::uuid and i.amount_halalas = 5500 and i.active)
             or (select count(*) from audit_events e where e.organization_id = t.org and e.action in ('expense.created', 'bank_movement.converted') and e.entity_id in ((r->>'expense_id')::uuid, (fxj->>'movement')::uuid) and e.branch_id = t.branch_id) <> 2
          then ok := false; det := det || ' CONTENT convert_out'; end if;
          if coalesce(chg, '') !~ 'bank_match_items:ins:1' or chg !~ 'bank_matches:ins:1' or chg !~ 'bank_movements:upd:1' or chg !~ 'expense_vouchers:ins:1' or chg !~ 'audit_events:ins:2' then ok := false; det := det || ' EFFECTS ' || coalesce(chg, ''); end if;
        elsif w = 'convert_in' then
          select target_id into jid from bank_match_items where match_id = (r->>'match_id')::uuid and target_type = 'journal';
          select coalesce(sum(debit_halalas),0), coalesce(sum(credit_halalas),0) into jl_d, jl_c from journal_lines where entry_id = jid;
          if r->>'as' <> 'income' or r->>'expense_id' is not null and r->'expense_id' <> 'null'::jsonb or jid is null or not exists (select 1 from journal_entries je where je.id = jid and je.source_type = 'bank_movement' and je.source_id = (fxj->>'movement')::uuid and je.branch_id = t.branch_id) or jl_d <> 5500 or jl_c <> 5500
             or not exists (select 1 from bank_movements where id = (fxj->>'movement')::uuid and status = 'converted')
             or not exists (select 1 from bank_matches b where b.id = (r->>'match_id')::uuid and b.kind = 'convert' and b.reason = 'MK-DESC-' || t.code and b.created_by = sid)
             or not exists (select 1 from audit_events e where e.organization_id = t.org and e.action = 'bank_movement.converted' and e.entity_id = (fxj->>'movement')::uuid and e.branch_id = t.branch_id)
          then ok := false; det := det || ' CONTENT convert_in dr=' || jl_d || ' cr=' || jl_c; end if;
          if coalesce(chg, '') !~ 'journal_entries:ins:1' or chg !~ 'journal_lines:ins:2' or chg !~ 'bank_matches:ins:1' or chg ~ 'expense_vouchers' then ok := false; det := det || ' EFFECTS ' || coalesce(chg, ''); end if;
        elsif w in ('match', 'match_diff') then
          amt := case w when 'match_diff' then 5500 - 5900 else 0 end;
          if (r->>'records')::int <> 1 or (r->>'difference_halalas')::bigint <> amt
             or not exists (select 1 from bank_movements where id = (fxj->>'movement')::uuid and status = 'matched')
             or not exists (select 1 from bank_matches b where b.id = (r->>'match_id')::uuid and b.kind = 'link' and b.difference_halalas = amt and b.created_by = sid and b.active and b.reason is not distinct from (case w when 'match_diff' then 'MK-RSN-' || t.code end))
             or not exists (select 1 from bank_match_items i where i.match_id = (r->>'match_id')::uuid and i.target_type = 'expense' and i.target_id = (fxj->>'expense')::uuid and i.amount_halalas = case w when 'match_diff' then 5900 else 5500 end)
             or not exists (select 1 from audit_events e where e.organization_id = t.org and e.action = 'bank_movement.matched' and e.entity_id = (fxj->>'movement')::uuid and e.branch_id = t.branch_id)
          then ok := false; det := det || ' CONTENT ' || w; end if;
          if w = 'match_diff' and (coalesce(chg, '') !~ 'journal_entries:ins:1' or chg !~ 'journal_lines:ins:2') then ok := false; det := det || ' EFFECTS diff GL ' || coalesce(chg, ''); end if;
          if w = 'match' and chg ~ 'journal_entries' then ok := false; det := det || ' EFFECTS unexpected GL'; end if;
        elsif w = 'unmatch' then
          if r->>'ok' <> 'true' or not exists (select 1 from bank_movements where id = (fxj->>'movement')::uuid and status = 'pending')
             or not exists (select 1 from bank_matches b where b.id = (fxj->>'match')::uuid and not b.active and b.released_by = sid and b.release_reason = 'MK-UNM-' || t.code)
             or exists (select 1 from bank_match_items i where i.match_id = (fxj->>'match')::uuid and i.active)
             or not exists (select 1 from audit_events e where e.organization_id = t.org and e.action = 'bank_movement.unmatched' and e.entity_id = (fxj->>'movement')::uuid and e.branch_id = t.branch_id)
          then ok := false; det := det || ' CONTENT unmatch'; end if;
        elsif w = 'reparse' then
          select * into settings from bank_mail_settings where organization_id = t.org;
          exp_reason := case when settings.mailbox_address is null or settings.relay_key_encrypted is null then 'بريد البنك غير مُعدّ' else 'ليست من بريد التطبيق' end;
          if r->>'ok' <> 'true' or r->>'status' <> 'rejected' or r->>'reason' <> exp_reason
             or not exists (select 1 from bank_messages b where b.id = (fxj->>'message')::uuid and b.status = 'rejected' and b.reject_reason = exp_reason and b.processed_at is not null)
             or not exists (select 1 from audit_events e where e.organization_id = t.org and e.action = 'bank_message.reparsed' and e.entity_id = (fxj->>'message')::uuid)
          then ok := false; det := det || ' CONTENT reparse'; end if;
          if exists (select 1 from bank_movements where message_id = (fxj->>'message')::uuid) then ok := false; det := det || ' MOVEMENT created by reparse'; end if;
        end if;
      end if;
      rs_spec := 'fn_bank_' || regexp_replace(w, '_.*', ''); rs_ok := ok; rs_det := nullif(det, ''); rs_set := true;
      raise exception 'MK_ROLLBACK';
    exception when others then
      if sqlerrm <> 'MK_ROLLBACK' then raise; end if;
    end;
    if not rs_set then raise exception 'call did not complete'; end if;
    insert into res values (rs_spec, a.key, w, t.code, exp_c, got, rs_ok, rs_det); rs_set := false;
   end loop;
  end loop;
 end loop;
 -- validation-state controls (owner A, own branch, labelled, not denial credit)
 perform iso.set_claims((select auth_user from iso.actor where key = 'owner|hotel-a|-'));
 for t in select * from mk where code = 'A1' loop
  for w, sa in select * from (values ('unmatch-pending', 'VALIDATION: movement_not_matched'), ('convert-matched', 'VALIDATION: movement_used'), ('reparse-parsed', 'VALIDATION: message_status'), ('match-bad-target', 'VALIDATION: target'), ('convert-wrong-as', 'VALIDATION: convert_as'), ('match-diff-no-reason', 'VALIDATION: difference_reason')) v(a, b) loop
   rs_det := null; msg := null;
   begin
     fxj := pg_temp.fx(t.branch_id, case w when 'unmatch-pending' then 'convert_out' when 'convert-matched' then 'unmatch' when 'reparse-parsed' then 'reparse' when 'match-bad-target' then 'convert_out' when 'convert-wrong-as' then 'convert_in' else 'match_diff' end, 5500);
     if w = 'reparse-parsed' then update bank_messages set status = 'parsed' where id = (fxj->>'message')::uuid; end if;
     set local role authenticated;
     begin
       perform case w when 'unmatch-pending' then fn_bank_unmatch((fxj->>'movement')::uuid, 'MK')
         when 'convert-matched' then fn_bank_convert((fxj->>'movement')::uuid, jsonb_build_object('description', 'x'))
         when 'reparse-parsed' then fn_bank_reparse((fxj->>'message')::uuid)
         when 'match-bad-target' then fn_bank_match((fxj->>'movement')::uuid, jsonb_build_array(jsonb_build_object('type', 'expense', 'id', gen_random_uuid())), null)
         when 'convert-wrong-as' then fn_bank_convert((fxj->>'movement')::uuid, jsonb_build_object('as', 'expense', 'description', 'x'))
         else fn_bank_match((fxj->>'movement')::uuid, jsonb_build_array(jsonb_build_object('type', 'expense', 'id', fxj->>'expense')), null) end;
     exception when others then msg := sqlerrm; end;
     reset role;
     rs_set := true; rs_det := msg;
     raise exception 'MK_ROLLBACK';
   exception when others then if sqlerrm <> 'MK_ROLLBACK' then raise; end if;
   end;
   insert into res values ('validation-label', 'owner|hotel-a|-', w, t.code, sa, coalesce(rs_det, 'allow'), rs_det = sa, null);
  end loop;
 end loop;
end $$;

select spec, count(*) calls, count(*) filter (where expect = 'allow') allow_exp, count(*) filter (where expect <> 'allow' and spec <> 'validation-label') deny_exp, count(*) filter (where expect = 'NOT_FOUND') foreign_owner_exp, count(*) filter (where not ok) failures from res group by 1 order by 1;
select * from res where not ok order by spec, actor, ctx, target limit 40;
select count(*) total_calls, count(*) filter (where not ok) failures from res;
select (:strict = 1 and exists (select 1 from res where not ok)) as fail \gset
\if :fail
  select 1/0 as read_data_bank4_strict_failure;
\endif
rollback;
