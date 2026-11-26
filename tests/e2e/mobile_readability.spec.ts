/** 390px readability proofs on the demo (invented data): cash ledger lines, payments reference, hub tab strip. */
import { test, expect } from "./fixtures";

test.describe("mobile readability (390px)", () => {
  test.beforeEach(async ({ page }) => { await page.setViewportSize({ width: 390, height: 844 }); });

  test("MOBLED the cash ledger on a phone is one compact card per movement: what and when on top, the amount and the balance together, no empty labels, no sideways scroll", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/ledger", { waitUntil: "networkidle" });
    const cards = page.getByTestId("ledger-card");
    if (await cards.count() === 0) { const sel = page.locator("select").first(); const n = await sel.locator("option").count(); for (let i = 0; i < n && await cards.count() === 0; i++) { await sel.selectOption({ index: i }); await page.waitForTimeout(500); } }
    await expect(cards.first()).toBeVisible();
    expect(await page.locator("body").evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    await expect(page.getByTestId("ledger-lines")).toBeHidden();       // the wide table is not what a phone shows
    const m = await cards.first().evaluate((li) => {
      const box = li.getBoundingClientRect(); const amt = li.querySelector('[data-testid="ledger-card-amount"]') as HTMLElement;
      const a = amt.getBoundingClientRect();
      return { fits: box.left >= 0 && box.right <= innerWidth + 1, amountInside: a.left >= box.left && a.right <= box.right, amountText: (amt as HTMLElement).innerText, height: box.height, text: (li as HTMLElement).innerText };
    });
    expect(m.fits).toBe(true); expect(m.amountInside).toBe(true);
    expect(m.amountText).toMatch(/^[+−]/);                              // a signed amount, never a bare empty «داخل/خارج» pair
    expect(m.text).toContain("ر.س");                                    // the currency is always on the amount
    expect(m.text).toContain("الرصيد بعد الحركة");                      // the running balance stays on every movement
    expect((m.text.match(/داخل|خارج/g) ?? []).length).toBe(1);          // one direction chip, never an empty in/out pair
    expect(m.text).not.toMatch(/البيان: —|\s—\s/);                    // an empty statement prints nothing, not a dash
    expect(m.height).toBeLessThan(170);                                 // compact: the scattered 2-column card was ~260px
  });

  for (const w of [390, 195]) test(`MOBCARD ${w}px: no two status chips of an arrival card overlap`, async ({ page, loginAs }) => {
    await page.setViewportSize({ width: w, height: 844 });
    await loginAs("supervisor");
    await page.goto("/#/staff/arrivals", { waitUntil: "networkidle" });
    const cards = page.locator('a[href*="/staff/reservations/"]');
    await expect(cards.first()).toBeVisible();
    const bad = await cards.evaluateAll((els) => els.flatMap((el) => {
      const bs = [...el.querySelectorAll(".badge")].map((b) => b.getBoundingClientRect()).filter((r) => r.width > 0);
      const out: string[] = [];
      for (let i = 0; i < bs.length; i++) for (let j = i + 1; j < bs.length; j++) { const a = bs[i], b = bs[j]; if (a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1) out.push(`${i}/${j}`); }
      return out;
    }));
    expect(bad).toEqual([]);
  });

  test("MOBPAY a reservation code in the payments list stays on one line", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/payments", { waitUntil: "networkidle" });
    const codes = page.locator("main p.font-mono").filter({ hasText: /^R-/ });
    await expect(codes.first()).toBeVisible();
    const n = await codes.count();
    for (let i = 0; i < Math.min(n, 8); i++) {
      const h = await codes.nth(i).evaluate((e) => ({ h: e.getBoundingClientRect().height, lh: parseFloat(getComputedStyle(e).lineHeight) }));
      expect(h.h).toBeLessThan(h.lh * 1.6);   // one line
    }
  });

  test("MOBTAB the finance tab strip scrolls and shows an edge cue", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/payments", { waitUntil: "networkidle" });
    const nav = page.getByTestId("hub-tabs");
    await expect(nav).toBeVisible();
    const m = await nav.evaluate((e) => ({ sw: e.scrollWidth, cw: e.clientWidth, bg: getComputedStyle(e).backgroundImage }));
    expect(m.sw).toBeGreaterThan(m.cw);
    expect(m.bg).toContain("gradient");
  });
  test("MOBZOOM at 200% text the staff shell reflows: no sideways scroll, the code alert text is a wide block (not a word-per-line column), the header stays under 160px, the last ledger card clears the bottom bar", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/ledger", { waitUntil: "networkidle" });
    await page.evaluate(() => { document.documentElement.style.fontSize = "200%"; });
    await page.waitForTimeout(300);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    const alert = page.getByTestId("keybox-alert");
    if (await alert.count()) { const w = await alert.locator("span.leading-relaxed").first().evaluate((e) => e.getBoundingClientRect().width); expect(w).toBeGreaterThan(390 * 0.6); }
    expect(await page.locator("header").first().evaluate((e) => e.getBoundingClientRect().height)).toBeLessThan(160);
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await page.waitForTimeout(200);
    const gap = await page.evaluate(() => { const c = [...document.querySelectorAll('[data-testid="ledger-card"]')].pop() as HTMLElement | undefined; const nav = document.querySelector("nav.fixed, nav[class*='fixed']") as HTMLElement | null; return { card: c ? c.getBoundingClientRect().bottom : 0, nav: nav ? nav.getBoundingClientRect().top : innerHeight }; });
    expect(gap.card).toBeLessThanOrEqual(gap.nav);
    const tabs = await page.getByTestId("bottom-tabs").evaluate((e) => [...e.children].map((c) => { const b = c.getBoundingClientRect(); return b.left >= -1 && b.right <= innerWidth + 1 && b.bottom <= innerHeight + 1 && b.width > 0; }));
    expect(tabs.length).toBeGreaterThanOrEqual(5); expect(tabs.every(Boolean)).toBe(true);   // every destination, «المزيد» included, is on screen: no hidden scroll strip
  });
});
