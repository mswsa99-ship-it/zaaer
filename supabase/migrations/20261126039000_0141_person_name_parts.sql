-- Name rule decided by the user 25 Nov 2026 13:17: every part of a person's name has at least two letters (so «طه» is
-- accepted) and a part made of one repeated letter is refused. The number of parts (word count) is unchanged and lives in
-- the callers. Mirrors checkPersonName in src/lib/validation.ts. Changes no stored data: it applies to writes from now on.
-- NOT APPLIED to any live database; review before it is.
create or replace function fn_check_person_name(p text) returns void
language plpgsql immutable set search_path = public as $$
declare part text; letters text;
begin
  if p is null or btrim(p) = '' then return; end if;
  if btrim(p) !~ '^[A-Za-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u024F\u0621-\u063A\u0640-\u0652\u0670-\u06D3 ''’.-]+$' then
    raise exception 'VALIDATION: name_letters_only';
  end if;
  for part in select x from regexp_split_to_table(btrim(p), '\s+') as x loop
    letters := lower(regexp_replace(part, '[^A-Za-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u024F\u0621-\u063A\u0641-\u064A\u0671-\u06D3]', '', 'g'));
    if length(letters) < 2 or letters ~ '^(.)\1*$' then
      raise exception 'VALIDATION: name_letters_only';
    end if;
  end loop;
end $$;
revoke all on function fn_check_person_name(text) from public, anon, authenticated;
