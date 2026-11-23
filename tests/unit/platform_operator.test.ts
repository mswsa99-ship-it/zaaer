import {beforeAll,describe,it,expect,vi} from 'vitest';
import {DEMO_OPERATOR} from '../../src/demo/platform';
let client:ReturnType<typeof import('../../src/demo/client')['createDemoClient']>;
const storage=()=>{const m=new Map<string,string>();return{getItem:(k:string)=>m.get(k)??null,setItem:(k:string,v:string)=>m.set(k,v),removeItem:(k:string)=>m.delete(k)};};
beforeAll(async()=>{vi.stubGlobal('window',globalThis);vi.stubGlobal('localStorage',storage());vi.stubGlobal('sessionStorage',storage());const d=await import('../../src/demo/client');d.resetDemo();client=d.createDemoClient();});
describe('platform identity and narrow onboarding demo parity',()=>{
 it('denies hotel owner, creates a separate hotel as operator, and scopes its invited owner',async()=>{
  await client.auth.signInWithPassword({email:'owner@demo.sa',password:'demo'});
  expect((await client.rpc('fn_platform_hotels')).error).not.toBeNull();
  await client.auth.signInWithPassword({email:DEMO_OPERATOR.email,password:'demo'});
  expect((await client.rpc('fn_claim_staff_profile')).data.error).toBe('PLATFORM_ACCOUNT');
  expect((await client.from('guest_profiles').select('*')).data).toEqual([]);
  const created=await client.rpc('fn_platform_create_hotel',{p:{name_ar:'فندق جديد اختباري',branch_name:'فرع جديد',owner_name:'مالك اختباري جديد',owner_email:'new-owner@example.test',slug:'new-platform-hotel'}});
  expect(created.error).toBeNull();
  expect((await client.functions.invoke('platform-invite',{body:{staff_id:created.data.owner_profile_id}})).data).toMatchObject({ok:true,simulated:true});
  await client.auth.signInWithPassword({email:'new-owner@example.test',password:'demo'});
  expect((await client.rpc('fn_claim_staff_profile')).data.claimed).toBe(true);
  const rows=await client.from('branches').select('*');expect(rows.data).toHaveLength(1);expect(rows.data[0].organization_id).toBe(created.data.id);
  expect((await client.rpc('fn_platform_hotels')).error).not.toBeNull();
  await client.auth.signInWithPassword({email:'owner@demo.sa',password:'demo'});
  expect((await client.from('branches').select('*')).data.every((b:any)=>b.organization_id!==created.data.id)).toBe(true);
  await client.auth.signInWithPassword({email:DEMO_OPERATOR.email,password:'demo'});
  await client.rpc('fn_platform_set_hotel_status',{p_org:created.data.id,p_status:'suspended',p_reason:'اختبار إيقاف الفندق'});
  await client.auth.signInWithPassword({email:'new-owner@example.test',password:'demo'});
  expect((await client.rpc('fn_staff_id')).data).toBeNull();
 });
});
