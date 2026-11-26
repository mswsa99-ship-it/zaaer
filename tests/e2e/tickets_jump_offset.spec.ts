/**
 * Ticket page jump chips: the section heading lands below the sticky top bars (header and alert banners), not under them.
 * Demo build, owner, phone widths. Not a live-site check.
 */
import { test, expect } from "./fixtures";

for (const w of [360, 390]) {
  test.describe(`tickets jump ${w}`, () => {
    test.use({ viewport: { width: w, height: 844 }, hasTouch: true });
    test(`TJ1 both chips leave the heading below the sticky bars ${w}`, async ({ page, loginAs, go }) => {
      await loginAs("owner");
      await go("/staff/tickets");
      for (const [chip, id] of [["طلبات التحويل", "tickets-handoff"], ["البلاغات والصيانة", "tickets-maintenance"]] as const) {
        await page.getByTestId("tickets-jump").getByRole("button", { name: new RegExp(chip) }).click();
        await page.waitForTimeout(400);
        const m = await page.evaluate((sid) => {
          const sec = document.getElementById(sid)!; const h = sec.querySelector("h1,h2,h3")!.getBoundingClientRect();
          const bars = Array.from(document.querySelectorAll<HTMLElement>("*")).filter((e) => getComputedStyle(e).position === "sticky" && e.getBoundingClientRect().top <= 1 && e.getBoundingClientRect().height > 0 && e.getBoundingClientRect().width > 200);
          return { headingTop: h.top, barBottom: Math.max(0, ...bars.map((b) => b.getBoundingClientRect().bottom)), maxScroll: document.documentElement.scrollHeight - innerHeight - scrollY };
        }, id);
        if (m.maxScroll > 4) expect(m.headingTop).toBeGreaterThanOrEqual(m.barBottom - 1);
      }
    });
  });
}
