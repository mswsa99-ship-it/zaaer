/**
 * One app, grouped menu on a phone (390px): every group opens, every page of every group can be scrolled into view and
 * is not covered, the keyboard reaches and operates the groups (RTL), and Escape gives focus back to «المزيد».
 * Presentation only: who may open what is proven elsewhere (tests/unit/grouped_menu.test.ts, nav.test.ts).
 */
import { test, expect, type DemoRole } from "./fixtures";

test.use({ viewport: { width: 390, height: 844 } });

for (const role of ["owner", "manager", "finance"] as DemoRole[]) {
  test(`NV96 on a phone ${role} opens every group and each page link scrolls fully into view`, async ({ page, loginAs, go }) => {
    await loginAs(role);
    await go("/staff/rooms");
    await page.getByTestId("bottom-tabs-more").click();
    const drawer = page.getByTestId("staff-menu-drawer");
    const toggle = drawer.getByTestId("admin-menu-toggle");
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await toggle.click();
    const admin = drawer.locator("#drawer-admin");
    const groups = admin.getByRole("button");
    const n = await groups.count();
    expect(n).toBeGreaterThan(0);
    let links = 0;
    for (let i = 0; i < n; i++) {
      const g = admin.getByRole("button").nth(i);
      await g.click();
      await expect(g).toHaveAttribute("aria-expanded", "true");
      const items = admin.locator(`#${await g.getAttribute("aria-controls")} a`);
      const c = await items.count();
      expect(c).toBeGreaterThan(0);
      for (let k = 0; k < c; k++) {
        const a = items.nth(k);
        await a.scrollIntoViewIfNeeded();
        const box = (await a.boundingBox())!;
        const view = page.viewportSize()!;
        expect(box.height, "link big enough to tap").toBeGreaterThanOrEqual(40);
        expect(box.x).toBeGreaterThanOrEqual(0);
        expect(box.x + box.width).toBeLessThanOrEqual(view.width + 1);
        expect(box.y + box.height).toBeLessThanOrEqual(view.height + 1);
        // nothing is drawn over the link
        const top = await a.evaluate((el) => { const r = el.getBoundingClientRect(); const t = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2); return !!t && (el === t || el.contains(t)); });
        expect(top, "the link is not covered").toBe(true);
        links++;
      }
      await g.click();   // collapse again
    }
    console.log(`NV96 ${role}: ${n} groups, ${links} links`);
  });
}

test("NV97 the keyboard opens «الإدارة» and a group, reaches its links in order, and Escape returns focus to «المزيد»", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/rooms");
  const more = page.getByTestId("bottom-tabs-more");
  await more.focus();
  await page.keyboard.press("Enter");
  const drawer = page.getByTestId("staff-menu-drawer");
  await expect(drawer).toBeVisible();
  const toggle = drawer.getByTestId("admin-menu-toggle");
  await toggle.focus();
  await page.keyboard.press("Enter");
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await page.keyboard.press("Tab");   // first group button
  const first = drawer.locator("#drawer-admin").getByRole("button").first();
  await expect(first).toBeFocused();
  await page.keyboard.press("Space");
  await expect(first).toHaveAttribute("aria-expanded", "true");
  await page.keyboard.press("Tab");   // its first page link
  await expect(drawer.locator("#drawer-admin a").first()).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/#\/admin\//);
  await expect(drawer).toHaveCount(0);   // choosing a page closes the drawer
  await more.click();
  await page.keyboard.press("Escape");
  await expect(more).toBeFocused();
});

/* NV98: the floating assistant button may sit over a table value while scrolling, but every value can be scrolled clear of it, and the last row ends clear. */
for (const path of ["/admin/finance", "/admin/audit-logs", "/staff/reservations"]) {
  test(`NV98 on a phone every value in ${path} can be scrolled clear of the assistant button; the last row ends clear`, async ({ page, loginAs, go }, info) => {
    test.skip(info.project.name !== "mobile", "phone width only");
    await loginAs("owner");
    await go(path);
    await page.waitForTimeout(600);
    const fab = page.getByRole("button", { name: /مساعد العمليات/ }).first();
    await expect(fab).toBeVisible();
    const covered = await page.evaluate(async () => {
      const fabEl = [...document.querySelectorAll("button")].find((b) => /مساعد العمليات/.test(b.getAttribute("aria-label") ?? "") || /مساعد العمليات/.test(b.textContent ?? ""))!;
      const cells = [...document.querySelectorAll<HTMLElement>("table tbody td")];
      let hidden = 0, checked = 0;
      for (const c of cells) {
        c.scrollIntoView({ block: "center", inline: "nearest" });   // normal scrolling puts it mid-screen
        await new Promise((r) => requestAnimationFrame(() => r(null)));
        const r = c.getBoundingClientRect();
        if (r.width === 0 || r.right < 0 || r.left > innerWidth) continue;   // sideways-scrolled out of the table's own window: reachable by that scroll
        checked++;
        const f = fabEl.getBoundingClientRect();
        const overlap = !(r.right <= f.left || r.left >= f.right || r.bottom <= f.top || r.top >= f.bottom);
        if (overlap) hidden++;
      }
      return { hidden, checked };
    });
    expect(covered.checked).toBeGreaterThan(0);
    expect(covered.hidden, "values still under the button after centring them").toBe(0);
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await page.waitForTimeout(300);
    const endClear = await page.evaluate(() => {
      const f = [...document.querySelectorAll("button")].find((b) => /مساعد العمليات/.test(b.getAttribute("aria-label") ?? "") || /مساعد العمليات/.test(b.textContent ?? ""))!.getBoundingClientRect();
      const rows = [...document.querySelectorAll<HTMLElement>("table tbody tr")];
      const last = rows[rows.length - 1].getBoundingClientRect();
      return last.bottom <= f.top || last.top >= f.bottom;
    });
    expect(endClear, "the last row ends above the assistant button").toBe(true);
  });
}
