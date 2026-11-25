import {test,expect} from './fixtures';
for(const f of [{name:'expense',path:'/staff/expenses',prefix:'zaaer:expense-draft:',banner:'expense-draft'}, {name:'reservation',path:'/staff/reservations/new',prefix:'zaaer:new-reservation:',banner:'reservation-draft'}]){
 test(`${f.name}: legacy branch-only draft discarded; scoped prior-user draft never offered after simulated session end`,async({page,loginAs,go})=>{
  await loginAs('owner');await go('/staff/dashboard');
  await page.evaluate((prefix)=>{sessionStorage.setItem(prefix+'legacy-branch',JSON.stringify({desc:'private',guest_name:'private'}));},f.prefix);
  await go(f.path);
  if(f.name==='expense'){
   await page.getByRole('button',{name:'سند صرف',exact:true}).click();
   await page.getByRole('dialog').getByLabel('الوصف').fill('private owner expense');
  }else{
   await page.getByRole('button',{name:'التالي',exact:true}).click();
   await page.getByLabel('الاسم (مطلوب)',{exact:true}).fill('private owner guest');
  }
  await page.waitForTimeout(700);
  const keys=await page.evaluate((prefix)=>Object.keys(sessionStorage).filter(k=>k.startsWith(prefix)&&k.split(':').length===5),f.prefix);
  expect(keys).toHaveLength(1);
  await page.evaluate(({prefix,key})=>{sessionStorage.setItem(prefix+key.split(':').at(-1),JSON.stringify({desc:'legacy',guest_name:'legacy'}));},{prefix:f.prefix,key:keys[0]});
  await page.reload({waitUntil:'networkidle'});
  if(f.name==='expense')await page.getByRole('button',{name:'سند صرف',exact:true}).click();
  expect(await page.evaluate(({prefix,key})=>sessionStorage.getItem(prefix+key.split(':').at(-1)),{prefix:f.prefix,key:keys[0]})).toBeNull();
  await page.evaluate(()=>sessionStorage.removeItem('zaaer_demo_session'));
  await page.reload({waitUntil:'networkidle'});await loginAs('manager');await go(f.path);
  if(f.name==='expense')await page.getByRole('button',{name:'سند صرف',exact:true}).click();
  await expect(page.getByTestId(f.banner)).toHaveCount(0);
  expect(await page.evaluate((prefix)=>Object.keys(sessionStorage).filter(k=>k.startsWith(prefix)&&k.split(':').length===5),f.prefix)).toEqual(keys);
 });
}
