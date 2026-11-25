-- Runtime proof of execution-skip precedence with harmless sentinels (never calls a real protected function).
-- Sequences are not rolled back by the probe's rollback, so any invocation is visible. Run on a loaded iso DB, then run the actor wrappers.
create sequence if not exists iso.sent_live; create sequence if not exists iso.sent_skip;
create or replace function iso.sentinel_hit(p_kind text) returns text language plpgsql security definer set search_path = iso, pg_temp as $$
begin
  if p_kind = 'live' then perform nextval('iso.sent_live'); else perform nextval('iso.sent_skip'); end if;
  return 'ISO-sentinel-' || p_kind;
end $$;
grant execute on function iso.sentinel_hit(text) to anon, authenticated;
grant usage on sequence iso.sent_live, iso.sent_skip to anon, authenticated;
insert into iso.rpc_adapter(signature,family,mutates,op,call_sql,reads_target,note) values
  ('fn_iso_sentinel_live()','proof',false,'read',$q$select iso.sentinel_hit('live')$q$,true,'sentinel: must execute'),
  ('fn_iso_sentinel_skip()','proof',false,'read',$q$select iso.sentinel_hit('skip')$q$,true,'sentinel: base adapter on a skipped signature'),
  ('fn_iso_sentinel_skip()#variant','proof',false,'read',$q$select iso.sentinel_hit('skip')$q$,true,'sentinel: variant adapter on a skipped signature')
  on conflict (signature) do nothing;
insert into iso.rpc_adapter_skip(signature,reason) values ('fn_iso_sentinel_skip()','proof sentinel: skip must win over any adapter') on conflict do nothing;
