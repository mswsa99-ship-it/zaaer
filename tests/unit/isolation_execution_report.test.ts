import {describe,it,expect} from 'vitest';
// @ts-expect-error Node module
import {assessCell,aggregate} from '../isolation/report.mjs';
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
});
