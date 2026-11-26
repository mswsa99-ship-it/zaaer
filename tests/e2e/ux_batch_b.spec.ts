/** UX batch B: touch targets, smallest text and card length on a phone (390). Measured, not assumed. */
import { test, expect } from "./fixtures";

test("BATCHB1 phone: buttons, chips, tabs and selects in the page are at least 44px tall (rooms, reports, reservations)", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner");
  for (const p of ["/staff/reservations", "/staff/rooms", "/staff/tickets"]) {
    await go(p);
    const small = await page.evaluate(() => [...document.querySelectorAll("main a,main button,main select,main [role=tab]")]
      .map((e) => ({ t: (e.textContent || "").trim().slice(0, 24), h: e.getBoundingClientRect().height, w: e.getBoundingClientRect().width }))
      .filter((x) => x.h > 0 && x.w > 0 && x.h < 43.5));
    expect(small, p).toEqual([]);
  }
});

test("BATCHB2 phone: reservation cards and the room board use no text under 12px", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner");
  for (const p of ["/staff/reservations", "/staff/rooms"]) {
    await go(p);
    const tiny = await page.evaluate(() => [...document.querySelectorAll("main *")].filter((e) => e.children.length === 0 && (e.textContent || "").trim() && e.getBoundingClientRect().width > 0)
      .map((e) => ({ t: (e.textContent || "").trim().slice(0, 20), f: parseFloat(getComputedStyle(e).fontSize) })).filter((x) => x.f < 12));
    expect(tiny, p).toEqual([]);
  }
});

test("BATCHB3 phone: a reservation card is shorter than before (was 377px) and the page does not scroll sideways", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner"); await go("/staff/reservations");
  const m = await page.evaluate(() => ({ rows: [...document.querySelectorAll(".res-table tbody tr")].map((r) => r.getBoundingClientRect().height), sw: document.documentElement.scrollWidth }));
  expect(m.rows.length).toBeGreaterThan(5);
  expect(Math.min(...m.rows)).toBeLessThan(330);
  expect(m.sw).toBeLessThanOrEqual(390);
});
