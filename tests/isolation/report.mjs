import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {generateMatrix} from './matrix-generator.mjs';

/** Raw observations never become PASS without a valid control, permission oracle and complete adapter. */
export function assessCell(cell, probe, control) {
  if (cell.status === 'exempt') return {status:'exception-review', reason:cell.reason};
  if (!probe) return {status:'unexecuted', reason:'No executed adapter for this exact cell'};
  if (!control || control.outcome!=='control-ok' || !(control.rows_ret>0))
    return {status:'invalid-control', reason:'Valid positive control missing or rejected; cannot infer permission denial'};
  if (probe.outcome==='adapter-incomplete') return {status:'unexecuted', reason:probe.detail};
  if (probe.errclass && probe.errclass!=='permission')
    return {status:'invalid-data-or-error', reason:probe.sqlerrm};
  if (cell.expected==='deny') {
    if (probe.side_effect || (probe.rows_ret??0)>0)
      return {status:'boundary-success-review', reason:'Blanket boundary expectation violated. Review operation-specific policy before calling this a product vulnerability'};
    if (probe.outcome==='denied' && probe.errclass==='permission' || probe.outcome==='success' && probe.rows_ret===0)
      return {status:'observed-denial', reason:'Valid control and no target reached. Not full role/capability acceptance'};
  }
  return {status:'oracle-incomplete', reason:'Role-operation oracle and exact adapter still need review'};
}
export function aggregate(rows) {
  const counts={}; for(const r of rows) counts[r.status]=(counts[r.status]??0)+1;
  return {passed:false, acceptance:'INCOMPLETE', total:rows.length, counts,
    reason:'General RPC adapters, unique composite-key fixtures, role-operation oracles and reviewed exceptions remain incomplete. No row is reported PASS.'};
}
export function report(dir) {
  const json=p=>JSON.parse(readFileSync(p,'utf8'));
  const matrix=generateMatrix(json('supabase/tenancy.json'),json('supabase/function-scope.json'),json(dir+'/catalog.json'));
  const probes=json(dir+'/probes.json'); const index=new Map(probes.map(p=>[p.probe_id,p]));
  const detailed=matrix.map(cell=>{
    const actor=cell.actor.role==='guest'?'guest|-|-':`${cell.actor.role}|${cell.actor.hotel}|${cell.actor.role==='owner'?'-':cell.actor.branch}`;
    const target=`${cell.target.hotel}|${cell.target.branch}`;
    const key=`${cell.surface}|${cell.signature}|${cell.operation}|${actor}|${target}`;
    const probe=index.get(key), control=index.get(`${cell.surface}|${cell.signature}|${cell.operation}|control|${target}`);
    return {...cell,...assessCell(cell,probe,control),probe_id:probe?.probe_id,control_id:control?.probe_id};
  });
  const summary=aggregate(detailed);
  summary.rawProbeCount=probes.length;
  summary.guestLinks=json(dir+'/guest-links.json');
  writeFileSync(dir+'/matrix.json',JSON.stringify(detailed)+'\n');
  writeFileSync(dir+'/summary.json',JSON.stringify(summary,null,2)+'\n');
  writeFileSync(dir+'/matrix.csv','id,status,reason,probe_id,control_id\n'+detailed.map(r=>[r.id,r.status,r.reason,r.probe_id??'',r.control_id??''].map(v=>'"'+v.replaceAll('"','""')+'"').join(',')).join('\n')+'\n');
  console.log(JSON.stringify(summary,null,2));
  return 1;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) process.exitCode=report(process.argv[2]);
