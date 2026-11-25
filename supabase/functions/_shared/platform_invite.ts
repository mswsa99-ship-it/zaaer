/** The request can name a pending profile only. Recipient/name come only from the authenticated resolver. */
import { inviteError } from './accounts.ts';
type Target={email:string;full_name:string;organization_id:string};
export async function deliverPlatformInvite(staffId:string,resolve:(id:string)=>Promise<{data:Target|null;error:unknown}>,send:(target:Target)=>Promise<{error:{message?:string;code?:string;status?:number}|null}>){
 const {data,error}=await resolve(staffId);
 if(error||!data||typeof data.email!=='string'||!data.email)return {ok:false,error:'forbidden_or_unavailable'};
 const result=await send(data);
 return result.error?{ok:false,error:inviteError(result.error)}:{ok:true};
}
