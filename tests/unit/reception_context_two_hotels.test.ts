import { describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';
import * as guardrails from '../../supabase/functions/_shared/guardrails';
import * as scope from '../../supabase/functions/_shared/reception_scope';
import * as budgets from '../../supabase/functions/_shared/budget_reads';
import * as reserve from '../../supabase/functions/_shared/guest_reserve';
import { localDay } from '../../supabase/functions/_shared/dates';

type Row = Record<string, any>;
// Local synthetic relational adapter. It evaluates the handler's actual query predicates.
// It is deliberately NOT a database/RLS proof and never constructs a real Supabase client.
async function exercise(hotel: 'A'|'B', options: { conversation?: string; token?: string; branch?: string } = {}) {
  const other = hotel === 'A' ? 'B' : 'A';
  const branch = options.branch ?? `${hotel}1`;
  const tables: Record<string, Row[]> = {
    organizations: ['A','B'].map(id => ({id, name_ar:`HOTEL_${id}`, platform_status:'active'})),
    branches: ['A1','A2','B1','B2'].map(id => ({id, organization_id:id[0], name_ar:`BRANCH_${id}`, timezone:'Asia/Riyadh', is_active:true, archived_at:null, address:`ADDRESS_${id}`})),
    ai_settings: ['A','B'].map(organization_id => ({organization_id, enabled:true, model:'local-stub', daily_request_limit:100, daily_token_budget:10000, per_session_message_limit:40, strict_scope:true, extra_instructions:`INSTRUCTIONS_${organization_id}`})),
    conversations: ['A1','A2','B1','B2'].map(id => ({id:`conv-${id}`, organization_id:id[0], branch_id:id, channel:'screen', status:'active', guest_token:`token-${id}-valid`, client_fingerprint:'local-fp'})),
    registration_sessions: ['A1','A2','B1','B2'].map(id => ({token:`token-${id}-valid`, reservation_id:`res-${id}`, organization_id:id[0], branch_id:id, expires_at:'2099-01-01'})),
    guest_phone_sessions: [],
    // Foreign records are physically present, not merely absent from the fixture.
    conversation_messages: [`${other}1`,`${hotel}2`,`${hotel}1`].map(id => ({id:`msg-${id}`, conversation_id:`conv-${id}`, sender:'guest', content:`HISTORY_${id}`, created_at:'2026-01-01'})),
    property_policies: [`${other}1`,`${hotel}2`,`${hotel}1`].map(id => ({branch_id:id, topic:'local', title:`POLICY_${id}`, content_ar:`POLICY_CONTENT_${id}`, is_public:true})),
    ai_usage_daily: [], ai_guardrail_events: [],
  };
  tables.registration_sessions.push({token:"token-A1-second",reservation_id:"res-second",organization_id:"A",branch_id:"A1",expires_at:"2099-01-01"});
  const writes: Row[] = [];
  const generate = vi.fn(async (input: unknown) => ({text:'أهلا بك في الفندق.',usage:{input:0,output:0},toolCalls:[],input}));
  const knowledgeCalls: string[] = [];
  const db = {
    async rpc(name: string, args: Row = {}) {
      if (name === 'fn_guest_org_id') return {data:hotel,error:null};
      if (name === 'fn_staff_id') return {data:null,error:null};
      if (name === 'fn_public_knowledge') { knowledgeCalls.push(args.p_branch); return {data:[],error:null}; }
      if (name === 'fn_ai_guest_reserve') return {data:{status:'ok'},error:null};
      return {data:null,error:null};
    },
    from(table: string) {
      const filters: ((r: Row)=>boolean)[] = [];
      let single = false, head = false, limit = Infinity;
      let operation = 'read', value: Row = {};
      const chain: Row = {};
      chain.select = (_columns: string, opt?: Row) => {head=!!opt?.head;return chain;};
      chain.eq = (key: string, val: unknown) => { filters.push(r=>r[key]===val);return chain; };
      chain.is = chain.eq;
      chain.gt = (key: string, val: unknown) => {filters.push(r=>r[key]>val!);return chain;};
      chain.order = () => chain;
      chain.limit = (n: number) => {limit=n;return chain;};
      chain.maybeSingle = chain.single = () => {single=true;return chain;};
      chain.insert = (row: Row) => {operation='insert';value=row;return chain;};
      chain.update = (row: Row) => {operation='update';value=row;return chain;};
      chain.then = (resolve: (r: unknown)=>unknown, reject: (e: unknown)=>unknown) => Promise.resolve().then(()=>{
        const rows=(tables[table]??[]).filter(r=>filters.every(f=>f(r))).slice(0,limit);
        if(operation==='insert') {
          const row={id:`local-${writes.length}`, ...value};
          (tables[table]??=[]).push(row); writes.push({table,...row});
          return {data:single?row:[row],count:1,error:null};
        }
        if(operation==='update') {for(const row of rows) Object.assign(row,value);writes.push({table,...value});}
        return {data:head?null:single?(rows[0]??null):rows,count:rows.length,error:null};
      }).then(resolve,reject);
      return chain;
    },
  };
  let serve!: (request: Request)=>Promise<Response>;
  let source=readFileSync(new URL('../../supabase/functions/ai-reception/index.ts',import.meta.url),'utf8');
  // Test-only mutation selected by the command running this suite, never a product change.
  const mutant=process.env.CONTEXT27_MUTANT;
  const mutations: Record<string,[string,string]> = {
    history: ['.eq("conversation_id", conversationId).order("created_at", { ascending: false })','.order("created_at", { ascending: false })'],
    policies: ['.eq("branch_id", branch.id).eq("is_public", true)','.eq("is_public", true)'],
    conversation: ['if (!c || !mayResumeConversation(c, { organizationId: org.id, branchId: branch.id, guestToken }, { trustedService, staff: !!staffId, fingerprint, channel }))','if (!c)'],
  };
  if(mutant) {
    if(!mutations[mutant]) throw new Error('unknown local mutant');
    const [before,after]=mutations[mutant];
    if(source.split(before).length!==2) throw new Error('mutation anchor must occur exactly once');
    source=source.replace(before,after);
  }
  const dependencies: Row = {
    'npm:@supabase/supabase-js@2.45.4':{createClient:()=>db},
    '../_shared/keys.ts':{projectKey:()=> 'local-only-key'},
    '../_shared/guardrails.ts':guardrails,
    '../_shared/reception_scope.ts':scope,
    '../_shared/budget_reads.ts':budgets,
    '../_shared/guest_reserve.ts':reserve,
    '../_shared/dates.ts':{localDay},
    '../_shared/tools.ts':{TOOL_DECLARATIONS:[],executeTool:()=>{throw new Error('unexpected tool call');}},
    '../_shared/llm.ts':{createProvider:()=>({generate}),ProviderError:class extends Error {}},
  };
  runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
    exports:{},require:(name:string)=>{if(!(name in dependencies))throw new Error(`unmocked import ${name}`);return dependencies[name];},
    Deno:{serve:(fn:typeof serve)=>{serve=fn;},env:{get:()=> 'https://local.invalid'}},Response,console,
    fetch:()=>{throw new Error('network prohibited');},
  });
  const response=await serve(new Request('https://local.invalid',{method:'POST',headers:{'content-type':'application/json','x-hotel-slug':`hotel-${hotel}`},body:JSON.stringify({message:'هل يمكنك مساعدتي في الإقامة؟',branch_id:branch,conversation_id:options.conversation??`conv-${hotel}1`,guest_token:options.token??`token-${hotel}1-valid`,client_fingerprint:'local-fp'})}));
  return {response,body:await response.json(),generate,writes,knowledgeCalls,tables};
}

describe('plan 2.7 actual reception context, two hotels with decoy records',()=>{
  for(const hotel of ['A','B'] as const) it(`assembles only hotel ${hotel} branch 1 facts, history and settings for the stub provider`,async()=>{
    const h=await exercise(hotel);
    expect(h.response.status).toBe(200);
    expect(h.body.mode).toBe('ai');
    expect(h.generate).toHaveBeenCalledOnce();
    const input=JSON.stringify(h.generate.mock.calls[0][0]);
    for(const own of [`HOTEL_${hotel}`,`BRANCH_${hotel}1`,`ADDRESS_${hotel}1`,`HISTORY_${hotel}1`,`POLICY_CONTENT_${hotel}1`,`INSTRUCTIONS_${hotel}`])expect(input).toContain(own);
    const other=hotel==='A'?'B':'A';
    for(const prefix of ['HOTEL_','BRANCH_','ADDRESS_','HISTORY_','POLICY_CONTENT_','INSTRUCTIONS_'])expect(input).not.toContain(`${prefix}${other}`);
    for(const prefix of ['BRANCH_','ADDRESS_','HISTORY_','POLICY_CONTENT_'])expect(input).not.toContain(`${prefix}${hotel}2`);
    expect(h.knowledgeCalls).toEqual([`${hotel}1`]);
    expect(h.tables.conversation_messages.some(r=>r.content===`HISTORY_${other}1`)).toBe(true);
    expect(h.tables.property_policies.some(r=>r.content_ar===`POLICY_CONTENT_${hotel}2`)).toBe(true);
  });
  for(const [label,options] of [
    ['foreign-hotel conversation',{conversation:'conv-B1'}],
    ['other-branch conversation',{conversation:'conv-A2'}],
    ['foreign-hotel token',{token:'token-B1-valid'}],
    ['other-branch token',{token:'token-A2-valid'}],
    ['unknown token',{token:'token-missing-valid'}],
    ['valid different booking capability in the same branch',{token:'token-A1-second'}],
    ['foreign branch selection',{branch:'B1'}],
  ] as const)it(`rejects ${label} before context/model access or writes`,async()=>{
    const h=await exercise('A',options);
    expect([400,403]).toContain(h.response.status);
    expect(h.generate).not.toHaveBeenCalled();
    expect(h.knowledgeCalls).toEqual([]);
    expect(h.writes).toEqual([]);
  });
  it('requires the original capability again even for a valid own conversation',async()=>{
    // A second valid local booking token is not permission to resume the first booking chat.
    const h=await exercise('A',{token:'token-A2-valid',branch:'A2',conversation:'conv-A1'});
    expect(h.response.status).toBe(403);expect(h.generate).not.toHaveBeenCalled();expect(h.writes).toEqual([]);
  });
});
