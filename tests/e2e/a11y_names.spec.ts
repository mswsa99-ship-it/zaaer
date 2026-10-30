/**
 * U1 note 13 (WCAG 4.1.2): every visible button, link and field on the staff and admin pages has a name a screen reader
 * can read — its text, an aria-label, or its label.
 */
import { test, expect } from "./fixtures";
const STAFF = ["/staff/dashboard", "/staff/arrivals", "/staff/reservations", "/staff/reservations/new", "/staff/identity-verification", "/staff/payments", "/staff/pos-settlement", "/staff/access-approvals", "/staff/followups", "/staff/platforms", "/staff/day-summary", "/staff/rooms", "/staff/housekeeping", "/staff/codes", "/staff/tickets", "/staff/inbox"];
const ADMIN = ["/admin/dashboard", "/admin/branches", "/admin/room-categories", "/admin/rooms", "/admin/structure", "/admin/facilities", "/admin/task-types", "/admin/services", "/admin/rates", "/admin/availability", "/admin/availability-rules", "/admin/reservations", "/admin/guests", "/admin/finance", "/admin/platform-payouts", "/admin/cash-accounts", "/admin/staff", "/admin/roles", "/admin/booking-sources", "/admin/ai-settings", "/admin/whatsapp", "/admin/payment-providers", "/admin/policies", "/admin/knowledge", "/admin/reports", "/admin/audit-logs", "/admin/usage", "/admin/review", "/admin/integrations", "/admin/assistant", "/admin/data-purge"];
test("NA01 no visible control without a readable name on the staff and admin pages", async ({ page, loginAs, go }) => {
  test.setTimeout(300_000);
  await loginAs("owner");
  const out: string[] = [];
  const paths = [...STAFF, ...ADMIN];
  for (const path of paths) {
    await go(path); await page.waitForTimeout(800);
    const r = await page.evaluate(() => {
      const name = (el: Element) => {
        const a = el.getAttribute("aria-label") || el.getAttribute("title"); if (a) return a.trim();
        const lb = el.getAttribute("aria-labelledby"); if (lb) return lb.split(" ").map((i) => document.getElementById(i)?.textContent ?? "").join(" ").trim();
        if ((el as HTMLInputElement).labels && (el as HTMLInputElement).labels!.length) return Array.from((el as HTMLInputElement).labels!).map((l) => l.textContent).join(" ").trim();
        if (el.tagName === "INPUT" || el.tagName === "SELECT" || el.tagName === "TEXTAREA") return (el.getAttribute("placeholder") ? "" : "");
        return (el.textContent ?? "").trim();
      };
      const vis = (el: Element) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      const bad: string[] = [];
      document.querySelectorAll("button, [role=button], a[href], input:not([type=hidden]), select, textarea").forEach((el) => {
        if (!vis(el)) return;
        if (!name(el)) bad.push(el.outerHTML.slice(0, 160));
      });
      return bad;
    });
    if (r.length) out.push(`## ${path} (${r.length})\n` + r.join("\n"));
  }
  expect(out.join("\n\n")).toBe("");
});
