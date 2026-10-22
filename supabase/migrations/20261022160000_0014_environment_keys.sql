/*
# 0014 — Environment bootstrap: encryption keys inside the database

Every hosted environment (staging, production) needs two encryption keys: keybox codes and identity
numbers. fn_bootstrap_encryption_keys() creates them INSIDE the database, in Supabase Vault, so they
never pass through CI logs, chat, files or a browser (0013 makes fn_secret read them from there).
It is safe to run any number of times:
  - an existing key is never replaced (that would make the data encrypted with it unreadable);
  - a row is moved onto the real key only when it still decrypts with one of the publicly known
    seed/test keys of this repository ('demo-…-v1' from 0004, 'test-…' from tests/sql/run.sh).
Installs without Vault (local, self-hosted, the test suite) keep using the database settings
app.keybox_key / app.identity_key, and the function changes nothing there.
Only the database owner can run it: no API role (anon, authenticated, service_role) can call it.
*/

create or replace function fn_bootstrap_encryption_keys() returns jsonb
language plpgsql set search_path = public, extensions as $$
declare
  has_vault boolean := to_regclass('vault.secrets') is not null;
  kk text; ik text; lk text; plain text; r record;
  moved_k int := 0; moved_i int := 0;
  legacy_k constant text[] := array['demo-keybox-key-v1', 'test-keybox-key'];
  legacy_i constant text[] := array['demo-id-key-v1', 'test-identity-key'];
begin
  if has_vault then
    if not exists (select 1 from vault.secrets where name = 'app.keybox_key') then
      perform vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'app.keybox_key', 'keybox code encryption');
    end if;
    if not exists (select 1 from vault.secrets where name = 'app.identity_key') then
      perform vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'app.identity_key', 'identity number encryption');
    end if;
  end if;
  begin
    kk := fn_secret('keybox_key');
    ik := fn_secret('identity_key');
  exception when others then
    return jsonb_build_object('vault', has_vault, 'keys_ready', false, 'reencrypted_keybox_codes', 0, 'reencrypted_identity_numbers', 0);
  end;

  for r in select id, code_encrypted from keyboxes where code_encrypted is not null loop
    foreach lk in array legacy_k loop
      continue when lk = kk;
      begin
        plain := pgp_sym_decrypt(r.code_encrypted, lk);
      exception when others then
        plain := null;            -- not encrypted with this key
      end;
      if plain is not null then
        update keyboxes set code_encrypted = pgp_sym_encrypt(plain, kk) where id = r.id;
        moved_k := moved_k + 1;
        exit;
      end if;
    end loop;
  end loop;

  for r in select id, identity_number_encrypted from reservation_guests where identity_number_encrypted is not null loop
    foreach lk in array legacy_i loop
      continue when lk = ik;
      begin
        plain := pgp_sym_decrypt(r.identity_number_encrypted, lk);
      exception when others then
        plain := null;
      end;
      if plain is not null then
        update reservation_guests set identity_number_encrypted = pgp_sym_encrypt(plain, ik) where id = r.id;
        moved_i := moved_i + 1;
        exit;
      end if;
    end loop;
  end loop;

  return jsonb_build_object('vault', has_vault, 'keys_ready', true,
                            'reencrypted_keybox_codes', moved_k, 'reencrypted_identity_numbers', moved_i);
end $$;
revoke all on function fn_bootstrap_encryption_keys() from public, anon, authenticated, service_role;

select fn_bootstrap_encryption_keys();
