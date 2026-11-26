/** Small clarity items (demo build only, not live): an inactive unit is tagged from its is_active value; reservation «فتح» links are named by reservation. */
import { test, expect } from "./fixtures";
const RIYADH = "00000000-0000-0000-0000-000000000010";
const JEDDAH = "00000000-0000-0000-0000-000000000012";
test("PS1 the inactive tag appears exactly on the cards whose room is inactive, and on no active card", async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go("/staff/rooms");
  const pick = page.getByLabel("الفرع النشط");
  const r: Array<{ dim: boolean; tag: boolean }> = [];
  for (const b of [RIYADH, JEDDAH]) {
    await pick.selectOption(b);
    await expect(page.getByTestId("unit-card").first()).toBeVisible(); await page.waitForTimeout(700);
    r.push(...await page.evaluate(() => Array.from(document.querySelectorAll('[data-testid="unit-card"]')).map((c) => ({ dim: c.className.includes("opacity-60"), tag: !!c.querySelector('[data-testid="unit-inactive"]') }))));
    if (b === RIYADH) await page.screenshot({ path: "/tmp/proof/ps1-rooms-riyadh.png" });
  }
  expect(r.length).toBeGreaterThan(0);
  expect(r.some((x) => x.tag)).toBe(true);                    // the demo has one inactive unit in this branch
  for (const x of r) expect(x.tag).toBe(x.dim);               // tag if and only if the card is dimmed for is_active=false
  await page.screenshot({ path: "/tmp/proof/ps1-rooms.png" });
});
test("PS2 each reservation row keeps both links, and the «فتح» link names its reservation", async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go("/staff/reservations"); await page.waitForTimeout(800);
  const rows = await page.evaluate(() => Array.from(document.querySelectorAll('[data-testid="reservation-row"]')).slice(0, 5).map((tr) => ({ stops: Array.from(tr.querySelectorAll<HTMLAnchorElement>("a")).length, label: Array.from(tr.querySelectorAll("a")).pop()?.getAttribute("aria-label") ?? "", ref: tr.querySelector("a")?.textContent?.trim() ?? "" })));
  expect(rows.length).toBeGreaterThan(0);
  for (const r of rows) { expect(r.stops).toBe(2); expect(r.label).toBe(`فتح الحجز ${r.ref}`); }
  expect(new Set(rows.map((r) => r.label)).size).toBe(rows.length);
});
