import { test, expect } from './fixtures';

// Synthetic demo only. No persistent password or real account change is made.
test('account same-tick submits cause one password-change audit operation', async ({page,loginAs,go}) => {
  await loginAs('owner'); await go('/staff/account');
  await page.getByLabel('كلمة المرور الجديدة', {exact:true}).fill('DemoOnly987x');
  await page.getByLabel('أعد كتابتها', {exact:true}).fill('DemoOnly987x');
  await page.evaluate(() => {
    const w=window as any; w.__calls=0;
    w.__demoLatency=(t:string,d:unknown)=>{if(t.startsWith('rpc:') && JSON.stringify(d).includes('security.password_changed')) {w.__calls++;return 500;}return 0;};
    const form=document.querySelector('[data-testid="account-page"] form')!;
    form.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
    form.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
  });
  await expect(page.getByTestId('account-notice')).toContainText('تغيّرت');
  expect(await page.evaluate(()=>(window as any).__calls)).toBe(1);
  await expect(page.getByLabel('كلمة المرور الجديدة', {exact:true})).toHaveValue('');
});

test('AI settings same-tick clicks cause one write and permit another after completion', async({page,loginAs,go})=>{
  await loginAs('owner');await go('/admin/ai-settings');
  const save=page.getByRole('button',{name:'حفظ الإعدادات',exact:true});await expect(save).toBeVisible();
  await page.evaluate(()=>{const w=window as any;w.__calls=0;w.__demoLatency=(t:string)=>{if(t==='rpc:fn_admin_update_ai_settings'){w.__calls++;return 500;}return 0;};});
  await save.evaluate((el)=>{(el as HTMLButtonElement).click();(el as HTMLButtonElement).click();});
  await expect(page.getByText('تم الحفظ',{exact:true})).toBeVisible();
  expect(await page.evaluate(()=>(window as any).__calls)).toBe(1);
  await save.click();await expect.poll(()=>page.evaluate(()=>(window as any).__calls)).toBe(2);
});

for(const [key,rpc] of [['late-entries-report','fn_reports_late_entries'],['identities-report','fn_reports_identities'],['discounts-report','fn_reports_discounts']] as const){
 test(`report section ${key} retries locally without route navigation`,async({page,loginAs,go,errors})=>{
  await loginAs('owner'); await go('/staff/account');
  await page.evaluate((r)=>{(window as any).__demoFail=(t:string)=>t==='rpc:'+r?'network down':null;},rpc);
  await page.evaluate(()=>{location.hash='/admin/reports';});
  const section=page.getByTestId(key);await expect(section.getByRole('alert')).toBeVisible();
  await page.evaluate(()=>{(window as any).__demoFail=undefined;});
  await section.getByRole('button',{name:'إعادة المحاولة',exact:true}).click();
  await expect(section.getByRole('alert')).toHaveCount(0);await expect(section.locator('.animate-spin')).toHaveCount(0);
  expect(page.url()).toContain('/admin/reports');
  const unexpected=errors.filter(e=>!/network down/i.test(e));errors.splice(0,errors.length,...unexpected);
 });
}

for (const c of [{path:'/admin/availability',rpc:'fn_admin_set_inventory',label:/^الوحدات المحجوبة/}, {path:'/admin/availability-rules',rpc:'fn_admin_upsert_release_rule',label:/^زيادة الإتاحة$/}]) {
 test(`same-tick inventory commit is single-flight: ${c.path}`,async({page,loginAs,go})=>{
  await loginAs('owner');await go(c.path);
  const input=page.getByRole('textbox',{name:c.label}).first();await expect(input).toBeVisible();
  const previous=Number(await input.inputValue());await input.fill(String(previous===0?1:0));
  await page.evaluate((rpc)=>{const w=window as any;w.__calls=0;w.__demoLatency=(t:string)=>{if(t==='rpc:'+rpc){w.__calls++;return 500;}return 0;};},c.rpc);
  await input.evaluate(el=>{el.dispatchEvent(new FocusEvent('focusout',{bubbles:true}));el.dispatchEvent(new FocusEvent('focusout',{bubbles:true}));});
  await expect.poll(()=>page.evaluate(()=>(window as any).__calls)).toBe(1);
  await expect(input).toBeEnabled();
  expect(await page.evaluate(()=>(window as any).__calls)).toBe(1);
 });
}
