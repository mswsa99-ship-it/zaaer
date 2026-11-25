import { test, expect } from './fixtures';

for (const width of [1366, 390]) {
  test(`assistant dock leaves visible values and actions uncovered at ${width}px`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    await loginAs('owner');
    await go('/staff/dashboard');
    for (const y of [0, 380, 600, 99999]) {
      await page.evaluate(y => window.scrollTo(0, y), y);
      await page.waitForTimeout(1000); // inspect the restored resting state, not only its scroll shrink
      const hits = await page.evaluate(() => {
        const fab = document.querySelector('[data-testid="ops-copilot-fab"]')!;
        const f = fab.getBoundingClientRect();
        const header = [...document.querySelectorAll('header')].find(e => e.getBoundingClientRect().height > 0);
        const safeTop = header ? Math.max(0, header.getBoundingClientRect().bottom) : 0;
        const tabs = document.querySelector('[data-testid="bottom-tabs"]');
        const safeBottom = tabs && tabs.getBoundingClientRect().height > 0 ? tabs.getBoundingClientRect().top : innerHeight;
        const hits: string[] = [];
        for (const el of document.querySelectorAll('main p,main span,main a,main button,main input')) {
          const r = el.getBoundingClientRect();
          const left = Math.max(r.left, f.left), right = Math.min(r.right, f.right);
          const top = Math.max(r.top, f.top, safeTop), bottom = Math.min(r.bottom, f.bottom, safeBottom);
          if (right <= left || bottom <= top) continue;
          const hit = document.elementFromPoint((left + right) / 2, (top + bottom) / 2);
          if (hit && (hit === fab || fab.contains(hit))) hits.push(`${el.tagName}: ${(el.textContent ?? '').trim().slice(0, 100)}`);
        }
        return hits;
      });
      expect(hits, `no assistant overlap at scroll target ${y}`).toEqual([]);
    }
    // Header and navigation stay independently pointer/keyboard reachable.
    for (const selector of width === 390
      ? ['[data-testid="ops-copilot-fab"]', '[data-testid="my-account-link-phone"]', '[aria-label="تسجيل الخروج"]', '[data-testid="bottom-tabs"] a', '[data-testid="bottom-tabs-more"]']
      : ['[data-testid="ops-copilot-fab"]', '[data-testid="my-account-link"]']) {
      for (const control of await page.locator(selector).all()) {
        await expect(control).toBeVisible();
        expect(await control.evaluate(el => {
          const r = el.getBoundingClientRect(); const hit = document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
          return hit === el || !!hit && el.contains(hit);
        }), `chrome hit target ${selector}`).toBe(true);
        await control.focus(); await expect(control).toBeFocused();
      }
    }
    // The assistant remains reachable and functional without consuming a content corner.
    const fab = page.getByTestId('ops-copilot-fab');
    await fab.focus(); await page.keyboard.press('Enter');
    const dialog = page.getByRole('dialog', { name: 'مساعد العمليات' });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('textbox', { name: 'سؤالك أو طلبك' })).toBeVisible();
    await dialog.getByRole('button', { name: 'إغلاق المساعد' }).focus();
    await page.keyboard.press('Enter');
    await expect(dialog).toBeHidden();
    if (width === 390) {
      await expect(page.getByTestId('bottom-tabs')).toBeVisible();
      await page.getByTestId('bottom-tabs-more').click();
      await expect(page.getByRole('dialog', { name: 'كل الصفحات' })).toBeVisible();
    }
  });
}
