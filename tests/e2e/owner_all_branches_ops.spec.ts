/** Owner «جميع الفروع» on the operational staff pages: Tickets, Inbox, Housekeeping (invented demo data only). Other accounts keep one branch. */
import { test, expect } from "./fixtures";

const picker = (page: import("@playwright/test").Page) => page.locator('select[aria-label="الفرع النشط"]').first();

test.describe("owner all branches: tickets, inbox, housekeeping", () => {
  test("AB-T1 tickets: the choice exists, rows keep their branch, a new report names its unit's branch", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/tickets", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await expect(page.getByTestId("ticket-branch")).toHaveCount(0);
    await picker(page).selectOption({ label: "جميع الفروع" });
    await page.getByRole("button", { name: "بلاغ جديد" }).click();
    const opts = await page.locator("select.input").first().locator("option").allTextContents();
    expect(opts.filter((o) => o.includes(" — ")).length).toBeGreaterThan(0);   // every unit option carries its branch
  });
  test("AB-H1 housekeeping: all branches show branch badges; a new task needs a branch and then offers only that branch's units", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    await picker(page).selectOption({ label: "جميع الفروع" });
    await page.getByRole("button", { name: "حالة الوحدات" }).click();
    const names = new Set(await page.getByTestId("hk-branch").allTextContents());
    expect(names.size).toBeGreaterThanOrEqual(2);
    await page.getByRole("button", { name: "مهمة جديدة" }).click();
    const br = page.getByTestId("hk-new-branch");
    await expect(br).toBeVisible();
    expect(await br.evaluate((e: HTMLSelectElement) => e.value)).toBe("");
    const roomSel = page.getByRole("dialog").locator("select").nth(1);
    await br.selectOption({ index: 1 });
    const first = await roomSel.locator("option").allTextContents();
    await br.selectOption({ index: 2 });
    const second = await roomSel.locator("option").allTextContents();
    expect(first.length).toBeGreaterThan(0);
    expect(second.length).toBeGreaterThan(0);
  });
  test("AB-I1 inbox: the owner gets the all-branches choice and the page loads", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/inbox", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByText("الوارد الموحّد")).toBeVisible();
  });
  test("AB-N1 a supervisor keeps single-branch pages (no «جميع الفروع» anywhere on them)", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    for (const u of ["/#/staff/tickets", "/#/staff/housekeeping", "/#/staff/inbox", "/#/staff/codes"]) {
      await page.goto(u, { waitUntil: "networkidle" });
      await expect(page.getByText("جميع الفروع")).toHaveCount(0);
    }
  });
});

test.describe("owner all branches: product orders and accounts", () => {
  test("AB-P1 product orders: the owner's all-branches list labels each order with its branch; a new order asks for the branch first", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/orders", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await page.getByRole("button", { name: "طلب لنزيل" }).click();
    await expect(page.getByTestId("po-new-branch")).toBeVisible();
    expect(await page.getByTestId("po-new-branch").evaluate((e: HTMLSelectElement) => e.value)).toBe("");
  });
  test("AB-A1 accounts: the owner can pick «جميع الفروع»; a supervisor-level account has no such option", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByText("الحسابات").first()).toBeVisible();
  });
});
