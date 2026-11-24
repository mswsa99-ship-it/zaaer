import type { Row } from './data';
export const DEMO_OPERATOR = {auth:'82000000-0000-0000-0000-000000000001',email:'platform@demo.sa',name:'مشغّل المنصة',role:'platform'};
type Context={T:(t:string)=>Row[]; uid:()=>string; user:()=>string|null; owner:()=>Row|null; emit:(t:string)=>void; atomic:<V>(f:()=>V)=>V};
export function platformRpcs(c:Context){
 const {T,uid,user,owner,emit}=c;
 const operator=()=>T('platform_operators').find(o=>o.auth_user_id===user()&&o.is_active)?.auth_user_id??null;
 const requireOperator=()=>{const id=operator();if(!id)throw new Error('FORBIDDEN: platform operator required');return id;};
 const event=(org:string,action:string,reason?:string,details:Row={})=>{T('platform_events').push({id:uid(),actor_user_id:user(),organization_id:org,action,reason,details,created_at:new Date().toISOString()});emit('platform_events');};
 const requireOwner=()=>{const o=owner();if(o?.role!=='owner')throw new Error('FORBIDDEN: hotel owner required');return o;};
 return {
  fn_platform_operator_id:()=>operator(),
  fn_platform_hotels:()=>{requireOperator();return T('organizations').map(o=>({id:o.id,name_ar:o.name_ar,slug:o.guest_slug??o.id,status:o.platform_status??'active',branches:T('branches').filter(b=>b.organization_id===o.id).length,pending_owner_id:T('staff_profiles').find(s=>s.organization_id===o.id&&s.role==='owner'&&s.is_active&&!s.auth_user_id)?.id??null,owner_invited:T('staff_profiles').some(s=>s.organization_id===o.id&&s.role==='owner'&&!!s.auth_user_id)}));},
  fn_platform_create_hotel:()=>{throw new Error('OWNER_SELF_SIGNUP_REQUIRED');},
  fn_owner_create_hotel:({p}:{p:Row})=>c.atomic(()=>{
   const auth=user();if(!auth||operator())throw new Error('FORBIDDEN');
   const linked=T('staff_profiles').find(s=>s.auth_user_id===auth);
   if(linked){if(linked.role==='owner'&&linked.is_active)return{ok:true,id:linked.organization_id,existing:true};throw new Error('ACCOUNT_ALREADY_LINKED');}
   const account=T('demo_auth_users').find(s=>s.id===auth);if(!account?.confirmed)throw new Error('EMAIL_NOT_CONFIRMED');
   const em=account.email;
   if(T('staff_profiles').some(s=>s.email===em&&s.is_active))throw new Error('ACCOUNT_PENDING_LINK');
   const branchRows=p?.branches as Row[]|undefined;if(branchRows&&(!Array.isArray(branchRows)||branchRows.length<1||branchRows.length>20||branchRows.some(b=>!b.name_ar?.trim()||!b.city?.trim()||!b.address?.trim()||(b.map_url&&!/^https:\/\//.test(b.map_url)))))throw new Error("VALIDATION: branch_location");
   const n=String(p?.name_ar??'').trim(),bn=String(p?.branch_name??'').trim(),nm=String(p?.full_name??'').trim(),slug=String(p?.slug??'').trim().toLowerCase();
   if(n.length<2||n.length>120||(!branchRows&&(bn.length<2||bn.length>120))||nm.length<3||nm.length>120||! /^[a-z0-9][a-z0-9-]{2,62}$/.test(slug))throw new Error('VALIDATION: hotel_fields');
   if(T('organizations').some(o=>o.guest_slug===slug))throw new Error('VALIDATION: slug_unavailable');
   const id=uid(),branch_id=uid(),owner_profile_id=uid();T('organizations').push({id,name_ar:n,guest_slug:slug,platform_status:'active'});
   T('branches').push({id:branch_id,organization_id:id,name_ar:bn,is_active:true,archived_at:null,timezone:'Asia/Riyadh',country_code:'SA',default_language:'ar',tax_rate_bp:0,prices_include_tax:true});
   if(branchRows){const safe=branchRows.map(br=>({name_ar:br.name_ar.trim(),city:br.city.trim(),address:br.address.trim(),map_url:br.map_url||null}));const first=T('branches').find(b=>b.id===branch_id)!;Object.assign(first,safe[0]);for(const br of safe.slice(1))T('branches').push({...first,...br,id:uid()});}
   T('staff_profiles').push({id:owner_profile_id,organization_id:id,auth_user_id:auth,full_name:nm,email:em,role:'owner',is_active:true});T('branch_memberships').push({id:uid(),staff_id:owner_profile_id,branch_id,organization_id:id,removed_at:null});
   for(const br of T('branches').filter(b=>b.organization_id===id&&b.id!==branch_id))T('branch_memberships').push({id:uid(),staff_id:owner_profile_id,branch_id:br.id,organization_id:id,removed_at:null});
   T('system_settings').push({organization_id:id,demo_mode:false,primary_country:'SA',primary_language:'ar'});T('ai_settings').push({organization_id:id,enabled:false,guest_otp_after_messages:10,guest_device_daily_message_limit:30,guest_branch_daily_message_limit:500,guest_otp_device_hourly_limit:3,guest_otp_phone_hourly_limit:6,guest_otp_cooldown_seconds:60});
   T('audit_events').push({id:uid(),organization_id:id,branch_id,actor_id:owner_profile_id,action:'hotel.owner_self_registered',entity_type:'organization',entity_id:id,details:{branch_id},created_at:new Date().toISOString()});
   for(const t of ['organizations','branches','staff_profiles','branch_memberships','system_settings','ai_settings','audit_events'])emit(t);
   return{ok:true,id,branch_id,owner_profile_id,existing:false};
  }),
  fn_platform_set_hotel_status:({p_org,p_status,p_reason}:Row)=>{requireOperator();if(!['active','suspended'].includes(p_status)||String(p_reason??'').trim().length<5||String(p_reason).length>500)throw new Error('VALIDATION: hotel_status');const o=T('organizations').find(o=>o.id===p_org);if(!o)throw new Error('NOT_FOUND');Object.assign(o,{platform_status:p_status,platform_status_reason:p_reason});if(p_status==='suspended')for(const s of T('staff_profiles').filter(s=>s.organization_id===p_org))s.sessions_ended_at=new Date().toISOString();event(o.id,'hotel.'+p_status,p_reason);emit('organizations');emit('staff_profiles');return{ok:true};},
  fn_platform_owner_invite_target:()=>{throw new Error('OWNER_SELF_SIGNUP_REQUIRED');},
  fn_platform_grant_support:({p_operator,p_reason,p_hours=1}:Row)=>{const o=requireOwner();if(p_operator===user()||!T('platform_operators').some(s=>s.auth_user_id===p_operator&&s.is_active))throw new Error('VALIDATION: operator');if(!Number.isInteger(p_hours)||p_hours<1||p_hours>24||String(p_reason??'').trim().length<5||String(p_reason).length>500)throw new Error('VALIDATION: support_scope');const id=uid();T('platform_support_grants').push({id,organization_id:o.organization_id,operator_user_id:p_operator,approved_by:o.id,reason:p_reason,expires_at:new Date(Date.now()+p_hours*3600000).toISOString(),revoked_at:null});event(o.organization_id,'support.granted',p_reason,{grant_id:id});emit('platform_support_grants');return{id};},
  fn_platform_revoke_support:({p_grant}:Row)=>{const o=requireOwner(),g=T('platform_support_grants').find(g=>g.id===p_grant&&g.organization_id===o.organization_id&&!g.revoked_at);if(!g)throw new Error('NOT_FOUND');g.revoked_at=new Date().toISOString();event(o.organization_id,'support.revoked',undefined,{grant_id:g.id});emit('platform_support_grants');return{ok:true};},
  fn_platform_support_guests:({p_grant}:Row)=>{const id=requireOperator(),g=T('platform_support_grants').find(g=>g.id===p_grant&&g.operator_user_id===id&&!g.revoked_at&&Date.parse(g.expires_at)>Date.now()&&T('organizations').find(o=>o.id===g.organization_id)?.platform_status!=='suspended');if(!g)throw new Error('FORBIDDEN: support grant required');event(g.organization_id,'support.guests_read',g.reason,{grant_id:g.id,fields:['id','full_name'],limit:100});return T('guest_profiles').filter(s=>s.organization_id===g.organization_id).sort((a,b)=>a.id.localeCompare(b.id)).slice(0,100).map(s=>({id:s.id,full_name:s.full_name}));}
 };
}
