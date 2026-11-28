/** Hub tab strips on a phone: a strip wider than the screen fades the side with more tabs; a strip that fits is never dimmed (invented demo data only). */
import { test, expect } from "./fixtures";

const read = (nav: import("@playwright/test").Locator) => nav.evaluate((e) => ({ over: e.scrollWidth > e.clientWidth + 2, l: (e as HTMLElement).style.getPropertyValue("--fade-l"), r: (e as HTMLElement).style.getPropertyValue("--fade-r"), mask: getComputedStyle(e).maskImage }));

test("a hub strip that overflows fades one side, scrolling moves the fade, and a strip that fits has none", async ({ page, loginAs }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await loginAs("owner");
  await page.goto("/#/staff/payments", { waitUntil: "networkidle" });
  const nav = page.getByTestId("hub-tabs");
  await expect(nav).toBeVisible();
  const a = await read(nav);
  expect(a.over).toBe(true);
  expect([a.l, a.r].filter((x) => x === "24px")).toHaveLength(1);              // exactly one side has more tabs
  expect(a.mask).not.toBe("none");
  await nav.evaluate((e) => { e.scrollLeft = e.scrollLeft === 0 ? -e.scrollWidth : 0; e.dispatchEvent(new Event("scroll")); });
  await expect.poll(async () => { const b = await read(nav); return b.l + "|" + b.r; }).not.toBe(a.l + "|" + a.r);   // the fade moved to the other side
  await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
  const fit = await read(page.getByTestId("hub-tabs"));
  expect(fit.over).toBe(false);
  expect(fit.l).toBe("0px"); expect(fit.r).toBe("0px");                        // nothing dimmed when the tabs fit
});
