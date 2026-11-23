/** Plan2.8: only an active platform operator can invite the pending first hotel owner. */
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { projectKey } from '../_shared/keys.ts';
import { resetUrl } from '../_shared/accounts.ts';
import { deliverPlatformInvite } from '../_shared/platform_invite.ts';
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS'};
const json=(b:unknown,s=200)=>new Response(JSON.stringify(b),{status:s,headers:{...cors,'Content-Type':'application/json'}});
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return json({error:'method'},405);
 const authorization=req.headers.get('authorization')??'';
 if(!authorization.toLowerCase().startsWith('bearer '))return json({error:'unauthorized'},401);
 let body:Record<string,unknown>;try{body=await req.json();}catch{return json({error:'bad_json'},400);}
 const id=body.staff_id;if(typeof id!=='string'||! /^[0-9a-f-]{36}$/i.test(id))return json({error:'staff_id'},400);
 const url=Deno.env.get('SUPABASE_URL')!;
 const caller=createClient(url,projectKey('publishable'),{global:{headers:{Authorization:authorization}},auth:{persistSession:false}});
 const result=await deliverPlatformInvite(id,
  async staffId=>{const {data,error}=await caller.rpc('fn_platform_owner_invite_target',{p_staff:staffId});return{data,error};},
  async target=>{const admin=createClient(url,projectKey('secret'),{auth:{persistSession:false}});return admin.auth.admin.inviteUserByEmail(target.email,{redirectTo:resetUrl(Deno.env.get('APP_BASE_URL')),data:{full_name:target.full_name}});});
 return json(result,result.error==='forbidden_or_unavailable'?403:200);
});
