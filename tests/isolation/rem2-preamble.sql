-- Shared preamble for the remaining2 local money proofs. Disposable database only; caller has issued "begin;".
-- No network, no credentials. Hard RAISE on any outbound precondition. Existing outbox rows in
-- synthetic isolation orgs are preserved byte-for-byte; no cleanup occurs.
do $$ begin
 if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'REFUSED: enabled keyed web_bridge channel exists'; end if;
end $$;
create temp table rm_assert(name text, ok boolean, detail text);
create function pg_temp.chk(n text, b boolean, d text default null) returns void language sql as $$insert into rm_assert values(n, coalesce(b,false), d)$$;
create temp table rm_ob0 as select id,to_jsonb(w) row_data from whatsapp_outbox w;
create function pg_temp.guard(lbl text) returns void language plpgsql as $$
begin
 if exists(select 1 from branch_whatsapp_channels where enabled and mode='web_bridge' and bridge_key_hash is not null) then raise exception 'PRECONDITION FAILED before %: enabled keyed web_bridge', lbl; end if;
 if exists((select id,to_jsonb(w) from whatsapp_outbox w except select id,row_data from rm_ob0) union all (select id,row_data from rm_ob0 except select id,to_jsonb(w) from whatsapp_outbox w)) then raise exception 'OUTBOX CHANGED before %',lbl;end if;
end $$;
select pg_temp.chk('baseline outbox preserved without cleanup',true);
-- run one call as an actor (null key = anon), return error text or null; session role always reset after.
create function pg_temp.act(p_actor text) returns void language plpgsql as $$
declare a iso.actor%rowtype;
begin
 select * into a from iso.actor where key = p_actor;
 if p_actor = 'guest|-|-' then perform iso.set_claims(null); set local role anon; else perform iso.set_claims(a.auth_user); set local role authenticated; end if;
end $$;
