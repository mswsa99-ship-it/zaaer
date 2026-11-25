import { describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';
import * as ops from '../../supabase/functions/_shared/ops';
import * as budgets from '../../supabase/functions/_shared/budget_reads';

type Row = Record<string, any>;
async function briefing(hotel: 'A'|'B', foreignBranch=false) {
  let serve!: (request: Request)=>Promise<Response>;
  const generate=vi.fn(async(input:unknown)=>({text:'راجع مهام اليوم.',usage:{input:0,output:0},toolCalls:[],input}));
  const trace: Row[]=[];
  const branchId=foreignBranch?(hotel==='A'?'B1':'A1'):`${hotel}1`;
  const tables: Record<string,Row[]>={
    staff_profiles:['A','B'].map(id=>({id:`staff-${id}`,organization_id:id,full_name:`STAFF_${id}`,role:'owner'})),
    branches:['A1','A2','B1','B2'].map(id=>({id,organization_id:id[0],name_ar:`BRANCH_${id}`,timezone:'Asia/Riyadh'})),
    organizations:['A','B'].map(id=>({id,name_ar:`HOTEL_${id}`})),
    ai_settings:['A','B'].map(organization_id=>({organization_id,enabled:true,ops_enabled:true,briefing_with_insights:true,model:'local-stub',extra_instructions:`INSTRUCTIONS_${organization_id}`})),
    ai_usage_daily:[],
  };
  // RPC is the existing database boundary, not reimplemented as proof of its SQL guard.
  // A user client sees only its own hotel in this synthetic boundary contract.
  function client(privileged:boolean) {
    return {
      async rpc(name:string,args:Row={}) {
        trace.push({kind:'rpc',privileged,name,args});
        if(name==='fn_staff_id')return {data:`staff-${hotel}`,error:null};
        if(name==='fn_user_page_can')return {data:true,error:null};
        if(name==='fn_ai_ops_context') {
          if(privileged)throw new Error('ops context must use caller client, never admin');
          if(!args.p_branch.startsWith(hotel))return {data:null,error:{message:'forbidden'}};
          return {data:{summary:{date:'2026-11-24',units:{}},branch:{name:`CONTEXT_${args.p_branch}`},sentinel:`FACT_${args.p_branch}`},error:null};
        }
        return {data:null,error:null};
      },
      from(table:string) {
        const filters:((r:Row)=>boolean)[]=[];let single=false,write=false;
        const c:Row={};
        c.select=()=>c;c.eq=(k:string,v:unknown)=>{filters.push(r=>r[k]===v);return c;};
        c.single=c.maybeSingle=()=>{single=true;return c;};
        c.insert=()=>{write=true;return c;};
        c.then=(resolve:(r:unknown)=>unknown,reject:(e:unknown)=>unknown)=>Promise.resolve().then(()=>{
          trace.push({kind:'table',table,privileged,write});
          const rows=(tables[table]??[]).filter(r=>(privileged||!r.organization_id||r.organization_id===hotel)&&filters.every(f=>f(r)));
          return {data:single?(rows[0]??null):rows,error:null};
        }).then(resolve,reject);
        return c;
      },
    };
  }
  let source=readFileSync(new URL('../../supabase/functions/ai-ops/index.ts',import.meta.url),'utf8');
  const mutations:Record<string,[string,string]>={
    settings:['.eq("organization_id", staff.organization_id).maybeSingle()','.eq("organization_id", staff.organization_id === "A" ? "B" : "A").maybeSingle()'],
    client:['await user.rpc("fn_ai_ops_context",','await admin.rpc("fn_ai_ops_context",'],
  };
  const mutant=process.env.OPS_CONTEXT27_MUTANT;
  if(mutant){const pair=mutations[mutant];if(!pair||source.split(pair[0]).length!==2)throw new Error('mutation anchor not unique');source=source.replace(...pair);}
  const dependencies:Row={
    'npm:@supabase/supabase-js@2.45.4':{createClient:(_url:string,key:string)=>client(key==='secret')},
    '../_shared/keys.ts':{projectKey:(kind:string)=>kind},
    '../_shared/ops.ts':ops,
    '../_shared/budget_reads.ts':budgets,
    '../_shared/llm.ts':{createProvider:()=>({generate}),ProviderError:class extends Error{}},
  };
  runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
    exports:{},require:(name:string)=>{if(!(name in dependencies))throw new Error(`unmocked import ${name}`);return dependencies[name];},
    Deno:{serve:(fn:typeof serve)=>{serve=fn;},env:{get:()=> 'https://local.invalid'}},Response,console,
    fetch:()=>{throw new Error('network prohibited');},
  });
  const response=await serve(new Request('https://local.invalid',{method:'POST',headers:{authorization:'Bearer local-test-only','content-type':'application/json'},body:JSON.stringify({mode:'briefing',branch_id:branchId})}));
  return {response,body:await response.json(),generate,trace};
}

describe('plan 2.7 actual Ops briefing context, two hotels',()=>{
  for(const hotel of ['A','B'] as const)it(`passes only ${hotel} context and settings to local provider using the user RPC client`,async()=>{
    const h=await briefing(hotel);expect(h.response.status).toBe(200);expect(h.generate).toHaveBeenCalledOnce();
    const input=JSON.stringify(h.generate.mock.calls[0][0]);
    for(const own of [`HOTEL_${hotel}`,`BRANCH_${hotel}1`,`STAFF_${hotel}`,`INSTRUCTIONS_${hotel}`,`FACT_${hotel}1`])expect(input).toContain(own);
    const other=hotel==='A'?'B':'A';
    for(const prefix of ['HOTEL_','BRANCH_','STAFF_','INSTRUCTIONS_','FACT_'])expect(input).not.toContain(`${prefix}${other}`);
    expect(input).not.toContain(`FACT_${hotel}2`);
    expect(h.trace.filter(t=>t.name==='fn_ai_ops_context')).toEqual([{kind:'rpc',privileged:false,name:'fn_ai_ops_context',args:{p_branch:`${hotel}1`,p_date:expect.any(String)}}]);
  });
  for(const hotel of ['A','B'] as const)it(`does not call the provider for ${hotel}'s request for a foreign branch`,async()=>{
    const h=await briefing(hotel,true);expect(h.response.status).toBe(403);expect(h.generate).not.toHaveBeenCalled();
    expect(h.trace.some(t=>t.write)).toBe(false);
  });
});
