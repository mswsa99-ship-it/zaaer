/** Room AI phase 1 (founding): RA20-RA27. Runs on the demo build; no model, no network. */
import { test, expect } from "./fixtures";
type Page = import("@playwright/test").Page;
const NEW = "فندق التأسيس التجريبي";

async function newBranch(page: Page, go: (p: string) => Promise<void>) {
  await go("/admin/branches");
  await page.getByRole("button", { name: "فرع جديد" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.getByLabel("الاسم العربي").fill(NEW);
  await dlg.getByLabel("الاسم الإنجليزي").fill("Founding Test");
  await dlg.getByRole("button", { name: "حفظ" }).click();
  await expect(dlg).toBeHidden();
  await go("/admin/room-categories");
  await page.reload({ waitUntil: "networkidle" });
  const sel = page.getByLabel("الفرع النشط", { exact: true }).first();
  await sel.selectOption(await sel.locator("option", { hasText: NEW }).getAttribute("value") as string);
}
async function openFounding(page: Page) {
  await page.getByRole("button", { name: "مساعد العمليات" }).click();
  await page.getByTestId("ops-tab-founding").click();
  await expect(page.getByTestId("roomai-founding")).toBeVisible();
}
const panel = (p: Page) => p.getByTestId("roomai-founding");
/** nothing is ticked by default: the user marks what he read */
async function tickAll(page: Page) { const boxes = panel(page).getByTestId("rfo-draft").getByRole("checkbox"); for (let i = 0; i < await boxes.count(); i++) await boxes.nth(i).check(); }

test.describe("Room AI founding (phase 1)", () => {
  test("RA20 proposing writes nothing; blanks block confirm; confirming adds only ready items to the active branch", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/policies");
    await expect(page.getByText("لا توجد سياسات لهذا الفرع")).toBeVisible();
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    await expect(panel(page).getByTestId("rfo-draft")).toHaveCount(8);
    // still nothing written
    await page.getByRole("button", { name: "إغلاق المساعد" }).click();
    await go("/admin/policies");
    await expect(page.getByText("لا توجد سياسات لهذا الفرع")).toBeVisible();
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    const ready = await panel(page).getByText("جاهز للمراجعة", { exact: true }).count();
    const blank = await panel(page).getByText("يحتاج إكمالك").count();
    expect(blank).toBeGreaterThanOrEqual(5);
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").click();
    await expect(panel(page).getByText("تمت الإضافة")).toHaveCount(ready);
    await page.getByRole("button", { name: "إغلاق المساعد" }).click();
    await go("/admin/policies");
    await expect(page.locator('[data-testid^="policy-"]')).toHaveCount(ready);
  });

  test("RA21 editing a blank unlocks the item; a second proposal skips what already exists", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/policies");
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    const card = panel(page).getByTestId("rfo-draft").filter({ hasText: "الإلغاء" }).first();
    await card.getByRole("button", { name: "تعديل" }).click();
    await card.locator("textarea").fill("الإلغاء مجاني قبل يومين من الوصول وبعدها يُحتسب أول ليلة.");
    await expect(card.getByText("جاهز للمراجعة")).toBeVisible();
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").click();
    await expect(card.getByText("تمت الإضافة")).toBeVisible();
    await panel(page).getByTestId("rfo-propose").click();
    await expect(panel(page).getByTestId("rfo-draft").filter({ hasText: "الإلغاء والتعديل" })).toHaveCount(0);
  });

  test("RA22 a category cannot be added without a price the user typed", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/room-categories");
    await openFounding(page);
    await expect(panel(page).getByTestId("rfo-step-categories")).toHaveAttribute("aria-pressed", "true");
    await panel(page).getByTestId("rfo-propose").click();
    await tickAll(page);
    await expect(panel(page).getByTestId("rfo-confirm")).toBeDisabled();
    const card = panel(page).getByTestId("rfo-draft").first();
    await card.getByRole("button", { name: "تعديل" }).click();
    await card.getByPlaceholder("اكتب المبلغ").fill("250");
    await expect(panel(page).getByTestId("rfo-confirm")).toBeEnabled();
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").click();
    await expect(card.getByText("تمت الإضافة")).toBeVisible();
    await page.getByRole("button", { name: "إغلاق المساعد" }).click();
    await go("/admin/room-categories");
    await expect(page.getByRole("heading", { name: "وحدة مفردة" })).toBeVisible();
  });

  test("RA23 structure: block and floors are created from the answer", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/structure");
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").click();
    await expect(panel(page).getByText("تمت الإضافة")).toBeVisible();
    await page.getByRole("button", { name: "إغلاق المساعد" }).click();
    await go("/admin/structure");
    await expect(page.getByText("المبنى الرئيسي").first()).toBeVisible();
    await expect(page.getByText("الثالث").first()).toBeVisible();
  });

  test("RA24 facilities and task types are added; review then lists remaining gaps", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/facilities");
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").click();
    await expect(panel(page).getByText("تمت الإضافة")).toHaveCount(5);
    await panel(page).getByTestId("rfo-step-task_types").click();
    await panel(page).getByTestId("rfo-propose").click();
    await expect(panel(page).getByTestId("rfo-draft")).toHaveCount(3);
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").click();
    await expect(panel(page).getByText("تمت الإضافة")).toHaveCount(3);   // the fourth, «تنظيف الوحدة وتعقيمها», already exists in the branch and is not proposed
    await panel(page).getByTestId("rfo-review").click();
    await expect(panel(page).getByTestId("rfo-finding").filter({ hasText: "لا توجد سياسات" })).toBeVisible();
    await expect(panel(page).getByTestId("rfo-finding").filter({ hasText: "لا توجد أنواع وحدات" })).toBeVisible();
    await expect(panel(page).getByTestId("rfo-finding").filter({ hasText: "المصلى" })).toHaveCount(0);
  });

  test("RA25 isolation: the other branch's data is untouched and not proposed again", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/policies");
    const before = await page.locator('[data-testid^="policy-"]').count();
    await newBranch(page, go);
    await go("/admin/policies");
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").click();
    await page.getByRole("button", { name: "إغلاق المساعد" }).click();
    await page.getByLabel("الفرع", { exact: true }).first().selectOption({ index: 0 });
    await expect(page.locator('[data-testid^="policy-"]')).toHaveCount(before);
  });

  test("RA26 only owner and manager see the founding tab", async ({ page, loginAs }) => {
    await loginAs("housekeeping");
    await page.getByRole("button", { name: "مساعد العمليات" }).click();
    await expect(page.getByTestId("ops-tab-founding")).toHaveCount(0);
  });

  test("RA27 the chat tab still works", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.getByRole("button", { name: "مساعد العمليات" }).click();
    await page.getByRole("button", { name: "ما وضع اليوم؟" }).click();
    await expect(page.locator("div.whitespace-pre-wrap")).toHaveCount(2, { timeout: 15_000 });
  });

  test("RA28 nothing is ticked by default and the full text of each item is on screen before confirming", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/policies");
    await openFounding(page);
    await expect(panel(page).getByText("قوالب جاهزة ثابتة")).toBeVisible();
    await panel(page).getByTestId("rfo-propose").click();
    await expect(panel(page).getByTestId("rfo-draft")).toHaveCount(8);
    expect(await panel(page).getByTestId("rfo-draft").getByRole("checkbox", { checked: true }).count()).toBe(0);
    await expect(panel(page).getByTestId("rfo-confirm")).toBeDisabled();
    const stay = panel(page).getByTestId("rfo-draft").filter({ hasText: "شروط الإقامة" });
    await expect(stay.getByTestId("rfo-content")).toContainText("يُشترط إبراز هوية سارية");   // whole body visible while collapsed
  });

  test("RA29 a double click on confirm writes each item once", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/facilities");
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    await tickAll(page);
    await panel(page).getByTestId("rfo-confirm").dblclick();
    await expect(panel(page).getByText("تمت الإضافة")).toHaveCount(5);
    await page.getByRole("button", { name: "إغلاق المساعد" }).click();
    await go("/admin/facilities");
    await expect(page.getByRole("heading", { name: "المصلى" })).toHaveCount(1);
  });

  test("RA30 switching the branch clears the drafts of the old one", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await newBranch(page, go);
    await go("/admin/room-categories");
    await openFounding(page);
    await panel(page).getByTestId("rfo-propose").click();
    await expect(panel(page).getByTestId("rfo-draft")).not.toHaveCount(0);
    await page.getByRole("button", { name: "إغلاق المساعد" }).click();
    await page.getByLabel("الفرع النشط", { exact: true }).first().selectOption({ index: 0 });
    await openFounding(page);
    await expect(panel(page).getByTestId("rfo-draft")).toHaveCount(0);
  });
});
