import {describe,it,expect,vi} from 'vitest';
import {deliverPlatformInvite} from '../../supabase/functions/_shared/platform_invite';
const target={email:'synthetic-owner@example.test',full_name:'مالك اختباري',organization_id:'hotel-a'};
describe('platform invite authority boundary with mocked delivery',()=>{
 it('delivers only to caller-scoped database target',async()=>{
  const resolve=vi.fn().mockResolvedValue({data:target,error:null});const send=vi.fn().mockResolvedValue({error:null});
  expect(await deliverPlatformInvite('pending-profile',resolve,send)).toEqual({ok:true});
  expect(resolve).toHaveBeenCalledWith('pending-profile');expect(send).toHaveBeenCalledWith(target);expect(send).toHaveBeenCalledTimes(1);
 });
 it('forbidden inactive suspended linked or missing targets never reach email delivery',async()=>{
  for(const result of [{data:null,error:{message:'FORBIDDEN'}},{data:null,error:null},{data:target,error:{message:'NOT_FOUND'}}]){
   const send=vi.fn();expect(await deliverPlatformInvite('any',async()=>result,send)).toEqual({ok:false,error:'forbidden_or_unavailable'});expect(send).not.toHaveBeenCalled();
  }
 });
 it('does not claim success if mail rate limits or fails',async()=>{
  expect(await deliverPlatformInvite('pending',async()=>({data:target,error:null}),async()=>({error:{status:429}}))).toEqual({ok:false,error:'rate_limited'});
 });
});
