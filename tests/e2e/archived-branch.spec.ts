/**
 * Plan item 7.2 (O5 «الفرع المؤرشف»): an archived branch never appears in a selection list — «ومنها المنتجات».
 * The owner creates a branch and archives it with a reason from /admin/branches; after that:
 *  - /admin/products does not offer it among the availability switches, the active branches stay;
 *  - the staff branch picker does not list it;
 *  - the management screen still finds it behind «إظهار المؤرشف» (archive keeps the history).
 * Descriptive names without a letter code, so no acceptance-library prefix is needed.
 */
import { test, expect } from "./fixtures";

const NAME = "فرع الاختبار المؤرشف";

async function createAndArchiveBranch(page: import("@playwright/test").Page, go: (p: string) => Promise<void>) {
  await go("/admin/branches");
  await page.getByRole("button", { name: "فرع جديد" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.getByLabel("الاسم العربي").fill(NAME);
  await dlg.getByLabel("الاسم الإنجليزي").fill("Archived Test Branch");
  await dlg.getByRole("button", { name: "حفظ" }).click();
  await expect(dlg).toBeHidden();
  await expect(page.getByRole("heading", { name: NAME })).toBeVisible();
  await page.getByRole("button", { name: `تعديل ${NAME}` }).click();
  await dlg.getByRole("button", { name: "أرشفة" }).click();
  await dlg.getByLabel(/سبب الأرشفة/).fill("اختبار قبول 7.2");
  await dlg.getByRole("button", { name: "تأكيد الأرشفة" }).click();
  await expect(dlg).toBeHidden();
  await expect(page.getByRole("heading", { name: NAME })).toBeHidden();
}

test.describe("the archived branch in selection lists (7.2)", () => {
  test("the products screen does not offer the archived branch, and the picker does not list it", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await createAndArchiveBranch(page, go);

    await go("/admin/products");
    const switches = page.getByTestId("product-card").first().getByRole("switch");
    await expect(switches.first()).toBeVisible();
    await expect(switches.filter({ hasText: NAME })).toHaveCount(0);
    // the two active branches are still there to choose
    await expect(switches.filter({ hasText: "فرع الرياض" })).toHaveCount(1);
    await expect(switches.filter({ hasText: "فرع جدة" })).toHaveCount(1);

    const picker = page.locator("select").filter({ hasText: "فرع الرياض" }).first();
    await expect(picker.locator("option", { hasText: NAME })).toHaveCount(0);
  });

  test("the management screen still shows the archived branch behind «إظهار المؤرشف»", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await createAndArchiveBranch(page, go);
    await expect(page.getByRole("heading", { name: NAME })).toBeHidden();
    await page.getByText("إظهار المؤرشف").click();
    await expect(page.getByRole("heading", { name: NAME })).toBeVisible();
  });
});
