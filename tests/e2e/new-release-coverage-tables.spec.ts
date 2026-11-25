/**
 * Plan 6.8 / mobile usability: on a phone a table scrolls sideways with whole words instead of breaking letter by
 * letter. Phone width only (the mobile project). Synthetic demo data.
 */
import { test, expect } from "./fixtures";


/* Mobile: a table never breaks a word into letter fragments; it scrolls sideways instead. */
const TABLE_ROUTES = ["/admin/audit-logs", "/admin/finance", "/staff/reservations", "/admin/reservations", "/staff/ledger", "/staff/payments", "/admin/guests", "/staff/bank", "/admin/usage", "/admin/reports", "/staff/expenses", "/admin/staff", "/admin/rooms", "/staff/codes", "/admin/platform-payouts"];
for (const path of TABLE_ROUTES) {
  test(`new-release-coverage mobile tables keep words whole: ${path}`, async ({ page, loginAs, go }, info) => {
    test.skip(info.project.name !== "mobile", "phone width only");
    await loginAs("owner");
    await go(path);
    await page.waitForTimeout(600);
    const broken = await page.evaluate(() => {
      const out: string[] = [];
      const probe = document.createElement("span");
      probe.style.cssText = "position:absolute;visibility:hidden;white-space:nowrap;left:-9999px";
      document.body.appendChild(probe);
      document.querySelectorAll<HTMLElement>("table td, table th").forEach((c) => {
        const r = c.getBoundingClientRect(); if (!r.width || !r.height) return;
        const cs = getComputedStyle(c);
        probe.style.font = cs.font; probe.style.letterSpacing = cs.letterSpacing;
        const inner = c.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
        const texts: string[] = []; const tw = document.createTreeWalker(c, NodeFilter.SHOW_TEXT); while (tw.nextNode()) texts.push(tw.currentNode.textContent || "");
        const text = texts.join(" ");
        for (const w of text.split(/[\s-]+/)) {
          if (w.length < 2) continue; // a hyphenated id may wrap at its hyphens; a word never splits mid-letter
          probe.textContent = w;
          if (probe.getBoundingClientRect().width > inner + 1) { out.push(w.slice(0, 20)); break; }
        }
      });
      probe.remove();
      return out;
    });
    expect(broken, `${path}: words wider than their cell`).toEqual([]);
  });
}
