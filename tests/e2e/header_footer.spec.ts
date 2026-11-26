/** Phone header and bottom bar: the header icons are 25% larger than before (16px icon, 48px target, grouped close on the left), a day/night switch is there and remembered, and the five bottom items are equal. */
import { test, expect } from "./fixtures";

for (const width of [360, 390]) {
  test(`HF1 header icons 20px in 48px targets, with a day/night switch, at ${width}`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width, height: 800 });
    await loginAs("owner"); await go("/staff/reservations");
    const header = page.locator("header").first();
    for (const name of ["حسابي", "تسجيل الخروج", /التحويل إلى الوضع/]) {
      const b = header.getByRole(typeof name === "string" ? "link" : "button", { name }).or(header.getByRole("button", { name }));
      const box = (await b.first().boundingBox())!;
      expect(Math.round(box.width)).toBe(48); expect(Math.round(box.height)).toBe(48);
      const svg = (await b.first().locator("svg").boundingBox())!;
      expect(Math.round(svg.width)).toBe(20);
    }
    const xs = await header.locator("button,a").evaluateAll((els) => els.map((e) => { const r = e.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.right)]; }));
    expect(Math.min(...xs.map((x) => x[0]))).toBeGreaterThanOrEqual(0);
    // the account, switch and logout buttons sit side by side (at most 8px between targets), all in the left half
    const own = xs.slice(-3).sort((a, b) => a[0] - b[0]);
    expect(own[1][0] - own[0][1]).toBeLessThanOrEqual(8); expect(own[2][0] - own[1][1]).toBeLessThanOrEqual(0);
    expect(own[2][1]).toBeLessThanOrEqual(width / 2);
  });
  test(`HF2 the five bottom items have the same width, icon box and label size at ${width}`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width, height: 800 });
    await loginAs("owner"); await go("/staff/reservations");
    const items = page.getByTestId("bottom-tabs").locator("> a, > button");
    await expect(items).toHaveCount(5);
    const rects = await items.evaluateAll((els) => els.map((e) => { const r = e.getBoundingClientRect(); const ib = e.querySelector("span")!.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height), top: Math.round(r.top), iw: Math.round(ib.width), ih: Math.round(ib.height), icy: Math.round(ib.top - r.top), fs: getComputedStyle(e.querySelectorAll("span")[1]).fontSize }; }));
    for (const r of rects) { expect(r.w).toBe(rects[0].w); expect(r.top).toBe(rects[0].top); expect(r.iw).toBe(56); expect(r.ih).toBe(28); expect(r.icy).toBe(rects[0].icy); expect(r.fs).toBe("12px"); }
    expect(rects[0].w).toBeGreaterThanOrEqual(Math.floor(width / 5) - 1);
  });
}
test("HF3 the current page's item is marked by a tinted pill, in both themes", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await loginAs("owner"); await go("/staff/reservations");
  for (const theme of ["light", "dark"]) {
    await page.evaluate((t) => { document.documentElement.dataset.theme = t; }, theme);
    const nav = page.getByTestId("bottom-tabs");
    const pill = nav.locator('[data-active="true"]');
    await expect(pill).toHaveCount(1);
    const bgs = await nav.locator("> a, > button").evaluateAll((els) => els.map((e) => getComputedStyle(e.querySelector("span")!).backgroundColor));
    expect(bgs.filter((b) => b !== "rgba(0, 0, 0, 0)").length).toBe(1);
  }
});
test("HF4 the day/night switch changes the theme, says which mode it will switch to, and is remembered after a reload", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await page.emulateMedia({ colorScheme: "dark" });
  await loginAs("owner"); await go("/staff/reservations");
  const html = page.locator("html"); const toggle = page.getByTestId("theme-toggle");
  await expect(html).toHaveAttribute("data-theme", "dark");
  await expect(toggle).toHaveAccessibleName("التحويل إلى الوضع النهاري");
  await toggle.click();
  await expect(html).toHaveAttribute("data-theme", "light");
  await expect(toggle).toHaveAccessibleName("التحويل إلى الوضع الليلي");
  await page.reload();
  await expect(html).toHaveAttribute("data-theme", "light");
  await page.getByTestId("theme-toggle").click();
  await expect(html).toHaveAttribute("data-theme", "dark");
});
test("HF5 nothing runs off the screen at 195 with the extra header button, and the last row of the reservations page clears the bar at 360", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 195, height: 700 });
  await loginAs("owner"); await go("/staff/reservations");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.setViewportSize({ width: 360, height: 700 });
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  const nav = (await page.getByTestId("bottom-tabs").boundingBox())!;
  const last = (await page.locator("main").evaluate((m) => { const k = [...m.querySelectorAll("*")].filter((e) => e.getBoundingClientRect().height > 0); return Math.max(...k.map((e) => e.getBoundingClientRect().bottom)); }));
  expect(last).toBeLessThanOrEqual(nav.y + 1);
});
