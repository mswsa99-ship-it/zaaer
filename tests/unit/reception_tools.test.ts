import { describe,it,expect,vi } from 'vitest';
import { executeTool, type ToolContext } from '../../supabase/functions/_shared/tools';
describe('assistant tool capability revalidation',()=>{
 function context(branch: string|null){
  const rpc=vi.fn(async(name:string)=>name==='fn_guest_session'?{data:branch?{reservation:{branch_id:branch}}:null,error:null}:{data:{access_status:'pending'},error:null});
  const ctx:ToolContext={db:{rpc,from:vi.fn()},organizationId:'hotel-a',branchId:'branch-a',conversationId:'conversation-a',guestToken:'token',appBaseUrl:'https://example.test',propertyName:'Hotel A'};
  return {rpc,ctx};
 }
 it('never submits arrival using a booking from another branch',async()=>{
  const {rpc,ctx}=context('branch-b');
  expect(await executeTool('submit_checkin_request',{},ctx)).toHaveProperty('error');
  expect(rpc.mock.calls.map(c=>c[0])).toEqual(['fn_guest_session']);
 });
 it('never submits an expired session',async()=>{
  const {rpc,ctx}=context(null);await executeTool('submit_checkin_request',{},ctx);
  expect(rpc.mock.calls.map(c=>c[0])).toEqual(['fn_guest_session']);
 });
 it('submits only after same-branch proof',async()=>{
  const {rpc,ctx}=context('branch-a');
  expect(await executeTool('submit_checkin_request',{},ctx)).toHaveProperty('ok',true);
  expect(rpc.mock.calls.map(c=>c[0])).toEqual(['fn_guest_session','fn_guest_submit_checkin']);
 });
});
