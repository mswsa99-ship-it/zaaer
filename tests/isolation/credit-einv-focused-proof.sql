-- Bounded canonical-engine proof. Requires four target fixtures, separate einv purpose and the #einv adapter.
-- No guest header/JWT reinterpretation. Each successful probe rolls back its business changes in the engine.
\set ON_ERROR_STOP on
begin;
do $$ declare t record; a record; actor text; own uuid; sig text:='fn_issue_credit_note(p_invoice uuid, p_reason text)#einv'; begin
 assert (select count(*) from iso.created where tbl='invoices' and purpose='einv')=4, 'four separate einv invoices required';
 for t in select * from iso.target order by key loop
  select auth_user into own from iso.actor where role='owner' and hotel=t.hotel;
  perform iso.set_claims(own);set local role authenticated;
  perform iso.rpc_probe('credit-control|'||t.key,sig,'control',t.key,true,iso.snap());
  reset role;
 end loop;
 update iso.probe_result set outcome='control-ok' where probe_id like 'credit-control|%' and outcome='success';
 for t in select * from iso.target order by key loop
  for a in select * from iso.actor where
      (role='manager' and hotel=t.hotel) or (hotel<>t.hotel and (role='owner' or (role='manager' and branch='branch-1'))) order by key loop
   perform iso.set_claims(a.auth_user);set local role authenticated;
   perform iso.rpc_probe('credit-actor|'||a.key||'|'||t.key,sig,a.key,t.key,false,iso.snap());
   reset role;
  end loop;
 end loop;
end $$;
select probe_id,outcome,errclass,rows_ret,side_effect,detail from iso.probe_result where probe_id like 'credit-%' order by probe_id;
do $$ begin
 assert (select count(*) from iso.probe_result where probe_id like 'credit-control|%' and outcome='control-ok' and rows_ret>0 and detail like '%nontarget=proved-rowlevel effect=asserted-ok%')=4, 'four exact valid owner controls';
 assert (select count(*) from iso.probe_result p join iso.target t on t.key=p.target_key where p.probe_id like 'credit-actor|%' and split_part(p.actor_key,'|',2)=t.hotel and split_part(p.actor_key,'|',3)=t.branch and p.outcome='success' and p.detail like '%nontarget=proved-rowlevel effect=asserted-ok%')=4, 'four own branch exact manager successes';
 assert (select count(*) from iso.probe_result p join iso.target t on t.key=p.target_key where p.probe_id like 'credit-actor|%' and not(split_part(p.actor_key,'|',2)=t.hotel and split_part(p.actor_key,'|',3)=t.branch) and p.outcome='denied' and p.errclass='permission' and p.side_effect=false)=12, 'three foreign actors denied per target';
 assert not exists(select 1 from invoices where credit_note_of in(select id::uuid from iso.created where tbl='invoices' and purpose='einv')), 'successful credit probes rolled back';
end $$;
rollback;
