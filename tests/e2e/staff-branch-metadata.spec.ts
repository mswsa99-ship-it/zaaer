import {test,expect} from './fixtures';
const SHOT_DIR = process.env.E2E_SHOT_DIR ?? "test-results/screens"; // CI has no /downloads folder
test('manager hidden branch metadata uses neutral wording and does not grant editing',async({page,loginAs,go,errors})=>{
 await loginAs('manager');
 await page.waitForTimeout(300);
 await page.evaluate(()=>{
  const key='zaaer_demo_store_v9'; const s=JSON.parse(localStorage.getItem(key)!);
  const mgr=s.staff_profiles.find((x:any)=>x.email==='manager@demo.sa');
  const memberships=s.branch_memberships.filter((m:any)=>m.staff_id===mgr.id&&!m.removed_at);
  s.branch_memberships=s.branch_memberships.filter((m:any)=>m.staff_id!==mgr.id||m.branch_id===memberships[0].branch_id);
  const mine=new Set(s.branch_memberships.filter((m:any)=>m.staff_id===mgr.id&&!m.removed_at).map((m:any)=>m.branch_id));
  const other=s.branches.find((b:any)=>!mine.has(b.id)&&b.organization_id===mgr.organization_id);
  if(!other) throw new Error('fixture requires other branch');
  const sup=s.staff_profiles.find((x:any)=>x.email==='reception@demo.sa');
  s.branch_memberships=s.branch_memberships.filter((m:any)=>m.staff_id!==sup.id);
  s.branch_memberships.push({id:'boundary-ui',staff_id:sup.id,branch_id:other.id,organization_id:mgr.organization_id,removed_at:null,created_at:new Date().toISOString()});
  localStorage.setItem(key,JSON.stringify(s));
 });
 await page.reload(); await go('/admin/staff');
 const card=page.locator('[data-testid=staff-card][data-email="reception@demo.sa"]');
 await expect(card).toContainText('لا توجد فروع ظاهرة ضمن صلاحياتك');
 await expect(card).not.toContainText('بلا فرع');
 await expect(page.getByTestId('staff-edit')).toHaveCount(0);
 await expect(page.getByTestId('staff-toggle-active')).toHaveCount(0);
 await expect(card.getByTestId('staff-force-logout')).toBeVisible();
 await page.screenshot({path:`${SHOT_DIR}/roomai-staff-branch-metadata1724.png`,fullPage:true});
 expect(errors).toEqual([]);
});
