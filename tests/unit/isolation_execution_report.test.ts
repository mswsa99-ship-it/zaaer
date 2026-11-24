import {describe,it,expect} from 'vitest';
// @ts-expect-error Node module
import {assessCell,aggregate,baseSignature,variantName,combineVariants,fieldScope} from '../isolation/report.mjs';
const cell={status:'pending',expected:'deny'};
const control={outcome:'control-ok',rows_ret:1};
describe('executable isolation evidence stays fail-closed',()=>{
 it('never reports incomplete coverage green',()=>expect(aggregate([{status:'observed-denial'}]).passed).toBe(false));
 it('does not count missing probes',()=>expect(assessCell(cell,null,control).status).toBe('unexecuted'));
 it('does not confuse malformed payload and denial',()=>expect(assessCell(cell,{outcome:'denied',errclass:'validation'},control).status).toBe('invalid-data-or-error'));
 it('requires an actually successful positive control',()=>expect(assessCell(cell,{outcome:'denied',errclass:'permission'},{outcome:'denied'}).status).toBe('invalid-control'));
 it('rejects zero-row positive controls',()=>expect(assessCell(cell,{outcome:'success',rows_ret:0},{outcome:'control-ok',rows_ret:0}).status).toBe('invalid-control'));
 it('detects side effects even with zero returned rows',()=>expect(assessCell(cell,{outcome:'success',rows_ret:0,side_effect:true},control).status).toBe('boundary-success-review'));
 it('detects forbidden successful reads',()=>expect(assessCell(cell,{outcome:'success',rows_ret:1},control).status).toBe('boundary-success-review'));
 it('records permission errors without presenting full acceptance',()=>expect(assessCell(cell,{outcome:'denied',errclass:'permission',side_effect:false},control).status).toBe('observed-denial'));
 it('keeps policy-dependent cells unresolved',()=>expect(assessCell({...cell,expected:'policy-dependent'},{outcome:'success',rows_ret:1},control).status).toBe('oracle-incomplete'));
 it('requires exception review rather than silently passing it',()=>expect(assessCell({status:'exempt',reason:'source note'},null,null).status).toBe('exception-review'));
 const imm={guard_prefix:'AUDIT_IMMUTABLE',source:'0088 trg_audit_immutable'};
 const guardCtl={outcome:'denied',sqlerrm:'AUDIT_IMMUTABLE: the audit log accepts no change'};
 it('verifies an immutable deny only when the guard fired for the control',()=>expect(assessCell(cell,{outcome:'denied',errclass:'permission',side_effect:false},guardCtl,imm).status).toBe('immutable-deny-verified'));
 it('rejects an immutable cell whose control was not refused by the guard',()=>expect(assessCell(cell,{outcome:'denied',errclass:'permission'},{outcome:'denied',sqlerrm:'other error'},imm).status).toBe('invalid-control'));
 it('rejects an immutable cell whose control succeeded',()=>expect(assessCell(cell,{outcome:'denied',errclass:'permission'},control,imm).status).toBe('invalid-control'));
 it('flags an actor change on an immutable table',()=>expect(assessCell(cell,{outcome:'success',rows_ret:1,side_effect:true},guardCtl,imm).status).toBe('boundary-success-review'));
 it('never reports an immutable-deny as accepted',()=>expect(aggregate([{status:'immutable-deny-verified'}]).passed).toBe(false));
 const fn={surface:'function',expected:'requires-adapter',status:'unsupported',actor:{hotel:'hotel-a'},target:{hotel:'hotel-b'}};
 it('treats a cross-hotel RPC success as a violation',()=>expect(assessCell(fn,{outcome:'success',rows_ret:1},control).status).toBe('boundary-success-review'));
 it('treats a cross-hotel RPC permission error with a data-returning control as observed denial only',()=>expect(assessCell(fn,{outcome:'denied',errclass:'permission',side_effect:false},control).status).toBe('observed-denial'));
 it('rejects a weak RPC control that returned no data or effect',()=>expect(assessCell(fn,{outcome:'denied',errclass:'permission'},{outcome:'control-ok',rows_ret:0}).status).toBe('invalid-control'));
 it('does not count a validation error as an RPC denial',()=>expect(assessCell(fn,{outcome:'denied',errclass:'validation',sqlerrm:'bad arg'},control).status).toBe('invalid-data-or-error'));
 it('flags an owner control that changed another hotel slice',()=>expect(assessCell(fn,{outcome:'denied',errclass:'permission'},{outcome:'scope-violation',rows_ret:2,detail:'outside=1'}).status).toBe('boundary-success-review'));
 it('keeps a public-by-design read distinct from isolation evidence',()=>expect(assessCell(fn,{outcome:'success',rows_ret:0,detail:'public_keys_ok=true public_identity_ok=true'},control).status).toBe('public-exception-verified'));
 it('does not grant public exception on keys alone',()=>expect(assessCell(fn,{outcome:'success',rows_ret:0,detail:'public_keys_ok=true'},control).status).not.toBe('public-exception-verified'));
 it('does not excuse a public read with extra keys',()=>expect(assessCell(fn,{outcome:'success',rows_ret:1,detail:'public_keys_ok=false extra_keys=1'},control).status).toBe('boundary-success-review'));
 it('resolves a variant signature to its base and variant name',()=>{expect(baseSignature('fn_x(p jsonb)#nogl')).toBe('fn_x(p jsonb)');expect(variantName('fn_x(p jsonb)#nogl')).toBe('nogl');expect(variantName('fn_x(p jsonb)')).toBe(null);});
 it('lets a variant leak worsen the base cell',()=>expect(combineVariants({status:'observed-denial',reason:'r'},[{variant:'nogl',status:'boundary-success-review',reason:'leak'}]).status).toBe('boundary-success-review'));
 it('never lets a variant upgrade the base cell',()=>expect(combineVariants({status:'oracle-incomplete',reason:'r'},[{variant:'nogl',status:'observed-denial',reason:'ok'}]).status).toBe('oracle-incomplete'));
 it('keeps variant results listed separately',()=>expect(combineVariants({status:'observed-denial',reason:'r'},[{variant:'nogl',status:'invalid-control',reason:'c'}]).variants).toHaveLength(1));
 it('keeps readiness blockers out of the acceptance claim',()=>expect(aggregate([{status:'observed-denial'}]).acceptance).toBe('INCOMPLETE'));
 it('keeps provenance additive and counts object occurrences, not unique rows',()=>{
  const probe={outcome:'success',rows_ret:3,detail:'markers=6 branch_struct=4 branch_null=2 prov=structured'};
  expect(fieldScope(probe)).toEqual({structuredBranchObjects:4,nullishBranchObjects:2,provenance:'structured',raw:{markers:6}});
  expect(fieldScope({detail:'markers=1 changed=0'})).toBeUndefined();
  expect(assessCell(cell,probe,control).status).toBe(assessCell(cell,{...probe,detail:'markers=6'},control).status);
 });
 it('keeps mutator provenance explicitly unmeasured',()=>{
  expect(fieldScope({detail:'markers=0 branch_struct=0 branch_null=0 prov=unmeasured'}).provenance).toBe('unmeasured');
 });
});
