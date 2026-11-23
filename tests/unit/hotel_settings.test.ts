import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const migration = readFileSync(join(__dirname,"../../supabase/migrations/20261123150000_0079_hotel_settings.sql"),"utf8");
describe("HS hotel settings defaults",()=>{
 it("HS20 settings seed uses defaults and never copies another hotel's settings",()=>{
  expect(migration).toMatch(/insert into ai_settings\(organization_id\) values\(p_org\) on conflict do nothing/);
  expect(migration).toMatch(/insert into system_settings\(organization_id\) values\(p_org\) on conflict do nothing/);
  expect(migration).not.toMatch(/insert into (?:ai_settings|system_settings)[\s\S]*?select \*/i);
  expect(migration).not.toMatch(/password_encrypted|relay_key_encrypted|secret_key_encrypted|last_uid/);
 });
 it("HS21 initialization is a transaction trigger and both helpers are private",()=>{
  expect(migration).toMatch(/after insert on public\.organizations/);
  expect(migration).toMatch(/revoke all on function public\.fn_hotel_settings_seed\(uuid\) from public,anon,authenticated/);
  expect(migration).toMatch(/revoke all on function public\.fn_trg_hotel_settings_seed\(\) from public,anon,authenticated/);
 });
 it("HS22 bank defaults are only for a hotel with no rules, preserving its edited list",()=>{
  expect(migration).toMatch(/where not exists\(select 1 from bank_parse_rules x where x\.organization_id=p_org\)/);
  expect(migration).toMatch(/pg_advisory_xact_lock/);
 });
});
