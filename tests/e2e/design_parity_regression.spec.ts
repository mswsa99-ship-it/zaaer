import { test, expect } from './fixtures';
for (const theme of ['light', 'dark'] as const) for (const width of [1366, 390]) {
  test(`approved notice icons and field states: ${theme} ${width}`, async ({ page, go }) => {
    await page.setViewportSize({width,height:900});
    await page.addInitScript(t=>localStorage.setItem('roomai-theme',t),theme);
    await go('/design-gallery');
    const notices=page.getByTestId('gallery-notices');
    await expect(notices.locator('.rai-notice')).toHaveCount(4);
    await expect(notices.locator('.rai-notice > svg[aria-hidden="true"]')).toHaveCount(4);
    const name=page.getByLabel('اسم النزيل',{exact:true});
    await expect(name).toBeVisible();
    await page.getByText('اسم النزيل',{exact:true}).click(); await expect(name).toBeFocused();
    const error=page.getByLabel('رقم الجوال',{exact:true});
    await expect(error).toHaveAttribute('aria-invalid','true');
    const expected=await error.evaluate(e=>getComputedStyle(e).getPropertyValue('--danger').trim());
    expect(await error.evaluate((e,color)=>{const probe=document.createElement('i');probe.style.color=color;document.body.append(probe);const resolved=getComputedStyle(probe).color;probe.remove();return getComputedStyle(e).borderColor===resolved;},expected)).toBe(true);
    const noteId=await error.getAttribute('aria-describedby');
    expect(noteId).toBeTruthy();
    await expect(page.locator(`[id="${noteId}"]`)).toHaveText('أضف إلى الجوال الرقم الناقص');
    if(theme==='dark') expect(await name.evaluate(e=>getComputedStyle(e).boxShadow)).toContain('39, 77, 87');
  });
}
