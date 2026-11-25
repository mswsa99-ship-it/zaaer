/** 390px readability proofs on the demo (invented data): cash ledger lines, payments reference, hub tab strip. */
import { test, expect } from "./fixtures";

test.describe("mobile readability (390px)", () => {
  test.beforeEach(async ({ page }) => { await page.setViewportSize({ width: 390, height: 844 }); });

  test("MOBLED the cash ledger lines are labelled cards: date, amount and balance visible together, no sideways scroll", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/ledger", { waitUntil: "networkidle" });
    const lines = page.getByTestId("ledger-line");
    if (await lines.count() === 0) { const sel = page.locator("select").first(); const n = await sel.locator("option").count(); for (let i = 0; i < n && await lines.count() === 0; i++) { await sel.selectOption({ index: i }); await page.waitForTimeout(500); } }
    await expect(lines.first()).toBeVisible();
    const m = await page.getByTestId("ledger-lines").evaluate((t) => ({ tableW: t.getBoundingClientRect().width, wrapSW: (t.parentElement as HTMLElement).scrollWidth, wrapCW: (t.parentElement as HTMLElement).clientWidth, view: innerWidth }));
    expect(m.wrapSW).toBeLessThanOrEqual(m.wrapCW + 1);
    expect(m.tableW).toBeLessThanOrEqual(m.view);
    const row = await lines.first().evaluate((tr) => Array.from(tr.querySelectorAll("td")).map((td) => { const r = td.getBoundingClientRect(); return [r.left >= 0, r.right <= innerWidth + 1, (td as HTMLElement).dataset.label]; }));
    for (const [l, r] of row) { expect(l).toBe(true); expect(r).toBe(true); }
    expect(row.map((x) => x[2])).toEqual(expect.arrayContaining(["التاريخ", "الرصيد"]));
  });

  test("MOBACC the trial balance rows are labelled cards at 390px: account and amounts together, no sideways scroll", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
    const rows = page.getByTestId("trial-row");
    await expect(rows.first()).toBeVisible();
    const m = await page.getByTestId("trial-rows").evaluate((t) => ({ wrapSW: (t.parentElement as HTMLElement).scrollWidth, wrapCW: (t.parentElement as HTMLElement).clientWidth }));
    expect(m.wrapSW).toBeLessThanOrEqual(m.wrapCW + 1);
    const row = await rows.first().evaluate((tr) => Array.from(tr.querySelectorAll("td")).map((td) => { const r = td.getBoundingClientRect(); return [r.left >= 0, r.right <= innerWidth + 1, (td as HTMLElement).dataset.label]; }));
    for (const [l, r] of row) { expect(l).toBe(true); expect(r).toBe(true); }
    expect(row.map((x) => x[2])).toEqual(expect.arrayContaining(["الحساب", "آخر الفترة"]));
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
});
