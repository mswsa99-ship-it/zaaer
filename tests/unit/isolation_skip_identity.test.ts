import {describe,it,expect} from 'vitest';
import {existsSync,readFileSync} from 'node:fs';
// Identity (not count) of the protected execution-skip set: outbound/queue, new-org and platform-operator functions never get coverage credit.
const PROTECTED=[
 'fn_log_client_error(p_trace text, p_code text, p_context text)','fn_owner_register_hotel(p jsonb)',
 'fn_platform_grant_support(p_operator uuid, p_reason text, p_hours integer)','fn_platform_payout_cancel(p_payout uuid, p_reason text)',
 'fn_platform_payout_confirm(p jsonb)','fn_platform_revoke_support(p_grant uuid)','fn_platform_set_hotel_status(p_org uuid, p_status text, p_reason text)',
 'fn_staff_deliver_access_code(p_reservation uuid, p_channel text)','fn_staff_journey_tick(p_branch uuid)'];
const file='tests/isolation/rpc-adapters.sql';
describe.skipIf(!existsSync(file))('protected skip set by identity',()=>{
 const sql=existsSync(file)?readFileSync(file,'utf8'):'';
 const skips=[...sql.matchAll(/insert into iso\.rpc_adapter_skip\(signature,reason\) values \(\$s\$([^$]*)\$s\$,\$r\$([^$]+)\$r\$/g)];
 it('registers exactly the protected signatures, each with a reason',()=>{expect(skips.map(m=>m[1]).sort()).toEqual([...PROTECTED].sort());expect(skips.every(m=>m[2].length>10)).toBe(true);});
 it('has no executable adapter row for a protected signature',()=>{
  const adapters=[...sql.matchAll(/insert into iso\.rpc_adapter\(signature[^)]*\) values \(\$s\$([^$]*)\$s\$/g)].map(m=>m[1].split('#')[0]);
  expect(adapters.filter(s=>PROTECTED.includes(s))).toEqual([]);});
 it('has no duplicate adapter signature (on conflict do nothing would silently drop the later row)',()=>{
  const adapters=[...sql.matchAll(/^insert into iso\.rpc_adapter\(signature[^)]*\) values \(\$s\$([^$]*)\$s\$/gm)].map(m=>m[1]);
  const dup=adapters.filter((s,i)=>adapters.indexOf(s)!==i);
  expect(dup).toEqual([]);});
});
