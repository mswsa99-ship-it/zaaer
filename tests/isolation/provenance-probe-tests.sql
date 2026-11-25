-- Engine-only sentinel tests in a disposable empty local database. No application RPC or mutator runs.
\set ON_ERROR_STOP on
begin;
insert into iso.target values ('proof|branch-2','proof','branch-2','11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222');
create sequence iso.provenance_probe_calls;
insert into iso.rpc_adapter(signature,family,mutates,call_sql) values
 ('iso_provenance_read()','proof',false,$q$select nextval('iso.provenance_probe_calls') as ordinal, '{branch}'::uuid as branch_id from generate_series(1,3)$q$),
 ('iso_provenance_mutator_label()','proof',true,$q$select nextval('iso.provenance_probe_calls') as ordinal$q$);
select iso.rpc_probe('proof-read','iso_provenance_read()','manager|proof|branch-1','proof|branch-2',false,iso.snap());
do $$
begin
 assert (select last_value from iso.provenance_probe_calls) = 3, 'one read execution, not two';
 assert exists(select 1 from iso.probe_result where probe_id='proof-read' and outcome='success' and rows_ret=1 and side_effect=false and detail like 'markers=1 %branch_struct=3 branch_null=0 prov=structured%'), 'raw outcome/count plus additive structured provenance';
end $$;
select iso.rpc_probe('proof-mutator-label','iso_provenance_mutator_label()','manager|proof|branch-1','proof|branch-2',false,iso.snap());
do $$
begin
 assert (select last_value from iso.provenance_probe_calls) = 4, 'mutator-labelled sentinel executed once';
 assert exists(select 1 from iso.probe_result where probe_id='proof-mutator-label' and outcome='success' and detail like '%branch_struct=0 branch_null=0 prov=unmeasured%'), 'mutator never presented as measured zero';
end $$;
rollback;
