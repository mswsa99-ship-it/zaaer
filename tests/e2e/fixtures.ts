/**
 * Shared Playwright fixtures for the demo build.
 *
 * - `page` is extended so that any uncaught page error or console.error fails the test
 *   (a UI that "works" while throwing in the console is not stable).
 * - `go(path)` navigates the HashRouter app (the demo build uses hash routes).
 * - `loginAs(role)` uses the demo one-click accounts on /staff/login.
 * - `openAssistant()` signs in as a supervisor (once per test) and opens a fresh chat on /admin/assistant — the same
 *   assistant guests reach on WhatsApp (the website itself only shows the branch's WhatsApp QR code).
 * - `ask(question)` sends a message in that chat and returns the last reply.
 */
import { test as base, expect, type Page } from "@playwright/test";

export type DemoRole = "owner" | "manager" | "supervisor" | "finance" | "housekeeping";

export const ROLE_BUTTON: Record<DemoRole, string> = {
  owner: "المالك — كل الصلاحيات",
  manager: "مدير الفرع",
  supervisor: "مشرف الاستقبال",
  finance: "المالية",
  housekeeping: "خدمة الغرف (صلاحيات محدودة)",
};

const IGNORED_CONSOLE = /favicon|fonts\.g(oogleapis|static)|ERR_TUNNEL|net::ERR|Download the React DevTools|third-party cookie/i;

export const test = base.extend<{ errors: string[]; go: (path: string) => Promise<void>; loginAs: (role: DemoRole) => Promise<void>; openAssistant: () => Promise<void>; ask: (q: string) => Promise<string> }>({
  errors: async ({ page }, use) => {
    const errors: string[] = [];
    page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
    page.on("console", (m) => {
      if (m.type() === "error" && !IGNORED_CONSOLE.test(m.text())) errors.push(`console.error: ${m.text().slice(0, 300)}`);
    });
    await use(errors);
    expect(errors, "no uncaught page errors / console errors").toEqual([]);
  },
  go: async ({ page }, use) => {
    await use(async (path: string) => {
      await page.goto(`/#${path}`, { waitUntil: "networkidle" });
      await page.waitForTimeout(250);
    });
  },
  loginAs: async ({ page }, use) => {
    await use(async (role: DemoRole) => {
      await page.goto("/#/staff/login", { waitUntil: "networkidle" });
      await page.getByRole("button", { name: ROLE_BUTTON[role] }).click();
      await page.waitForURL(/#\/(staff|admin)\//, { timeout: 15_000 });
      await page.waitForTimeout(300);
    });
  },
  openAssistant: async ({ page, loginAs }, use) => {
    let signedIn = false;
    await use(async () => {
      if (!signedIn) { await loginAs("supervisor"); signedIn = true; }
      await page.goto("/#/admin/assistant?new=1", { waitUntil: "networkidle" });
      await page.waitForTimeout(250);
    });
  },
  ask: async ({ page }, use) => {
    await use(async (q: string) => {
      const input = page.getByPlaceholder(/اكتب سؤالك|اكتب لموظف/).first();
      const bubbles = page.locator("div.whitespace-pre-line");
      const before = await bubbles.count();
      await input.fill(q);
      await input.press("Enter");
      // guest bubble + assistant reply
      await expect.poll(() => bubbles.count(), { timeout: 15_000 }).toBeGreaterThanOrEqual(before + 2);
      await expect(input).toBeEnabled({ timeout: 15_000 });
      const msgs = await bubbles.allInnerTexts();
      return msgs[msgs.length - 1] ?? "";
    });
  },
});

export { expect };

/** Opens the first reservation row link on the staff reservations list. */
export async function openFirstReservation(page: Page) {
  await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
  const link = page.locator("table a[href*='/staff/reservations/']").first();
  await expect(link).toBeVisible();
  await link.click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  await page.waitForTimeout(400);
}

/** Creates a confirmed reservation through the UI and returns its detail URL. */
export async function createReservation(page: Page, guestName: string, phone: string, opts: { pickRoom?: boolean } = {}) {
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill(guestName);
  await page.getByPlaceholder("05xxxxxxxx").fill(phone);
  await page.waitForTimeout(500);
  if (opts.pickRoom !== false) {
    const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
    const n = await roomSel.locator("option").count();
    if (n > 1) await roomSel.selectOption({ index: 1 });
  }
  await page.getByRole("button", { name: "إنشاء الحجز" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
  await page.waitForTimeout(500);
  return page.url();
}

/** "‏١٬٢٣٤٫٥٠ ر.س.‏" → 1234.5  (ar-SA currency formatting uses Arabic-Indic digits). */
export function parseSar(text: string): number {
  const ascii = text
    .replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))
    .replace(/[٬,]/g, "")
    .replace(/٫/g, ".");
  const m = ascii.match(/-?\d+(?:\.\d+)?/);
  return m ? Number(m[0]) : NaN;
}

/** Reads one cell of the finance grid (label → SAR amount as a number). */
export async function financeCell(page: Page, label: string): Promise<number> {
  // an amount box (AmountBox, B6): the label above, the value below in its own ltr line
  const el = page.locator(`div:has(> :is(p, span):text-is("${label}")) > :is(p, span)[dir=ltr]`).first();
  await expect(el).toBeVisible();
  return parseSar(await el.innerText());
}
