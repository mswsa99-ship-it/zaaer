/*
# 0013 — Encryption keys from Supabase Vault (hosted platform)

fn_secret() read the keybox / identity encryption keys from database settings
(`alter database postgres set app.keybox_key = …`). On hosted Supabase (PostgreSQL 15+, `postgres`
is not a superuser) that statement is refused: "permission denied to set parameter". Found while
creating the staging environment.

fn_secret(name) now resolves, in order:
  1. Supabase Vault — secret named 'app.<name>' (vault.decrypted_secrets; encrypted at rest,
     readable only by privileged roles; never exposed through the API);
  2. the database setting app.<name> (local / self-hosted installs and the test suite).
Nothing else changes: callers, grants and error codes stay the same.

Create the keys once per environment, inside the database so they never leave it:
  select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'app.keybox_key',   'keybox code encryption');
  select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'app.identity_key', 'identity number encryption');
Never rotate them by re-creating: data encrypted with the old key would become unreadable.
*/
create or replace function fn_secret(p_name text) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare v text;
begin
  -- 1) Supabase Vault (dynamic SQL so this compiles where the vault extension is absent)
  if to_regclass('vault.decrypted_secrets') is not null then
    begin
      execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 order by created_at desc limit 1'
        into v using 'app.' || p_name;
    exception when insufficient_privilege or undefined_table or invalid_schema_name then
      v := null;
    end;
  end if;
  -- 2) database setting (local / self-hosted / tests)
  if v is null or v = '' then
    v := current_setting('app.' || p_name, true);
  end if;
  if v is null or v = '' then
    raise exception 'SECRET_NOT_CONFIGURED: app.%', p_name using errcode = 'P0001';
  end if;
  return v;
end $$;
revoke all on function fn_secret(text) from public, anon, authenticated;
