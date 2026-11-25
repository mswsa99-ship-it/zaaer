import {describe,it,expect} from 'vitest';
import {emptyStaffBranchesLabel,changedStaffBranches} from '../../src/lib/staffBranchMetadata';
describe('partial staff branch metadata',()=>{
 it('never calls hidden/empty nonowner metadata unassigned',()=>expect(emptyStaffBranchesLabel(false)).toBe('لا توجد فروع ظاهرة ضمن صلاحياتك'));
 it('keeps the owner complete-list label',()=>expect(emptyStaffBranchesLabel(true)).toBe('بلا فرع'));
 it('omits unchanged empty partial memberships',()=>expect(changedStaffBranches([],[])).toEqual({}));
 it('omits unchanged reordered memberships',()=>expect(changedStaffBranches(['a','b'],['b','a'])).toEqual({}));
 it('sends only explicitly changed membership lists',()=>expect(changedStaffBranches(['a'],['b'])).toEqual({branch_ids:['b']}));
});
