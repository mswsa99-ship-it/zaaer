import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {generateMatrix} from './matrix-generator.mjs';

/** Raw observations never become PASS without a valid control, permission oracle and complete adapter. */
export function assessCell(cell, probe, control, immutable) {
  if (cell.status === 'exempt') return {status:'exception-review', reason:cell.reason};
  if (!probe) return {status:'unexecuted', reason:'No executed adapter for this exact cell'};
  if (immutable) {
    // Reviewed immutability: the control must be refused by the cited guard, so the guard demonstrably fires for the owner.
    if (!control || control.outcome!=='denied' || !String(control.sqlerrm??'').startsWith(immutable.guard_prefix))
      return {status:'invalid-control', reason:'Immutable guard did not fire for the control: '+immutable.source};
    if (probe.side_effect || (probe.rows_ret??0)>0 || probe.outcome==='success' && probe.rows_ret>0)
      return {status:'boundary-success-review', reason:'Immutable operation changed data: '+immutable.source};
    if (probe.outcome==='denied' || probe.outcome==='success' && probe.rows_ret===0)
      return {status:'immutable-deny-verified', reason:'Guard refuses the owner control and the actor changed nothing. Not role isolation evidence: '+immutable.source};
  }
  if (control?.outcome==='scope-violation')
    return {status:'boundary-success-review', reason:'Positive owner control changed slices outside its own hotel: '+String(control.detail??'').slice(0,300)};
  if (!control || control.outcome!=='control-ok' || !(control.rows_ret>0))
    return {status:'invalid-control', reason:'Valid positive control missing or rejected; cannot infer permission denial'};
  if (probe.outcome==='adapter-incomplete') return {status:'unexecuted', reason:probe.detail};
  if (probe.errclass && probe.errclass!=='permission')
    return {status:'invalid-data-or-error', reason:probe.sqlerrm};
  if (probe.outcome==='success' && probe.rows_ret===0 && /public_keys_ok=true/.test(probe.detail??'') && /public_identity_ok=true/.test(probe.detail??''))
    return {status:'public-exception-verified', reason:'Returned only the documented public fields. Not isolation evidence, source exception needs adjudication'};
  const hardDeny = cell.surface==='function' && cell.actor?.hotel!==cell.target?.hotel;
  if (cell.expected==='deny' || hardDeny) {
    if (probe.side_effect || (probe.rows_ret??0)>0)
      return {status:'boundary-success-review', reason:'Blanket boundary expectation violated. Review operation-specific policy before calling this a product vulnerability'};
    if (cell.surface==='function' && (/effect=unasserted/.test(probe.detail??'') || /effect=asserted-ok/.test(probe.detail??'') && /nontarget=unproven/.test(probe.detail??'')) && probe.outcome==='success')
      return {status:'oracle-incomplete', reason:'Mutating function has no source-grounded effect_sql/guard_sql assertion: an unchanged target row and untouched non-target actors are unproven'};
    if (probe.outcome==='denied' && probe.errclass==='permission' || probe.outcome==='success' && probe.rows_ret===0)
      return {status:'observed-denial', reason:'Valid control and no target reached. Not full role/capability acceptance'};
  }
  return {status:'oracle-incomplete', reason:'Role-operation oracle and exact adapter still need review'};
}
/** Variant adapters use '<base signature>#<variant>' (e.g. a lazy-first-use fixture). They never replace the base probe. */
/** Additive provenance only, never an acceptance oracle. Counts matching JSON object occurrences,
 * not unique database rows, people, or individual fields. Nullish means null branch_id or empty branch_ids.
 * Mutators are unmeasured. Raw marker counts and statuses are unchanged. */
export function fieldScope(probe) {
  const d=String(probe?.detail??''); const m=/branch_struct=(\d+) branch_null=(\d+) prov=([a-z-]+)/.exec(d);
  if (!m) return undefined;
  return {structuredBranchObjects:+m[1], nullishBranchObjects:+m[2], provenance:m[3], raw:{markers:+((/markers=(\d+)/.exec(d)||[])[1]??0)}};
}
export const baseSignature = sig => String(sig).split('#')[0];
export const variantName = sig => String(sig).includes('#') ? String(sig).slice(String(sig).indexOf('#')+1) : null;
/** A variant can only worsen the base cell: a leak in any variant makes the base cell a boundary review. Variants never upgrade a status. */
export function combineVariants(base, variants) {
  const leak = variants.find(v=>v.status==='boundary-success-review');
  const out = leak && base.status!=='boundary-success-review'
    ? {status:'boundary-success-review', reason:'Variant #'+leak.variant+': '+leak.reason}
    : {status:base.status, reason:base.reason};
  return {...out, variants};
}
export function aggregate(rows) {
  const counts={}; for(const r of rows) counts[r.status]=(counts[r.status]??0)+1;
  return {passed:false, acceptance:'INCOMPLETE', total:rows.length, counts,
    reason:'General RPC adapters, unique composite-key fixtures, role-operation oracles and reviewed exceptions remain incomplete. No row is reported PASS.'};
}
export function report(dir, immutableRows = []) {
  const json=p=>JSON.parse(readFileSync(p,'utf8'));
  const matrix=generateMatrix(json('supabase/tenancy.json'),json('supabase/function-scope.json'),json(dir+'/catalog.json'));
  const probes=json(dir+'/probes.json'); const imm=new Map(immutableRows.map(i=>[i.tbl+'|'+i.op,i])); const index=new Map(probes.map(p=>[p.probe_id,p]));
  const variantsBySig=new Map(); const variantProbeIds=new Set();
  for (const p of probes) { const sig=String(p.probe_id).split('|')[1]; const v=variantName(sig); if (v!==null) { const b=baseSignature(sig); variantsBySig.set(b,[...(variantsBySig.get(b)??[])].includes(v)?variantsBySig.get(b):[...(variantsBySig.get(b)??[]),v]); variantProbeIds.add(p.probe_id); } }
  const usedVariantProbes=new Set(); const variantCounts={};
  let skipInfo; try { skipInfo=json(dir+'/skips.json'); } catch { skipInfo=null; }
  const skipMap=new Map((skipInfo?.skips??[]).map(k=>[k.signature,k.reason]));
  const detailed=matrix.map(cell=>{
    if (cell.surface==='function' && skipMap.has(cell.signature)) return {...cell,status:'unexecuted',reason:'Explicitly skipped, not credited, never executed: '+skipMap.get(cell.signature)};
    const actor=cell.actor.role==='guest'?'guest|-|-':`${cell.actor.role}|${cell.actor.hotel}|${cell.actor.role==='owner'?'-':cell.actor.branch}`;
    const target=`${cell.target.hotel}|${cell.target.branch}`;
    const key=`${cell.surface}|${cell.signature}|${cell.operation}|${actor}|${target}`;
    const probe=index.get(key), control=index.get(`${cell.surface}|${cell.signature}|${cell.operation}|control|${target}`);
    const base=assessCell(cell,probe,control,cell.surface==='table'?imm.get(cell.signature+'|'+cell.operation):undefined);
    const variants=(variantsBySig.get(cell.signature)??[]).map(v=>{
      const vsig=cell.signature+'#'+v;
      const vp=index.get(`${cell.surface}|${vsig}|${cell.operation}|${actor}|${target}`), vc=index.get(`${cell.surface}|${vsig}|${cell.operation}|control|${target}`);
      if (vp) usedVariantProbes.add(vp.probe_id); if (vc) usedVariantProbes.add(vc.probe_id);
      const r=assessCell(cell,vp,vc); variantCounts[v]??={}; variantCounts[v][r.status]=(variantCounts[v][r.status]??0)+1;
      return {variant:v,status:r.status,reason:r.reason};
    });
    return {...cell,...(variants.length?combineVariants(base,variants):base),probe_id:probe?.probe_id,control_id:control?.probe_id,...(fieldScope(probe)?{fieldScope:fieldScope(probe)}:{})};
  });
  const summary=aggregate(detailed);
  summary.rawProbeCount=probes.length;
  summary.variantCounts=variantCounts;
  summary.readinessBlockers=[];
  const matrixSigs=new Set(matrix.filter(c=>c.surface==='function').map(c=>c.signature));
  summary.skipped=[...skipMap.keys()];
  if (!skipInfo) summary.readinessBlockers.push('skips.json missing: execution-skip precedence cannot be verified');
  for (const sig of skipMap.keys()) if (!matrixSigs.has(sig)) summary.readinessBlockers.push('skip signature matches no matrix function: '+sig);
  for (const sig of skipInfo?.conflicts??[]) summary.readinessBlockers.push('adapter exists for a skipped signature (skip wins, not executed): '+sig);
  summary.orphanVariantProbes=[...variantProbeIds].filter(id=>!usedVariantProbes.has(id)).length;
  if (summary.orphanVariantProbes>0) summary.readinessBlockers.push('orphan-variant-probes:'+summary.orphanVariantProbes+' (variant adapter matched no matrix cell, fix the adapter signature)');
  summary.guestLinks=json(dir+'/guest-links.json');
  writeFileSync(dir+'/matrix.json',JSON.stringify(detailed)+'\n');
  writeFileSync(dir+'/summary.json',JSON.stringify(summary,null,2)+'\n');
  writeFileSync(dir+'/matrix.csv','id,status,reason,probe_id,control_id\n'+detailed.map(r=>[r.id,r.status,r.reason,r.probe_id??'',r.control_id??''].map(v=>'"'+v.replaceAll('"','""')+'"').join(',')).join('\n')+'\n');
  console.log(JSON.stringify(summary,null,2));
  return 1;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) process.exitCode=report(process.argv[2], (()=>{try{return JSON.parse(readFileSync(process.argv[2]+'/immutable.json','utf8'));}catch{return [];}})());
