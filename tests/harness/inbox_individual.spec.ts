/**
 * LOCAL harness proof: the REAL Inbox page (demo build + injected page_access, see vite.individual.config.ts) rendered for
 * individual-mode accounts. Bound: the demo backend writes by the legacy rule, so this proves the UI affordances only; no
 * message is sent (the send button is never clicked). Server enforcement is proven by SQL/HTTP tests, not here.
 */
import { test, expect } from "@playwright/test";
const SHOTS = process.env.SHOTS_DIR ?? "/downloads/inbox-individual-shots";
const g = (o: Record<string, boolean>) => ({ mode: "individual", revision: 1, sensitive: [], home_page: null, pages: { "/staff/inbox": o, "/staff/reservations": { view: true } } });
const cases: { name: string; grants: Record<string, boolean>; route: boolean; reply: boolean; take: boolean }[] = [
  { name: "view-only", grants: { view: true }, route: true, reply: false, take: false },
  { name: "view-add", grants: { view: true, add: true }, route: true, reply: true, take: false },
  { name: "view-edit", grants: { view: true, edit: true }, route: true, reply: false, take: true },
  { name: "view-add-edit", grants: { view: true, add: true, edit: true }, route: true, reply: true, take: true },
  { name: "no-view", grants: { view: false, add: false, edit: false }, route: false, reply: false, take: false },
];
for (const c of cases) {
  test(`individual ${c.name}`, async ({ page }) => {
    const errs: string[] = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.addInitScript((v) => localStorage.setItem("__harness_page_access", v), JSON.stringify(g(c.grants)));
    await page.goto("/#/staff/login", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: "مدير الفرع" }).click();
    await page.waitForURL(/#\/(staff|admin)\//, { timeout: 15_000 });
    await page.goto("/#/staff/inbox", { waitUntil: "networkidle" }); await page.waitForTimeout(500);
    const input = page.getByPlaceholder(/اكتب ردًا|استلم المحادثة أولًا/);
    if (!c.route) {
      await page.waitForTimeout(500);
      await expect(page.getByText("هذه الصفحة غير متاحة لدورك")).toBeVisible(); await expect(input).toHaveCount(0);
      await page.screenshot({ path: `${SHOTS}/${c.name}.png` }); expect(errs).toEqual([]); return;
    }
    const first = page.locator("button", { hasText: /محادثة|واتساب|شاشة/ }).first();
    await expect(first).toBeVisible();
    await first.click();
    await expect(input).toBeVisible();
    const send = page.getByTestId("inbox-send");
    const take = page.getByRole("button", { name: /استلام المحادثة|إعادة للمساعد/ });
    if (c.reply) { await expect(input).toBeEnabled(); await input.fill("x"); await expect(send).toBeEnabled(); }
    else { await expect(input).toBeDisabled(); await expect(send).toBeDisabled(); }
    if (c.take) await expect(take.first()).toBeVisible(); else await expect(take).toHaveCount(0);
    await page.screenshot({ path: `${SHOTS}/${c.name}.png` });
    expect(errs).toEqual([]);
  });
}
